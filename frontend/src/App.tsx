import { For, Show, batch, createMemo, createSignal, onCleanup, onMount } from "solid-js";
import {
  archiveAccount,
  beginCodexLogin,
  codexLoginWithApiKey,
  completeCodexLogin,
  getAccounts,
  getEmbeddedBootstrapState,
  getRemainingCreditsForAccount,
  getSavedTheme,
  importCurrentAccount,
  listenForCodexCallback,
  moveAccount,
  removeAccount,
  saveEmbeddedBootstrapState,
  saveTheme,
  stopCodexCallbackListener,
  switchAccount,
  unarchiveAccount,
  type AccountSummary,
  type AccountBucket,
  type AccountsView,
  type BrowserLoginStart,
  type CreditsInfo,
} from "./lib/codexAuth";
import "./App.css";

type CreditsByAccount = Record<string, CreditsInfo | undefined>;

type Theme = "light" | "dark";
const SHOW_DESKTOP_TOP_BAR = import.meta.env.VITE_SHOW_WINDOW_BAR !== "0";
const QUOTA_EPSILON = 0.0001;
const DRAG_SELECT_LOCK_CLASS = "drag-select-lock";
const AUTO_ARCHIVE_ZERO_QUOTA = true;
const AUTO_UNARCHIVE_NON_ZERO_QUOTA = true;
const AUTO_SWITCH_AWAY_FROM_DEPLETED_OR_FROZEN = true;

type BridgeResult<T> = {
  ok: boolean;
  value?: T;
  error?: string;
};

const isDesktopBridgeRuntime = (): boolean => {
  if (typeof window === "undefined") {
    return false;
  }

  return typeof window.cm_window_close === "function" || typeof window.webui?.call === "function";
};

const runWindowAction = async <T,>(
  actionNames: string[],
  action: ((...args: never[]) => Promise<T> | T) | undefined,
  ...args: unknown[]
): Promise<T | null> => {
  const parseBridgeResult = (raw: unknown): T | null => {
    if (typeof raw === "string") {
      const trimmed = raw.trim();
      if (trimmed.startsWith("{") || trimmed.startsWith("[")) {
        let parsedJson: unknown;
        try {
          parsedJson = JSON.parse(raw);
        } catch {
          return raw as T;
        }

        if (parsedJson && typeof parsedJson === "object" && "ok" in (parsedJson as Record<string, unknown>)) {
          const parsed = parsedJson as BridgeResult<T>;
          if (!parsed.ok) {
            throw new Error(parsed.error || "Backend bridge call failed.");
          }
          return (parsed.value ?? null) as T | null;
        }
      }
      return raw as T;
    }

    if (raw && typeof raw === "object" && "ok" in (raw as Record<string, unknown>)) {
      const parsed = raw as BridgeResult<T>;
      if (!parsed.ok) {
        throw new Error(parsed.error || "Backend bridge call failed.");
      }
      return (parsed.value ?? null) as T | null;
    }

    return (raw ?? null) as T | null;
  };

  let lastError: string | null = null;
  if (typeof action === "function") {
    try {
      const directRaw = await action(...(args as never[]));
      // For side-effect commands (close/minimize/toggle), many WebUI bindings return
      // `undefined` even when they succeed. Treat that as success and do not re-issue
      // the same action through fallback RPC (which causes lag/double-toggle).
      if (directRaw === undefined) {
        return null;
      }
      return parseBridgeResult(directRaw);
    } catch (error) {
      lastError = error instanceof Error ? error.message : String(error);
    }
  }

  if (!isDesktopBridgeRuntime()) {
    throw new Error(lastError || "Desktop window bridge is unavailable.");
  }

  const webuiCall = window.webui?.call;
  if (typeof webuiCall !== "function") {
    throw new Error(lastError || "WebUI call bridge is unavailable.");
  }

  for (const name of actionNames) {
    try {
      const raw = await webuiCall(name, ...args);
      return parseBridgeResult(raw);
    } catch (error) {
      lastError = error instanceof Error ? error.message : String(error);
    }
  }

  throw new Error(lastError || `Window action failed: ${actionNames.join(", ")}`);
};

const windowFullscreenGetter = () => window.cm_window_is_fullscreen;
const windowFullscreenToggler = () => window.cm_window_toggle_fullscreen;

const nowEpoch = (): number => Math.floor(Date.now() / 1000);

const formatEpoch = (epoch: number | null | undefined): string => {
  if (!epoch) {
    return "Never";
  }

  return new Date(epoch * 1000).toLocaleString();
};

const numberOrDash = (value: number | null): string => {
  if (value === null) {
    return "-";
  }

  return value.toFixed(2);
};

const percentFromCredits = (credits: CreditsInfo | undefined): number => {
  if (!credits) {
    return 0;
  }

  if (credits.mode === "balance" && credits.available !== null && credits.total === null) {
    return 100;
  }

  const { available, total } = credits;
  if (available === null || total === null || total <= 0) {
    return 0;
  }

  const ratio = (available / total) * 100;
  return Math.max(0, Math.min(100, ratio));
};

const creditsUnit = (credits: CreditsInfo | undefined): string => {
  if (!credits) {
    return "USD";
  }

  return credits.unit;
};

const renderCreditValue = (value: number | null, credits: CreditsInfo | undefined): string => {
  const amount = numberOrDash(value);
  if (amount === "-") {
    return amount;
  }

  const unit = creditsUnit(credits);
  return unit === "%" ? `${amount}%` : `${amount} ${unit}`;
};

const percentOrDash = (value: number | null): string => {
  if (value === null) {
    return "-";
  }

  return `${value.toFixed(1)}%`;
};

const percentWidth = (value: number | null): number => {
  if (value === null) {
    return 0;
  }

  return Math.max(0, Math.min(100, value));
};

const quotaRemainingPercent = (credits: CreditsInfo | undefined): number | null => {
  if (!credits || credits.status !== "available") {
    return null;
  }

  if (credits.isPaidPlan) {
    const windows = [credits.weeklyRemainingPercent, credits.hourlyRemainingPercent].filter(
      (value): value is number => value !== null,
    );

    if (windows.length === 0) {
      return null;
    }

    return Math.min(...windows);
  }

  return percentFromCredits(credits);
};

const hasZeroQuotaRemaining = (credits: CreditsInfo | undefined): boolean => {
  const remaining = quotaRemainingPercent(credits);
  return remaining !== null && remaining <= QUOTA_EPSILON;
};

const hasNonZeroQuotaRemaining = (credits: CreditsInfo | undefined): boolean => {
  const remaining = quotaRemainingPercent(credits);
  return remaining !== null && remaining > QUOTA_EPSILON;
};

const accountTitle = (account: AccountSummary): string => {
  return account.label || account.email || account.accountId || account.id;
};

const accountMainIdentity = (account: AccountSummary): string => {
  return account.accountId || account.id;
};

const accountMetaLine = (account: AccountSummary): string | null => {
  const title = accountTitle(account);
  const id = account.accountId || account.id;
  if (id !== title) {
    return id;
  }
  return null;
};

const applyTheme = (theme: Theme) => {
  document.documentElement.dataset.theme = theme;
  localStorage.setItem("codex-manager-theme", theme);
};

const IconPlus = () => (
  <svg viewBox="0 0 24 24" aria-hidden="true">
    <path d="M12 5v14M5 12h14" />
  </svg>
);

const IconMoon = () => (
  <svg viewBox="0 0 24 24" aria-hidden="true">
    <path d="M20 14.4A8.5 8.5 0 1 1 9.6 4 7.1 7.1 0 0 0 20 14.4Z" />
  </svg>
);

