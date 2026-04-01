const CODEX_OAUTH_ISSUER = "https://auth.openai.com";
const CODEX_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";
const CODEX_REDIRECT_URI = "http://localhost:1455/auth/callback";
const CODEX_ORIGINATOR = "codex_cli_rs";
const CODEX_SCOPE = "openid profile email offline_access api.connectors.read api.connectors.invoke";
const AUTO_REFRESH_ACTIVE_DEFAULT_INTERVAL_SEC = 300;
const AUTO_REFRESH_ACTIVE_MIN_INTERVAL_SEC = 15;
const AUTO_REFRESH_ACTIVE_MAX_INTERVAL_SEC = 21600;

export type AccountSummary = {
  id: string;
  email: string | null;
  state: "active" | "archived" | "frozen";
};

export type AccountBucket = "active" | "depleted" | "frozen";

export type AccountsView = {
  accounts: AccountSummary[];
  activeAccountId: string | null;
  activeDiskAccountId: string | null;
  codexAuthExists: boolean;
  codexAuthPath: string;
  storePath: string;
};

export type BrowserLoginStart = {
  authUrl: string;
  redirectUri: string;
};

export type LoginResult = {
  view: AccountsView;
  output: string;
};

export type OAuthCallbackListenerPollResult =
  | { status: "running" | "idle" }
  | { status: "ready"; account: AccountSummary }
  | { status: "error"; error: string };

export type CreditsInfo = {
  available: number | null;
  used: number | null;
  total: number | null;
  currency: string;
  source: "wham_usage" | "legacy_credit_grants";
  mode: "balance" | "percent_fallback" | "legacy";
  unit: "USD" | "%";
  planType: string | null;
  isPaidPlan: boolean;
  hourlyRemainingPercent: number | null;
  weeklyRemainingPercent: number | null;
  hourlyRefreshAt: number | null;
  weeklyRefreshAt: number | null;
  status: "available" | "unavailable" | "error";
  message: string;
  checkedAt: number;
};

export type EmbeddedBootstrapState = {
  theme: "light" | "dark" | null;
  autoArchiveZeroQuota: boolean;
  autoUnarchiveNonZeroQuota: boolean;
  autoSwitchAwayFromArchived: boolean;
  autoRefreshActiveEnabled: boolean;
  autoRefreshActiveIntervalSec: number;
  usageRefreshDisplayMode: "date" | "remaining";
  view: AccountsView | null;
  usageById: Record<string, CreditsInfo>;
  savedAt: number;
};

export type AppStateSnapshot = EmbeddedBootstrapState;

type PendingBrowserLogin = {
  issuer: string;
  clientId: string;
  redirectUri: string;
  state: string;
  codeVerifier: string;
  startedAt: number;
};

type WebuiRpcBridge = {
  cm_rpc: (request: Record<string, unknown>) => Promise<unknown> | unknown;
};

type BackendApis = {
  invoke: <T>(command: string, payload?: Record<string, unknown>) => Promise<T>;
  openUrl: (url: string) => Promise<void>;
};

let backendApisPromise: Promise<BackendApis> | null = null;
let pendingBrowserLogin: PendingBrowserLogin | null = null;
const inflightRefreshByAccountId = new Map<string, Promise<CreditsInfo>>();

// Now epoch.
const nowEpoch = (): number => Math.floor(Date.now() / 1000);

// Normalizes normalize optional.
const normalizeOptional = (value: string | null | undefined): string | null => {
  if (!value) {
    return null;
  }

  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
};

// Parses as record.
const asRecord = (value: unknown): Record<string, unknown> | null => {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return null;
  }

  return value as Record<string, unknown>;
};

// Value as boolean.
const valueAsBoolean = (value: unknown): boolean | null => {
  if (typeof value === "boolean") {
    return value;
  }

  if (typeof value === "number") {
    if (value === 1) {
      return true;
    }
    if (value === 0) {
      return false;
    }
  }

  if (typeof value === "string") {
    const normalized = value.trim().toLowerCase();
    if (normalized === "true" || normalized === "1") {
      return true;
    }
    if (normalized === "false" || normalized === "0") {
      return false;
    }
  }

  return null;
};

