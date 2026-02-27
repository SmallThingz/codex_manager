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
type UsageRefreshDisplayMode = "date" | "remaining";
const QUOTA_EPSILON = 0.0001;
const DRAG_SELECT_LOCK_CLASS = "drag-select-lock";
const AUTO_ARCHIVE_ZERO_QUOTA = true;
const AUTO_UNARCHIVE_NON_ZERO_QUOTA = true;
const AUTO_SWITCH_AWAY_FROM_DEPLETED_OR_FROZEN = true;
const AUTO_REFRESH_ACTIVE_MIN_INTERVAL_SEC = 15;
const AUTO_REFRESH_ACTIVE_MAX_INTERVAL_SEC = 21600;
const AUTO_REFRESH_ACTIVE_STEP_SEC = 15;
const AUTO_REFRESH_ACTIVE_DEFAULT_INTERVAL_SEC = 300;
const AUTO_REFRESH_DEPLETED_COOLDOWN_SEC = 30;
const AUTO_REFRESH_DEPLETED_GRACE_SEC = 5;

const nowEpoch = (): number => Math.floor(Date.now() / 1000);

const pad2 = (value: number): string => String(value).padStart(2, "0");

const normalizeAutoRefreshIntervalSec = (value: number | null | undefined): number => {
  if (value === null || value === undefined || !Number.isFinite(value)) {
    return AUTO_REFRESH_ACTIVE_DEFAULT_INTERVAL_SEC;
  }

  const normalized = Math.floor(value);
  return Math.max(
    AUTO_REFRESH_ACTIVE_MIN_INTERVAL_SEC,
    Math.min(AUTO_REFRESH_ACTIVE_MAX_INTERVAL_SEC, normalized),
  );
};

const formatAutoRefreshInterval = (intervalSec: number): string => {
  const hours = Math.floor(intervalSec / 3600);
  const minutes = Math.floor((intervalSec % 3600) / 60);
  const seconds = intervalSec % 60;
  if (hours > 0) {
    return `${hours}h ${pad2(minutes)}m ${pad2(seconds)}s`;
  }
  return `${minutes}m ${pad2(seconds)}s`;
};

const formatUsageRefreshDateTime = (epoch: number | null | undefined): string => {
  if (!epoch) {
    return "Unknown";
  }

  const value = new Date(epoch * 1000);
  const month = pad2(value.getMonth() + 1);
  const day = pad2(value.getDate());
  const year = pad2(value.getFullYear() % 100);
  const hours = pad2(value.getHours());
  const minutes = pad2(value.getMinutes());
  const seconds = pad2(value.getSeconds());
  return `${month}/${day}/${year} ${hours}:${minutes}:${seconds}`;
};

const formatUsageRefreshRemaining = (
  epoch: number | null | undefined,
  currentEpoch: number,
): string => {
  if (!epoch) {
    return "Unknown";
  }

  const remaining = Math.max(0, Math.floor(epoch - currentEpoch));
  const days = Math.floor(remaining / 86400);
  const hours = Math.floor((remaining % 86400) / 3600);
  const minutes = Math.floor((remaining % 3600) / 60);
  const seconds = remaining % 60;
  return `${days}d ${pad2(hours)}:${pad2(minutes)}:${pad2(seconds)}`;
};