const IconSun = () => (
  <svg viewBox="0 0 24 24" aria-hidden="true">
    <circle cx="12" cy="12" r="4" />
    <path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4" />
  </svg>
);

const IconRefresh = () => (
  <svg viewBox="0 0 24 24" aria-hidden="true">
    <g stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M21 12a9 9 0 0 0-9-9 9.75 9.75 0 0 0-6.74 2.74L3 8" />
      <path d="M3 3v5h5" />
      <path d="M3 12a9 9 0 0 0 9 9 9.75 9.75 0 0 0 6.74-2.74L21 16" />
      <path d="M21 21v-5h-5" />
    </g>
  </svg>
);

const IconRefreshing = () => (
  <svg class="icon-rotor" viewBox="0 0 24 24" aria-hidden="true">
    <g stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M21 12a9 9 0 0 0-9-9 9.75 9.75 0 0 0-6.74 2.74L3 8" />
      <path d="M3 3v5h5" />
      <path d="M3 12a9 9 0 0 0 9 9 9.75 9.75 0 0 0 6.74-2.74L21 16" />
      <path d="M21 21v-5h-5" />
    </g>
  </svg>
);

const IconDragHandle = () => (
  <svg viewBox="0 0 24 24" aria-hidden="true">
    <circle cx="8" cy="7" r="1.2" />
    <circle cx="16" cy="7" r="1.2" />
    <circle cx="8" cy="12" r="1.2" />
    <circle cx="16" cy="12" r="1.2" />
    <circle cx="8" cy="17" r="1.2" />
    <circle cx="16" cy="17" r="1.2" />
  </svg>
);

const IconFrost = () => (
  <svg class="icon-frost" viewBox="0 0 100 100" aria-hidden="true">
    <g fill="none" stroke="currentColor" stroke-width="8" stroke-linecap="round" stroke-linejoin="round">
      <g>
        <path d="M50 50V15" />
        <path d="M38 25l12-10 12 10" />
      </g>
      <g transform="rotate(60 50 50)">
        <path d="M50 50V15" />
        <path d="M38 25l12-10 12 10" />
      </g>
      <g transform="rotate(120 50 50)">
        <path d="M50 50V15" />
        <path d="M38 25l12-10 12 10" />
      </g>
      <g transform="rotate(180 50 50)">
        <path d="M50 50V15" />
        <path d="M38 25l12-10 12 10" />
      </g>
      <g transform="rotate(240 50 50)">
        <path d="M50 50V15" />
        <path d="M38 25l12-10 12 10" />
      </g>
      <g transform="rotate(300 50 50)">
        <path d="M50 50V15" />
        <path d="M38 25l12-10 12 10" />
      </g>
      <circle cx="50" cy="50" r="3" fill="currentColor" stroke="none" />
    </g>
  </svg>
);

const IconTrash = () => (
  <svg viewBox="0 0 24 24" aria-hidden="true">
    <path d="M4 7h16" />
    <path d="M9 7V4h6v3" />
    <path d="M7 7l1 13h8l1-13" />
  </svg>
);

const IconClose = () => (
  <svg viewBox="0 0 24 24" aria-hidden="true">
    <path d="M6 6l12 12M18 6 6 18" />
  </svg>
);

const IconMinimize = () => (
  <svg viewBox="0 0 24 24" aria-hidden="true">
    <path d="M5 12h14" />
  </svg>
);

const IconMaximize = () => (
  <svg viewBox="0 0 24 24" aria-hidden="true">
    <rect x="5" y="5" width="14" height="14" />
  </svg>
);

const IconRestore = () => (
  <svg viewBox="0 0 24 24" aria-hidden="true">
    <path d="M8 8h11v11H8z" />
    <path d="M5 5h11v3" />
  </svg>
);