// Value as number.
const valueAsNumber = (value: unknown): number | null => {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }

  if (typeof value === "string") {
    const parsed = Number.parseFloat(value);
    return Number.isFinite(parsed) ? parsed : null;
  }

  return null;
};

// Normalizes normalize auto refresh interval sec.
const normalizeAutoRefreshIntervalSec = (value: unknown): number => {
  const parsed = valueAsNumber(value);
  if (parsed === null) {
    return AUTO_REFRESH_ACTIVE_DEFAULT_INTERVAL_SEC;
  }

  const normalized = Math.floor(parsed);
  return Math.max(
    AUTO_REFRESH_ACTIVE_MIN_INTERVAL_SEC,
    Math.min(AUTO_REFRESH_ACTIVE_MAX_INTERVAL_SEC, normalized),
  );
};

// Normalizes normalize usage refresh display mode.
const normalizeUsageRefreshDisplayMode = (value: unknown): "date" | "remaining" => {
  return value === "remaining" ? "remaining" : "date";
};

// Error credits info.
const errorCreditsInfo = (message: string): CreditsInfo => ({
  available: null,
  used: null,
  total: null,
  currency: "USD",
  source: "wham_usage",
  mode: "balance",
  unit: "USD",
  planType: null,
  isPaidPlan: false,
  hourlyRemainingPercent: null,
  weeklyRemainingPercent: null,
  hourlyRefreshAt: null,
  weeklyRefreshAt: null,
  status: "error",
  message: message.trim().length > 0 ? message.trim() : "Credits refresh failed.",
  checkedAt: nowEpoch(),
});

// Parses as accounts view.
const asAccountsView = (value: unknown): AccountsView | null => {
  const parsed = asRecord(value);
  if (!parsed) {
    return null;
  }

  const rawAccounts = Array.isArray(parsed.accounts) ? parsed.accounts : [];
  const accounts: AccountSummary[] = rawAccounts
    .map((entry) => asAccountSummary(entry))
    .filter((entry): entry is AccountSummary => entry !== null);

  return {
    accounts,
    activeAccountId: normalizeOptional(typeof parsed.activeAccountId === "string" ? parsed.activeAccountId : null),
    activeDiskAccountId: normalizeOptional(
      typeof parsed.activeDiskAccountId === "string" ? parsed.activeDiskAccountId : null,
    ),
    codexAuthExists: valueAsBoolean(parsed.codexAuthExists) ?? false,
    codexAuthPath: typeof parsed.codexAuthPath === "string" ? parsed.codexAuthPath : "",
    storePath: typeof parsed.storePath === "string" ? parsed.storePath : "",
  };
};

// Parses as account summary.
const asAccountSummary = (value: unknown): AccountSummary | null => {
  const account = asRecord(value);
  if (!account || typeof account.id !== "string") {
    return null;
  }

  return {
    id: account.id,
    email: normalizeOptional(typeof account.email === "string" ? account.email : null),
    state:
      account.state === "archived" || account.state === "frozen" || account.state === "active"
        ? account.state
        : "active",
  };
};

// Parses as oauth callback listener poll result.
const asOAuthCallbackListenerPollResult = (value: unknown): OAuthCallbackListenerPollResult => {
  const parsed = asRecord(value);
  if (!parsed) {
    return { status: "error", error: "Invalid callback listener response." };
  }

  const status = typeof parsed.status === "string" ? parsed.status : null;
  if (status === "running" || status === "idle") {
    return { status };
  }

  if (status === "ready") {
    const account = asAccountSummary(parsed.account);
    if (account) {
      return { status: "ready", account };
    }
    return { status: "error", error: "Callback listener returned an invalid account payload." };
  }

  if (status === "error") {
    const error = typeof parsed.error === "string" && parsed.error.length > 0
      ? parsed.error
      : "Callback listener failed.";
    return { status: "error", error };
  }

  return { status: "error", error: "Unknown callback listener status." };
};

