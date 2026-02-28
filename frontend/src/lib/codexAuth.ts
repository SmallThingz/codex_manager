const CODEX_OAUTH_ISSUER = "https://auth.openai.com";
const CODEX_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";
const CODEX_REDIRECT_URI = "http://localhost:1455/auth/callback";
const CODEX_ORIGINATOR = "codex_cli_rs";
const CODEX_SCOPE = "openid profile email";
const AUTO_REFRESH_ACTIVE_DEFAULT_INTERVAL_SEC = 300;
const AUTO_REFRESH_ACTIVE_MIN_INTERVAL_SEC = 15;
const AUTO_REFRESH_ACTIVE_MAX_INTERVAL_SEC = 21600;

export type AccountSummary = {
  id: string;
  accountId: string | null;
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

export type OAuthLoginResult = {
  account: AccountSummary;
  output: string;
};

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
  nonce: string;
  startedAt: number;
};

type BridgeResult<T> = {
  ok: boolean;
  value?: T;
  error?: string;
};

type WebuiRpcBridge = {
  cm_rpc: (requestJson: string) => Promise<unknown> | unknown;
};

type BackendApis = {
  invoke: <T>(command: string, payload?: Record<string, unknown>) => Promise<T>;
  openUrl: (url: string) => Promise<void>;
};

let backendApisPromise: Promise<BackendApis> | null = null;
let pendingBrowserLogin: PendingBrowserLogin | null = null;
const inflightRefreshByAccountId = new Map<string, Promise<CreditsInfo>>();

const nowEpoch = (): number => Math.floor(Date.now() / 1000);

const normalizeOptional = (value: string | null | undefined): string | null => {
  if (!value) {
    return null;
  }

  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
};

const asRecord = (value: unknown): Record<string, unknown> | null => {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return null;
  }

  return value as Record<string, unknown>;
};

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

const normalizeUsageRefreshDisplayMode = (value: unknown): "date" | "remaining" => {
  return value === "remaining" ? "remaining" : "date";
};

const defaultCreditsInfo = (message: string): CreditsInfo => ({
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
  status: "unavailable",
  message,
  checkedAt: nowEpoch(),
});

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

const asAccountSummary = (value: unknown): AccountSummary | null => {
  const account = asRecord(value);
  if (!account || typeof account.id !== "string") {
    return null;
  }

  return {
    id: account.id,
    accountId: normalizeOptional(typeof account.accountId === "string" ? account.accountId : null),
    email: normalizeOptional(typeof account.email === "string" ? account.email : null),
    state:
      account.state === "archived" || account.state === "frozen" || account.state === "active"
        ? account.state
        : "active",
  };
};

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

  if (typeof record.ok === "boolean") {
    const bridged = record as BridgeResult<T>;
    if (!bridged.ok) {
      throw new Error(bridged.error || `Backend bridge call failed for op "${op}".`);
    }
    return bridged.value as T;
  }

  if (record.value !== undefined || record.error !== undefined) {
    if (typeof record.error === "string") {
      throw new Error(record.error);
    }
    if (record.value === undefined) {
      throw new Error(`Backend bridge call failed for op "${op}".`);
    }
    return decodeBridgeValue<T>(op, record.value);
  }

  return value as T;
};

const getWebuiBridge = (): WebuiRpcBridge | null => {
  const bridge = (globalThis as { webuiRpc?: WebuiRpcBridge }).webuiRpc;
  if (!bridge || typeof bridge.cm_rpc !== "function") {
    return null;
  }
  return bridge;
};

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

const callBridge = async <T>(op: string, payload: Record<string, unknown> = {}): Promise<T> => {
  const request = JSON.stringify({ op, ...payload });
  const bridge = await waitForWebuiBridge();
  const rawResponse = await bridge.cm_rpc(request);
  return decodeBridgeValue<T>(op, rawResponse);
};

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

const parseAccountsViewResponse = (payload: unknown, opName: string): AccountsView => {
  const view = asAccountsView(payload);
  if (view) {
    return view;
  }

  throw new Error(`Unexpected ${opName} response from backend.`);
};

const parseThemeFromPreferencesResponse = (payload: unknown): "light" | "dark" | null => {
  const parsed = asRecord(payload);
  if (!parsed) {
    throw new Error("Unexpected get_ui_preferences response from backend.");
  }

  return parsed.theme === "light" || parsed.theme === "dark" ? parsed.theme : null;
};

const parseUsageCacheResponse = (payload: unknown): Record<string, CreditsInfo> => {
  const parsed = asRecord(payload);
  if (!parsed) {
    throw new Error("Unexpected get_usage_cache response from backend.");
  }

  const usageById: Record<string, CreditsInfo> = {};
  for (const [id, creditsRaw] of Object.entries(parsed)) {
    const credits = asCreditsInfo(creditsRaw);
    if (credits) {
      usageById[id] = credits;
    }
  }
  return usageById;
};

const randomBase64Url = (size: number): string => {
  const bytes = new Uint8Array(size);
  crypto.getRandomValues(bytes);
  const binary = Array.from(bytes, (byte) => String.fromCharCode(byte)).join("");
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
};

const buildAuthorizeUrl = (
  issuer: string,
  clientId: string,
  redirectUri: string,
  state: string,
  nonce: string,
): string => {
  const query = new URLSearchParams({
    response_type: "id_token",
    response_mode: "query",
    client_id: clientId,
    redirect_uri: redirectUri,
    scope: CODEX_SCOPE,
    id_token_add_organizations: "true",
    codex_cli_simplified_flow: "true",
    state,
    nonce,
    originator: CODEX_ORIGINATOR,
  });

  return `${issuer}/oauth/authorize?${query.toString()}`;
};

