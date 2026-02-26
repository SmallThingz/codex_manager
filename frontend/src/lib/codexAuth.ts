const CODEX_OAUTH_ISSUER = "https://auth.openai.com";
const CODEX_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";
const CODEX_REDIRECT_URI = "http://localhost:1455/auth/callback";
const CODEX_ORIGINATOR = "codex_cli_rs";
const CODEX_SCOPE = "openid profile email offline_access";
const TOKEN_EXCHANGE_GRANT = "urn:ietf:params:oauth:grant-type:token-exchange";
const ID_TOKEN_TYPE = "urn:ietf:params:oauth:token-type:id_token";
const AUTO_REFRESH_ACTIVE_DEFAULT_INTERVAL_SEC = 300;
const AUTO_REFRESH_ACTIVE_MIN_INTERVAL_SEC = 15;
const AUTO_REFRESH_ACTIVE_MAX_INTERVAL_SEC = 21600;

export type AccountSummary = {
  id: string;
  label: string | null;
  accountId: string | null;
  email: string | null;
  archived: boolean;
  frozen: boolean;
  isActive: boolean;
  updatedAt: number;
  lastUsedAt: number | null;
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

export type LoginResult = {
  view: AccountsView;
  output: string;
};

export type BrowserLoginStart = {
  authUrl: string;
  redirectUri: string;
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

type ManagedAccount = {
  id: string;
  label: string | null;
  accountId: string | null;
  email: string | null;
  archived: boolean;
  frozen: boolean;
  auth: unknown;
  createdAt: number;
  updatedAt: number;
  lastUsedAt: number | null;
};

type AccountsStore = {
  activeAccountId: string | null;
  accounts: ManagedAccount[];
};

type Paths = {
  codexHome: string;
  codexAuthPath: string;
  storeDir: string;
  storePath: string;
  bootstrapStatePath: string;
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

type PendingBrowserLogin = {
  issuer: string;
  clientId: string;
  redirectUri: string;
  state: string;
  codeVerifier: string;
  startedAt: number;
};

type TokenPair = {
  idToken: string;
  accessToken: string;
  refreshToken: string;
};

type WhamUsageResponse = {
  status: number;
  body: unknown;
};

type OAuthCallbackPollResponse = {
  status: "idle" | "running" | "ready" | "error";
  callbackUrl?: string | null;
  error?: string | null;
};

let pathsPromise: Promise<Paths> | null = null;
let pendingBrowserLogin: PendingBrowserLogin | null = null;

type BackendApis = {
  invoke: <T>(command: string, payload?: Record<string, unknown>) => Promise<T>;
  openUrl: (url: string) => Promise<void>;
  getManagedPaths: () => Promise<Paths>;
  readManagedStore: () => Promise<string | null>;
  writeManagedStore: (contents: string) => Promise<void>;
  readCodexAuth: () => Promise<string | null>;
  writeCodexAuth: (contents: string) => Promise<void>;
  readBootstrapState: () => Promise<string | null>;
  writeBootstrapState: (contents: string) => Promise<void>;
};

type BridgeResult<T> = {
  ok: boolean;
  value?: T;
  error?: string;
};

let backendApisPromise: Promise<BackendApis> | null = null;

type WebUiBridge = {
  call?: (fn: string, ...args: unknown[]) => Promise<string> | string;
};

const callBridge = async <T>(op: string, payload: Record<string, unknown> = {}): Promise<T> => {
  const request = JSON.stringify({
    op,
    ...payload,
  });

  let lastBridgeError: string | null = null;

  const startedAt = Date.now();
  while (Date.now() - startedAt < 15000) {
    if (typeof window.cm_rpc === "function") {
      try {
        const rawResponse = await window.cm_rpc(request);
        const parsed = JSON.parse(rawResponse) as BridgeResult<T>;
        if (!parsed.ok) {
          throw new Error(parsed.error || `Backend bridge call failed for op "${op}".`);
        }
        return parsed.value as T;
      } catch (error) {
        lastBridgeError = error instanceof Error ? error.message : String(error);
      }
    }

    const webuiCall = (window as Window & { webui?: WebUiBridge }).webui?.call;
    if (typeof webuiCall === "function") {
      try {
        const rawResponse = await webuiCall("cm_rpc", request);
        const parsed = JSON.parse(rawResponse) as BridgeResult<T>;
        if (!parsed.ok) {
          throw new Error(parsed.error || `Backend bridge call failed for op "${op}".`);
        }
        return parsed.value as T;
      } catch (error) {
        lastBridgeError = error instanceof Error ? error.message : String(error);
      }
    }

    if (window.location.protocol === "http:" || window.location.protocol === "https:") {
      try {
        const rpcPayload = JSON.stringify({
          name: "call",
          args: ["cm_rpc", request],
        });
        const response = await fetch("/rpc", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
          },
          body: rpcPayload,
          cache: "no-store",
        });
        if (!response.ok) {
          lastBridgeError = `HTTP bridge request failed (${response.status}).`;
        } else {
          const rawResponse = await response.text();
          const rpcResponse = JSON.parse(rawResponse) as { value?: string };
          if (typeof rpcResponse.value !== "string") {
            throw new Error(`Backend bridge call failed for op "${op}".`);
          }

          const parsed = JSON.parse(rpcResponse.value) as BridgeResult<T>;
          if (!parsed.ok) {
            throw new Error(parsed.error || `Backend bridge call failed for op "${op}".`);
          }
          return parsed.value as T;
        }
      } catch (error) {
        lastBridgeError = error instanceof Error ? error.message : String(error);
      }
    }

    await new Promise((resolve) => {
      window.setTimeout(resolve, 75);
    });
  }

  const hasCmRpc = typeof window.cm_rpc === "function";
  const hasWebUiObject = typeof (window as Window & { webui?: WebUiBridge }).webui !== "undefined";
  const hasWebUiCall = typeof (window as Window & { webui?: WebUiBridge }).webui?.call === "function";

  throw new Error(
    [
      `Backend RPC unavailable in this session at ${window.location.origin}.`,
      `has_cm_rpc=${String(hasCmRpc)}`,
      `has_webui=${String(hasWebUiObject)}`,
      `has_webui_call=${String(hasWebUiCall)}`,
      `document_ready_state=${document.readyState}`,
      lastBridgeError ? `last_bridge_error=${lastBridgeError}` : "last_bridge_error=none",
    ].join(" "),
  );
};

const loadBackendApis = async (): Promise<BackendApis> => {
  if (!backendApisPromise) {
    backendApisPromise = Promise.resolve({
      invoke: async <T>(command: string, payload: Record<string, unknown> = {}) =>
        callBridge<T>(`invoke:${command}`, payload),
      openUrl: async (url: string) => {
        await callBridge<null>("shell:open_url", { url });
      },
      getManagedPaths: async () => callBridge<Paths>("invoke:get_managed_paths"),
      readManagedStore: async () => callBridge<string | null>("invoke:read_managed_store"),
      writeManagedStore: async (contents: string) => {
        await callBridge<null>("invoke:write_managed_store", { contents });
      },
      readCodexAuth: async () => callBridge<string | null>("invoke:read_codex_auth"),
      writeCodexAuth: async (contents: string) => {
        await callBridge<null>("invoke:write_codex_auth", { contents });
      },
      readBootstrapState: async () => callBridge<string | null>("invoke:read_bootstrap_state"),
      writeBootstrapState: async (contents: string) => {
        await callBridge<null>("invoke:write_bootstrap_state", { contents });
      },
    });
  }

  return backendApisPromise;
};

export const getSavedTheme = async (): Promise<"light" | "dark" | null> => {
  const value = await callBridge<string | null>("settings:get_theme");
  if (value === "light" || value === "dark") {
    return value;
  }

  return null;
};

export const saveTheme = async (theme: "light" | "dark"): Promise<void> => {
  await callBridge<null>("settings:set_theme", { theme });
};

const nowEpoch = (): number => Math.floor(Date.now() / 1000);

const generateAccountId = (): string =>
  `acct-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;

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

const getString = (obj: Record<string, unknown> | null, key: string): string | null => {
  if (!obj) {
    return null;
  }

  const value = obj[key];
  return typeof value === "string" && value.trim().length > 0 ? value : null;
};

const decodeJwtPayload = (token: string): Record<string, unknown> | null => {
  const payload = token.split(".")[1];
  if (!payload) {
    return null;
  }

  try {
    const base64 = payload.replace(/-/g, "+").replace(/_/g, "/");
    const padding = base64.length % 4;
    const normalized = padding === 0 ? base64 : `${base64}${"=".repeat(4 - padding)}`;
    const binary = atob(normalized);
    const bytes = Uint8Array.from(binary, (char) => char.charCodeAt(0));
    const json = new TextDecoder().decode(bytes);
    return asRecord(JSON.parse(json));
  } catch {
    return null;
  }
};

const extractTokens = (auth: unknown): Record<string, unknown> | null => {
  const root = asRecord(auth);
  return asRecord(root?.tokens);
};

const extractApiKey = (auth: unknown): string | null => {
  const root = asRecord(auth);
  return getString(root, "OPENAI_API_KEY");
};

const extractIdToken = (auth: unknown): string | null => {
  const tokens = extractTokens(auth);
  const direct = getString(tokens, "id_token");
  if (direct) {
    return direct;
  }

  const idTokenObj = asRecord(tokens?.id_token);
  return getString(idTokenObj, "raw_jwt");
};

const extractAuthClaims = (auth: unknown): Record<string, unknown> | null => {
  const idToken = extractIdToken(auth);
  if (!idToken) {
    return null;
  }

  const payload = decodeJwtPayload(idToken);
  return asRecord(payload?.["https://api.openai.com/auth"]);
};

const extractAccountId = (auth: unknown): string | null => {
  const fromTokens = getString(extractTokens(auth), "account_id");
  if (fromTokens) {
    return fromTokens;
  }

  return getString(extractAuthClaims(auth), "chatgpt_account_id");
};

const extractEmail = (auth: unknown): string | null => {
  const idToken = extractIdToken(auth);
  if (!idToken) {
    return null;
  }

  const payload = decodeJwtPayload(idToken);
  const profile = asRecord(payload?.["https://api.openai.com/profile"]);

  return (
    getString(payload, "email") ||
    getString(profile, "email") ||
    getString(payload, "preferred_username") ||
    getString(payload, "upn") ||
    getString(payload, "name") ||
    getString(payload, "sub")
  );
};

const validateAuth = (auth: unknown): void => {
  const apiKey = extractApiKey(auth);
  if (apiKey) {
    return;
  }

  const accessToken = getString(extractTokens(auth), "access_token");
  if (accessToken) {
    return;
  }

  throw new Error("Auth JSON must contain OPENAI_API_KEY or tokens.access_token.");
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

const parseCreditsPayload = (
  payload: Record<string, unknown>,
): { available: number | null; used: number | null; total: number | null } | null => {
  const summary = asRecord(payload.credit_summary);

  const available = valueAsNumber(payload.total_available) ?? valueAsNumber(summary?.total_available);
  const used = valueAsNumber(payload.total_used) ?? valueAsNumber(summary?.total_used);
  const total = valueAsNumber(payload.total_granted) ?? valueAsNumber(summary?.total_granted);

  if (available === null && used === null && total === null) {
    return null;
  }

  return { available, used, total };
};

const parseRateLimitUsedPercent = (payload: Record<string, unknown>): number | null => {
  const rateLimit = asRecord(payload.rate_limit) ?? asRecord(payload.rateLimit);
  const primaryWindow = asRecord(rateLimit?.primary_window) ?? asRecord(rateLimit?.primaryWindow);
  return valueAsNumber(primaryWindow?.used_percent) ?? valueAsNumber(primaryWindow?.usedPercent);
};

type RateLimitWindowInfo = {
  usedPercent: number;
  windowSeconds: number;
  refreshAt: number | null;
};

const parseEpochSeconds = (value: unknown): number | null => {
  if (typeof value === "number" && Number.isFinite(value)) {
    if (value > 1_000_000_000_000) {
      return Math.floor(value / 1000);
    }
    return Math.floor(value);
  }

  if (typeof value === "string") {
    const trimmed = value.trim();
    if (!trimmed) {
      return null;
    }

    const asNumber = Number.parseFloat(trimmed);
    if (Number.isFinite(asNumber)) {
      if (asNumber > 1_000_000_000_000) {
        return Math.floor(asNumber / 1000);
      }
      return Math.floor(asNumber);
    }

    const parsedDate = Date.parse(trimmed);
    if (Number.isFinite(parsedDate)) {
      return Math.floor(parsedDate / 1000);
    }
  }

  return null;
};

const clampPercent = (value: number): number => Math.max(0, Math.min(100, value));

const parseRateLimitWindows = (
  rateLimit: Record<string, unknown> | null,
  checkedAt: number,
): RateLimitWindowInfo[] => {
  if (!rateLimit) {
    return [];
  }

  const windows: RateLimitWindowInfo[] = [];

  for (const key of ["primary_window", "secondary_window", "primaryWindow", "secondaryWindow"]) {
    const window = asRecord(rateLimit[key]);
    const usedPercent = valueAsNumber(window?.used_percent) ?? valueAsNumber(window?.usedPercent);
    const windowSeconds = valueAsNumber(window?.limit_window_seconds) ?? valueAsNumber(window?.limitWindowSeconds);

    if (usedPercent === null || windowSeconds === null) {
      continue;
    }

    const refreshAt =
      parseEpochSeconds(window?.next_reset_at) ??
      parseEpochSeconds(window?.nextResetAt) ??
      parseEpochSeconds(window?.reset_at) ??
      parseEpochSeconds(window?.resetAt) ??
      parseEpochSeconds(window?.resets_at) ??
      parseEpochSeconds(window?.resetsAt) ??
      parseEpochSeconds(window?.window_reset_at) ??
      parseEpochSeconds(window?.windowResetAt) ??
      parseEpochSeconds(window?.next_refresh_at) ??
      parseEpochSeconds(window?.nextRefreshAt) ??
      parseEpochSeconds(window?.refresh_at) ??
      parseEpochSeconds(window?.refreshAt) ??
      (() => {
        const resetInSeconds =
          valueAsNumber(window?.seconds_until_reset) ??
          valueAsNumber(window?.secondsUntilReset) ??
          valueAsNumber(window?.reset_in_seconds) ??
          valueAsNumber(window?.resetInSeconds) ??
          valueAsNumber(window?.time_until_reset_seconds) ??
          valueAsNumber(window?.timeUntilResetSeconds) ??
          valueAsNumber(window?.window_remaining_seconds);
        if (resetInSeconds === null || resetInSeconds < 0) {
          return null;
        }
        return checkedAt + Math.floor(resetInSeconds);
      })();

    windows.push({
      usedPercent: clampPercent(usedPercent),
      windowSeconds,
      refreshAt,
    });
  }

  return windows;
};

const collectAllRateLimitWindows = (payload: Record<string, unknown>, checkedAt: number): RateLimitWindowInfo[] => {
  const windows: RateLimitWindowInfo[] = [];
  windows.push(...parseRateLimitWindows(asRecord(payload.rate_limit) ?? asRecord(payload.rateLimit), checkedAt));

  const additional = payload.additional_rate_limits ?? payload.additionalRateLimits;
  if (!Array.isArray(additional)) {
    return windows;
  }

  for (const entry of additional) {
    const record = asRecord(entry);
    windows.push(
      ...parseRateLimitWindows(asRecord(record?.rate_limit) ?? asRecord(record?.rateLimit), checkedAt),
    );
  }

  return windows;
};

const remainingFromWindow = (window: RateLimitWindowInfo | null): number | null => {
  if (!window) {
    return null;
  }

  return clampPercent(100 - window.usedPercent);
};

const refreshAtFromWindow = (window: RateLimitWindowInfo | null, checkedAt: number): number | null => {
  if (!window) {
    return null;
  }

  if (window.refreshAt !== null) {
    return window.refreshAt;
  }

  if (window.windowSeconds > 0) {
    return checkedAt + Math.floor(window.windowSeconds);
  }

  return null;
};

const pickWeeklyWindow = (windows: RateLimitWindowInfo[]): RateLimitWindowInfo | null => {
  if (windows.length === 0) {
    return null;
  }

  const weeklyCandidates = windows
    .filter((window) => window.windowSeconds >= 86400)
    .sort((a, b) => Math.abs(a.windowSeconds - 604800) - Math.abs(b.windowSeconds - 604800));

  if (weeklyCandidates.length > 0) {
    return weeklyCandidates[0];
  }

  const sorted = [...windows].sort((a, b) => b.windowSeconds - a.windowSeconds);
  return sorted[0] ?? null;
};

const pickHourlyWindow = (
  windows: RateLimitWindowInfo[],
  weeklyWindow: RateLimitWindowInfo | null,
): RateLimitWindowInfo | null => {
  if (windows.length === 0) {
    return null;
  }

  const withoutWeekly = weeklyWindow
    ? windows.filter(
        (window) =>
          !(
            window.windowSeconds === weeklyWindow.windowSeconds &&
            window.usedPercent === weeklyWindow.usedPercent
          ),
      )
    : windows;

  const shortCandidates = withoutWeekly
    .filter((window) => window.windowSeconds <= 43200)
    .sort((a, b) => a.windowSeconds - b.windowSeconds);

  if (shortCandidates.length > 0) {
    return shortCandidates[0];
  }

  const sorted = [...withoutWeekly].sort((a, b) => a.windowSeconds - b.windowSeconds);
  return sorted[0] ?? null;
};

const parseWhamCredits = (
  payload: Record<string, unknown>,
  checkedAt: number,
): {
  balance: number | null;
  hasCredits: boolean | null;
  unlimited: boolean | null;
  usedPercent: number | null;
  planType: string | null;
  isPaidPlan: boolean;
  hourlyRemainingPercent: number | null;
  weeklyRemainingPercent: number | null;
  hourlyRefreshAt: number | null;
  weeklyRefreshAt: number | null;
} => {
  const credits = asRecord(payload.credits);
  const balance = valueAsNumber(credits?.balance);
  const hasCredits = valueAsBoolean(credits?.has_credits);
  const unlimited = valueAsBoolean(credits?.unlimited);
  const usedPercent = parseRateLimitUsedPercent(payload);
  const planType = normalizeOptional(getString(payload, "plan_type"));
  const isPaidPlan = Boolean(planType && planType.toLowerCase() !== "free");
  const windows = collectAllRateLimitWindows(payload, checkedAt);
  const weeklyWindow = pickWeeklyWindow(windows);
  const hourlyWindow = pickHourlyWindow(windows, weeklyWindow);
  const hourlyRemainingPercent = isPaidPlan ? remainingFromWindow(hourlyWindow) : null;
  const weeklyRemainingPercent = isPaidPlan ? remainingFromWindow(weeklyWindow) : null;
  const hourlyRefreshAt = refreshAtFromWindow(hourlyWindow, checkedAt);
  const weeklyRefreshAt = refreshAtFromWindow(weeklyWindow, checkedAt);

  return {
    balance,
    hasCredits,
    unlimited,
    usedPercent,
    planType,
    isPaidPlan,
    hourlyRemainingPercent,
    weeklyRemainingPercent,
    hourlyRefreshAt,
    weeklyRefreshAt,
  };
};

const base64UrlEncode = (bytes: Uint8Array): string => {
  const binary = Array.from(bytes, (byte) => String.fromCharCode(byte)).join("");
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
};

const randomBase64Url = (size: number): string => {
  const bytes = new Uint8Array(size);
  crypto.getRandomValues(bytes);
  return base64UrlEncode(bytes);
};

const sha256Base64Url = async (value: string): Promise<string> => {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return base64UrlEncode(new Uint8Array(digest));
};

const buildAuthorizeUrl = (
  issuer: string,
  clientId: string,
  redirectUri: string,
  codeChallenge: string,
  state: string,
): string => {
  const query = new URLSearchParams({
    response_type: "code",
    client_id: clientId,
    redirect_uri: redirectUri,
    scope: CODEX_SCOPE,
    code_challenge: codeChallenge,
    code_challenge_method: "S256",
    id_token_add_organizations: "true",
    codex_cli_simplified_flow: "true",
    state,
    originator: CODEX_ORIGINATOR,
  });

  return `${issuer}/oauth/authorize?${query.toString()}`;
};

const parseTokenEndpointError = (bodyText: string): string => {
  const trimmed = bodyText.trim();
  if (!trimmed) {
    return "unknown error";
  }

  try {
    const parsed = asRecord(JSON.parse(trimmed));
    const description = getString(parsed, "error_description");
    if (description) {
      return description;
    }

    const errorObj = asRecord(parsed?.error);
    const errorMessage = getString(errorObj, "message");
    if (errorMessage) {
      return errorMessage;
    }

    const errorCode = getString(parsed, "error");
    if (errorCode) {
      return errorCode;
    }
  } catch {
    // plain-text responses still provide useful details
  }

  return trimmed;
};

const parseCallbackInput = (callbackInput: string): { code: string; state: string | null } => {
  const trimmed = callbackInput.trim();
  if (!trimmed) {
    throw new Error("Paste the callback URL from your browser.");
  }

  let url: URL;
  try {
    url = new URL(trimmed);
  } catch {
    throw new Error(
      "Invalid callback URL. Paste the full URL that starts with http://localhost:1455/auth/callback?",
    );
  }

  const code = normalizeOptional(url.searchParams.get("code"));
  if (!code) {
    const errorCode = normalizeOptional(url.searchParams.get("error"));
    const errorDescription = normalizeOptional(url.searchParams.get("error_description"));

    if (errorCode) {
      throw new Error(errorDescription ? `Login failed: ${errorDescription}` : `Login failed: ${errorCode}`);
    }

    throw new Error("The callback URL does not contain an authorization code.");
  }

  return {
    code,
    state: normalizeOptional(url.searchParams.get("state")),
  };
};

const waitForOAuthCallbackFromBrowser = async (): Promise<string> => {
  const tauri = await loadBackendApis();
  await tauri.invoke<boolean>("start_oauth_callback_listener", {
    timeoutSeconds: 180,
  });

  const renderCallbackError = (errorCode: string): string => {
    if (errorCode === "CallbackListenerStopped") {
      return "Callback listener stopped.";
    }
    if (errorCode === "CallbackListenerTimeout") {
      return "Callback listener timed out.";
    }
    if (errorCode === "AddressInUse") {
      return "Callback listener port 1455 is already in use.";
    }
    return errorCode;
  };

  while (true) {
    const status = await tauri.invoke<OAuthCallbackPollResponse>("poll_oauth_callback_listener");

    if (status.status === "ready") {
      const normalized = normalizeOptional(status.callbackUrl);
      if (!normalized) {
        throw new Error("Callback listener returned an empty redirect URL.");
      }
      return normalized;
    }

    if (status.status === "error") {
      const errorCode = normalizeOptional(status.error) || "Callback listener failed.";
      throw new Error(renderCallbackError(errorCode));
    }

    await new Promise((resolve) => {
      window.setTimeout(resolve, 250);
    });
  }
};

const fetchWhamUsageViaTauri = async (
  accessToken: string,
  accountId: string | null,
): Promise<{ status: number; payload: Record<string, unknown> | null; rawBody: unknown }> => {
  const tauri = await loadBackendApis();
  const response = await tauri.invoke<WhamUsageResponse>("fetch_wham_usage", {
    accessToken,
    accountId,
  });

  const bodyCandidate =
    typeof response.body === "string"
      ? (() => {
          try {
            return JSON.parse(response.body);
          } catch {
            return response.body;
          }
        })()
      : response.body;
  const payload = asRecord(bodyCandidate);
  return {
    status: response.status,
    payload,
    rawBody: bodyCandidate,
  };
};

export const listenForCodexCallback = async (): Promise<string> => {
  return waitForOAuthCallbackFromBrowser();
};

export const stopCodexCallbackListener = async (): Promise<void> => {
  const tauri = await loadBackendApis();
  await tauri.invoke<boolean>("cancel_oauth_callback_listener");
};

const exchangeAuthorizationCode = async (
  pending: PendingBrowserLogin,
  code: string,
): Promise<TokenPair> => {
  const body = new URLSearchParams({
    grant_type: "authorization_code",
    code,
    redirect_uri: pending.redirectUri,
    client_id: pending.clientId,
    code_verifier: pending.codeVerifier,
  }).toString();

  const response = await fetch(`${pending.issuer}/oauth/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });

  if (!response.ok) {
    const details = parseTokenEndpointError(await response.text());
    throw new Error(`Token exchange failed (${response.status}): ${details}`);
  }

  const payload = asRecord(await response.json());
  const idToken = getString(payload, "id_token");
  const accessToken = getString(payload, "access_token");
  const refreshToken = getString(payload, "refresh_token");

  if (!idToken || !accessToken || !refreshToken) {
    throw new Error("Token exchange succeeded but returned an unexpected payload.");
  }

  return { idToken, accessToken, refreshToken };
};