// Parses as credits info.
const asCreditsInfo = (value: unknown): CreditsInfo | null => {
  const parsed = asRecord(value);
  if (!parsed) {
    return null;
  }

  const source = parsed.source === "legacy_credit_grants" ? "legacy_credit_grants" : "wham_usage";
  const mode = parsed.mode === "legacy" ? "legacy" : parsed.mode === "percent_fallback" ? "percent_fallback" : "balance";
  const unit = parsed.unit === "%" ? "%" : "USD";
  const status = parsed.status === "available" ? "available" : parsed.status === "error" ? "error" : "unavailable";

  return {
    available: valueAsNumber(parsed.available),
    used: valueAsNumber(parsed.used),
    total: valueAsNumber(parsed.total),
    currency: typeof parsed.currency === "string" ? parsed.currency : unit === "%" ? "%" : "USD",
    source,
    mode,
    unit,
    planType: normalizeOptional(typeof parsed.planType === "string" ? parsed.planType : null),
    isPaidPlan: valueAsBoolean(parsed.isPaidPlan) ?? false,
    hourlyRemainingPercent: valueAsNumber(parsed.hourlyRemainingPercent),
    weeklyRemainingPercent: valueAsNumber(parsed.weeklyRemainingPercent),
    hourlyRefreshAt: valueAsNumber(parsed.hourlyRefreshAt),
    weeklyRefreshAt: valueAsNumber(parsed.weeklyRefreshAt),
    status,
    message: typeof parsed.message === "string" ? parsed.message : "",
    checkedAt: valueAsNumber(parsed.checkedAt) ?? nowEpoch(),
  };
};

// Parses as snapshot.
const asSnapshot = (value: unknown): AppStateSnapshot => {
  const parsed = asRecord(value);
  if (!parsed) {
    return {
      theme: null,
      autoArchiveZeroQuota: true,
      autoUnarchiveNonZeroQuota: true,
      autoSwitchAwayFromArchived: true,
      autoRefreshActiveEnabled: false,
      autoRefreshActiveIntervalSec: AUTO_REFRESH_ACTIVE_DEFAULT_INTERVAL_SEC,
      usageRefreshDisplayMode: "date",
      view: null,
      usageById: {},
      savedAt: nowEpoch(),
    };
  }

  const usageById: Record<string, CreditsInfo> = {};
  const usageRaw = asRecord(parsed.usageById);
  if (usageRaw) {
    for (const [id, credits] of Object.entries(usageRaw)) {
      const parsedCredits = asCreditsInfo(credits);
      if (parsedCredits) {
        usageById[id] = parsedCredits;
      }
    }
  }

  return {
    theme: parsed.theme === "light" || parsed.theme === "dark" ? parsed.theme : null,
    autoArchiveZeroQuota: valueAsBoolean(parsed.autoArchiveZeroQuota) ?? true,
    autoUnarchiveNonZeroQuota: valueAsBoolean(parsed.autoUnarchiveNonZeroQuota) ?? true,
    autoSwitchAwayFromArchived: valueAsBoolean(parsed.autoSwitchAwayFromArchived) ?? true,
    autoRefreshActiveEnabled: valueAsBoolean(parsed.autoRefreshActiveEnabled) ?? false,
    autoRefreshActiveIntervalSec: normalizeAutoRefreshIntervalSec(parsed.autoRefreshActiveIntervalSec),
    usageRefreshDisplayMode: normalizeUsageRefreshDisplayMode(parsed.usageRefreshDisplayMode),
    view: asAccountsView(parsed.view),
    usageById,
    savedAt: valueAsNumber(parsed.savedAt) ?? nowEpoch(),
  };
};

// Unwraps the bridge response and throws when the backend returned a JSON error envelope.
const decodeBridgeValue = <T>(op: string, value: unknown): T => {
  if (typeof value === "string") {
    try {
      return decodeBridgeValue<T>(op, JSON.parse(value) as unknown);
    } catch {
      return value as T;
    }
  }

  const record = asRecord(value);
  if (!record) {
    return value as T;
  }

  const keys = Object.keys(record);
  const isBridgeErrorObject =
    typeof record.error === "string" &&
    record.error.length > 0 &&
    keys.length === 1 &&
    keys[0] === "error";
  if (isBridgeErrorObject) {
    throw new Error(record.error as string);
  }

  return value as T;
};