const normalizeUsageRefreshDisplayMode = (value: string | null | undefined): UsageRefreshDisplayMode => {
  if (value === "remaining") {
    return "remaining";
  }

  return "date";
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

const usageRefreshEpoch = (credits: CreditsInfo | undefined, currentEpoch: number): number | null => {
  if (!credits || credits.status !== "available") {
    return null;
  }

  const candidates = [credits.hourlyRefreshAt ?? null, credits.weeklyRefreshAt ?? null].filter(
    (value): value is number => value !== null && Number.isFinite(value) && value > 0,
  );

  const upcoming = candidates.filter((value) => value >= currentEpoch);
  if (upcoming.length > 0) {
    return Math.min(...upcoming);
  }

  if (candidates.length > 0) {
    return Math.min(...candidates);
  }

  // Fallback for older cached entries that predate explicit refresh timestamps.
  if (Number.isFinite(credits.checkedAt) && credits.checkedAt > 0) {
    if (credits.hourlyRemainingPercent !== null) {
      return Math.floor(credits.checkedAt) + 3600;
    }
    if (credits.weeklyRemainingPercent !== null) {
      return Math.floor(credits.checkedAt) + 7 * 24 * 3600;
    }
  }

  return null;
};

type UsageRefreshRow = {
  label: string | null;
  value: string;
};

const refreshEpochFromWindow = (
  refreshAt: number | null | undefined,
  checkedAt: number,
  fallbackWindowSeconds: number,
  hasRemainingData: boolean,
): number | null => {
  if (refreshAt !== null && refreshAt !== undefined && Number.isFinite(refreshAt) && refreshAt > 0) {
    return Math.floor(refreshAt);
  }

  if (hasRemainingData && Number.isFinite(checkedAt) && checkedAt > 0) {
    return Math.floor(checkedAt) + fallbackWindowSeconds;
  }

  return null;
};

const usageRefreshRows = (
  credits: CreditsInfo | undefined,
  currentEpoch: number,
  mode: UsageRefreshDisplayMode,
): UsageRefreshRow[] => {
  const formatValue = (epoch: number | null): string =>
    mode === "remaining" ? formatUsageRefreshRemaining(epoch, currentEpoch) : formatUsageRefreshDateTime(epoch);

  if (credits?.isPaidPlan) {
    const hourlyEpoch = refreshEpochFromWindow(
      credits.hourlyRefreshAt,
      credits.checkedAt,
      3600,
      credits.hourlyRemainingPercent !== null,
    );
    const weeklyEpoch = refreshEpochFromWindow(
      credits.weeklyRefreshAt,
      credits.checkedAt,
      7 * 24 * 3600,
      credits.weeklyRemainingPercent !== null,
    );

    return [
      { label: "Hourly", value: formatValue(hourlyEpoch) },
      { label: "Weekly", value: formatValue(weeklyEpoch) },
    ];
  }

  return [{ label: null, value: formatValue(usageRefreshEpoch(credits, currentEpoch)) }];
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

const IconSettings = () => (
  <svg viewBox="0 0 24 24" aria-hidden="true">
    <path d="M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58c.18-.14.23-.41.12-.61l-1.92-3.32c-.12-.22-.37-.29-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54c-.04-.24-.24-.41-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.07.62-.07.94s.02.64.07.94l-2.03 1.58c-.18.14-.23.41-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.57 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z" />
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

function App() {
  const embeddedState = getEmbeddedBootstrapState();
  const hasEmbeddedState =
    Boolean(embeddedState?.view) || Boolean(embeddedState && Object.keys(embeddedState.usageById).length > 0);

  const [view, setView] = createSignal<AccountsView | null>(embeddedState?.view ?? null);
  const [creditsById, setCreditsById] = createSignal<CreditsByAccount>(embeddedState?.usageById ?? {});
  const [browserStart, setBrowserStart] = createSignal<BrowserLoginStart | null>(null);
  const [apiKeyDraft, setApiKeyDraft] = createSignal("");
  const [theme, setTheme] = createSignal<Theme>(embeddedState?.theme === "dark" ? "dark" : "light");
  const [autoRefreshActiveEnabled, setAutoRefreshActiveEnabled] = createSignal(
    embeddedState?.autoRefreshActiveEnabled === true,
  );
  const [autoRefreshActiveIntervalSec, setAutoRefreshActiveIntervalSec] = createSignal(
    normalizeAutoRefreshIntervalSec(embeddedState?.autoRefreshActiveIntervalSec),
  );
  const [usageRefreshDisplayMode, setUsageRefreshDisplayMode] = createSignal<UsageRefreshDisplayMode>(
    normalizeUsageRefreshDisplayMode(embeddedState?.usageRefreshDisplayMode),
  );
  const [addMenuOpen, setAddMenuOpen] = createSignal(false);
  const [settingsMenuOpen, setSettingsMenuOpen] = createSignal(false);
  const [isListeningForCallback, setIsListeningForCallback] = createSignal(false);
  const [showDepleted, setShowDepleted] = createSignal(false);
  const [showFrozen, setShowFrozen] = createSignal(false);
  const [draggingAccountId, setDraggingAccountId] = createSignal<string | null>(null);
  const [draggingBucket, setDraggingBucket] = createSignal<AccountBucket | null>(null);
  const [dragHover, setDragHover] = createSignal<{ bucket: AccountBucket; targetId: string | null } | null>(null);
  const [refreshingById, setRefreshingById] = createSignal<Record<string, boolean>>({});
  const [refreshingAll, setRefreshingAll] = createSignal(false);
  const [nowTick, setNowTick] = createSignal(nowEpoch());
  const [initializing, setInitializing] = createSignal(!hasEmbeddedState);
  const [busy, setBusy] = createSignal<string | null>(null);
  const [error, setError] = createSignal<string | null>(null);
  const [notice, setNotice] = createSignal<string | null>(null);
  let callbackListenRunId = 0;
  let autoQuotaSyncInFlight = false;
  let autoDepletedRefreshInFlight = false;
  let autoActiveRefreshInFlight = false;
  let lastActiveAutoRefreshAt = 0;
  let depletedAutoRefreshCooldownUntil = 0;
  let persistStateTimer: number | undefined;
  let addMenuRef: HTMLDivElement | undefined;
  let addButtonRef: HTMLButtonElement | undefined;
  let settingsMenuRef: HTMLDivElement | undefined;
  let settingsButtonRef: HTMLButtonElement | undefined;
  let dragPreviewElement: HTMLDivElement | undefined;
  let contentScrollRef: HTMLElement | undefined;
  let nowTickInterval: number | undefined;

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
  const settingsMenuVisible = createMemo(
    () => !initializing() && settingsMenuOpen(),
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

  const newlyAddedAccountIds = (previousView: AccountsView | null, nextView: AccountsView): string[] => {
    const previousIds = new Set((previousView?.accounts ?? []).map((account) => account.id));
    return nextView.accounts
      .filter((account) => !previousIds.has(account.id))
      .map((account) => account.id);
  };

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
        autoRefreshActiveEnabled: autoRefreshActiveEnabled(),
        autoRefreshActiveIntervalSec: autoRefreshActiveIntervalSec(),
        usageRefreshDisplayMode: usageRefreshDisplayMode(),
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

    const ids = activeAccountIds(currentView);
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

  const handleRefreshFrozenCredits = async () => {
    const ids = frozenAccounts().map((account) => account.id);
    if (ids.length === 0) {
      setNotice("No frozen accounts to refresh.");
      return;
    }

    await refreshCreditsForAccounts(ids);
    setNotice("Frozen account credits refreshed.");
  };

  const maybeAutoRefreshDepleted = async (currentEpoch: number) => {
    if (autoDepletedRefreshInFlight || currentEpoch < depletedAutoRefreshCooldownUntil) {
      return;
    }

    const refreshing = refreshingById();
    const cachedCredits = creditsById();
    const dueIds = depletedAccounts()
      .map((account) => account.id)
      .filter((id) => {
        if (refreshing[id]) {
          return false;
        }

        const refreshAt = usageRefreshEpoch(cachedCredits[id], currentEpoch);
        return refreshAt !== null && refreshAt + AUTO_REFRESH_DEPLETED_GRACE_SEC <= currentEpoch;
      });

    if (dueIds.length === 0) {
      return;
    }

    autoDepletedRefreshInFlight = true;
    depletedAutoRefreshCooldownUntil = currentEpoch + AUTO_REFRESH_DEPLETED_COOLDOWN_SEC;
    try {
      await refreshCreditsForAccounts(dueIds, { quiet: true });
    } finally {
      autoDepletedRefreshInFlight = false;
    }
  };

  const maybeAutoRefreshActive = async (currentEpoch: number) => {
    if (!autoRefreshActiveEnabled() || autoActiveRefreshInFlight) {
      return;
    }

    const intervalSec = normalizeAutoRefreshIntervalSec(autoRefreshActiveIntervalSec());
    if (currentEpoch - lastActiveAutoRefreshAt < intervalSec) {
      return;
    }

    const refreshing = refreshingById();
    const ids = activeAccounts()
      .map((account) => account.id)
      .filter((id) => !refreshing[id]);
    if (ids.length === 0) {
      lastActiveAutoRefreshAt = currentEpoch;
      return;
    }

    autoActiveRefreshInFlight = true;
    lastActiveAutoRefreshAt = currentEpoch;
    try {
      await refreshCreditsForAccounts(ids, { quiet: true });
    } finally {
      autoActiveRefreshInFlight = false;
    }
  };

  const handleToggleAutoRefreshActive = (event: Event) => {
    const input = event.currentTarget as HTMLInputElement | null;
    const next = input ? input.checked : !autoRefreshActiveEnabled();
    setAutoRefreshActiveEnabled(next);
    if (next) {
      lastActiveAutoRefreshAt = 0;
    }
    schedulePersistEmbeddedState();
  };

  const handleAutoRefreshIntervalInput = (event: Event) => {
    const input = event.currentTarget as HTMLInputElement | null;
    if (!input) {
      return;
    }

    const parsed = Number.parseInt(input.value, 10);
    const next = normalizeAutoRefreshIntervalSec(Number.isFinite(parsed) ? parsed : null);
    setAutoRefreshActiveIntervalSec(next);
    schedulePersistEmbeddedState();
  };

  const handleUsageRefreshDisplayModeChange = (event: Event) => {
    const select = event.currentTarget as HTMLSelectElement | null;
    if (!select) {
      return;
    }

    const next = normalizeUsageRefreshDisplayMode(select.value);
    setUsageRefreshDisplayMode(next);
    schedulePersistEmbeddedState();
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

      const previousView = view();
      setViewState(login.view);
      setBrowserStart(null);
      setApiKeyDraft("");
      if (activeAccountIds(login.view).length > 0) {
        setAddMenuOpen(false);
      }
      setNotice(login.output.length > 0 ? login.output : "ChatGPT login completed.");

      const addedIds = newlyAddedAccountIds(previousView, login.view);
      if (addedIds.length > 0) {
        await refreshCreditsForAccounts(addedIds, { quiet: true });
      }
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

    const previousView = view();
    setViewState(login.view);
    setApiKeyDraft("");
    if (activeAccountIds(login.view).length > 0) {
      setAddMenuOpen(false);
    }
    setNotice(login.output.length > 0 ? login.output : "API key login completed.");

    const addedIds = newlyAddedAccountIds(previousView, login.view);
    if (addedIds.length > 0) {
      await refreshCreditsForAccounts(addedIds, { quiet: true });
    }
  };

  const handleImportCurrent = async () => {
    const next = await runAction("Importing current auth.json", () => importCurrentAccount());

    if (!next) {
      return;
    }

    const previousView = view();
    setViewState(next);
    setApiKeyDraft("");
    if (activeAccountIds(next).length > 0) {
      setAddMenuOpen(false);
    }
    setNotice("Imported active Codex auth into managed accounts.");

    const addedIds = newlyAddedAccountIds(previousView, next);
    if (addedIds.length > 0) {
      await refreshCreditsForAccounts(addedIds, { quiet: true });
    }
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

      if (settingsMenuVisible()) {
        if (!settingsMenuRef?.contains(target) && !settingsButtonRef?.contains(target)) {
          setSettingsMenuOpen(false);
        }
      }
    };

    window.addEventListener("pointerdown", handlePointerDown);
    window.addEventListener("pointerup", releaseDragSelectionLock);
    window.addEventListener("pointercancel", releaseDragSelectionLock);
    nowTickInterval = window.setInterval(() => {
      const currentEpoch = nowEpoch();
      setNowTick(currentEpoch);
      void maybeAutoRefreshDepleted(currentEpoch);
      void maybeAutoRefreshActive(currentEpoch);
    }, 1000);
    onCleanup(() => {
      window.removeEventListener("pointerdown", handlePointerDown);
      window.removeEventListener("pointerup", releaseDragSelectionLock);
      window.removeEventListener("pointercancel", releaseDragSelectionLock);
      if (nowTickInterval !== undefined) {
        window.clearInterval(nowTickInterval);
      }
      document.body.classList.remove(DRAG_SELECT_LOCK_CLASS);
      if (persistStateTimer !== undefined) {
        window.clearTimeout(persistStateTimer);
      }
      removeDragPreview();
    });

    try {
      await refreshAccounts(true);
    } finally {
      setInitializing(false);
    }
  });

  return (
    <div class="app-root">
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
          <div class="settings-wrap">
            <button
              class="icon-btn"
              ref={(element) => {
                settingsButtonRef = element;
              }}
              type="button"
              disabled={initializing()}
              onClick={() => {
                setSettingsMenuOpen((open) => !open);
                setAddMenuOpen(false);
              }}
              aria-label={settingsMenuVisible() ? "Close settings menu" : "Open settings menu"}
              title={settingsMenuVisible() ? "Close settings menu" : "Open settings menu"}
            >
              <Show when={settingsMenuVisible()} fallback={<IconSettings />}>
                <IconClose />
              </Show>
            </button>

            <Show when={settingsMenuVisible()}>
              <div
                class="context-menu settings-menu reveal"
                ref={(element) => {
                  settingsMenuRef = element;
                }}
              >
                <header class="context-head">
                  <p class="label">Settings</p>
                </header>

                <section class="settings-section">
                  <div class="auto-refresh-controls">
                    <label class="auto-refresh-toggle">
                      <input
                        type="checkbox"
                        checked={autoRefreshActiveEnabled()}
                        onChange={handleToggleAutoRefreshActive}
                        disabled={initializing()}
                      />
                      <span>Auto refresh active accounts</span>
                    </label>
                    <div class="auto-refresh-slider">
                      <div class="auto-refresh-slider-head">
                        <p class="label">Interval</p>
                        <p class="mono muted">{formatAutoRefreshInterval(autoRefreshActiveIntervalSec())}</p>
                      </div>
                      <input
                        class="themed-slider"
                        type="range"
                        min={AUTO_REFRESH_ACTIVE_MIN_INTERVAL_SEC}
                        max={AUTO_REFRESH_ACTIVE_MAX_INTERVAL_SEC}
                        step={AUTO_REFRESH_ACTIVE_STEP_SEC}
                        value={autoRefreshActiveIntervalSec()}
                        onInput={handleAutoRefreshIntervalInput}
                        disabled={!autoRefreshActiveEnabled() || initializing()}
                      />
                    </div>
                  </div>
                  <div class="settings-field">
                    <p class="label">Usage Refreshes Display</p>
                    <select
                      class="settings-select"
                      value={usageRefreshDisplayMode()}
                      onChange={handleUsageRefreshDisplayModeChange}
                    >
                      <option value="date">Refresh Date/Time</option>
                      <option value="remaining">Time Remaining</option>
                    </select>
                  </div>
                </section>
              </div>
            </Show>
          </div>
          <div class="add-menu-wrap">
            <button
              class="icon-btn"
              ref={(element) => {
                addButtonRef = element;
              }}
              type="button"
              disabled={initializing()}
              onClick={() => {
                setAddMenuOpen((open) => !open);
                setSettingsMenuOpen(false);
              }}
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
                      const refreshRows = () => usageRefreshRows(credits(), nowTick(), usageRefreshDisplayMode());

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

                          <div class="mini-grid mini-grid-full">
                            <div>
                              <div class="usage-refresh-head">
                                <p class="label">Usage refreshes</p>
                                <Show
                                  when={refreshRows().length > 1}
                                  fallback={<p class="mono usage-refresh-value">{refreshRows()[0]?.value ?? "Unknown"}</p>}
                                >
                                  <div class="usage-refresh-list">
                                    <For each={refreshRows()}>
                                      {(row) => (
                                        <p class="mono usage-refresh-item">
                                          <span class="usage-refresh-item-label">{row.label}</span>
                                          <span class="usage-refresh-item-value">{row.value}</span>
                                        </p>
                                      )}
                                    </For>
                                  </div>
                                </Show>
                              </div>
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
                        const refreshRows = () => usageRefreshRows(credits(), nowTick(), usageRefreshDisplayMode());

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

                            <div class="mini-grid mini-grid-full">
                              <div>
                                <div class="usage-refresh-head">
                                  <p class="label">Usage refreshes</p>
                                  <Show
                                    when={refreshRows().length > 1}
                                    fallback={<p class="mono usage-refresh-value">{refreshRows()[0]?.value ?? "Unknown"}</p>}
                                  >
                                    <div class="usage-refresh-list">
                                      <For each={refreshRows()}>
                                        {(row) => (
                                          <p class="mono usage-refresh-item">
                                            <span class="usage-refresh-item-label">{row.label}</span>
                                            <span class="usage-refresh-item-value">{row.value}</span>
                                          </p>
                                        )}
                                      </For>
                                    </div>
                                  </Show>
                                </div>
                              </div>
                            </div>

                            <div class="card-actions">
                              <button type="button" class="switch-btn" onClick={() => void handleThaw(account.id)}>
                                Activate
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
                <div class="section-actions">
                  <Show when={frozenAccounts().length > 0}>
                    <button type="button" onClick={handleRefreshFrozenCredits}>
                      Refresh Frozen
                    </button>
                  </Show>
                  <button type="button" onClick={handleToggleFrozenSection}>
                    {showFrozen() ? "Hide" : "Show"}
                  </button>
                </div>
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
                      {(account) => {
                        const credits = () => creditsById()[account.id];
                        const availablePercent = () => quotaRemainingPercent(credits());
                        const refreshRows = () => usageRefreshRows(credits(), nowTick(), usageRefreshDisplayMode());

                        return (
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
                              </div>
                            </header>

                            <div class="credit-bars">
                              <div class="credit-bar-item">
                                <div class="credit-bar-head">
                                  <p class="label">Available</p>
                                  <p class="mono credit-value align-right">{percentOrDash(availablePercent())}</p>
                                </div>
                                <div class="progress-track">
                                  <div
                                    class="progress-fill progress-available"
                                    style={{ width: `${percentWidth(availablePercent())}%` }}
                                  />
                                </div>
                              </div>
                            </div>

                            <div class="mini-grid mini-grid-full">
                              <div>
                                <div class="usage-refresh-head">
                                  <p class="label">Usage refreshes</p>
                                  <Show
                                    when={refreshRows().length > 1}
                                    fallback={<p class="mono usage-refresh-value">{refreshRows()[0]?.value ?? "Unknown"}</p>}
                                  >
                                    <div class="usage-refresh-list">
                                      <For each={refreshRows()}>
                                        {(row) => (
                                          <p class="mono usage-refresh-item">
                                            <span class="usage-refresh-item-label">{row.label}</span>
                                            <span class="usage-refresh-item-value">{row.value}</span>
                                          </p>
                                        )}
                                      </For>
                                    </div>
                                  </Show>
                                </div>
                              </div>
                            </div>

                            <div class="card-actions">
                              <button type="button" class="switch-btn" onClick={() => void handleThaw(account.id)}>
                                Activate
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
          </Show>
        </div>
      </main>
    </div>
  );
}

export default App;