function App() {
  const embeddedState = getEmbeddedBootstrapState();
  const hasEmbeddedState =
    Boolean(embeddedState?.view) || Boolean(embeddedState && Object.keys(embeddedState.usageById).length > 0);

  const [view, setView] = createSignal<AccountsView | null>(embeddedState?.view ?? null);
  const [creditsById, setCreditsById] = createSignal<CreditsByAccount>(embeddedState?.usageById ?? {});
  const [browserStart, setBrowserStart] = createSignal<BrowserLoginStart | null>(null);
  const [apiKeyDraft, setApiKeyDraft] = createSignal("");
  const [theme, setTheme] = createSignal<Theme>(embeddedState?.theme === "dark" ? "dark" : "light");
  const [fullscreen, setFullscreen] = createSignal(false);
  const [addMenuOpen, setAddMenuOpen] = createSignal(false);
  const [isListeningForCallback, setIsListeningForCallback] = createSignal(false);
  const [showDepleted, setShowDepleted] = createSignal(false);
  const [showFrozen, setShowFrozen] = createSignal(false);
  const [draggingAccountId, setDraggingAccountId] = createSignal<string | null>(null);
  const [draggingBucket, setDraggingBucket] = createSignal<AccountBucket | null>(null);
  const [dragHover, setDragHover] = createSignal<{ bucket: AccountBucket; targetId: string | null } | null>(null);
  const [refreshingById, setRefreshingById] = createSignal<Record<string, boolean>>({});
  const [refreshingAll, setRefreshingAll] = createSignal(false);
  const [initializing, setInitializing] = createSignal(!hasEmbeddedState);
  const [busy, setBusy] = createSignal<string | null>(null);
  const [error, setError] = createSignal<string | null>(null);
  const [notice, setNotice] = createSignal<string | null>(null);
  let callbackListenRunId = 0;
  let autoQuotaSyncInFlight = false;
  let persistStateTimer: number | undefined;
  let addMenuRef: HTMLDivElement | undefined;
  let addButtonRef: HTMLButtonElement | undefined;
  let dragPreviewElement: HTMLDivElement | undefined;
  let contentScrollRef: HTMLElement | undefined;

  const activeAccounts = createMemo(
    () => view()?.accounts.filter((account) => !account.archived && !account.frozen) || [],
  );
  const depletedAccounts = createMemo(
    () => view()?.accounts.filter((account) => account.archived && !account.frozen) || [],
  );
  const frozenAccounts = createMemo(
    () => view()?.accounts.filter((account) => account.frozen) || [],
  );
  const addMenuVisible = createMemo(
    () => !initializing() && addMenuOpen(),
  );
  const visibleNotice = createMemo(() => {
    if (initializing()) {
      return null;
    }
    const value = notice();
    if (!value) {
      return null;
    }
    const trimmed = value.trim();
    return trimmed.length > 0 ? trimmed : null;
  });
  const visibleBusy = createMemo(() => {
    if (initializing()) {
      return null;
    }
    const value = busy();
    if (!value) {
      return null;
    }
    const trimmed = value.trim();
    return trimmed.length > 0 ? trimmed : null;
  });

  type RefreshOptions = {
    quiet?: boolean;
    trackAll?: boolean;
    skipAutoSync?: boolean;
  };

  const activeAccountIds = (nextView: AccountsView): string[] =>
    nextView.accounts.filter((account) => !account.archived && !account.frozen).map((account) => account.id);

  const quotaSyncAccountIds = (nextView: AccountsView): string[] => {
    const ids = new Set(activeAccountIds(nextView));

    for (const account of nextView.accounts) {
      if (account.archived && !account.frozen) {
        ids.add(account.id);
      }
    }

    return [...ids];
  };

  const nonFrozenAccountIds = (nextView: AccountsView): string[] =>
    nextView.accounts.filter((account) => !account.frozen).map((account) => account.id);

  const normalizedCreditsCache = (): Record<string, CreditsInfo> => {
    const current = creditsById();
    const next: Record<string, CreditsInfo> = {};
    for (const [accountId, credits] of Object.entries(current)) {
      if (credits) {
        next[accountId] = credits;
      }
    }
    return next;
  };

  const schedulePersistEmbeddedState = () => {
    if (typeof window === "undefined") {
      return;
    }

    if (persistStateTimer !== undefined) {
      window.clearTimeout(persistStateTimer);
    }

    persistStateTimer = window.setTimeout(() => {
      persistStateTimer = undefined;
      const currentView = view();

      void saveEmbeddedBootstrapState({
        theme: theme(),
        autoArchiveZeroQuota: AUTO_ARCHIVE_ZERO_QUOTA,
        autoUnarchiveNonZeroQuota: AUTO_UNARCHIVE_NON_ZERO_QUOTA,
        autoSwitchAwayFromArchived: AUTO_SWITCH_AWAY_FROM_DEPLETED_OR_FROZEN,
        view: currentView,
        usageById: normalizedCreditsCache(),
        savedAt: nowEpoch(),
      }).catch(() => {});
    }, 120);
  };

  const runAction = async <T,>(message: string, action: () => Promise<T>): Promise<T | undefined> => {
    batch(() => {
      setBusy(message);
      setError(null);
      setNotice(null);
    });

    try {
      return await action();
    } catch (actionError) {
      const rendered = actionError instanceof Error ? actionError.message : String(actionError);
      setError(rendered);
      return undefined;
    } finally {
      setBusy(null);
    }
  };

  const setViewState = (nextView: AccountsView) => {
    batch(() => {
      setView(nextView);
      if (nextView.accounts.length === 0) {
        setAddMenuOpen(true);
      }
    });
    schedulePersistEmbeddedState();
  };

  const markRefreshing = (accountIds: string[], refreshing: boolean) => {
    setRefreshingById((previous) => {
      let changed = false;
      let next: Record<string, boolean> | null = null;

      for (const id of accountIds) {
        if (refreshing) {
          if (!previous[id]) {
            next = next || { ...previous };
            next[id] = true;
            changed = true;
          }
        } else if (previous[id]) {
          next = next || { ...previous };
          delete next[id];
          changed = true;
        }
      }

      return changed && next ? next : previous;
    });
  };

  const refreshCreditsForAccounts = async (
    accountIds: string[],
    options: RefreshOptions = {},
  ) => {
    const quiet = options.quiet ?? false;
    const trackAll = options.trackAll ?? false;
    const skipAutoSync = options.skipAutoSync ?? false;

    if (accountIds.length === 0) {
      setCreditsById({});
      return;
    }

    if (!quiet) {
      batch(() => {
        setBusy("Checking remaining credits");
        setError(null);
      });
    }
    if (trackAll) {
      setRefreshingAll(true);
    }
    markRefreshing(accountIds, true);

    try {
      const entries = await Promise.all(
        accountIds.map(async (id) => [id, await getRemainingCreditsForAccount(id)] as const),
      );

      setCreditsById((previous) => {
        const next = { ...previous };

        for (const [id, credits] of entries) {
          next[id] = credits;
        }

        return next;
      });
      schedulePersistEmbeddedState();

      if (!quiet) {
        const failures = entries.filter((entry) => entry[1].status === "error");
        if (failures.length > 0) {
          const first = failures[0][1];
          setError(`Credits check issue: ${first.message}`);
        }
      }
    } catch (creditsError) {
      const rendered = creditsError instanceof Error ? creditsError.message : String(creditsError);
      setError(rendered);
    } finally {
      markRefreshing(accountIds, false);
      if (trackAll) {
        setRefreshingAll(false);
      }
      if (!quiet) {
        setBusy(null);
      }
    }

    if (!skipAutoSync) {
      await syncAutoQuotaPolicies();
    }
  };

  const refreshAccountCredits = async (id: string) => {
    markRefreshing([id], true);
    setError(null);
    try {
      const credits = await getRemainingCreditsForAccount(id);

      setCreditsById((current) => ({
        ...current,
        [id]: credits,
      }));
      schedulePersistEmbeddedState();

      if (credits.status !== "error") {
        setNotice("Credits refreshed.");
      } else {
        setError(`Credits check issue: ${credits.message}`);
      }
    } finally {
      markRefreshing([id], false);
    }

    await syncAutoQuotaPolicies();
  };

  const syncAutoQuotaPolicies = async () => {
    if (autoQuotaSyncInFlight) {
      return;
    }

    const currentView = view();
    if (!currentView) {
      return;
    }

    autoQuotaSyncInFlight = true;
    try {
      let nextView = currentView;
      const cachedCredits = creditsById();
      let changed = false;

      const active = nextView.activeAccountId
        ? nextView.accounts.find((account) => account.id === nextView.activeAccountId) ?? null
        : null;
      if (!active || active.archived || active.frozen) {
        const switchTarget = nextView.accounts.find((account) => !account.archived && !account.frozen);
        if (switchTarget) {
          const switchedView = await switchAccount(switchTarget.id);
          nextView = switchedView;
          setViewState(switchedView);
          changed = true;
        }
      }

      const activeAccountsWithQuota = nextView.accounts.filter((account) => !account.archived && !account.frozen);
      const depletedActiveIds = activeAccountsWithQuota
        .filter((account) => hasZeroQuotaRemaining(cachedCredits[account.id]))
        .map((account) => account.id);

      const activeId = nextView.activeAccountId;
      if (activeId && depletedActiveIds.includes(activeId)) {
        let switchTarget = activeAccountsWithQuota.find(
          (account) =>
            account.id !== activeId &&
            !depletedActiveIds.includes(account.id) &&
            hasNonZeroQuotaRemaining(cachedCredits[account.id]),
        );

        if (!switchTarget) {
          const archivedRecoveryTarget = nextView.accounts.find(
            (account) => account.archived && !account.frozen && hasNonZeroQuotaRemaining(cachedCredits[account.id]),
          );

          if (archivedRecoveryTarget) {
            const restoredView = await unarchiveAccount(archivedRecoveryTarget.id);
            nextView = restoredView;
            setViewState(restoredView);
            changed = true;

            const restoredActive = nextView.accounts.filter((account) => !account.archived && !account.frozen);
            switchTarget = restoredActive.find(
              (account) =>
                account.id !== activeId &&
                hasNonZeroQuotaRemaining(cachedCredits[account.id]),
            );
          }
        }

        if (switchTarget) {
          const switchedView = await switchAccount(switchTarget.id);
          nextView = switchedView;
          setViewState(switchedView);
          changed = true;
        }
      }

      for (const id of depletedActiveIds) {
        const stillActive = nextView.accounts.find(
          (account) => account.id === id && !account.archived && !account.frozen,
        );
        if (!stillActive || !hasZeroQuotaRemaining(cachedCredits[id])) {
          continue;
        }

        const archivedView = await archiveAccount(id, {
          switchAwayFromArchived: AUTO_SWITCH_AWAY_FROM_DEPLETED_OR_FROZEN,
        });
        nextView = archivedView;
        setViewState(archivedView);
        changed = true;
      }

      const recoverableArchivedIds = nextView.accounts
        .filter(
          (account) => account.archived && !account.frozen && hasNonZeroQuotaRemaining(cachedCredits[account.id]),
        )
        .map((account) => account.id);

      for (const id of recoverableArchivedIds) {
        const stillArchived = nextView.accounts.find(
          (account) => account.id === id && account.archived && !account.frozen,
        );
        if (!stillArchived || !hasNonZeroQuotaRemaining(cachedCredits[id])) {
          continue;
        }

        const restoredView = await unarchiveAccount(id);
        nextView = restoredView;
        setViewState(restoredView);
        changed = true;
      }

      if (changed) {
        setNotice("Auto quota sync updated account status.");
      }
    } catch (syncError) {
      const rendered = syncError instanceof Error ? syncError.message : String(syncError);
      setError(rendered);
    } finally {
      autoQuotaSyncInFlight = false;
    }
  };

  const handleRefreshAllCredits = async () => {
    const currentView = view();
    if (!currentView) {
      return;
    }

    const ids = nonFrozenAccountIds(currentView);
    await refreshCreditsForAccounts(ids, { trackAll: true });
    setNotice("All credits refreshed.");
  };

  const handleRefreshDepletedCredits = async () => {
    const ids = depletedAccounts().map((account) => account.id);
    if (ids.length === 0) {
      setNotice("No depleted accounts to refresh.");
      return;
    }

    await refreshCreditsForAccounts(ids);
    setNotice("Depleted account credits refreshed.");
  };

  const refreshAccounts = async (initialLoad = false) => {
    if (!initialLoad) {
      batch(() => {
        setBusy("Loading accounts");
        setError(null);
        setNotice(null);
      });
    } else {
      setError(null);
    }

    try {
      const next = await getAccounts();
      setViewState(next);
      if (!initialLoad) {
        await refreshCreditsForAccounts(quotaSyncAccountIds(next), { quiet: false });
      }
    } catch (actionError) {
      const rendered = actionError instanceof Error ? actionError.message : String(actionError);
      setError(rendered);
    } finally {
      if (!initialLoad) {
        setBusy(null);
      }
    }
  };

  const handleAddChatgptStart = async () => {
    const started = await runAction("Opening Codex login in browser", () => beginCodexLogin());

    if (!started) {
      return;
    }

    setBrowserStart(started);
    setNotice("Browser opened. Listening for callback.");
    if (!isListeningForCallback()) {
      void startCallbackListener();
    }
  };

  const startCallbackListener = async () => {
    const runId = ++callbackListenRunId;
    setIsListeningForCallback(true);
    setBusy("Listening for browser callback");
    setError(null);
    setNotice("Listening for callback. Click again to stop.");

    try {
      const callbackUrl = await listenForCodexCallback();
      if (runId !== callbackListenRunId) {
        return;
      }

      const login = await completeCodexLogin(callbackUrl);
      if (runId !== callbackListenRunId) {
        return;
      }

      setViewState(login.view);
      setBrowserStart(null);
      setApiKeyDraft("");
      if (activeAccountIds(login.view).length > 0) {
        setAddMenuOpen(false);
      }
      setNotice(login.output.length > 0 ? login.output : "ChatGPT login completed.");

      await refreshCreditsForAccounts(quotaSyncAccountIds(login.view), { quiet: true });
    } catch (listenerError) {
      if (runId !== callbackListenRunId) {
        return;
      }

      const rendered = listenerError instanceof Error ? listenerError.message : String(listenerError);
      if (rendered.includes("Callback listener stopped.")) {
        setNotice("Stopped listening for callback.");
      } else if (rendered.includes("No active login session")) {
        setNotice("Listener is running. Start ChatGPT Login when you're ready.");
      } else {
        setError(rendered);
      }
    } finally {
      if (runId === callbackListenRunId) {
        setIsListeningForCallback(false);
        setBusy(null);
      }
    }
  };

  const stopCallbackListener = async () => {
    callbackListenRunId += 1;
    setBusy("Stopping callback listener");

    try {
      await stopCodexCallbackListener();
      setNotice("Stopped listening for callback.");
    } catch (listenerError) {
      const rendered = listenerError instanceof Error ? listenerError.message : String(listenerError);
      setError(rendered);
    } finally {
      setIsListeningForCallback(false);
      setBusy(null);
    }
  };

  const handleToggleCallbackListener = async () => {
    if (isListeningForCallback()) {
      await stopCallbackListener();
      return;
    }

    await startCallbackListener();
  };

  const handleAddApiKey = async () => {
    const apiKey = apiKeyDraft().trim();
    if (!apiKey) {
      setError("Enter an API key in the add account popup first.");
      return;
    }

    const login = await runAction("Saving API key account", () => codexLoginWithApiKey(apiKey));

    if (!login) {
      return;
    }

    setViewState(login.view);
    setApiKeyDraft("");
    if (activeAccountIds(login.view).length > 0) {
      setAddMenuOpen(false);
    }
    setNotice(login.output.length > 0 ? login.output : "API key login completed.");

    await refreshCreditsForAccounts(quotaSyncAccountIds(login.view), { quiet: true });
  };

  const handleImportCurrent = async () => {
    const next = await runAction("Importing current auth.json", () => importCurrentAccount());

    if (!next) {
      return;
    }

    setViewState(next);
    setApiKeyDraft("");
    if (activeAccountIds(next).length > 0) {
      setAddMenuOpen(false);
    }
    setNotice("Imported active Codex auth into managed accounts.");

    await refreshCreditsForAccounts(quotaSyncAccountIds(next), { quiet: true });
  };

  const handleSwitch = async (id: string) => {
    const next = await runAction("Switching account", () => switchAccount(id));

    if (!next) {
      return;
    }

    setViewState(next);
    setNotice("Active Codex account switched.");
    await refreshAccountCredits(id);
  };

  const accountsForBucket = (bucket: AccountBucket): AccountSummary[] => {
    if (bucket === "active") {
      return activeAccounts();
    }
    if (bucket === "depleted") {
      return depletedAccounts();
    }
    return frozenAccounts();
  };

  const isDropBefore = (bucket: AccountBucket, targetId: string): boolean => {
    const current = dragHover();
    return Boolean(current && current.bucket === bucket && current.targetId === targetId);
  };

  const isDropAtEnd = (bucket: AccountBucket): boolean => {
    const current = dragHover();
    return Boolean(current && current.bucket === bucket && current.targetId === null);
  };

  const isDropBucketHovered = (bucket: AccountBucket): boolean => {
    const current = dragHover();
    return Boolean(current && current.bucket === bucket);
  };

  const moveAccountToBucket = async (id: string, bucket: AccountBucket, targetIndex: number) => {
    const next = await runAction("Moving account", () =>
      moveAccount(id, bucket, targetIndex, {
        switchAwayFromMoved: AUTO_SWITCH_AWAY_FROM_DEPLETED_OR_FROZEN,
      }),
    );

    if (!next) {
      return;
    }

    setViewState(next);
    setNotice("Account moved.");
  };

  const resolveDragId = (event: DragEvent): string | null => {
    const inMemory = draggingAccountId();
    if (inMemory) {
      return inMemory;
    }

    const transfer = event.dataTransfer?.getData("text/plain");
    return transfer && transfer.trim().length > 0 ? transfer : null;
  };

  const allowDrop = (event: DragEvent) => {
    event.preventDefault();
    if (event.dataTransfer) {
      event.dataTransfer.dropEffect = "move";
    }
  };

  const setDragHoverTarget = (bucket: AccountBucket, targetId: string | null) => {
    const current = dragHover();
    if (current && current.bucket === bucket && current.targetId === targetId) {
      return;
    }
    setDragHover({ bucket, targetId });
  };

  const accountBucketForId = (accountId: string): AccountBucket | null => {
    const account = view()?.accounts.find((entry) => entry.id === accountId);
    if (!account) {
      return null;
    }
    if (account.frozen) {
      return "frozen";
    }
    if (account.archived) {
      return "depleted";
    }
    return "active";
  };

  const canDropInBucket = (draggedId: string, bucket: AccountBucket): boolean => {
    const sourceBucket = draggingBucket() ?? accountBucketForId(draggedId);
    if (!sourceBucket) {
      return false;
    }
    if (sourceBucket === "depleted" || bucket === "depleted") {
      return sourceBucket === "depleted" && bucket === "depleted";
    }
    return true;
  };

  const handleDragOverBucket = (event: DragEvent, bucket: AccountBucket) => {
    allowDrop(event);
    const draggedId = resolveDragId(event);
    if (!draggedId) {
      setDragHover(null);
      return;
    }
    if (!canDropInBucket(draggedId, bucket)) {
      setDragHover(null);
      if (event.dataTransfer) {
        event.dataTransfer.dropEffect = "none";
      }
      return;
    }
    setDragHoverTarget(bucket, null);
  };

  const handleDragOverAccount = (event: DragEvent, bucket: AccountBucket, targetId: string) => {
    event.stopPropagation();
    allowDrop(event);
    const draggedId = resolveDragId(event);
    if (!draggedId) {
      setDragHover(null);
      return;
    }
    if (!canDropInBucket(draggedId, bucket)) {
      setDragHover(null);
      if (event.dataTransfer) {
        event.dataTransfer.dropEffect = "none";
      }
      return;
    }
    if (draggedId === targetId) {
      setDragHoverTarget(bucket, null);
      return;
    }
    setDragHoverTarget(bucket, targetId);
  };

  const removeDragPreview = () => {
    if (dragPreviewElement?.parentNode) {
      dragPreviewElement.parentNode.removeChild(dragPreviewElement);
    }
    dragPreviewElement = undefined;
  };

  const createDragPreviewElement = (account: AccountSummary): HTMLDivElement => {
    const element = document.createElement("div");
    element.className = "drag-preview";

    const title = document.createElement("div");
    title.className = "drag-preview-title";
    title.textContent = accountTitle(account);

    const meta = accountMetaLine(account);
    const sub = document.createElement("div");
    sub.className = "drag-preview-meta";
    sub.textContent = meta || accountMainIdentity(account);

    element.appendChild(title);
    element.appendChild(sub);
    document.body.appendChild(element);
    return element;
  };

  const resolveEventElement = (target: EventTarget | null): Element | null => {
    if (target instanceof Element) {
      return target;
    }
    if (target instanceof Node) {
      return target.parentElement;
    }
    return null;
  };

  const accountCopySelectionActive = (): boolean => {
    const selection = window.getSelection();
    if (!selection || selection.isCollapsed) {
      return false;
    }

    const isCopyableNode = (node: Node | null): boolean => {
      if (!node) {
        return false;
      }
      const element = node instanceof Element ? node : node.parentElement;
      return Boolean(element?.closest(".account-copyable, .account-main-value"));
    };

    return isCopyableNode(selection.anchorNode) || isCopyableNode(selection.focusNode);
  };

  const dragStartBlocked = (target: EventTarget | null): boolean => {
    const element = resolveEventElement(target);
    if (element?.closest("button, input, select, textarea, a, .account-copyable, .account-main-value")) {
      return true;
    }

    return accountCopySelectionActive();
  };

  const handleDropOnBucket = async (event: DragEvent, bucket: AccountBucket) => {
    event.preventDefault();
    const draggedId = resolveDragId(event);
    document.body.classList.remove(DRAG_SELECT_LOCK_CLASS);
    setDraggingAccountId(null);
    setDraggingBucket(null);
    setDragHover(null);
    removeDragPreview();
    if (!draggedId) {
      return;
    }
    if (!canDropInBucket(draggedId, bucket)) {
      return;
    }

    const accounts = accountsForBucket(bucket).filter((account) => account.id !== draggedId);
    await moveAccountToBucket(draggedId, bucket, accounts.length);
  };

  const handleDropBeforeAccount = async (event: DragEvent, bucket: AccountBucket, targetId: string) => {
    event.preventDefault();
    event.stopPropagation();

    const draggedId = resolveDragId(event);
    document.body.classList.remove(DRAG_SELECT_LOCK_CLASS);
    setDraggingAccountId(null);
    setDraggingBucket(null);
    setDragHover(null);
    removeDragPreview();
    if (!draggedId || draggedId === targetId) {
      return;
    }
    if (!canDropInBucket(draggedId, bucket)) {
      return;
    }

    const accounts = accountsForBucket(bucket).filter((account) => account.id !== draggedId);
    const targetIndex = accounts.findIndex((account) => account.id === targetId);
    if (targetIndex < 0) {
      return;
    }

    await moveAccountToBucket(draggedId, bucket, targetIndex);
  };

  const handleDragStart = (event: DragEvent, account: AccountSummary, bucket: AccountBucket) => {
    if (dragStartBlocked(event.target)) {
      event.preventDefault();
      return;
    }

    const accountId = account.id;
    document.body.classList.add(DRAG_SELECT_LOCK_CLASS);
    setDraggingAccountId(accountId);
    setDraggingBucket(bucket);
    setDragHoverTarget(bucket, null);
    if (event.dataTransfer) {
      event.dataTransfer.effectAllowed = "move";
      event.dataTransfer.setData("text/plain", accountId);
      removeDragPreview();
      dragPreviewElement = createDragPreviewElement(account);
      event.dataTransfer.setDragImage(dragPreviewElement, 24, 18);
    }
  };

  const handleDragEnd = () => {
    document.body.classList.remove(DRAG_SELECT_LOCK_CLASS);
    setDraggingAccountId(null);
    setDraggingBucket(null);
    setDragHover(null);
    removeDragPreview();
  };

  const releaseDragSelectionLock = () => {
    if (!draggingAccountId()) {
      document.body.classList.remove(DRAG_SELECT_LOCK_CLASS);
    }
  };

  const normalizeContentScrollAfterCollapse = (forceTop: boolean) => {
    if (!contentScrollRef) {
      return;
    }

    window.requestAnimationFrame(() => {
      if (!contentScrollRef) {
        return;
      }

      const maxTop = Math.max(0, contentScrollRef.scrollHeight - contentScrollRef.clientHeight);
      const clampedTop = Math.min(contentScrollRef.scrollTop, maxTop);
      if (contentScrollRef.scrollTop !== clampedTop) {
        contentScrollRef.scrollTop = clampedTop;
      }

      if (forceTop) {
        contentScrollRef.scrollTo({ top: 0, behavior: "smooth" });
      }
    });
  };

  const handleToggleDepletedSection = () => {
    const nextVisible = !showDepleted();
    setShowDepleted(nextVisible);
    if (!nextVisible) {
      normalizeContentScrollAfterCollapse(true);
    }
  };

  const handleToggleFrozenSection = () => {
    const nextVisible = !showFrozen();
    setShowFrozen(nextVisible);
    if (!nextVisible) {
      normalizeContentScrollAfterCollapse(false);
    }
  };

  const handleFreeze = async (id: string) => {
    const targetIndex = frozenAccounts().filter((account) => account.id !== id).length;
    await moveAccountToBucket(id, "frozen", targetIndex);
  };

  const handleThaw = async (id: string) => {
    const targetIndex = activeAccounts().filter((account) => account.id !== id).length;
    await moveAccountToBucket(id, "active", targetIndex);
    await refreshAccountCredits(id);
  };

  const handleRemove = async (id: string) => {
    const confirmed = window.confirm("Remove this account permanently?");
    if (!confirmed) {
      return;
    }

    const next = await runAction("Removing account", () => removeAccount(id));

    if (!next) {
      return;
    }

    setViewState(next);
    setCreditsById((current) => {
      const nextCredits = { ...current };
      delete nextCredits[id];
      return nextCredits;
    });
    schedulePersistEmbeddedState();
    setNotice("Account removed.");
  };

  const refreshWindowState = async () => {
    try {
      const status = await runWindowAction<boolean>(
        ["cm_window_is_fullscreen"],
        windowFullscreenGetter(),
      );
      setFullscreen(Boolean(status));
    } catch {
      setFullscreen(false);
    }
  };

  const handleMinimize = async () => {
    try {
      await runWindowAction(["cm_window_minimize"], window.cm_window_minimize);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setError(`Minimize failed: ${message}`);
    }
  };

  const handleToggleFullscreen = async () => {
    try {
      await runWindowAction<boolean>(
        ["cm_window_toggle_fullscreen"],
        windowFullscreenToggler(),
      );
      const status = await runWindowAction<boolean>(
        ["cm_window_is_fullscreen"],
        windowFullscreenGetter(),
      );
      setFullscreen(Boolean(status));
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setError(`Fullscreen toggle failed: ${message}`);
    }
  };

  const handleCloseWindow = async () => {
    try {
      await runWindowAction(["cm_window_close"], window.cm_window_close);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setError(`Close failed: ${message}`);
    }
  };

  const handleTitleBarDoubleClick = async (event: MouseEvent) => {
    const target = event.target as HTMLElement | null;
    if (target?.closest(".window-controls")) {
      return;
    }
    await handleToggleFullscreen();
  };

  const toggleTheme = () => {
    const nextTheme: Theme = theme() === "light" ? "dark" : "light";
    setTheme(nextTheme);
    applyTheme(nextTheme);
    schedulePersistEmbeddedState();
    void saveTheme(nextTheme).catch(() => {});
  };

  onMount(async () => {
    const fallbackTheme = localStorage.getItem("codex-manager-theme");
    let initialTheme: Theme = embeddedState?.theme === "dark" ? "dark" : fallbackTheme === "dark" ? "dark" : "light";
    try {
      const bridgedTheme = await getSavedTheme();
      if (bridgedTheme) {
        initialTheme = bridgedTheme;
      }
    } catch {
      // Keep localStorage fallback for pure browser sessions.
    }
    setTheme(initialTheme);
    applyTheme(initialTheme);
    schedulePersistEmbeddedState();
    void saveTheme(initialTheme).catch(() => {});

    const handlePointerDown = (event: PointerEvent) => {
      const target = event.target as Node | null;
      if (!target) {
        return;
      }

      if (addMenuVisible()) {
        if (!addMenuRef?.contains(target) && !addButtonRef?.contains(target)) {
          setAddMenuOpen(false);
        }
      }
    };

    window.addEventListener("pointerdown", handlePointerDown);
    window.addEventListener("pointerup", releaseDragSelectionLock);
    window.addEventListener("pointercancel", releaseDragSelectionLock);
    onCleanup(() => {
      window.removeEventListener("pointerdown", handlePointerDown);
      window.removeEventListener("pointerup", releaseDragSelectionLock);
      window.removeEventListener("pointercancel", releaseDragSelectionLock);
      document.body.classList.remove(DRAG_SELECT_LOCK_CLASS);
      if (persistStateTimer !== undefined) {
        window.clearTimeout(persistStateTimer);
      }
      removeDragPreview();
    });

    try {
      await Promise.all([refreshWindowState(), refreshAccounts(true)]);
    } finally {
      setInitializing(false);
    }
  });

  return (
    <div class="app-root">
      <Show when={SHOW_DESKTOP_TOP_BAR}>
        <header class="window-bar reveal" onDblClick={(event) => void handleTitleBarDoubleClick(event)}>
          <div class="window-title mono">
            Codex Account Manager
          </div>
          <div class="window-drag-area" />
          <div class="window-controls">
            <button
              class="window-btn"
              type="button"
              onClick={handleMinimize}
              aria-label="Minimize"
            >
              <IconMinimize />
            </button>
            <button
              class="window-btn"
              type="button"
              onClick={handleToggleFullscreen}
              aria-label="Toggle fullscreen"
            >
              <Show when={fullscreen()} fallback={<IconMaximize />}>
                <IconRestore />
              </Show>
            </button>
            <button
              class="window-btn window-btn-close"
              type="button"
              onClick={handleCloseWindow}
              aria-label="Close"
            >
              <IconClose />
            </button>
          </div>
        </header>
      </Show>

      <header class="topbar reveal">
        <div class="topbar-main">
          <h1>Managed Accounts</h1>
          <p>Switch accounts on the fly with per-account credits.</p>
        </div>

        <div class="top-actions">
          <button class="icon-btn" type="button" onClick={toggleTheme} aria-label="Toggle theme" title="Toggle theme">
            <Show when={theme() === "dark"} fallback={<IconSun />}>
              <IconMoon />
            </Show>
          </button>
          <div class="add-menu-wrap">
            <button
              class="icon-btn"
              ref={(element) => {
                addButtonRef = element;
              }}
              type="button"
              disabled={initializing()}
              onClick={() => setAddMenuOpen((open) => !open)}
              aria-label={addMenuVisible() ? "Close add account menu" : "Add account"}
              title={addMenuVisible() ? "Close add account menu" : "Add account"}
            >
              <Show when={addMenuVisible()} fallback={<IconPlus />}>
                <IconClose />
              </Show>
            </button>

            <Show when={addMenuVisible()}>
              <div
                class="context-menu reveal"
                ref={(element) => {
                  addMenuRef = element;
                }}
              >
                <header class="context-head">
                  <p class="label">Add Account</p>
                </header>

                <div class="context-actions">
                  <button type="button" onClick={handleAddChatgptStart}>
                    Start ChatGPT Login
                  </button>

                  <button type="button" onClick={handleToggleCallbackListener}>
                    {isListeningForCallback() ? "Stop listening" : "Listen for callback"}
                  </button>

                  <div class="context-row">
                    <input
                      type="password"
                      value={apiKeyDraft()}
                      onInput={(event) => setApiKeyDraft(event.currentTarget.value)}
                      placeholder="OpenAI API key"
                    />
                    <button type="button" onClick={handleAddApiKey}>
                      Add
                    </button>
                  </div>

                  <button type="button" onClick={handleImportCurrent}>
                    Import Current auth.json
                  </button>
                </div>

                <Show when={browserStart()}>
                  {(started) => (
                    <p class="mono muted helper">
                      Redirect URI: {started().redirectUri}
                    </p>
                  )}
                </Show>
              </div>
            </Show>
          </div>
        </div>
      </header>

      <main
        class="content-scroll"
        ref={(element) => {
          contentScrollRef = element;
        }}
      >
        <div class="shell">
          <Show when={error()}>{(message) => <section class="notice error reveal">{message()}</section>}</Show>
          <Show when={visibleNotice()}>
            {(message) => <section class="notice reveal">{message()}</section>}
          </Show>
          <Show when={visibleBusy()}>
            {(message) => <section class="notice reveal">{message()}</section>}
          </Show>

          <Show
            when={!initializing()}
            fallback={
              <section class="panel boot-panel reveal">
                <div class="boot-pulse" />
                <p class="boot-title">Loading accounts</p>
                <p class="mono muted">Syncing account state and remaining credits.</p>
                <div class="boot-skeleton-grid" aria-hidden="true">
                  <div class="boot-skeleton-card" />
                  <div class="boot-skeleton-card" />
                  <div class="boot-skeleton-card" />
                </div>
              </section>
            }
          >
            <section class="panel panel-accounts reveal">
              <div class="section-head">
                <h2>Managed Accounts</h2>
                <Show when={activeAccounts().length > 0}>
                  <button
                    type="button"
                    onClick={handleRefreshAllCredits}
                    disabled={refreshingAll()}
                  >
                    Refresh All
                  </button>
                </Show>
              </div>

              <Show
                when={activeAccounts().length > 0}
                fallback={
                  <div
                    class={`empty-state drop-surface ${draggingAccountId() ? "drag-active" : ""} ${
                      isDropBucketHovered("active") ? "drop-hot" : ""
                    }`}
                    onDragOver={(event) => handleDragOverBucket(event, "active")}
                    onDrop={(event) => void handleDropOnBucket(event, "active")}
                  >
                    <p class="mono muted">No accounts yet.</p>
                    <button type="button" onClick={() => setAddMenuOpen(true)}>
                      Add Account
                    </button>
                  </div>
                }
              >
                <div
                  class={`accounts-grid drop-surface ${draggingAccountId() ? "drag-active" : ""} ${
                    isDropAtEnd("active") ? "drop-tail" : ""
                  } ${isDropBucketHovered("active") ? "drop-hot" : ""}`}
                  onDragOver={(event) => handleDragOverBucket(event, "active")}
                  onDrop={(event) => void handleDropOnBucket(event, "active")}
                >
                  <For each={activeAccounts()}>
                    {(account) => {
                      const credits = () => creditsById()[account.id];

                      return (
                        <article
                          class={`account ${account.isActive ? "active" : ""} ${
                            draggingAccountId() === account.id ? "dragging" : ""
                          } ${isDropBefore("active", account.id) ? "drop-before" : ""}${
                            draggingAccountId() && draggingAccountId() !== account.id ? " drag-context" : ""
                          }`}
                          draggable={true}
                          onDragStart={(event) => handleDragStart(event, account, "active")}
                          onDragEnd={handleDragEnd}
                          onDragOver={(event) => handleDragOverAccount(event, "active", account.id)}
                          onDrop={(event) => void handleDropBeforeAccount(event, "active", account.id)}
                        >
                          <header class="account-head">
                            <span class="icon-btn drag-handle" aria-hidden="true">
                              <IconDragHandle />
                            </span>
                            <div class="account-main">
                              <p class="account-title account-main-value">{accountTitle(account)}</p>
                              <p class="mono muted account-copyable">{accountMainIdentity(account)}</p>
                            </div>
                            <Show when={account.isActive}>
                              <p class="pill pill-active">ACTIVE</p>
                            </Show>
                          </header>

                          <Show when={credits()?.isPaidPlan !== true}>
                            <div class="credit-bars">
                              <div class="credit-bar-item">
                                <div class="credit-bar-head">
                                  <p class="mono credit-value">
                                    Available: {renderCreditValue(credits()?.available ?? null, credits())}
                                  </p>
                                  <p class="mono credit-value align-right">
                                    Total: {renderCreditValue(credits()?.total ?? null, credits())}
                                  </p>
                                </div>
                                <div class="progress-track">
                                  <div
                                    class="progress-fill progress-available"
                                    style={{
                                      width: `${percentFromCredits(credits())}%`,
                                    }}
                                  />
                                </div>
                              </div>
                            </div>
                          </Show>

                          <Show when={credits()?.isPaidPlan}>
                            <div class="rate-limits-grid">
                              <div class="rate-limits-item">
                                <div class="rate-limit-head">
                                  <p class="label">Hourly Remaining</p>
                                  <p class="mono">{percentOrDash(credits()?.hourlyRemainingPercent ?? null)}</p>
                                </div>
                                <div class="limit-track">
                                  <div
                                    class="limit-fill"
                                    style={{ width: `${percentWidth(credits()?.hourlyRemainingPercent ?? null)}%` }}
                                  />
                                </div>
                              </div>
                              <div class="rate-limits-item">
                                <div class="rate-limit-head">
                                  <p class="label">Weekly Remaining</p>
                                  <p class="mono">{percentOrDash(credits()?.weeklyRemainingPercent ?? null)}</p>
                                </div>
                                <div class="limit-track">
                                  <div
                                    class="limit-fill"
                                    style={{ width: `${percentWidth(credits()?.weeklyRemainingPercent ?? null)}%` }}
                                  />
                                </div>
                              </div>
                            </div>
                          </Show>

                          <div class="mini-grid">
                            <div>
                              <p class="label">Updated</p>
                              <p class="mono">{formatEpoch(account.updatedAt)}</p>
                            </div>
                            <div>
                              <p class="label">Last used</p>
                              <p class="mono">{formatEpoch(account.lastUsedAt)}</p>
                            </div>
                          </div>

                          <div class="card-actions">
                            <button
                              type="button"
                              class="switch-btn"
                              disabled={account.isActive}
                              onClick={() => handleSwitch(account.id)}
                            >
                              {account.isActive ? "Current Account" : "Switch Account"}
                            </button>

                            <div class="icon-actions">
                              <button
                                type="button"
                                class="icon-btn action"
                                onClick={() => refreshAccountCredits(account.id)}
                                disabled={Boolean(refreshingById()[account.id])}
                                aria-label="Refresh credits"
                                title="Refresh credits"
                              >
                                <Show when={refreshingById()[account.id]} fallback={<IconRefresh />}>
                                  <IconRefreshing />
                                </Show>
                              </button>
                              <button
                                type="button"
                                class="icon-btn action"
                                onClick={() => void handleFreeze(account.id)}
                                aria-label="Freeze account"
                                title="Freeze account"
                              >
                                <IconFrost />
                              </button>
                              <button
                                type="button"
                                class="icon-btn danger-icon"
                                onClick={() => handleRemove(account.id)}
                                aria-label="Delete account"
                                title="Delete account"
                              >
                                <IconTrash />
                              </button>
                            </div>
                          </div>
                        </article>
                      );
                    }}
                  </For>
                </div>
              </Show>
            </section>

            <section class="panel panel-depleted reveal">
              <div class="section-head">
                <h2>Depleted Accounts</h2>
                <div class="section-actions">
                  <Show when={depletedAccounts().length > 0}>
                    <button type="button" onClick={handleRefreshDepletedCredits}>
                      Refresh Depleted
                    </button>
                  </Show>
                  <button type="button" onClick={handleToggleDepletedSection}>
                    {showDepleted() ? "Hide" : "Show"}
                  </button>
                </div>
              </div>

              <Show when={showDepleted()}>
                <Show
                  when={depletedAccounts().length > 0}
                  fallback={
                    <div
                      class={`empty-state drop-surface ${draggingAccountId() ? "drag-active" : ""} ${
                        isDropBucketHovered("depleted") ? "drop-hot" : ""
                      }`}
                      onDragOver={(event) => handleDragOverBucket(event, "depleted")}
                      onDrop={(event) => void handleDropOnBucket(event, "depleted")}
                    >
                      <p class="mono muted">No depleted accounts.</p>
                    </div>
                  }
                >
                  <div
                    class={`accounts-grid drop-surface ${draggingAccountId() ? "drag-active" : ""} ${
                      isDropAtEnd("depleted") ? "drop-tail" : ""
                    } ${isDropBucketHovered("depleted") ? "drop-hot" : ""}`}
                    onDragOver={(event) => handleDragOverBucket(event, "depleted")}
                    onDrop={(event) => void handleDropOnBucket(event, "depleted")}
                  >
                    <For each={depletedAccounts()}>
                      {(account) => {
                        const credits = () => creditsById()[account.id];

                        return (
                          <article
                            class={`account account-depleted archived ${draggingAccountId() === account.id ? "dragging" : ""} ${
                              isDropBefore("depleted", account.id) ? "drop-before" : ""
                            }${draggingAccountId() && draggingAccountId() !== account.id ? " drag-context" : ""}`}
                            draggable={true}
                            onDragStart={(event) => handleDragStart(event, account, "depleted")}
                            onDragEnd={handleDragEnd}
                            onDragOver={(event) => handleDragOverAccount(event, "depleted", account.id)}
                            onDrop={(event) => void handleDropBeforeAccount(event, "depleted", account.id)}
                          >
                            <header class="account-head">
                              <span class="icon-btn drag-handle" aria-hidden="true">
                                <IconDragHandle />
                              </span>
                              <div class="account-main">
                                <p class="account-title account-main-value">{accountTitle(account)}</p>
                                <p class="mono muted account-copyable">{accountMainIdentity(account)}</p>
                              </div>
                            </header>

                            <Show when={credits()}>
                              <Show when={credits()?.isPaidPlan !== true}>
                                <div class="credit-bars">
                                  <div class="credit-bar-item">
                                    <div class="credit-bar-head">
                                      <p class="mono credit-value">
                                        Available: {renderCreditValue(credits()?.available ?? null, credits())}
                                      </p>
                                      <p class="mono credit-value align-right">
                                        Total: {renderCreditValue(credits()?.total ?? null, credits())}
                                      </p>
                                    </div>
                                    <div class="progress-track">
                                      <div
                                        class="progress-fill progress-available"
                                        style={{
                                          width: `${percentFromCredits(credits())}%`,
                                        }}
                                      />
                                    </div>
                                  </div>
                                </div>
                              </Show>

                              <Show when={credits()?.isPaidPlan}>
                                <div class="rate-limits-grid">
                                  <div class="rate-limits-item">
                                    <div class="rate-limit-head">
                                      <p class="label">Hourly Remaining</p>
                                      <p class="mono">{percentOrDash(credits()?.hourlyRemainingPercent ?? null)}</p>
                                    </div>
                                    <div class="limit-track">
                                      <div
                                        class="limit-fill"
                                        style={{
                                          width: `${percentWidth(credits()?.hourlyRemainingPercent ?? null)}%`,
                                        }}
                                      />
                                    </div>
                                  </div>
                                  <div class="rate-limits-item">
                                    <div class="rate-limit-head">
                                      <p class="label">Weekly Remaining</p>
                                      <p class="mono">{percentOrDash(credits()?.weeklyRemainingPercent ?? null)}</p>
                                    </div>
                                    <div class="limit-track">
                                      <div
                                        class="limit-fill"
                                        style={{
                                          width: `${percentWidth(credits()?.weeklyRemainingPercent ?? null)}%`,
                                        }}
                                      />
                                    </div>
                                  </div>
                                </div>
                              </Show>
                            </Show>

                            <div class="card-actions">
                              <button type="button" class="switch-btn" onClick={() => void handleThaw(account.id)}>
                                Activate
                              </button>

                              <div class="icon-actions">
                                <button
                                  type="button"
                                  class="icon-btn action"
                                  onClick={() => void handleFreeze(account.id)}
                                  aria-label="Freeze account"
                                  title="Freeze account"
                                >
                                  <IconFrost />
                                </button>
                                <button
                                  type="button"
                                  class="icon-btn danger-icon"
                                  onClick={() => handleRemove(account.id)}
                                  aria-label="Delete account"
                                  title="Delete account"
                                >
                                  <IconTrash />
                                </button>
                              </div>
                            </div>
                          </article>
                        );
                      }}
                    </For>
                  </div>
                </Show>
              </Show>
            </section>

            <section class="panel panel-frozen reveal">
              <div class="section-head">
                <h2>Frozen Accounts</h2>
                <button type="button" onClick={handleToggleFrozenSection}>
                  {showFrozen() ? "Hide" : "Show"}
                </button>
              </div>

              <Show when={showFrozen()}>
                <Show
                  when={frozenAccounts().length > 0}
                  fallback={
                    <div
                      class={`empty-state drop-surface ${draggingAccountId() ? "drag-active" : ""} ${
                        isDropBucketHovered("frozen") ? "drop-hot" : ""
                      }`}
                      onDragOver={(event) => handleDragOverBucket(event, "frozen")}
                      onDrop={(event) => void handleDropOnBucket(event, "frozen")}
                    >
                      <p class="mono muted">No frozen accounts.</p>
                    </div>
                  }
                >
                  <div
                    class={`accounts-grid drop-surface ${draggingAccountId() ? "drag-active" : ""} ${
                      isDropAtEnd("frozen") ? "drop-tail" : ""
                    } ${isDropBucketHovered("frozen") ? "drop-hot" : ""}`}
                    onDragOver={(event) => handleDragOverBucket(event, "frozen")}
                    onDrop={(event) => void handleDropOnBucket(event, "frozen")}
                  >
                    <For each={frozenAccounts()}>
                      {(account) => (
                        <article
                          class={`account account-frozen archived ${draggingAccountId() === account.id ? "dragging" : ""} ${
                            isDropBefore("frozen", account.id) ? "drop-before" : ""
                          }${draggingAccountId() && draggingAccountId() !== account.id ? " drag-context" : ""}`}
                          draggable={true}
                          onDragStart={(event) => handleDragStart(event, account, "frozen")}
                          onDragEnd={handleDragEnd}
                          onDragOver={(event) => handleDragOverAccount(event, "frozen", account.id)}
                          onDrop={(event) => void handleDropBeforeAccount(event, "frozen", account.id)}
                        >
                          <header class="account-head">
                            <span class="icon-btn drag-handle" aria-hidden="true">
                              <IconDragHandle />
                            </span>
                            <div class="account-main">
                              <p class="account-title account-main-value">{accountTitle(account)}</p>
                              <p class="mono muted account-copyable">{accountMainIdentity(account)}</p>
                            </div>
                          </header>

                          <div class="mini-grid">
                            <div>
                              <p class="label">Updated</p>
                              <p class="mono">{formatEpoch(account.updatedAt)}</p>
                            </div>
                            <div>
                              <p class="label">Last used</p>
                              <p class="mono">{formatEpoch(account.lastUsedAt)}</p>
                            </div>
                          </div>

                          <div class="card-actions">
                            <button type="button" class="switch-btn" onClick={() => void handleThaw(account.id)}>
                              Activate
                            </button>

                            <div class="icon-actions">
                              <button
                                type="button"
                                class="icon-btn danger-icon"
                                onClick={() => handleRemove(account.id)}
                                aria-label="Delete account"
                                title="Delete account"
                              >
                                <IconTrash />
                              </button>
                            </div>
                          </div>
                        </article>
                      )}
                    </For>
                  </div>
                </Show>
              </Show>
            </section>
          </Show>
        </div>
      </main>
    </div>
  );
}

export default App;