// Returns get webui bridge.
const getWebuiBridge = (): WebuiRpcBridge | null => {
  const bridge = (globalThis as { webuiRpc?: WebuiRpcBridge }).webuiRpc;
  if (!bridge || typeof bridge.cm_rpc !== "function") {
    return null;
  }
  return bridge;
};

// Wait for webui bridge.
const waitForWebuiBridge = async (): Promise<WebuiRpcBridge> => {
  const immediate = getWebuiBridge();
  if (immediate) {
    return immediate;
  }

  for (let attempt = 0; attempt < 40; attempt += 1) {
    await new Promise((resolve) => window.setTimeout(resolve, 25));
    const bridge = getWebuiBridge();
    if (bridge) {
      return bridge;
    }
  }

  throw new Error("WebUI bridge is unavailable (webuiRpc.cm_rpc missing).");
};

// Sends a request through the injected webui bridge and decodes the backend response.
const callBridge = async <T>(op: string, payload: Record<string, unknown> = {}): Promise<T> => {
  const request = { op, ...payload };
  const bridge = await waitForWebuiBridge();
  const rawResponse = await bridge.cm_rpc(request);
  return decodeBridgeValue<T>(op, rawResponse);
};

// Loads load backend apis.
const loadBackendApis = async (): Promise<BackendApis> => {
  if (!backendApisPromise) {
    backendApisPromise = Promise.resolve({
      invoke: async <T>(command: string, payload: Record<string, unknown> = {}) =>
        callBridge<T>(`invoke:${command}`, payload),
      openUrl: async (url: string) => {
        await callBridge<null>("shell:open_url", { url });
      },
    });
  }

  return backendApisPromise;
};

// Try open url from window context.
const tryOpenUrlFromWindowContext = (url: string): boolean => {
  if (typeof window === "undefined" || typeof window.open !== "function") {
    return false;
  }

  try {
    const popup = window.open(url, "_blank");

    if (popup) {
      try {
        popup.focus();
      } catch {
        // Ignore focus errors; a successful open attempt is enough.
      }
    }

    // Browsers may return null for security/popup-policy reasons even when
    // the navigation is accepted. Do not treat null as a hard failure here.
    return true;
  } catch {
    return false;
  }
};

// Parses parse accounts view response.
const parseAccountsViewResponse = (payload: unknown, opName: string): AccountsView => {
  const view = asAccountsView(payload);
  if (view) {
    return view;
  }

  throw new Error(`Unexpected ${opName} response from backend.`);
};

// Random base64 url.
const randomBase64Url = (size: number): string => {
  const bytes = new Uint8Array(size);
  crypto.getRandomValues(bytes);
  // Binary.
  const binary = Array.from(bytes, (byte) => String.fromCharCode(byte)).join("");
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
};

// Sha256 base64 url.
const sha256Base64Url = async (value: string): Promise<string> => {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  const bytes = new Uint8Array(digest);
  // Binary.
  const binary = Array.from(bytes, (byte) => String.fromCharCode(byte)).join("");
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
};

// Builds the authorize URL to match Codex CLI's OAuth query ordering and encoding.
const buildAuthorizeUrl = (
  issuer: string,
  clientId: string,
  redirectUri: string,
  codeChallenge: string,
  state: string,
): string => {
  const pairs: Array<[string, string]> = [
    ["response_type", "code"],
    ["client_id", clientId],
    ["redirect_uri", redirectUri],
    ["scope", CODEX_SCOPE],
    ["code_challenge", codeChallenge],
    ["code_challenge_method", "S256"],
    ["id_token_add_organizations", "true"],
    ["codex_cli_simplified_flow", "true"],
    ["state", state],
    ["originator", CODEX_ORIGINATOR],
  ];

  const query = pairs
    .map(([key, value]) => `${key}=${encodeURIComponent(value)}`)
    .join("&");
  return `${issuer}/oauth/authorize?${query}`;
};

// Creates create pending browser login.
const createPendingBrowserLogin = (): PendingBrowserLogin => ({
  issuer: CODEX_OAUTH_ISSUER,
  clientId: CODEX_CLIENT_ID,
  redirectUri: CODEX_REDIRECT_URI,
  state: randomBase64Url(32),
  codeVerifier: randomBase64Url(64),
  startedAt: nowEpoch(),
});