const waitForOAuthCallbackFromBrowser = async (
  pending: PendingBrowserLogin,
  label?: string,
): Promise<AccountSummary> => {
  const tauri = await loadBackendApis();

  const renderCallbackError = (errorCode: string): string => {
    if (errorCode === "CallbackListenerStopped") return "Callback listener stopped.";
    if (errorCode === "CallbackListenerTimeout") return "Callback listener timed out.";
    if (errorCode === "AddressInUse") return "Callback listener port 1455 is already in use.";
    if (errorCode === "OAuthStateMismatch") return "State mismatch. Start a fresh login and try again.";
    if (errorCode === "AuthorizationCodeExchangeFailed") return "Token exchange failed. Start a fresh login and try again.";
    if (errorCode === "OAuthAuthorizationFailed") return "Login authorization failed in browser.";
    return errorCode;
  };

  try {
    const payload = await tauri.invoke<unknown>("wait_for_oauth_callback", {
      timeoutSeconds: 180,
      issuer: pending.issuer,
      clientId: pending.clientId,
      redirectUri: pending.redirectUri,
      oauthState: pending.state,
      label,
    });
    const account = asAccountSummary(payload);
    if (!account) {
      throw new Error("Callback listener returned an invalid account payload.");
    }
    return account;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(renderCallbackError(message));
  }
};

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

export const getSavedTheme = async (): Promise<"light" | "dark" | null> => {
  const tauri = await loadBackendApis();
  const response = await tauri.invoke<unknown>("get_ui_preferences");
  return parseThemeFromPreferencesResponse(response);
};

export const saveTheme = async (theme: "light" | "dark"): Promise<void> => {
  const tauri = await loadBackendApis();
  await tauri.invoke<unknown>("update_ui_preferences", { theme });
};

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

export const getUsageCache = async (): Promise<Record<string, CreditsInfo>> => {
  const tauri = await loadBackendApis();
  const usage = await tauri.invoke<unknown>("get_usage_cache");
  return parseUsageCacheResponse(usage);
};

export const importCurrentAccount = async (label?: string): Promise<AccountsView> => {
  const tauri = await loadBackendApis();
  const view = await tauri.invoke<unknown>("import_current_account", { label });
  return parseAccountsViewResponse(view, "import_current_account");
};

export const beginCodexLogin = async (): Promise<BrowserLoginStart> => {
  const state = randomBase64Url(32);
  const nonce = randomBase64Url(32);

  const pending: PendingBrowserLogin = {
    issuer: CODEX_OAUTH_ISSUER,
    clientId: CODEX_CLIENT_ID,
    redirectUri: CODEX_REDIRECT_URI,
    state,
    nonce,
    startedAt: nowEpoch(),
  };

  pendingBrowserLogin = pending;

  const authUrl = buildAuthorizeUrl(
    pending.issuer,
    pending.clientId,
    pending.redirectUri,
    pending.state,
    pending.nonce,
  );

  const tauri = await loadBackendApis();
  await tauri.openUrl(authUrl);

  return {
    authUrl,
    redirectUri: pending.redirectUri,
  };
};

export const listenForCodexCallback = async (): Promise<OAuthLoginResult> => {
  if (!pendingBrowserLogin) {
    throw new Error("No active login session. Start ChatGPT login first.");
  }

  const pending = pendingBrowserLogin;
  const account = await waitForOAuthCallbackFromBrowser(pending);
  pendingBrowserLogin = null;
  return {
    account,
    output: "ChatGPT login completed.",
  };
};

export const stopCodexCallbackListener = async (): Promise<void> => {
  const tauri = await loadBackendApis();
  await tauri.invoke<boolean>("cancel_oauth_callback_listener");
};

export const codexLoginWithApiKey = async (apiKey: string, label?: string): Promise<LoginResult> => {
  const normalized = normalizeOptional(apiKey);
  if (!normalized) {
    throw new Error("API key is required.");
  }

  const tauri = await loadBackendApis();
  const view = parseAccountsViewResponse(
    await tauri.invoke<unknown>("login_with_api_key", {
      apiKey: normalized,
      label,
    }),
    "login_with_api_key",
  );

  return {
    view,
    output: "API key login completed.",
  };
};

export const switchAccount = async (id: string): Promise<AccountsView> => {
  const tauri = await loadBackendApis();
  const view = await tauri.invoke<unknown>("switch_account", { accountId: id });
  return parseAccountsViewResponse(view, "switch_account");
};

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

export const archiveAccount = async (
  id: string,
  options?: { switchAwayFromArchived?: boolean },
): Promise<void> => {
  return moveAccount(id, "depleted", Number.MAX_SAFE_INTEGER, {
    switchAwayFromMoved: options?.switchAwayFromArchived,
  });
};

export const unarchiveAccount = async (id: string): Promise<void> => {
  return moveAccount(id, "active", Number.MAX_SAFE_INTEGER);
};

export const removeAccount = async (id: string): Promise<AccountsView> => {
  const tauri = await loadBackendApis();
  const view = await tauri.invoke<unknown>("remove_account", { accountId: id });
  return parseAccountsViewResponse(view, "remove_account");
};

export const getRemainingCreditsForAccount = async (id: string): Promise<CreditsInfo> => {
  const existing = inflightRefreshByAccountId.get(id);
  if (existing) {
    return existing;
  }

  const pending = (async (): Promise<CreditsInfo> => {
    const tauri = await loadBackendApis();
    const payload = await tauri.invoke<unknown>("refresh_account_usage", { accountId: id });
    const record = asRecord(payload);
    if (record) {
      const credits = asCreditsInfo(record.credits);
      if (credits) {
        return credits;
      }
    }
    return defaultCreditsInfo("No usage data available for this account.");
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
