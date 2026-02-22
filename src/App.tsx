import { For, Show, createMemo, createSignal, onCleanup, onMount } from "solid-js";
import { getCurrentWindow } from "@tauri-apps/api/window";
import {
  archiveAccount,
  beginCodexLogin,
  codexLoginWithApiKey,
  completeCodexLogin,
  getAccounts,
  getRemainingCreditsForAccount,
  importCurrentAccount,
  listenForCodexCallback,
  removeAccount,
  stopCodexCallbackListener,
  switchAccount,
  unarchiveAccount,
  type AccountSummary,
  type AccountsView,
  type BrowserLoginStart,
  type CreditsInfo,
} from "./lib/codexAuth";
import "./App.css";

type CreditsByAccount = Record<string, CreditsInfo | undefined>;

type Theme = "light" | "dark";

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

const accountTitle = (account: AccountSummary): string => {
  return account.label || account.email || account.accountId || account.id;
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

const IconSun = () => (
  <svg viewBox="0 0 24 24" aria-hidden="true">
    <circle cx="12" cy="12" r="4" />
    <path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4" />
  </svg>
);

const IconMoon = () => (
  <svg viewBox="0 0 24 24" aria-hidden="true">
    <path d="M20 14.2A8 8 0 1 1 9.8 4 6.5 6.5 0 0 0 20 14.2Z" />
  </svg>
);

const IconRefresh = () => (
  <svg viewBox="0 0 24 24" aria-hidden="true">
    <path d="M8 4.8A8.5 8.5 0 0 1 20 12" />
    <path d="M20 7.5V12h-4.5" />
    <path d="M16 19.2A8.5 8.5 0 0 1 4 12" />
    <path d="M4 16.5V12h4.5" />
  </svg>
);

const IconRefreshing = () => (
  <svg class="icon-rotor" viewBox="0 0 24 24" aria-hidden="true">
    <circle cx="12" cy="12" r="7.2" opacity="0.28" />
    <path d="M12 4.8a7.2 7.2 0 0 1 6.8 4.8" />
    <path d="M19.1 9.6l-.1 2.8-2.6-.8" />
  </svg>
);

const IconArchive = () => (
  <svg viewBox="0 0 24 24" aria-hidden="true">
    <path d="M4 4h16v4H4zM5 8h14v11H5z" />
    <path d="M10 12h4" />
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
  const [view, setView] = createSignal<AccountsView | null>(null);
  const [creditsById, setCreditsById] = createSignal<CreditsByAccount>({});
  const [browserStart, setBrowserStart] = createSignal<BrowserLoginStart | null>(null);
  const [apiKeyDraft, setApiKeyDraft] = createSignal("");
  const [theme, setTheme] = createSignal<Theme>("light");
  const [fullscreen, setFullscreen] = createSignal(false);
  const [addMenuOpen, setAddMenuOpen] = createSignal(false);
  const [isListeningForCallback, setIsListeningForCallback] = createSignal(false);
  const [showArchived, setShowArchived] = createSignal(false);
  const [refreshingById, setRefreshingById] = createSignal<Record<string, boolean>>({});
  const [refreshingAll, setRefreshingAll] = createSignal(false);
  const [busy, setBusy] = createSignal<string | null>(null);
  const [error, setError] = createSignal<string | null>(null);
  const [notice, setNotice] = createSignal<string | null>(null);
  let callbackListenRunId = 0;
  let addMenuRef: HTMLDivElement | undefined;
  let addButtonRef: HTMLButtonElement | undefined;

  const activeAccounts = createMemo(() => view()?.accounts.filter((account) => !account.archived) || []);
  const archivedAccounts = createMemo(() => view()?.accounts.filter((account) => account.archived) || []);

  const runAction = async <T,>(message: string, action: () => Promise<T>): Promise<T | undefined> => {
    setBusy(message);
    setError(null);
    setNotice(null);

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
    setView(nextView);

    if (nextView.accounts.length === 0) {
      setAddMenuOpen(true);
    }
  };

  const markRefreshing = (accountIds: string[], refreshing: boolean) => {
    setRefreshingById((previous) => {
      const next = { ...previous };
      for (const id of accountIds) {
        if (refreshing) {
          next[id] = true;
        } else {
          delete next[id];
        }
      }
      return next;
    });
  };

  const refreshCreditsForAccounts = async (accountIds: string[]) => {
    if (accountIds.length === 0) {
      setCreditsById({});
      return;
    }

    setBusy("Checking remaining credits");
    setError(null);
    setRefreshingAll(true);
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

      const failures = entries.filter((entry) => entry[1].status === "error");
      if (failures.length > 0) {
        const first = failures[0][1];
        setError(`Credits check issue: ${first.message}`);
      }
    } catch (creditsError) {
      const rendered = creditsError instanceof Error ? creditsError.message : String(creditsError);
      setError(rendered);
    } finally {
      markRefreshing(accountIds, false);
      setRefreshingAll(false);
      setBusy(null);
    }
  };

  const refreshAccountCredits = async (id: string) => {
    markRefreshing([id], true);
    try {
      const credits = await runAction("Checking remaining credits", () => getRemainingCreditsForAccount(id));
      if (!credits) {
        return;
      }

      setCreditsById((current) => ({
        ...current,
        [id]: credits,
      }));

      if (credits.status !== "error") {
        setNotice("Credits refreshed.");
        return;
      }

      setError(`Credits check issue: ${credits.message}`);
    } finally {
      markRefreshing([id], false);
    }
  };

  const handleRefreshAllCredits = async () => {
    const ids = activeAccounts().map((account) => account.id);
    await refreshCreditsForAccounts(ids);
    setNotice("All credits refreshed.");
  };

  const refreshAccounts = async () => {
    const next = await runAction("Loading accounts", () => getAccounts());
    if (!next) {
      return;
    }

    setViewState(next);
    const ids = next.accounts.filter((account) => !account.archived).map((account) => account.id);
    await refreshCreditsForAccounts(ids);
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
      if (activeAccounts().length > 0) {
        setAddMenuOpen(false);
      }
      setNotice(login.output.length > 0 ? login.output : "ChatGPT login completed.");

      const ids = login.view.accounts.filter((account) => !account.archived).map((account) => account.id);
      await refreshCreditsForAccounts(ids);
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
    if (activeAccounts().length > 0) {
      setAddMenuOpen(false);
    }
    setNotice(login.output.length > 0 ? login.output : "API key login completed.");

    const ids = login.view.accounts.filter((account) => !account.archived).map((account) => account.id);
    await refreshCreditsForAccounts(ids);
  };

  const handleImportCurrent = async () => {
    const next = await runAction("Importing current auth.json", () => importCurrentAccount());

    if (!next) {
      return;
    }

    setViewState(next);
    setApiKeyDraft("");
    if (activeAccounts().length > 0) {
      setAddMenuOpen(false);
    }
    setNotice("Imported active Codex auth into managed accounts.");

    const ids = next.accounts.filter((account) => !account.archived).map((account) => account.id);
    await refreshCreditsForAccounts(ids);
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

  const handleArchive = async (id: string) => {
    const next = await runAction("Archiving account", () => archiveAccount(id));

    if (!next) {
      return;
    }

    setViewState(next);
    setNotice("Account archived.");
  };

  const handleUnarchive = async (id: string) => {
    const next = await runAction("Restoring account", () => unarchiveAccount(id));

    if (!next) {
      return;
    }

    setViewState(next);
    setNotice("Account restored.");
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
    setNotice("Account removed.");
  };

  const refreshWindowState = async () => {
    try {
      const current = getCurrentWindow();
      setFullscreen(await current.isFullscreen());
    } catch {
      setFullscreen(false);
    }
  };

  const handleMinimize = async () => {
    try {
      await getCurrentWindow().minimize();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setError(`Minimize failed: ${message}`);
    }
  };

  const handleToggleFullscreen = async () => {
    try {
      const current = getCurrentWindow();
      const next = !(await current.isFullscreen());
      await current.setFullscreen(next);
      setFullscreen(next);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setError(`Fullscreen toggle failed: ${message}`);
    }
  };

  const handleCloseWindow = async () => {
    try {
      await getCurrentWindow().close();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setError(`Close failed: ${message}`);
    }
  };

  const handleWindowBarPointerDown = async (event: PointerEvent) => {
    if (event.button !== 0) {
      return;
    }

    const target = event.target as HTMLElement | null;
    if (!target) {
      return;
    }

    if (target.closest(".window-controls, button, input, a, [role='button']")) {
      return;
    }

    try {
      event.preventDefault();
      await getCurrentWindow().startDragging();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setError(`Drag failed: ${message}`);
    }
  };

  const toggleTheme = () => {
    const nextTheme: Theme = theme() === "light" ? "dark" : "light";
    setTheme(nextTheme);
    applyTheme(nextTheme);
  };

  const closeAddMenu = () => {
    if (activeAccounts().length === 0) {
      return;
    }

    setAddMenuOpen(false);
  };

  onMount(async () => {
    const savedTheme = localStorage.getItem("codex-manager-theme");
    const initialTheme: Theme = savedTheme === "dark" ? "dark" : "light";
    setTheme(initialTheme);
    applyTheme(initialTheme);

    const handlePointerDown = (event: PointerEvent) => {
      if (!addMenuOpen() || activeAccounts().length === 0) {
        return;
      }

      const target = event.target as Node | null;
      if (!target) {
        return;
      }

      if (addMenuRef?.contains(target) || addButtonRef?.contains(target)) {
        return;
      }

      setAddMenuOpen(false);
    };

    window.addEventListener("pointerdown", handlePointerDown);
    onCleanup(() => {
      window.removeEventListener("pointerdown", handlePointerDown);
    });

    await refreshWindowState();
    await refreshAccounts();
  });

  return (
    <div class="app-root">
      <header class="window-bar reveal" data-tauri-drag-region onPointerDown={handleWindowBarPointerDown}>
        <div class="window-title mono" data-tauri-drag-region>
          Codex Account Manager
        </div>
        <div class="window-drag-area" data-tauri-drag-region />
        <div class="window-controls" data-tauri-drag-region="false">
          <button
            class="window-btn"
            data-tauri-drag-region="false"
            type="button"
            onClick={handleMinimize}
            aria-label="Minimize"
          >
            <IconMinimize />
          </button>
          <button
            class="window-btn"
            data-tauri-drag-region="false"
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
            data-tauri-drag-region="false"
            type="button"
            onClick={handleCloseWindow}
            aria-label="Close"
          >
            <IconClose />
          </button>
        </div>
      </header>

      <header class="topbar reveal">
        <div class="topbar-main">
          <h1>Managed Accounts</h1>
          <p>Switch accounts on the fly with per-account credits.</p>
        </div>

        <div class="top-actions">
          <button class="icon-btn" type="button" onClick={toggleTheme} aria-label="Toggle theme" title="Toggle theme">
            <Show when={theme() === "dark"} fallback={<IconMoon />}>
              <IconSun />
            </Show>
          </button>
          <div class="add-menu-wrap">
            <button
              class="icon-btn"
              ref={(element) => {
                addButtonRef = element;
              }}
              type="button"
              onClick={() => setAddMenuOpen((open) => !open)}
              aria-label="Add account"
              title="Add account"
            >
              <IconPlus />
            </button>

            <Show when={addMenuOpen() || activeAccounts().length === 0}>
              <div
                class="context-menu reveal"
                ref={(element) => {
                  addMenuRef = element;
                }}
              >
                <header class="context-head">
                  <p class="label">Add Account</p>
                  <Show when={activeAccounts().length > 0}>
                    <button
                      class="icon-btn"
                      type="button"
                      onClick={closeAddMenu}
                      aria-label="Close add account menu"
                      title="Close"
                    >
                      <IconClose />
                    </button>
                  </Show>
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

      <main class="content-scroll">
      <div class="shell">
      <Show when={error()}>{(message) => <section class="notice error reveal">{message()}</section>}</Show>
      <Show when={notice()}>{(message) => <section class="notice reveal">{message()}</section>}</Show>
      <Show when={busy()}>{(message) => <section class="notice reveal">{message()}</section>}</Show>

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
            <div class="empty-state">
              <p class="mono muted">No accounts yet.</p>
              <button type="button" onClick={() => setAddMenuOpen(true)}>
                Add Account
              </button>
            </div>
          }
        >
          <div class="accounts-grid">
            <For each={activeAccounts()}>
              {(account) => {
                const credits = () => creditsById()[account.id];

                return (
                  <article class={`account ${account.isActive ? "active" : ""}`}>
                    <header class="account-head">
                      <div>
                        <p class="account-title">{accountTitle(account)}</p>
                        <p class="mono muted">{account.email || account.accountId || account.id}</p>
                      </div>
                      <p class={`pill ${account.isActive ? "pill-active" : ""}`}>
                        {account.isActive ? "ACTIVE" : "STANDBY"}
                      </p>
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
                          onClick={() => handleArchive(account.id)}
                          aria-label="Archive account"
                          title="Archive account"
                        >
                          <IconArchive />
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

      <Show when={archivedAccounts().length > 0}>
        <section class="panel panel-archived reveal">
          <div class="section-head">
            <h2>Archived Accounts</h2>
            <button type="button" onClick={() => setShowArchived((value) => !value)}>
              {showArchived() ? "Hide" : "Show"}
            </button>
          </div>

          <Show when={showArchived()}>
            <div class="accounts-grid">
              <For each={archivedAccounts()}>
                {(account) => (
                  <article class="account archived">
                    <header class="account-head">
                      <div>
                        <p class="account-title">{accountTitle(account)}</p>
                        <p class="mono muted">{account.email || account.accountId || account.id}</p>
                      </div>
                      <p class="pill">ARCHIVED</p>
                    </header>

                    <div class="card-actions">
                      <button type="button" class="switch-btn" onClick={() => handleUnarchive(account.id)}>
                        Restore
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
        </section>
      </Show>
      </div>
      </main>
    </div>
  );
}

export default App;