// Ensure pending browser login.
const ensurePendingBrowserLogin = (): PendingBrowserLogin => {
  if (!pendingBrowserLogin) {
    pendingBrowserLogin = createPendingBrowserLogin();
  }
  return pendingBrowserLogin;
};

// Builds build browser login start.
const buildBrowserLoginStart = async (pending: PendingBrowserLogin): Promise<BrowserLoginStart> => {
  const codeChallenge = await sha256Base64Url(pending.codeVerifier);
  const authUrl = buildAuthorizeUrl(
    pending.issuer,
    pending.clientId,
    pending.redirectUri,
    codeChallenge,
    pending.state,
  );
  return {
    authUrl,
    redirectUri: pending.redirectUri,
  };
};

/**
 * Reads the bootstrap snapshot injected into the served HTML, if one is present.
 */
export const getEmbeddedBootstrapState = (): EmbeddedBootstrapState | null => {
  if (typeof window === "undefined") {
    return null;
  }

  const encoded = window.__CM_BOOTSTRAP_STATE__;
  if (!encoded || encoded === "REPLACE_THIS_VARIABLE_WHEN_SENDING") {
    return null;
  }

  try {
    const json = atob(encoded);
    return asSnapshot(JSON.parse(json));
  } catch {
    return null;
  }
};

/**
 * Persists the selected UI theme through the backend preference store.
 */
export const saveTheme = async (theme: "light" | "dark"): Promise<void> => {
  await updateUiPreferences({ theme });
};

/**
 * Writes the supplied UI preference subset without disturbing unspecified settings.
 */
export const updateUiPreferences = async (
  payload: Partial<{
    autoRefreshActiveEnabled: boolean;
    autoRefreshActiveIntervalSec: number;
    usageRefreshDisplayMode: "date" | "remaining";
    theme: "light" | "dark";
  }>,
): Promise<void> => {
  const tauri = await loadBackendApis();
  await tauri.invoke<unknown>("update_ui_preferences", payload as Record<string, unknown>);
};

/**
 * Imports the currently active Codex CLI account into the manager store.
 */
export const importCurrentAccount = async (): Promise<AccountsView> => {
  const tauri = await loadBackendApis();
  const view = await tauri.invoke<unknown>("import_current_account");
  return parseAccountsViewResponse(view, "import_current_account");
};

/**
 * Builds or reuses the pending OAuth login session and returns the browser launch payload.
 */
export const prepareCodexLoginSession = async (): Promise<BrowserLoginStart> => {
  const pending = ensurePendingBrowserLogin();
  return buildBrowserLoginStart(pending);
};

/**
 * Drops any pending OAuth login session state held in the frontend.
 */
export const resetCodexLoginSession = (): void => {
  pendingBrowserLogin = null;
};

/**
 * Starts the backend OAuth callback listener for the current pending login session.
 */
export const startCodexCallbackListener = async (): Promise<void> => {
  const pending = ensurePendingBrowserLogin();
  const tauri = await loadBackendApis();
  await tauri.invoke<unknown>("start_oauth_callback_listener", {
    issuer: pending.issuer,
    clientId: pending.clientId,
    redirectUri: pending.redirectUri,
    oauthState: pending.state,
    codeVerifier: pending.codeVerifier,
  });
};

/**
 * Polls the backend callback listener for completion, failure, or idle state.
 */
export const pollCodexCallbackListener = async (): Promise<OAuthCallbackListenerPollResult> => {
  const tauri = await loadBackendApis();
  const payload = await tauri.invoke<unknown>("poll_oauth_callback_listener");
  return asOAuthCallbackListenerPollResult(payload);
};

/**
 * Opens the current OAuth authorize URL while preserving the pending callback listener session.
 */
export const beginCodexLogin = async (): Promise<BrowserLoginStart> => {
  const pending = ensurePendingBrowserLogin();
  const start = await buildBrowserLoginStart(pending);

  if (tryOpenUrlFromWindowContext(start.authUrl)) {
    return start;
  }

  const tauri = await loadBackendApis();
  try {
    await tauri.openUrl(start.authUrl);
  } catch (openError) {
    // Keep login session/listener alive even when external launcher reports
    // flaky desktop integration errors.
    console.warn("Codex login browser open fallback failed:", openError);
  }
  return start;
};