const exchangeApiKey = async (
  issuer: string,
  clientId: string,
  idToken: string,
): Promise<string | null> => {
  const body = new URLSearchParams({
    grant_type: TOKEN_EXCHANGE_GRANT,
    client_id: clientId,
    requested_token: "openai-api-key",
    subject_token: idToken,
    subject_token_type: ID_TOKEN_TYPE,
  }).toString();

  const response = await fetch(`${issuer}/oauth/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });

  if (!response.ok) {
    return null;
  }

  const payload = asRecord(await response.json());
  return getString(payload, "access_token");
};

const buildChatgptAuthPayload = (tokens: TokenPair, apiKey: string | null): Record<string, unknown> => {
  const claims = decodeJwtPayload(tokens.idToken);
  const authClaims = asRecord(claims?.["https://api.openai.com/auth"]);
  const accountId = getString(authClaims, "chatgpt_account_id");

  const payload: Record<string, unknown> = {
    auth_mode: "chatgpt",
    tokens: {
      id_token: tokens.idToken,
      access_token: tokens.accessToken,
      refresh_token: tokens.refreshToken,
      account_id: accountId,
    },
    last_refresh: new Date().toISOString(),
  };

  if (apiKey) {
    payload.OPENAI_API_KEY = apiKey;
  }

  return payload;
};

const resolvePaths = async (): Promise<Paths> => {
  if (!pathsPromise) {
    pathsPromise = (async () => {
      const tauri = await loadBackendApis();
      return tauri.getManagedPaths();
    })();
  }

  return pathsPromise;
};

const asBootstrapState = (value: unknown): EmbeddedBootstrapState | null => {
  const parsed = asRecord(value);
  if (!parsed) {
    return null;
  }

  const themeRaw = parsed.theme;
  const theme = themeRaw === "light" || themeRaw === "dark" ? themeRaw : null;
  const viewRaw = parsed.view;
  const view = asRecord(viewRaw) ? (viewRaw as AccountsView) : null;
  const usageRaw = asRecord(parsed.usageById);
  const usageById: Record<string, CreditsInfo> = {};
  const legacyArchiveFolders = Array.isArray(parsed.archiveFolders) ? parsed.archiveFolders : [];
  const legacyAutoArchiveEnabled = legacyArchiveFolders.some((entry) => {
    const folder = asRecord(entry);
    return valueAsBoolean(folder?.autoArchiveDepleted) === true;
  });

  if (usageRaw) {
    for (const [id, credits] of Object.entries(usageRaw)) {
      if (asRecord(credits)) {
        usageById[id] = credits as CreditsInfo;
      }
    }
  }

  return {
    theme,
    autoArchiveZeroQuota: valueAsBoolean(parsed.autoArchiveZeroQuota) ?? legacyAutoArchiveEnabled,
    autoUnarchiveNonZeroQuota: valueAsBoolean(parsed.autoUnarchiveNonZeroQuota) ?? false,
    autoSwitchAwayFromArchived: valueAsBoolean(parsed.autoSwitchAwayFromArchived) ?? true,
    autoRefreshActiveEnabled: valueAsBoolean(parsed.autoRefreshActiveEnabled) ?? false,
    autoRefreshActiveIntervalSec: normalizeAutoRefreshIntervalSec(parsed.autoRefreshActiveIntervalSec),
    usageRefreshDisplayMode: getString(parsed, "usageRefreshDisplayMode") === "remaining" ? "remaining" : "date",
    view,
    usageById,
    savedAt: valueAsNumber(parsed.savedAt) ?? nowEpoch(),
  };
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
    const parsed = JSON.parse(json);
    return asBootstrapState(parsed);
  } catch {
    return null;
  }
};

export const saveEmbeddedBootstrapState = async (state: EmbeddedBootstrapState): Promise<void> => {
  const tauri = await loadBackendApis();
  await tauri.writeBootstrapState(JSON.stringify(state, null, 2));
};

const readAuthFile = async (): Promise<unknown> => {
  const paths = await resolvePaths();
  const tauri = await loadBackendApis();
  const rawAuth = await tauri.readCodexAuth();

  if (rawAuth === null) {
    throw new Error(`Codex auth not found at ${paths.codexAuthPath}`);
  }

  return JSON.parse(rawAuth);
};

const writeAuthFile = async (auth: unknown): Promise<void> => {
  const tauri = await loadBackendApis();
  await tauri.writeCodexAuth(JSON.stringify(auth, null, 2));
};

const sanitizeAccount = (value: unknown): ManagedAccount | null => {
  const obj = asRecord(value);
  if (!obj) {
    return null;
  }

  const id = getString(obj, "id");
  if (!id) {
    return null;
  }

  const createdAt = valueAsNumber(obj.createdAt) ?? nowEpoch();
  const updatedAt = valueAsNumber(obj.updatedAt) ?? createdAt;
  const lastUsedAt = valueAsNumber(obj.lastUsedAt);
  const frozen = Boolean(obj.frozen);

  return {
    id,
    label: normalizeOptional(getString(obj, "label")),
    accountId: normalizeOptional(getString(obj, "accountId")),
    email: normalizeOptional(getString(obj, "email")),
    archived: Boolean(obj.archived) && !frozen,
    frozen,
    auth: obj.auth,
    createdAt,
    updatedAt,
    lastUsedAt,
  };
};

const readStore = async (): Promise<AccountsStore> => {
  const tauri = await loadBackendApis();
  const rawStore = await tauri.readManagedStore();
  if (!rawStore) {
    return { activeAccountId: null, accounts: [] };
  }
  const store = JSON.parse(rawStore) as AccountsStore;

  const rawAccounts = Array.isArray(store.accounts) ? store.accounts : [];
  const accounts = rawAccounts
    .map((entry) => sanitizeAccount(entry))
    .filter((entry): entry is ManagedAccount => entry !== null);

  const activeAccountId =
    typeof store.activeAccountId === "string" && accounts.some((a) => a.id === store.activeAccountId)
      ? store.activeAccountId
      : null;

  return {
    activeAccountId,
    accounts,
  };
};

const writeStore = async (store: AccountsStore): Promise<void> => {
  const tauri = await loadBackendApis();
  await tauri.writeManagedStore(JSON.stringify(store, null, 2));
};

const upsertAccount = (
  store: AccountsStore,
  auth: unknown,
  label: string | null,
  setActive: boolean,
): string => {
  const now = nowEpoch();
  const accountId = extractAccountId(auth);
  const email = extractEmail(auth);
  const normalizedLabel = normalizeOptional(label);

  const existingIndex = store.accounts.findIndex((account) => {
    const accountMatch = accountId && account.accountId === accountId;
    const emailMatch = email && account.email === email;
    return Boolean(accountMatch || emailMatch);
  });

  if (existingIndex >= 0) {
    const existing = store.accounts[existingIndex];
    existing.accountId = accountId;
    existing.email = email;
    existing.label = normalizedLabel ?? existing.label;
    existing.auth = auth;
    existing.archived = false;
    existing.frozen = false;
    existing.updatedAt = now;

    if (setActive) {
      existing.lastUsedAt = now;
      store.activeAccountId = existing.id;
    }

    return existing.id;
  }

  const id = generateAccountId();
  const next: ManagedAccount = {
    id,
    label: normalizedLabel,
    accountId,
    email,
    archived: false,
    frozen: false,
    auth,
    createdAt: now,
    updatedAt: now,
    lastUsedAt: setActive ? now : null,
  };

  store.accounts.push(next);

  if (setActive) {
    store.activeAccountId = id;
  }

  return id;
};

const moveActiveToFallback = async (store: AccountsStore, removedId?: string): Promise<void> => {
  const active = store.activeAccountId;
  if (!active) {
    return;
  }

  if (removedId && active !== removedId) {
    return;
  }

  const next = store.accounts.find((account) => !account.archived && !account.frozen && account.id !== removedId);
  if (!next) {
    store.activeAccountId = null;
    return;
  }

  validateAuth(next.auth);
  await writeAuthFile(next.auth);

  const now = nowEpoch();
  next.lastUsedAt = now;
  next.updatedAt = now;
  store.activeAccountId = next.id;
};

const accountBucketOf = (account: Pick<ManagedAccount, "archived" | "frozen">): AccountBucket => {
  if (account.frozen) {
    return "frozen";
  }
  if (account.archived) {
    return "depleted";
  }
  return "active";
};

const applyBucket = (account: ManagedAccount, bucket: AccountBucket) => {
  account.archived = bucket === "depleted";
  account.frozen = bucket === "frozen";
};

const buildView = async (store: AccountsStore): Promise<AccountsView> => {
  const paths = await resolvePaths();
  const tauri = await loadBackendApis();
  const activeAuthRaw = await tauri.readCodexAuth();
  const activeAuth = activeAuthRaw ? (JSON.parse(activeAuthRaw) as unknown) : null;
  const activeDiskAccountId = activeAuth ? extractAccountId(activeAuth) : null;
  const activeDiskEmail = activeAuth ? extractEmail(activeAuth) : null;

  const activeByAccountId = activeDiskAccountId
    ? store.accounts.find((account) => !account.archived && !account.frozen && account.accountId === activeDiskAccountId)
    : null;
  const activeByEmail =
    !activeByAccountId && activeDiskEmail
      ? store.accounts.find((account) => !account.archived && !account.frozen && account.email === activeDiskEmail)
      : null;
  const activeFromStore =
    store.activeAccountId &&
    store.accounts.some((account) => account.id === store.activeAccountId && !account.archived && !account.frozen)
      ? store.activeAccountId
      : null;

  const normalizedActiveId = activeByAccountId?.id || activeByEmail?.id || activeFromStore;
  const activeChanged = store.activeAccountId !== normalizedActiveId;
  store.activeAccountId = normalizedActiveId;

  if (activeChanged) {
    await writeStore(store);
  }

  const accounts = store.accounts.map((account) => ({
    id: account.id,
    label: account.label,
    accountId: account.accountId,
    email: account.email,
    archived: account.archived,
    frozen: account.frozen,
    isActive: account.id === normalizedActiveId,
    updatedAt: account.updatedAt,
    lastUsedAt: account.lastUsedAt,
  }));

  return {
    accounts,
    activeAccountId: normalizedActiveId,
    activeDiskAccountId,
    codexAuthExists: activeAuth !== null,
    codexAuthPath: paths.codexAuthPath,
    storePath: paths.storePath,
  };
};

const importFromCurrentAuth = async (label?: string): Promise<AccountsView> => {
  const auth = await readAuthFile();
  validateAuth(auth);

  const store = await readStore();
  upsertAccount(store, auth, normalizeOptional(label), true);
  await writeStore(store);

  return buildView(store);
};

const fetchLegacyCreditsFromApiKey = async (apiKey: string, checkedAt: number): Promise<CreditsInfo> => {
  const endpoints = [
    "https://api.openai.com/dashboard/billing/credit_grants",
    "https://api.openai.com/v1/dashboard/billing/credit_grants",
  ];

  let lastError = "No usable billing payload returned.";

  for (const endpoint of endpoints) {
    try {
      const response = await fetch(endpoint, {
        method: "GET",
        headers: {
          Authorization: `Bearer ${apiKey}`,
        },
      });

      if (!response.ok) {
        lastError = `Credit endpoint ${endpoint} returned ${response.status}.`;
        continue;
      }

      const payload = asRecord(await response.json());
      if (!payload) {
        lastError = `Credit endpoint ${endpoint} returned invalid JSON.`;
        continue;
      }

      const parsed = parseCreditsPayload(payload);
      if (!parsed) {
        lastError = `Credit endpoint ${endpoint} returned an unexpected payload shape.`;
        continue;
      }

      return {
        available: parsed.available,
        used: parsed.used,
        total: parsed.total,
        currency: "USD",
        source: "legacy_credit_grants",
        mode: "legacy",
        unit: "USD",
        planType: null,
        isPaidPlan: false,
        hourlyRemainingPercent: null,
        weeklyRemainingPercent: null,
        hourlyRefreshAt: null,
        weeklyRefreshAt: null,
        status: "available",
        message: "Remaining credits loaded from billing endpoint.",
        checkedAt,
      };
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      lastError = `Failed to fetch credits from ${endpoint}: ${detail}`;
    }
  }

  return {
    available: null,
    used: null,
    total: null,
    currency: "USD",
    source: "legacy_credit_grants",
    mode: "legacy",
    unit: "USD",
    planType: null,
    isPaidPlan: false,
    hourlyRemainingPercent: null,
    weeklyRemainingPercent: null,
    hourlyRefreshAt: null,
    weeklyRefreshAt: null,
    status: "error",
    message: lastError,
    checkedAt,
  };
};

const fetchCreditsFromAuth = async (auth: unknown): Promise<CreditsInfo> => {
  const checkedAt = nowEpoch();
  const tokens = extractTokens(auth);
  const accessToken = getString(tokens, "access_token");
  const accountId = extractAccountId(auth);

  if (accessToken) {
    const endpoint = "https://chatgpt.com/backend-api/wham/usage";

    try {
      const usage = await fetchWhamUsageViaTauri(accessToken, accountId);
      if (usage.status < 200 || usage.status >= 300) {
        const detailText =
          typeof usage.rawBody === "string"
            ? usage.rawBody
            : JSON.stringify(usage.rawBody);
        const detail = detailText.length > 0 ? ` Body: ${detailText.slice(0, 200)}` : "";
        return {
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
          message: `Usage endpoint ${endpoint} returned ${usage.status}.${detail}`,
          checkedAt,
        };
      }

      const payload = usage.payload;
      if (!payload) {
        return {
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
          message: `Usage endpoint ${endpoint} returned invalid JSON.`,
          checkedAt,
        };
      }

      const parsed = parseWhamCredits(payload, checkedAt);

      if (parsed.balance !== null) {
        return {
          available: parsed.balance,
          used: null,
          total: null,
          currency: "USD",
          source: "wham_usage",
          mode: "balance",
          unit: "USD",
          planType: parsed.planType,
          isPaidPlan: parsed.isPaidPlan,
          hourlyRemainingPercent: parsed.hourlyRemainingPercent,
          weeklyRemainingPercent: parsed.weeklyRemainingPercent,
          hourlyRefreshAt: parsed.hourlyRefreshAt,
          weeklyRefreshAt: parsed.weeklyRefreshAt,
          status: "available",
          message: "Remaining credits loaded from Codex usage endpoint.",
          checkedAt,
        };
      }

      if (parsed.usedPercent !== null) {
        const usedPercent = Math.max(0, Math.min(100, parsed.usedPercent));
        return {
          available: Math.max(0, 100 - usedPercent),
          used: usedPercent,
          total: 100,
          currency: "%",
          source: "wham_usage",
          mode: "percent_fallback",
          unit: "%",
          planType: parsed.planType,
          isPaidPlan: parsed.isPaidPlan,
          hourlyRemainingPercent: parsed.hourlyRemainingPercent,
          weeklyRemainingPercent: parsed.weeklyRemainingPercent,
          hourlyRefreshAt: parsed.hourlyRefreshAt,
          weeklyRefreshAt: parsed.weeklyRefreshAt,
          status: "available",
          message: "Usage fallback loaded from rate-limit percent.",
          checkedAt,
        };
      }

      const flags = [
        `has_credits=${parsed.hasCredits === null ? "unknown" : parsed.hasCredits ? "true" : "false"}`,
        `unlimited=${parsed.unlimited === null ? "unknown" : parsed.unlimited ? "true" : "false"}`,
      ].join(", ");

      return {
        available: null,
        used: null,
        total: null,
        currency: "USD",
        source: "wham_usage",
        mode: "balance",
        unit: "USD",
        planType: parsed.planType,
        isPaidPlan: parsed.isPaidPlan,
        hourlyRemainingPercent: parsed.hourlyRemainingPercent,
        weeklyRemainingPercent: parsed.weeklyRemainingPercent,
        hourlyRefreshAt: parsed.hourlyRefreshAt,
        weeklyRefreshAt: parsed.weeklyRefreshAt,
        status: "error",
        message: `Usage endpoint returned no balance or rate-limit usage data (${flags}).`,
        checkedAt,
      };
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      return {
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
        message: `Failed to fetch usage from ${endpoint}: ${detail}`,
        checkedAt,
      };
    }
  }

  const apiKey = extractApiKey(auth);
  if (apiKey) {
    return fetchLegacyCreditsFromApiKey(apiKey, checkedAt);
  }

  return {
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
    message: "No access token available for this account.",
    checkedAt,
  };
};

export const getAccounts = async (): Promise<AccountsView> => {
  const store = await readStore();
  return buildView(store);
};

export const importCurrentAccount = async (label?: string): Promise<AccountsView> => {
  return importFromCurrentAuth(label);
};

export const beginCodexLogin = async (): Promise<BrowserLoginStart> => {
  const codeVerifier = randomBase64Url(64);
  const codeChallenge = await sha256Base64Url(codeVerifier);
  const state = randomBase64Url(32);

  const pending: PendingBrowserLogin = {
    issuer: CODEX_OAUTH_ISSUER,
    clientId: CODEX_CLIENT_ID,
    redirectUri: CODEX_REDIRECT_URI,
    state,
    codeVerifier,
    startedAt: nowEpoch(),
  };

  pendingBrowserLogin = pending;

  const authUrl = buildAuthorizeUrl(
    pending.issuer,
    pending.clientId,
    pending.redirectUri,
    codeChallenge,
    pending.state,
  );

  const tauri = await loadBackendApis();
  await tauri.openUrl(authUrl);

  return {
    authUrl,
    redirectUri: pending.redirectUri,
  };
};

export const completeCodexLogin = async (
  callbackUrl?: string,
  label?: string,
): Promise<LoginResult> => {
  if (!pendingBrowserLogin) {
    throw new Error("No active login session. Start ChatGPT login first.");
  }

  const pending = pendingBrowserLogin;
  const capturedCallbackUrl = normalizeOptional(callbackUrl) || (await waitForOAuthCallbackFromBrowser());
  const parsed = parseCallbackInput(capturedCallbackUrl);

  if (parsed.state !== pending.state) {
    throw new Error("State mismatch. Start a fresh login and use the newest callback URL.");
  }

  const tokens = await exchangeAuthorizationCode(pending, parsed.code);
  const apiKey = await exchangeApiKey(pending.issuer, pending.clientId, tokens.idToken);

  const auth = buildChatgptAuthPayload(tokens, apiKey);
  validateAuth(auth);

  await writeAuthFile(auth);
  pendingBrowserLogin = null;

  const view = await importFromCurrentAuth(label);

  return {
    view,
    output: "ChatGPT login completed.",
  };
};

export const codexLoginWithApiKey = async (apiKey: string, label?: string): Promise<LoginResult> => {
  const normalized = normalizeOptional(apiKey);
  if (!normalized) {
    throw new Error("API key is required.");
  }

  const auth = {
    auth_mode: "apikey",
    OPENAI_API_KEY: normalized,
  };

  validateAuth(auth);
  await writeAuthFile(auth);

  const view = await importFromCurrentAuth(label);

  return {
    view,
    output: "API key login completed.",
  };
};

export const switchAccount = async (id: string): Promise<AccountsView> => {
  const store = await readStore();
  const index = store.accounts.findIndex((account) => account.id === id);

  if (index < 0) {
    throw new Error("Account not found.");
  }

  const account = store.accounts[index];
  if (account.archived || account.frozen) {
    throw new Error("Cannot switch to a depleted or frozen account.");
  }

  validateAuth(account.auth);
  await writeAuthFile(account.auth);

  const now = nowEpoch();
  account.lastUsedAt = now;
  account.updatedAt = now;
  store.activeAccountId = account.id;

  await writeStore(store);
  return buildView(store);
};

export const moveAccount = async (
  id: string,
  targetBucket: AccountBucket,
  targetIndex: number,
  options?: { switchAwayFromMoved?: boolean },
): Promise<AccountsView> => {
  const store = await readStore();
  const sourceIndex = store.accounts.findIndex((entry) => entry.id === id);

  if (sourceIndex < 0) {
    throw new Error("Account not found.");
  }

  const [account] = store.accounts.splice(sourceIndex, 1);
  if (!account) {
    throw new Error("Account not found.");
  }

  applyBucket(account, targetBucket);
  account.updatedAt = nowEpoch();

  if (store.activeAccountId === id && targetBucket !== "active") {
    if (options?.switchAwayFromMoved ?? true) {
      await moveActiveToFallback(store, id);
    } else {
      store.activeAccountId = null;
    }
  }

  const bucketIds = store.accounts
    .filter((entry) => accountBucketOf(entry) === targetBucket)
    .map((entry) => entry.id);
  const normalizedIndex = Number.isFinite(targetIndex)
    ? Math.max(0, Math.min(Math.floor(targetIndex), bucketIds.length))
    : bucketIds.length;

  let insertIndex = store.accounts.length;
  if (normalizedIndex < bucketIds.length) {
    const anchorId = bucketIds[normalizedIndex];
    const anchorIndex = store.accounts.findIndex((entry) => entry.id === anchorId);
    insertIndex = anchorIndex >= 0 ? anchorIndex : store.accounts.length;
  } else if (bucketIds.length > 0) {
    const tailId = bucketIds[bucketIds.length - 1];
    const tailIndex = store.accounts.findIndex((entry) => entry.id === tailId);
    insertIndex = tailIndex >= 0 ? tailIndex + 1 : store.accounts.length;
  }

  store.accounts.splice(insertIndex, 0, account);

  await writeStore(store);
  return buildView(store);
};

export const archiveAccount = async (
  id: string,
  options?: { switchAwayFromArchived?: boolean },
): Promise<AccountsView> => {
  return moveAccount(id, "depleted", Number.MAX_SAFE_INTEGER, {
    switchAwayFromMoved: options?.switchAwayFromArchived,
  });
};

export const unarchiveAccount = async (id: string): Promise<AccountsView> => {
  return moveAccount(id, "active", Number.MAX_SAFE_INTEGER);
};

export const clearAccountLabel = async (id: string): Promise<AccountsView> => {
  const store = await readStore();
  const account = store.accounts.find((entry) => entry.id === id);

  if (!account) {
    throw new Error("Account not found.");
  }

  account.label = null;
  account.updatedAt = nowEpoch();

  await writeStore(store);
  return buildView(store);
};

export const removeAccount = async (id: string): Promise<AccountsView> => {
  const store = await readStore();
  const nextAccounts = store.accounts.filter((entry) => entry.id !== id);

  if (nextAccounts.length === store.accounts.length) {
    throw new Error("Account not found.");
  }

  store.accounts = nextAccounts;

  if (store.activeAccountId === id) {
    await moveActiveToFallback(store, id);
  }

  await writeStore(store);
  return buildView(store);
};

export const getRemainingCredits = async (): Promise<CreditsInfo> => {
  let auth: unknown;

  try {
    auth = await readAuthFile();
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return {
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
    };
  }

  return fetchCreditsFromAuth(auth);
};

export const getRemainingCreditsForAccount = async (id: string): Promise<CreditsInfo> => {
  const store = await readStore();
  const account = store.accounts.find((entry) => entry.id === id);

  if (!account) {
    return {
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
      message: "Account not found.",
      checkedAt: nowEpoch(),
    };
  }

  return fetchCreditsFromAuth(account.auth);
};