/**
 * Stops the backend OAuth callback listener for the active login session.
 */
export const stopCodexCallbackListener = async (): Promise<void> => {
  const tauri = await loadBackendApis();
  await tauri.invoke<boolean>("cancel_oauth_callback_listener");
};

/**
 * Saves an API-key account directly without going through the browser OAuth flow.
 */
export const codexLoginWithApiKey = async (apiKey: string): Promise<LoginResult> => {
  const normalized = normalizeOptional(apiKey);
  if (!normalized) {
    throw new Error("API key is required.");
  }

  const tauri = await loadBackendApis();
  const view = parseAccountsViewResponse(
    await tauri.invoke<unknown>("login_with_api_key", {
      apiKey: normalized,
    }),
    "login_with_api_key",
  );

  return {
    view,
    output: "API key login completed.",
  };
};

/**
 * Switches the active managed account and returns the refreshed account view.
 */
export const switchAccount = async (id: string): Promise<AccountsView> => {
  const tauri = await loadBackendApis();
  const view = await tauri.invoke<unknown>("switch_account", { accountId: id });
  return parseAccountsViewResponse(view, "switch_account");
};

/**
 * Reorders an account into the requested bucket/index position.
 */
export const moveAccount = async (
  id: string,
  targetBucket: AccountBucket,
  targetIndex: number,
  options?: { switchAwayFromMoved?: boolean },
): Promise<void> => {
  const tauri = await loadBackendApis();
  await tauri.invoke<unknown>("move_account", {
    accountId: id,
    targetBucket,
    targetIndex,
    switchAwayFromMoved: options?.switchAwayFromMoved,
  });
};

/**
 * Moves an account into the archived/depleted bucket.
 */
export const archiveAccount = async (
  id: string,
  options?: { switchAwayFromArchived?: boolean },
): Promise<void> => {
  return moveAccount(id, "depleted", Number.MAX_SAFE_INTEGER, {
    switchAwayFromMoved: options?.switchAwayFromArchived,
  });
};

/**
 * Restores an archived account back into the active bucket.
 */
export const unarchiveAccount = async (id: string): Promise<void> => {
  return moveAccount(id, "active", Number.MAX_SAFE_INTEGER);
};

/**
 * Deletes an account from the managed store and returns the refreshed account view.
 */
export const removeAccount = async (id: string): Promise<AccountsView> => {
  const tauri = await loadBackendApis();
  const view = await tauri.invoke<unknown>("remove_account", { accountId: id });
  return parseAccountsViewResponse(view, "remove_account");
};

/**
 * Fetches the latest remaining-credits snapshot for a managed account.
 */
export const getRemainingCreditsForAccount = async (id: string): Promise<CreditsInfo> => {
  const existing = inflightRefreshByAccountId.get(id);
  if (existing) {
    return existing;
  }

  // Pending.
  const pending = (async (): Promise<CreditsInfo> => {
    try {
      const tauri = await loadBackendApis();

      while (true) {
        let payload: unknown;
        try {
          payload = await tauri.invoke<unknown>("refresh_account_usage", { accountId: id });
        } catch (invokeError) {
          const rendered = invokeError instanceof Error ? invokeError.message : String(invokeError);
          return errorCreditsInfo(rendered);
        }

        const record = asRecord(payload);
        if (record) {
          const inFlight = valueAsBoolean(record.inFlight) ?? false;
          if (inFlight) {
            await new Promise((resolve) => window.setTimeout(resolve, 500));
            continue;
          }

          const credits = asCreditsInfo(record.credits);
          if (credits) {
            return credits;
          }
        }

        return errorCreditsInfo("Usage refresh returned an invalid response.");
      }
    } catch (refreshError) {
      const rendered = refreshError instanceof Error ? refreshError.message : String(refreshError);
      return errorCreditsInfo(rendered);
    }
  })();

  inflightRefreshByAccountId.set(id, pending);
  try {
    return await pending;
  } finally {
    const current = inflightRefreshByAccountId.get(id);
    if (current === pending) {
      inflightRefreshByAccountId.delete(id);
    }
  }
};
