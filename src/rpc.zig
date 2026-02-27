const std = @import("std");
const builtin = @import("builtin");
const embedded_index = @import("embedded_index.zig");

const APP_ID = "com.codex.manager";
const CODEX_DIR = ".codex";
const AUTH_FILE = "auth.json";
const STORE_FILE = "accounts.json";
const BOOTSTRAP_STATE_FILE = "bootstrap-state.json";
const TOKEN_EXCHANGE_GRANT = "urn:ietf:params:oauth:grant-type:token-exchange";
const ID_TOKEN_TYPE = "urn:ietf:params:oauth:token-type:id_token";
const OAUTH_CALLBACK_SUCCESS_HTML =
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="utf-8" />
    \\  <meta name="viewport" content="width=device-width, initial-scale=1" />
    \\  <title>Login Complete</title>
    \\  <style>
    \\    :root {
    \\      color-scheme: light;
    \\      --bg-1: #f7fbff;
    \\      --bg-2: #edf4ff;
    \\      --line: #c7d8ee;
    \\      --card: #ffffff;
    \\      --text: #1b2a40;
    \\      --muted: #4e6784;
    \\      --accent: #2f6ea8;
    \\    }
    \\    * { box-sizing: border-box; }
    \\    html, body { height: 100%; }
    \\    body {
    \\      margin: 0;
    \\      font-family: "IBM Plex Sans", "Segoe UI", "Helvetica Neue", Arial, sans-serif;
    \\      background: radial-gradient(120% 120% at 10% 0%, var(--bg-2), var(--bg-1));
    \\      color: var(--text);
    \\      display: grid;
    \\      place-items: center;
    \\      padding: 1.5rem;
    \\    }
    \\    .card {
    \\      width: min(680px, 100%);
    \\      border: 1px solid var(--line);
    \\      background: linear-gradient(180deg, #ffffff, #fbfdff);
    \\      box-shadow: 0 14px 42px rgba(48, 85, 126, 0.16);
    \\      padding: 1.6rem 1.7rem;
    \\    }
    \\    .eyebrow {
    \\      margin: 0 0 0.5rem;
    \\      font-size: 0.74rem;
    \\      letter-spacing: 0.09em;
    \\      text-transform: uppercase;
    \\      color: var(--accent);
    \\      font-weight: 700;
    \\    }
    \\    h1 {
    \\      margin: 0;
    \\      font-size: clamp(1.18rem, 2vw + 0.4rem, 1.65rem);
    \\      line-height: 1.35;
    \\      font-weight: 600;
    \\      text-wrap: balance;
    \\    }
    \\    p {
    \\      margin: 0.8rem 0 0;
    \\      color: var(--muted);
    \\      line-height: 1.55;
    \\      font-size: 0.95rem;
    \\    }
    \\  </style>
    \\</head>
    \\<body>
    \\  <main class="card">
    \\    <p class="eyebrow">Codex Account Manager</p>
    \\    <h1>login complete, you can return to codex account manager</h1>
    \\    <p>This tab can now be closed.</p>
    \\  </main>
    \\</body>
    \\</html>
;

pub const RpcRequest = struct {
    op: []const u8,
    path: ?[]const u8 = null,
    paths: ?[]const []const u8 = null,
    contents: ?[]const u8 = null,
    theme: ?[]const u8 = null,
    label: ?[]const u8 = null,
    apiKey: ?[]const u8 = null,
    issuer: ?[]const u8 = null,
    clientId: ?[]const u8 = null,
    redirectUri: ?[]const u8 = null,
    oauthState: ?[]const u8 = null,
    codeVerifier: ?[]const u8 = null,
    url: ?[]const u8 = null,
    recursive: ?bool = null,
    timeoutSeconds: ?u64 = null,
    accessToken: ?[]const u8 = null,
    accountId: ?[]const u8 = null,
    targetBucket: ?[]const u8 = null,
    targetIndex: ?i64 = null,
    switchAwayFromMoved: ?bool = null,
    autoArchiveZeroQuota: ?bool = null,
    autoUnarchiveNonZeroQuota: ?bool = null,
    autoSwitchAwayFromArchived: ?bool = null,
    autoRefreshActiveEnabled: ?bool = null,
    autoRefreshActiveIntervalSec: ?u64 = null,
    usageRefreshDisplayMode: ?[]const u8 = null,
    requestId: ?u64 = null,
};

const UsageResult = struct {
    status: u16,
    body: []u8,
};

const ManagedPaths = struct {
    codexHome: []u8,
    codexAuthPath: []u8,
    storeDir: []u8,
    storePath: []u8,
    bootstrapStatePath: []u8,

    fn deinit(self: *ManagedPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.codexHome);
        allocator.free(self.codexAuthPath);
        allocator.free(self.storeDir);
        allocator.free(self.storePath);
        allocator.free(self.bootstrapStatePath);
    }
};

const OAuthReadyAccount = struct {
    id: []u8,
    accountId: ?[]u8 = null,
    email: ?[]u8 = null,
    state: []const u8 = "active",

    fn deinit(self: *OAuthReadyAccount, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.accountId) |value| allocator.free(value);
        if (self.email) |value| allocator.free(value);
    }
};

const OAuthListenerState = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    thread: ?std.Thread = null,
    running: bool = false,
    callback_url: ?[]u8 = null,
    ready_account: ?OAuthReadyAccount = null,
    error_name: ?[]u8 = null,
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

const OAuthPollResult = struct {
    status: []const u8,
    account: ?OAuthReadyAccount = null,
    @"error": ?[]const u8 = null,
};

var oauth_listener_state = OAuthListenerState{};

const USAGE_FETCH_DEBOUNCE_MS: i64 = 15 * 1000;

const UsageFetchEntry = struct {
    key: []u8,
    last_request_id: u64 = 0,
    inflight: bool = false,
    last_started_ms: i64 = 0,
    last_completed_ms: i64 = 0,
    last_status: u16 = 0,
    last_body: ?[]u8 = null,
};

const UsageFetchState = struct {
    mutex: std.Thread.Mutex = .{},
    entries: std.ArrayListUnmanaged(UsageFetchEntry) = .{},
    next_request_id: u64 = 1,
};

const UsageFetchWorkerArgs = struct {
    key: []u8,
    access_token: []u8,
    account_id: ?[]u8,
    request_id: u64,

    fn init(access_token: []const u8, account_id: ?[]const u8, key: []const u8, request_id: u64) !UsageFetchWorkerArgs {
        const key_copy = try std.heap.page_allocator.dupe(u8, key);
        errdefer std.heap.page_allocator.free(key_copy);

        const token_copy = try std.heap.page_allocator.dupe(u8, access_token);
        errdefer std.heap.page_allocator.free(token_copy);

        const account_copy = if (account_id) |id| try std.heap.page_allocator.dupe(u8, id) else null;
        errdefer if (account_copy) |id| std.heap.page_allocator.free(id);

        return .{
            .key = key_copy,
            .access_token = token_copy,
            .account_id = account_copy,
            .request_id = request_id,
        };
    }

    fn deinit(self: *UsageFetchWorkerArgs) void {
        std.heap.page_allocator.free(self.key);
        std.heap.page_allocator.free(self.access_token);
        if (self.account_id) |id| {
            std.heap.page_allocator.free(id);
        }
    }
};

var usage_fetch_state = UsageFetchState{};
var managed_files_mutex: std.Thread.Mutex = .{};
var refresh_debounce_state: std.Thread.Mutex = .{};
var refresh_debounce_entries: std.ArrayListUnmanaged(struct {
    account_id: []u8,
    inflight: bool,
    last_started_ms: i64,
}) = .{};

const AUTO_REFRESH_ACTIVE_DEFAULT_INTERVAL_SEC: u64 = 300;
const AUTO_REFRESH_ACTIVE_MIN_INTERVAL_SEC: u64 = 15;
const AUTO_REFRESH_ACTIVE_MAX_INTERVAL_SEC: u64 = 21600;
const DEFAULT_THEME: ?[]const u8 = null;
const DEFAULT_USAGE_REFRESH_DISPLAY_MODE = "date";

const AccountBucket = enum {
    active,
    depleted,
    frozen,
};

const CreditsSource = enum {
    wham_usage,
    legacy_credit_grants,
};

const CreditsMode = enum {
    balance,
    percent_fallback,
    legacy,
};

const CreditsUnit = enum {
    USD,
    percent,
};

const CreditsStatus = enum {
    available,
    unavailable,
    err,
};

const CreditsInfo = struct {
    available: ?f64 = null,
    used: ?f64 = null,
    total: ?f64 = null,
    currency: []u8,
    source: CreditsSource = .wham_usage,
    mode: CreditsMode = .balance,
    unit: CreditsUnit = .USD,
    plan_type: ?[]u8 = null,
    is_paid_plan: bool = false,
    hourly_remaining_percent: ?f64 = null,
    weekly_remaining_percent: ?f64 = null,
    hourly_refresh_at: ?i64 = null,
    weekly_refresh_at: ?i64 = null,
    status: CreditsStatus = .unavailable,
    message: []u8,
    checked_at: i64 = 0,

    fn deinit(self: *CreditsInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.currency);
        allocator.free(self.message);
        if (self.plan_type) |value| {
            allocator.free(value);
        }
    }
};

const UsageCacheEntry = struct {
    account_id: []u8,
    credits: CreditsInfo,

    fn deinit(self: *UsageCacheEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.account_id);
        self.credits.deinit(allocator);
    }
};

const ManagedAccount = struct {
    id: []u8,
    label: ?[]u8 = null,
    account_id: ?[]u8 = null,
    email: ?[]u8 = null,
    archived: bool = false,
    frozen: bool = false,
    auth_json: []u8,
    created_at: i64,
    updated_at: i64,
    last_used_at: ?i64 = null,

    fn deinit(self: *ManagedAccount, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.label) |value| allocator.free(value);
        if (self.account_id) |value| allocator.free(value);
        if (self.email) |value| allocator.free(value);
        allocator.free(self.auth_json);
    }
};

const StoreState = struct {
    active_account_id: ?[]u8 = null,
    accounts: std.ArrayListUnmanaged(ManagedAccount) = .{},

    fn deinit(self: *StoreState, allocator: std.mem.Allocator) void {
        if (self.active_account_id) |value| allocator.free(value);
        for (self.accounts.items) |*account| {
            account.deinit(allocator);
        }
        self.accounts.deinit(allocator);
    }
};

const UiPreferences = struct {
    theme: ?[]u8 = null,
    auto_archive_zero_quota: bool = true,
    auto_unarchive_non_zero_quota: bool = true,
    auto_switch_away_from_archived: bool = true,
    auto_refresh_active_enabled: bool = false,
    auto_refresh_active_interval_sec: u64 = AUTO_REFRESH_ACTIVE_DEFAULT_INTERVAL_SEC,
    usage_refresh_display_mode: []u8,

    fn deinit(self: *UiPreferences, allocator: std.mem.Allocator) void {
        if (self.theme) |value| allocator.free(value);
        allocator.free(self.usage_refresh_display_mode);
    }
};

const AppState = struct {
    paths: ManagedPaths,
    store: StoreState,
    preferences: UiPreferences,
    usage_by_id: std.ArrayListUnmanaged(UsageCacheEntry) = .{},
    saved_at: i64 = 0,

    fn deinit(self: *AppState, allocator: std.mem.Allocator) void {
        self.paths.deinit(allocator);
        self.store.deinit(allocator);
        self.preferences.deinit(allocator);
        for (self.usage_by_id.items) |*entry| {
            entry.deinit(allocator);
        }
        self.usage_by_id.deinit(allocator);
    }
};

pub fn handleRpcText(allocator: std.mem.Allocator, request_text: []const u8, cancel_ptr: *std.atomic.Value(bool)) ![]u8 {
    return rpcFromText(allocator, request_text, cancel_ptr);
}

fn jsonError(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(.{ .ok = false, .@"error" = message }, .{})});
}

fn jsonOk(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(.{ .ok = true, .value = value }, .{})});
}

fn jsonOkRaw(allocator: std.mem.Allocator, raw_value: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"ok\":true,\"value\":{s}}}", .{raw_value});
}

fn rpcFromText(allocator: std.mem.Allocator, request_text: []const u8, cancel_ptr: *std.atomic.Value(bool)) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const request = std.json.parseFromSliceLeaky(RpcRequest, arena.allocator(), request_text, .{
        .ignore_unknown_fields = true,
    }) catch {
        return jsonError(allocator, "invalid RPC payload");
    };

    return rpcHandleRequest(allocator, request, cancel_ptr);
}

fn rpcHandleRequest(allocator: std.mem.Allocator, request: RpcRequest, cancel_ptr: *std.atomic.Value(bool)) ![]u8 {
    if (std.mem.eql(u8, request.op, "path:home_dir")) {
        const home = getHomeDir(allocator) catch |err| {
            return jsonError(allocator, @errorName(err));
        };
        defer allocator.free(home);
        return jsonOk(allocator, home);
    }

    if (std.mem.eql(u8, request.op, "path:app_local_data_dir")) {
        const dir = getAppLocalDataDir(allocator) catch |err| {
            return jsonError(allocator, @errorName(err));
        };
        defer allocator.free(dir);
        return jsonOk(allocator, dir);
    }

    if (std.mem.eql(u8, request.op, "path:join")) {
        const paths = request.paths orelse return jsonError(allocator, "path join requires paths");
        if (paths.len == 0) {
            return jsonError(allocator, "path join requires at least one segment");
        }

        const joined = std.fs.path.join(allocator, paths) catch |err| {
            return jsonError(allocator, @errorName(err));
        };
        defer allocator.free(joined);
        return jsonOk(allocator, joined);
    }

    if (std.mem.eql(u8, request.op, "settings:get_theme")) {
        const settings_path = getThemeSettingsPath(allocator) catch |err| {
            return jsonError(allocator, @errorName(err));
        };
        defer allocator.free(settings_path);

        if (!pathExists(settings_path)) {
            return jsonOk(allocator, @as(?[]const u8, null));
        }

        const contents = readTextFile(allocator, settings_path) catch |err| {
            return jsonError(allocator, @errorName(err));
        };
        defer allocator.free(contents);

        const trimmed = std.mem.trim(u8, contents, " \r\n\t");
        if (trimmed.len == 0) {
            return jsonOk(allocator, @as(?[]const u8, null));
        }

        return jsonOk(allocator, trimmed);
    }

    if (std.mem.eql(u8, request.op, "settings:set_theme")) {
        const theme = request.theme orelse return jsonError(allocator, "set_theme requires theme");
        const trimmed = std.mem.trim(u8, theme, " \r\n\t");
        if (trimmed.len == 0) {
            return jsonError(allocator, "set_theme requires non-empty theme");
        }

        const settings_path = getThemeSettingsPath(allocator) catch |err| {
            return jsonError(allocator, @errorName(err));
        };
        defer allocator.free(settings_path);

        writeTextFile(settings_path, trimmed) catch |err| {
            return jsonError(allocator, @errorName(err));
        };

        return jsonOk(allocator, @as(?u8, null));
    }

    if (std.mem.eql(u8, request.op, "fs:exists")) {
        const path = request.path orelse return jsonError(allocator, "exists requires path");
        return jsonOk(allocator, pathExists(path));
    }

    if (std.mem.eql(u8, request.op, "fs:mkdir")) {
        const path = request.path orelse return jsonError(allocator, "mkdir requires path");
        const recursive = request.recursive orelse false;

        if (recursive) {
            std.fs.cwd().makePath(path) catch |err| {
                return jsonError(allocator, @errorName(err));
            };
        } else {
            std.fs.makeDirAbsolute(path) catch |err| {
                if (err != error.PathAlreadyExists) {
                    return jsonError(allocator, @errorName(err));
                }
            };
        }

        return jsonOk(allocator, @as(?u8, null));
    }

    if (std.mem.eql(u8, request.op, "fs:read_text")) {
        const path = request.path orelse return jsonError(allocator, "read_text requires path");
        const text = readTextFile(allocator, path) catch |err| {
            return jsonError(allocator, @errorName(err));
        };
        defer allocator.free(text);
        return jsonOk(allocator, text);
    }

    if (std.mem.eql(u8, request.op, "fs:write_text")) {
        const path = request.path orelse return jsonError(allocator, "write_text requires path");
        const contents = request.contents orelse return jsonError(allocator, "write_text requires contents");

        writeTextFile(path, contents) catch |err| {
            return jsonError(allocator, @errorName(err));
        };

        return jsonOk(allocator, @as(?u8, null));
    }

    if (std.mem.eql(u8, request.op, "shell:open_url")) {
        const url = request.url orelse return jsonError(allocator, "open_url requires url");
        openUrl(url, allocator) catch |err| {
            return jsonError(allocator, @errorName(err));
        };
        return jsonOk(allocator, @as(?u8, null));
    }

    if (std.mem.startsWith(u8, request.op, "invoke:")) {
        const command = request.op["invoke:".len..];

        if (std.mem.eql(u8, command, "get_app_state")) {
            return handleGetAppStateCommand(allocator) catch |err| {
                return jsonError(allocator, @errorName(err));
            };
        }

        if (std.mem.eql(u8, command, "get_usage_cache")) {
            return handleGetUsageCacheCommand(allocator) catch |err| {
                return jsonError(allocator, @errorName(err));
            };
        }

        if (std.mem.eql(u8, command, "get_ui_preferences")) {
            return handleGetUiPreferencesCommand(allocator) catch |err| {
                return jsonError(allocator, @errorName(err));
            };
        }

        if (std.mem.eql(u8, command, "refresh_account_usage")) {
            const account_id = request.accountId orelse return jsonError(allocator, "refresh_account_usage requires accountId");
            return handleRefreshAccountUsageCommand(allocator, account_id) catch |err| {
                return jsonError(allocator, @errorName(err));
            };
        }

        if (std.mem.eql(u8, command, "switch_account")) {
            const account_id = request.accountId orelse return jsonError(allocator, "switch_account requires accountId");
            return handleSwitchAccountCommand(allocator, account_id) catch |err| {
                return jsonError(allocator, @errorName(err));
            };
        }

        if (std.mem.eql(u8, command, "move_account")) {
            const account_id = request.accountId orelse return jsonError(allocator, "move_account requires accountId");
            const target_bucket = request.targetBucket orelse return jsonError(allocator, "move_account requires targetBucket");
            const target_index = request.targetIndex orelse return jsonError(allocator, "move_account requires targetIndex");
            const switch_away = request.switchAwayFromMoved orelse true;
            return handleMoveAccountCommand(allocator, account_id, target_bucket, target_index, switch_away) catch |err| {
                return jsonError(allocator, @errorName(err));
            };
        }

        if (std.mem.eql(u8, command, "remove_account")) {
            const account_id = request.accountId orelse return jsonError(allocator, "remove_account requires accountId");
            return handleRemoveAccountCommand(allocator, account_id) catch |err| {
                return jsonError(allocator, @errorName(err));
            };
        }

        if (std.mem.eql(u8, command, "import_current_account")) {
            return handleImportCurrentAccountCommand(allocator, request.label) catch |err| {
                return jsonError(allocator, @errorName(err));
            };
        }

        if (std.mem.eql(u8, command, "login_with_api_key")) {
            const api_key = request.apiKey orelse return jsonError(allocator, "login_with_api_key requires apiKey");
            return handleLoginWithApiKeyCommand(allocator, api_key, request.label) catch |err| {
                return jsonError(allocator, @errorName(err));
            };
        }

        if (std.mem.eql(u8, command, "update_ui_preferences")) {
            return handleUpdateUiPreferencesCommand(allocator, request) catch |err| {
                return jsonError(allocator, @errorName(err));
            };
        }

        if (std.mem.eql(u8, command, "start_oauth_callback_listener")) {
            const timeout_seconds = request.timeoutSeconds orelse 180;
            const issuer = trimOptionalString(request.issuer) orelse return jsonError(allocator, "start_oauth_callback_listener requires issuer");
            const client_id = trimOptionalString(request.clientId) orelse return jsonError(allocator, "start_oauth_callback_listener requires clientId");
            const redirect_uri = trimOptionalString(request.redirectUri) orelse return jsonError(allocator, "start_oauth_callback_listener requires redirectUri");
            const oauth_state = trimOptionalString(request.oauthState) orelse return jsonError(allocator, "start_oauth_callback_listener requires oauthState");
            const code_verifier = trimOptionalString(request.codeVerifier) orelse return jsonError(allocator, "start_oauth_callback_listener requires codeVerifier");

            startOAuthCallbackListener(
                timeout_seconds,
                cancel_ptr,
                issuer,
                client_id,
                redirect_uri,
                oauth_state,
                code_verifier,
                trimOptionalString(request.label),
            ) catch |err| {
                return jsonError(allocator, @errorName(err));
            };
            return jsonOk(allocator, true);
        }

        if (std.mem.eql(u8, command, "poll_oauth_callback_listener")) {
            const polled = pollOAuthCallbackListener() catch |err| {
                return jsonError(allocator, @errorName(err));
            };
            return jsonOk(allocator, polled);
        }

        if (std.mem.eql(u8, command, "wait_for_oauth_callback")) {
            const timeout_seconds = request.timeoutSeconds orelse 180;
            const issuer = trimOptionalString(request.issuer) orelse return jsonError(allocator, "wait_for_oauth_callback requires issuer");
            const client_id = trimOptionalString(request.clientId) orelse return jsonError(allocator, "wait_for_oauth_callback requires clientId");
            const redirect_uri = trimOptionalString(request.redirectUri) orelse return jsonError(allocator, "wait_for_oauth_callback requires redirectUri");
            const oauth_state = trimOptionalString(request.oauthState) orelse return jsonError(allocator, "wait_for_oauth_callback requires oauthState");
            const code_verifier = trimOptionalString(request.codeVerifier) orelse return jsonError(allocator, "wait_for_oauth_callback requires codeVerifier");

            startOAuthCallbackListener(
                timeout_seconds,
                cancel_ptr,
                issuer,
                client_id,
                redirect_uri,
                oauth_state,
                code_verifier,
                trimOptionalString(request.label),
            ) catch |err| {
                if (err != error.CallbackListenerAlreadyRunning) {
                    return jsonError(allocator, @errorName(err));
                }
            };

            var ready_account = waitForOAuthReadyAccountResult(allocator) catch |err| {
                return jsonError(allocator, @errorName(err));
            };
            defer ready_account.deinit(allocator);
            return jsonOk(allocator, ready_account);
        }

        if (std.mem.eql(u8, command, "cancel_oauth_callback_listener")) {
            cancelOAuthCallbackListener(cancel_ptr);
            cancel_ptr.store(true, .seq_cst);
            return jsonOk(allocator, true);
        }

        if (std.mem.eql(u8, command, "fetch_wham_usage_start")) {
            const access_token = request.accessToken orelse return jsonError(allocator, "fetch_wham_usage_start requires accessToken");
            return startWhamUsageFetch(allocator, access_token, request.accountId) catch |err| {
                return jsonError(allocator, @errorName(err));
            };
        }

        if (std.mem.eql(u8, command, "fetch_wham_usage_poll")) {
            const request_id = request.requestId orelse return jsonError(allocator, "fetch_wham_usage_poll requires requestId");
            return pollWhamUsageFetch(allocator, request_id) catch |err| {
                return jsonError(allocator, @errorName(err));
            };
        }

        if (std.mem.eql(u8, command, "fetch_wham_usage")) {
            const access_token = request.accessToken orelse return jsonError(allocator, "fetch_wham_usage requires accessToken");
            const usage = fetchWhamUsage(allocator, access_token, request.accountId) catch |err| {
                return jsonError(allocator, @errorName(err));
            };
            defer allocator.free(usage.body);
            return jsonOk(allocator, .{ .status = usage.status, .body = usage.body });
        }

        return jsonError(allocator, "unknown invoke command");
    }

    return jsonError(allocator, "unknown RPC op");
}

fn pathExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn getHomeDir(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        return std.process.getEnvVarOwned(allocator, "USERPROFILE");
    }

    return std.process.getEnvVarOwned(allocator, "HOME");
}

fn getAppLocalDataDir(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        const appdata = try std.process.getEnvVarOwned(allocator, "APPDATA");
        defer allocator.free(appdata);
        return std.fs.path.join(allocator, &.{ appdata, APP_ID });
    }

    const home = try getHomeDir(allocator);
    defer allocator.free(home);

    if (builtin.os.tag == .macos) {
        return std.fs.path.join(allocator, &.{ home, "Library", "Application Support", APP_ID });
    }

    return std.fs.path.join(allocator, &.{ home, ".local", "share", APP_ID });
}

fn getThemeSettingsPath(allocator: std.mem.Allocator) ![]u8 {
    const app_dir = try getAppLocalDataDir(allocator);
    defer allocator.free(app_dir);
    return std.fs.path.join(allocator, &.{ app_dir, "ui-theme.txt" });
}

fn getManagedPaths(allocator: std.mem.Allocator) !ManagedPaths {
    const home = try getHomeDir(allocator);
    defer allocator.free(home);

    const codex_home = try std.fs.path.join(allocator, &.{ home, CODEX_DIR });
    errdefer allocator.free(codex_home);

    const codex_auth_path = try std.fs.path.join(allocator, &.{ codex_home, AUTH_FILE });
    errdefer allocator.free(codex_auth_path);

    const store_dir = try getAppLocalDataDir(allocator);
    errdefer allocator.free(store_dir);

    const store_path = try std.fs.path.join(allocator, &.{ store_dir, STORE_FILE });
    errdefer allocator.free(store_path);

    const bootstrap_state_path = try std.fs.path.join(allocator, &.{ store_dir, BOOTSTRAP_STATE_FILE });
    errdefer allocator.free(bootstrap_state_path);

    return .{
        .codexHome = codex_home,
        .codexAuthPath = codex_auth_path,
        .storeDir = store_dir,
        .storePath = store_path,
        .bootstrapStatePath = bootstrap_state_path,
    };
}

fn readOptionalTextFile(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    if (!pathExists(path)) {
        return null;
    }
    const text = try readTextFile(allocator, path);
    return text;
}

fn readManagedStore(allocator: std.mem.Allocator) !?[]u8 {
    var paths = try getManagedPaths(allocator);
    defer paths.deinit(allocator);
    return readOptionalTextFile(allocator, paths.storePath);
}

fn writeManagedStore(contents: []const u8, allocator: std.mem.Allocator) !void {
    var paths = try getManagedPaths(allocator);
    defer paths.deinit(allocator);

    managed_files_mutex.lock();
    defer managed_files_mutex.unlock();
    try writeTextFile(paths.storePath, contents);
}

fn readCodexAuth(allocator: std.mem.Allocator) !?[]u8 {
    var paths = try getManagedPaths(allocator);
    defer paths.deinit(allocator);
    return readOptionalTextFile(allocator, paths.codexAuthPath);
}

fn writeCodexAuth(contents: []const u8, allocator: std.mem.Allocator) !void {
    var paths = try getManagedPaths(allocator);
    defer paths.deinit(allocator);

    managed_files_mutex.lock();
    defer managed_files_mutex.unlock();
    try writeTextFile(paths.codexAuthPath, contents);
}

fn readBootstrapState(allocator: std.mem.Allocator) !?[]u8 {
    var paths = try getManagedPaths(allocator);
    defer paths.deinit(allocator);
    return readOptionalTextFile(allocator, paths.bootstrapStatePath);
}

fn writeBootstrapState(contents: []const u8, allocator: std.mem.Allocator) !void {
    var paths = try getManagedPaths(allocator);
    defer paths.deinit(allocator);

    managed_files_mutex.lock();
    defer managed_files_mutex.unlock();
    try writeTextFile(paths.bootstrapStatePath, contents);
}

fn readTextFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    return file.readToEndAlloc(allocator, 16 * 1024 * 1024);
}

fn writeTextFile(path: []const u8, contents: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try std.fs.cwd().makePath(parent);
    }

    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();

    try file.writeAll(contents);
}

fn writeTextFileAtomic(allocator: std.mem.Allocator, path: []const u8, contents: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try std.fs.cwd().makePath(parent);
    }

    const temp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(temp_path);

    const temp_file = try std.fs.createFileAbsolute(temp_path, .{ .truncate = true });
    defer temp_file.close();
    try temp_file.writeAll(contents);
    try temp_file.sync();

    std.fs.renameAbsolute(temp_path, path) catch |err| switch (err) {
        error.PathAlreadyExists => {
            try std.fs.deleteFileAbsolute(path);
            try std.fs.renameAbsolute(temp_path, path);
        },
        else => return err,
    };
}

fn nowEpochSeconds() i64 {
    return @divFloor(std.time.milliTimestamp(), 1000);
}

fn trimOptionalString(value: ?[]const u8) ?[]const u8 {
    const raw = value orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \r\n\t");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn normalizeAutoRefreshIntervalSec(value: ?u64) u64 {
    const raw = value orelse AUTO_REFRESH_ACTIVE_DEFAULT_INTERVAL_SEC;
    if (raw < AUTO_REFRESH_ACTIVE_MIN_INTERVAL_SEC) return AUTO_REFRESH_ACTIVE_MIN_INTERVAL_SEC;
    if (raw > AUTO_REFRESH_ACTIVE_MAX_INTERVAL_SEC) return AUTO_REFRESH_ACTIVE_MAX_INTERVAL_SEC;
    return raw;
}

fn jsonGetObject(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

fn jsonGetArray(value: std.json.Value) ?std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => null,
    };
}

fn jsonGetString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |s| if (std.mem.trim(u8, s, " \r\n\t").len > 0) s else null,
        else => null,
    };
}

fn jsonGetBool(value: std.json.Value) ?bool {
    return switch (value) {
        .bool => |b| b,
        .integer => |n| if (n == 0) false else if (n == 1) true else null,
        .float => |n| if (n == 0.0) false else if (n == 1.0) true else null,
        .string => |s| blk: {
            const trimmed = std.mem.trim(u8, s, " \r\n\t");
            if (std.ascii.eqlIgnoreCase(trimmed, "true") or std.mem.eql(u8, trimmed, "1")) break :blk true;
            if (std.ascii.eqlIgnoreCase(trimmed, "false") or std.mem.eql(u8, trimmed, "0")) break :blk false;
            break :blk null;
        },
        else => null,
    };
}

fn jsonGetF64(value: std.json.Value) ?f64 {
    const parsed: ?f64 = switch (value) {
        .float => |n| n,
        .integer => |n| @floatFromInt(n),
        .string => |s| std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \r\n\t")) catch null,
        else => null,
    };
    if (parsed == null) return null;
    if (!std.math.isFinite(parsed.?)) return null;
    return parsed;
}

fn jsonGetI64(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |n| n,
        .float => |n| @intFromFloat(@floor(n)),
        .string => |s| std.fmt.parseInt(i64, std.mem.trim(u8, s, " \r\n\t"), 10) catch null,
        else => null,
    };
}

fn dupMaybeString(allocator: std.mem.Allocator, input: ?[]const u8) !?[]u8 {
    const value = input orelse return null;
    return try allocator.dupe(u8, value);
}

fn parseAccountBucket(value: []const u8) ?AccountBucket {
    if (std.mem.eql(u8, value, "active")) return .active;
    if (std.mem.eql(u8, value, "depleted")) return .depleted;
    if (std.mem.eql(u8, value, "frozen")) return .frozen;
    return null;
}

fn creditsSourceString(value: CreditsSource) []const u8 {
    return switch (value) {
        .wham_usage => "wham_usage",
        .legacy_credit_grants => "legacy_credit_grants",
    };
}

fn creditsModeString(value: CreditsMode) []const u8 {
    return switch (value) {
        .balance => "balance",
        .percent_fallback => "percent_fallback",
        .legacy => "legacy",
    };
}

fn creditsUnitString(value: CreditsUnit) []const u8 {
    return switch (value) {
        .USD => "USD",
        .percent => "%",
    };
}

fn creditsStatusString(value: CreditsStatus) []const u8 {
    return switch (value) {
        .available => "available",
        .unavailable => "unavailable",
        .err => "error",
    };
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.print("{f}", .{std.json.fmt(value, .{})});
}

fn writeJsonOptionalString(writer: anytype, value: ?[]const u8) !void {
    if (value) |text| {
        try writeJsonString(writer, text);
    } else {
        try writer.writeAll("null");
    }
}

fn writeJsonOptionalI64(writer: anytype, value: ?i64) !void {
    if (value) |n| {
        try writer.print("{}", .{n});
    } else {
        try writer.writeAll("null");
    }
}

fn writeJsonOptionalF64(writer: anytype, value: ?f64) !void {
    if (value) |n| {
        if (std.math.isFinite(n)) {
            try writer.print("{d}", .{n});
        } else {
            try writer.writeAll("null");
        }
    } else {
        try writer.writeAll("null");
    }
}

fn writeJsonBool(writer: anytype, value: bool) !void {
    try writer.writeAll(if (value) "true" else "false");
}

fn setRefreshInflight(account_id: []const u8, inflight: bool) !void {
    refresh_debounce_state.lock();
    defer refresh_debounce_state.unlock();

    const now_ms = std.time.milliTimestamp();

    for (refresh_debounce_entries.items) |*entry| {
        if (std.mem.eql(u8, entry.account_id, account_id)) {
            entry.inflight = inflight;
            if (inflight) {
                entry.last_started_ms = now_ms;
            }
            return;
        }
    }

    const account_copy = try std.heap.page_allocator.dupe(u8, account_id);
    errdefer std.heap.page_allocator.free(account_copy);
    try refresh_debounce_entries.append(std.heap.page_allocator, .{
        .account_id = account_copy,
        .inflight = inflight,
        .last_started_ms = if (inflight) now_ms else 0,
    });
}

fn shouldDebounceRefresh(account_id: []const u8) bool {
    refresh_debounce_state.lock();
    defer refresh_debounce_state.unlock();

    const now_ms = std.time.milliTimestamp();
    for (refresh_debounce_entries.items) |*entry| {
        if (!std.mem.eql(u8, entry.account_id, account_id)) continue;
        if (entry.inflight) return true;
        if (entry.last_started_ms > 0 and now_ms - entry.last_started_ms < USAGE_FETCH_DEBOUNCE_MS) {
            return true;
        }
        return false;
    }
    return false;
}

fn loadStoreState(allocator: std.mem.Allocator, store_path: []const u8) !StoreState {
    var store = StoreState{};
    errdefer store.deinit(allocator);

    const raw_store = try readOptionalTextFile(allocator, store_path);
    defer if (raw_store) |text| allocator.free(text);
    if (raw_store == null) {
        return store;
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_store.?, .{}) catch return store;
    defer parsed.deinit();

    const root = jsonGetObject(parsed.value) orelse return store;

    if (root.get("activeAccountId")) |active_value| {
        if (jsonGetString(active_value)) |active_id| {
            store.active_account_id = try allocator.dupe(u8, active_id);
        }
    }

    const accounts_value = root.get("accounts") orelse return store;
    const accounts_array = jsonGetArray(accounts_value) orelse return store;

    for (accounts_array.items) |entry_value| {
        const account_obj = jsonGetObject(entry_value) orelse continue;
        const id_raw = account_obj.get("id") orelse continue;
        const id = jsonGetString(id_raw) orelse continue;
        const auth_value = account_obj.get("auth") orelse continue;

        const auth_json = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(auth_value, .{})});
        errdefer allocator.free(auth_json);

        var account = ManagedAccount{
            .id = try allocator.dupe(u8, id),
            .label = null,
            .account_id = null,
            .email = null,
            .archived = if (account_obj.get("archived")) |v| jsonGetBool(v) orelse false else false,
            .frozen = if (account_obj.get("frozen")) |v| jsonGetBool(v) orelse false else false,
            .auth_json = auth_json,
            .created_at = if (account_obj.get("createdAt")) |v| jsonGetI64(v) orelse nowEpochSeconds() else nowEpochSeconds(),
            .updated_at = if (account_obj.get("updatedAt")) |v| jsonGetI64(v) orelse nowEpochSeconds() else nowEpochSeconds(),
            .last_used_at = if (account_obj.get("lastUsedAt")) |v| jsonGetI64(v) else null,
        };
        errdefer account.deinit(allocator);

        if (account_obj.get("label")) |label| {
            if (jsonGetString(label)) |value| account.label = try allocator.dupe(u8, value);
        }
        if (account_obj.get("accountId")) |account_id| {
            if (jsonGetString(account_id)) |value| account.account_id = try allocator.dupe(u8, value);
        }
        if (account_obj.get("email")) |email| {
            if (jsonGetString(email)) |value| account.email = try allocator.dupe(u8, value);
        }

        try store.accounts.append(allocator, account);
    }

    return store;
}

fn parseCreditsInfo(allocator: std.mem.Allocator, value: std.json.Value) !?CreditsInfo {
    const obj = jsonGetObject(value) orelse return null;

    const currency = if (obj.get("currency")) |v| jsonGetString(v) else null;
    const source = if (obj.get("source")) |v| jsonGetString(v) else null;
    const mode = if (obj.get("mode")) |v| jsonGetString(v) else null;
    const unit = if (obj.get("unit")) |v| jsonGetString(v) else null;
    const status = if (obj.get("status")) |v| jsonGetString(v) else null;
    const message = if (obj.get("message")) |v| jsonGetString(v) else null;
    const plan_type = if (obj.get("planType")) |v| jsonGetString(v) else null;

    var info = CreditsInfo{
        .available = if (obj.get("available")) |v| jsonGetF64(v) else null,
        .used = if (obj.get("used")) |v| jsonGetF64(v) else null,
        .total = if (obj.get("total")) |v| jsonGetF64(v) else null,
        .currency = try allocator.dupe(u8, currency orelse "USD"),
        .source = if (source) |source_text| if (std.mem.eql(u8, source_text, "legacy_credit_grants")) .legacy_credit_grants else .wham_usage else .wham_usage,
        .mode = if (mode) |mode_text| blk: {
            if (std.mem.eql(u8, mode_text, "legacy")) break :blk .legacy;
            if (std.mem.eql(u8, mode_text, "percent_fallback")) break :blk .percent_fallback;
            break :blk .balance;
        } else .balance,
        .unit = if (unit) |unit_text| if (std.mem.eql(u8, unit_text, "%")) .percent else .USD else .USD,
        .plan_type = try dupMaybeString(allocator, plan_type),
        .is_paid_plan = if (obj.get("isPaidPlan")) |v| jsonGetBool(v) orelse false else false,
        .hourly_remaining_percent = if (obj.get("hourlyRemainingPercent")) |v| jsonGetF64(v) else null,
        .weekly_remaining_percent = if (obj.get("weeklyRemainingPercent")) |v| jsonGetF64(v) else null,
        .hourly_refresh_at = if (obj.get("hourlyRefreshAt")) |v| jsonGetI64(v) else null,
        .weekly_refresh_at = if (obj.get("weeklyRefreshAt")) |v| jsonGetI64(v) else null,
        .status = if (status) |status_text| blk: {
            if (std.mem.eql(u8, status_text, "available")) break :blk .available;
            if (std.mem.eql(u8, status_text, "error")) break :blk .err;
            break :blk .unavailable;
        } else .unavailable,
        .message = try allocator.dupe(u8, message orelse ""),
        .checked_at = if (obj.get("checkedAt")) |v| jsonGetI64(v) orelse nowEpochSeconds() else nowEpochSeconds(),
    };
    errdefer info.deinit(allocator);
    return info;
}

fn loadPreferencesAndUsage(
    allocator: std.mem.Allocator,
    bootstrap_path: []const u8,
) !struct {
    preferences: UiPreferences,
    usage: std.ArrayListUnmanaged(UsageCacheEntry),
    saved_at: i64,
} {
    var preferences = UiPreferences{
        .theme = if (DEFAULT_THEME) |theme| try allocator.dupe(u8, theme) else null,
        .auto_archive_zero_quota = true,
        .auto_unarchive_non_zero_quota = true,
        .auto_switch_away_from_archived = true,
        .auto_refresh_active_enabled = false,
        .auto_refresh_active_interval_sec = AUTO_REFRESH_ACTIVE_DEFAULT_INTERVAL_SEC,
        .usage_refresh_display_mode = try allocator.dupe(u8, DEFAULT_USAGE_REFRESH_DISPLAY_MODE),
    };
    errdefer preferences.deinit(allocator);

    var usage = std.ArrayListUnmanaged(UsageCacheEntry){};
    errdefer {
        for (usage.items) |*entry| entry.deinit(allocator);
        usage.deinit(allocator);
    }
    var saved_at: i64 = 0;

    const raw_bootstrap = try readOptionalTextFile(allocator, bootstrap_path);
    defer if (raw_bootstrap) |text| allocator.free(text);
    if (raw_bootstrap == null) {
        return .{ .preferences = preferences, .usage = usage, .saved_at = saved_at };
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_bootstrap.?, .{}) catch {
        return .{ .preferences = preferences, .usage = usage, .saved_at = saved_at };
    };
    defer parsed.deinit();

    const root = jsonGetObject(parsed.value) orelse {
        return .{ .preferences = preferences, .usage = usage, .saved_at = saved_at };
    };

    if (root.get("theme")) |value| {
        if (jsonGetString(value)) |theme| {
            if (preferences.theme) |existing| allocator.free(existing);
            preferences.theme = try allocator.dupe(u8, theme);
        }
    }

    if (root.get("autoArchiveZeroQuota")) |value| {
        preferences.auto_archive_zero_quota = jsonGetBool(value) orelse preferences.auto_archive_zero_quota;
    }
    if (root.get("autoUnarchiveNonZeroQuota")) |value| {
        preferences.auto_unarchive_non_zero_quota = jsonGetBool(value) orelse preferences.auto_unarchive_non_zero_quota;
    }
    if (root.get("autoSwitchAwayFromArchived")) |value| {
        preferences.auto_switch_away_from_archived = jsonGetBool(value) orelse preferences.auto_switch_away_from_archived;
    }
    if (root.get("autoRefreshActiveEnabled")) |value| {
        preferences.auto_refresh_active_enabled = jsonGetBool(value) orelse preferences.auto_refresh_active_enabled;
    }
    if (root.get("autoRefreshActiveIntervalSec")) |value| {
        const parsed_interval = if (jsonGetI64(value)) |n| if (n < 0) null else @as(?u64, @intCast(n)) else null;
        preferences.auto_refresh_active_interval_sec = normalizeAutoRefreshIntervalSec(parsed_interval);
    }
    if (root.get("usageRefreshDisplayMode")) |value| {
        if (jsonGetString(value)) |mode| {
            allocator.free(preferences.usage_refresh_display_mode);
            preferences.usage_refresh_display_mode = try allocator.dupe(u8, if (std.mem.eql(u8, mode, "remaining")) "remaining" else "date");
        }
    }
    if (root.get("savedAt")) |value| {
        saved_at = jsonGetI64(value) orelse saved_at;
    }

    if (root.get("usageById")) |usage_value| {
        if (jsonGetObject(usage_value)) |usage_object| {
            var it = usage_object.iterator();
            while (it.next()) |entry| {
                const account_id = entry.key_ptr.*;
                const parsed_info = try parseCreditsInfo(allocator, entry.value_ptr.*);
                if (parsed_info == null) continue;
                var usage_entry = UsageCacheEntry{
                    .account_id = try allocator.dupe(u8, account_id),
                    .credits = parsed_info.?,
                };
                errdefer usage_entry.deinit(allocator);
                try usage.append(allocator, usage_entry);
            }
        }
    }

    return .{
        .preferences = preferences,
        .usage = usage,
        .saved_at = saved_at,
    };
}

fn loadAppState(allocator: std.mem.Allocator) !AppState {
    const paths = try getManagedPaths(allocator);
    errdefer {
        var owned_paths = paths;
        owned_paths.deinit(allocator);
    }

    var store = try loadStoreState(allocator, paths.storePath);
    errdefer store.deinit(allocator);

    const prefs_and_usage = try loadPreferencesAndUsage(allocator, paths.bootstrapStatePath);
    errdefer {
        var preferences_owned = prefs_and_usage.preferences;
        preferences_owned.deinit(allocator);
        var usage_owned = prefs_and_usage.usage;
        for (usage_owned.items) |*entry| entry.deinit(allocator);
        usage_owned.deinit(allocator);
    }

    return .{
        .paths = paths,
        .store = store,
        .preferences = prefs_and_usage.preferences,
        .usage_by_id = prefs_and_usage.usage,
        .saved_at = prefs_and_usage.saved_at,
    };
}

fn usageEntryIndex(usage: []const UsageCacheEntry, account_id: []const u8) ?usize {
    for (usage, 0..) |entry, idx| {
        if (std.mem.eql(u8, entry.account_id, account_id)) return idx;
    }
    return null;
}

fn accountIndex(store: *const StoreState, account_id: []const u8) ?usize {
    for (store.accounts.items, 0..) |account, idx| {
        if (std.mem.eql(u8, account.id, account_id)) return idx;
    }
    return null;
}

fn accountBucket(account: *const ManagedAccount) AccountBucket {
    if (account.frozen) return .frozen;
    if (account.archived) return .depleted;
    return .active;
}

fn applyBucket(account: *ManagedAccount, bucket: AccountBucket) void {
    account.archived = bucket == .depleted;
    account.frozen = bucket == .frozen;
}

fn accountStateString(account: *const ManagedAccount) []const u8 {
    if (account.frozen) return "frozen";
    if (account.archived) return "archived";
    return "active";
}

fn sanitizeStoreActiveAccount(allocator: std.mem.Allocator, store: *StoreState) !void {
    if (store.active_account_id) |active_id| {
        const idx = accountIndex(store, active_id);
        if (idx) |account_idx| {
            const account = store.accounts.items[account_idx];
            if (!account.archived and !account.frozen) {
                return;
            }
        }
    }

    for (store.accounts.items) |account| {
        if (!account.archived and !account.frozen) {
            if (store.active_account_id == null or !std.mem.eql(u8, store.active_account_id.?, account.id)) {
                if (store.active_account_id) |previous| allocator.free(previous);
                store.active_account_id = try allocator.dupe(u8, account.id);
            }
            return;
        }
    }

    if (store.active_account_id) |previous| {
        allocator.free(previous);
        store.active_account_id = null;
    }
}

fn loadCodexAuthJson(allocator: std.mem.Allocator, codex_auth_path: []const u8) !?[]u8 {
    return readOptionalTextFile(allocator, codex_auth_path);
}

fn writeCodexAuthPath(allocator: std.mem.Allocator, codex_auth_path: []const u8, contents: []const u8) !void {
    try writeTextFileAtomic(allocator, codex_auth_path, contents);
}

fn extractAccessTokenFromAuthJson(allocator: std.mem.Allocator, auth_json: []const u8) ?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, auth_json, .{}) catch return null;
    defer parsed.deinit();

    const root = jsonGetObject(parsed.value) orelse return null;
    const tokens = root.get("tokens") orelse return null;
    const tokens_obj = jsonGetObject(tokens) orelse return null;
    const access = tokens_obj.get("access_token") orelse return null;
    const access_token = jsonGetString(access) orelse return null;
    return allocator.dupe(u8, access_token) catch null;
}

fn extractApiKeyFromAuthJson(allocator: std.mem.Allocator, auth_json: []const u8) ?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, auth_json, .{}) catch return null;
    defer parsed.deinit();

    const root = jsonGetObject(parsed.value) orelse return null;
    const value = root.get("OPENAI_API_KEY") orelse return null;
    const api_key = jsonGetString(value) orelse return null;
    return allocator.dupe(u8, api_key) catch null;
}

fn extractAccountIdFromAuthJson(allocator: std.mem.Allocator, auth_json: []const u8) ?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, auth_json, .{}) catch return null;
    defer parsed.deinit();

    const root = jsonGetObject(parsed.value) orelse return null;
    const tokens = root.get("tokens") orelse return null;
    const tokens_obj = jsonGetObject(tokens) orelse return null;
    const account_id_value = tokens_obj.get("account_id") orelse return null;
    const account_id = jsonGetString(account_id_value) orelse return null;
    return allocator.dupe(u8, account_id) catch null;
}

fn extractEmailFromIdToken(allocator: std.mem.Allocator, id_token: []const u8) ?[]u8 {
    const first_dot = std.mem.indexOfScalar(u8, id_token, '.') orelse return null;
    const second_dot = std.mem.indexOfScalarPos(u8, id_token, first_dot + 1, '.') orelse return null;
    if (second_dot <= first_dot + 1) return null;

    const payload_b64 = id_token[first_dot + 1 .. second_dot];
    const decoded_len = std.base64.url_safe_no_pad.Decoder.calcSizeUpperBound(payload_b64.len) catch return null;
    const decoded = allocator.alloc(u8, decoded_len) catch return null;
    defer allocator.free(decoded);
    std.base64.url_safe_no_pad.Decoder.decode(decoded, payload_b64) catch return null;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, decoded, .{}) catch return null;
    defer parsed.deinit();

    const payload = jsonGetObject(parsed.value) orelse return null;
    if (payload.get("email")) |email_value| {
        if (jsonGetString(email_value)) |email| return allocator.dupe(u8, email) catch null;
    }

    if (payload.get("https://api.openai.com/profile")) |profile_value| {
        const profile = jsonGetObject(profile_value) orelse return null;
        if (profile.get("email")) |email_value| {
            if (jsonGetString(email_value)) |email| return allocator.dupe(u8, email) catch null;
        }
    }

    return null;
}

fn extractAccountIdFromIdToken(allocator: std.mem.Allocator, id_token: []const u8) ?[]u8 {
    const first_dot = std.mem.indexOfScalar(u8, id_token, '.') orelse return null;
    const second_dot = std.mem.indexOfScalarPos(u8, id_token, first_dot + 1, '.') orelse return null;
    if (second_dot <= first_dot + 1) return null;

    const payload_b64 = id_token[first_dot + 1 .. second_dot];
    const decoded_len = std.base64.url_safe_no_pad.Decoder.calcSizeUpperBound(payload_b64.len) catch return null;
    const decoded = allocator.alloc(u8, decoded_len) catch return null;
    defer allocator.free(decoded);
    std.base64.url_safe_no_pad.Decoder.decode(decoded, payload_b64) catch return null;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, decoded, .{}) catch return null;
    defer parsed.deinit();

    const payload = jsonGetObject(parsed.value) orelse return null;
    const auth_value = payload.get("https://api.openai.com/auth") orelse return null;
    const auth = jsonGetObject(auth_value) orelse return null;
    const account_id_value = auth.get("chatgpt_account_id") orelse return null;
    const account_id = jsonGetString(account_id_value) orelse return null;
    return allocator.dupe(u8, account_id) catch null;
}

fn extractEmailFromAuthJson(allocator: std.mem.Allocator, auth_json: []const u8) ?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, auth_json, .{}) catch return null;
    defer parsed.deinit();

    const root = jsonGetObject(parsed.value) orelse return null;
    if (root.get("email")) |email_value| {
        if (jsonGetString(email_value)) |email| {
            return allocator.dupe(u8, email) catch null;
        }
    }

    if (root.get("tokens")) |tokens_value| {
        const tokens = jsonGetObject(tokens_value) orelse return null;
        if (tokens.get("email")) |email_value| {
            if (jsonGetString(email_value)) |email| {
                return allocator.dupe(u8, email) catch null;
            }
        }

        if (tokens.get("id_token")) |id_token_value| {
            switch (id_token_value) {
                .string => |id_token| {
                    if (extractEmailFromIdToken(allocator, id_token)) |email| return email;
                },
                .object => |id_token_object| {
                    if (id_token_object.get("raw_jwt")) |raw_jwt_value| {
                        if (jsonGetString(raw_jwt_value)) |raw_jwt| {
                            if (extractEmailFromIdToken(allocator, raw_jwt)) |email| return email;
                        }
                    }
                },
                else => {},
            }
        }
    }

    return null;
}

fn serializeStoreState(allocator: std.mem.Allocator, store: *const StoreState) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    const writer = buffer.writer(allocator);

    try writer.writeAll("{\"activeAccountId\":");
    try writeJsonOptionalString(writer, store.active_account_id);
    try writer.writeAll(",\"accounts\":[");

    for (store.accounts.items, 0..) |account, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{\"id\":");
        try writeJsonString(writer, account.id);
        try writer.writeAll(",\"label\":");
        try writeJsonOptionalString(writer, account.label);
        try writer.writeAll(",\"accountId\":");
        try writeJsonOptionalString(writer, account.account_id);
        try writer.writeAll(",\"email\":");
        try writeJsonOptionalString(writer, account.email);
        try writer.writeAll(",\"archived\":");
        try writeJsonBool(writer, account.archived);
        try writer.writeAll(",\"frozen\":");
        try writeJsonBool(writer, account.frozen);
        try writer.writeAll(",\"auth\":");
        try writer.writeAll(account.auth_json);
        try writer.writeAll(",\"createdAt\":");
        try writer.print("{}", .{account.created_at});
        try writer.writeAll(",\"updatedAt\":");
        try writer.print("{}", .{account.updated_at});
        try writer.writeAll(",\"lastUsedAt\":");
        try writeJsonOptionalI64(writer, account.last_used_at);
        try writer.writeByte('}');
    }

    try writer.writeAll("]}");
    return buffer.toOwnedSlice(allocator);
}

fn writeCreditsInfoJson(writer: anytype, credits: *const CreditsInfo) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"available\":");
    try writeJsonOptionalF64(writer, credits.available);
    try writer.writeAll(",\"used\":");
    try writeJsonOptionalF64(writer, credits.used);
    try writer.writeAll(",\"total\":");
    try writeJsonOptionalF64(writer, credits.total);
    try writer.writeAll(",\"currency\":");
    try writeJsonString(writer, credits.currency);
    try writer.writeAll(",\"source\":");
    try writeJsonString(writer, creditsSourceString(credits.source));
    try writer.writeAll(",\"mode\":");
    try writeJsonString(writer, creditsModeString(credits.mode));
    try writer.writeAll(",\"unit\":");
    try writeJsonString(writer, creditsUnitString(credits.unit));
    try writer.writeAll(",\"planType\":");
    try writeJsonOptionalString(writer, credits.plan_type);
    try writer.writeAll(",\"isPaidPlan\":");
    try writeJsonBool(writer, credits.is_paid_plan);
    try writer.writeAll(",\"hourlyRemainingPercent\":");
    try writeJsonOptionalF64(writer, credits.hourly_remaining_percent);
    try writer.writeAll(",\"weeklyRemainingPercent\":");
    try writeJsonOptionalF64(writer, credits.weekly_remaining_percent);
    try writer.writeAll(",\"hourlyRefreshAt\":");
    try writeJsonOptionalI64(writer, credits.hourly_refresh_at);
    try writer.writeAll(",\"weeklyRefreshAt\":");
    try writeJsonOptionalI64(writer, credits.weekly_refresh_at);
    try writer.writeAll(",\"status\":");
    try writeJsonString(writer, creditsStatusString(credits.status));
    try writer.writeAll(",\"message\":");
    try writeJsonString(writer, credits.message);
    try writer.writeAll(",\"checkedAt\":");
    try writer.print("{}", .{credits.checked_at});
    try writer.writeByte('}');
}

fn buildSnapshotJson(allocator: std.mem.Allocator, state: *AppState) ![]u8 {
    try sanitizeStoreActiveAccount(allocator, &state.store);
    const view_json = try buildAccountsViewJson(allocator, state);
    defer allocator.free(view_json);

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    const writer = buffer.writer(allocator);

    try writer.writeByte('{');
    try writer.writeAll("\"theme\":");
    try writeJsonOptionalString(writer, state.preferences.theme);
    try writer.writeAll(",\"autoArchiveZeroQuota\":");
    try writeJsonBool(writer, state.preferences.auto_archive_zero_quota);
    try writer.writeAll(",\"autoUnarchiveNonZeroQuota\":");
    try writeJsonBool(writer, state.preferences.auto_unarchive_non_zero_quota);
    try writer.writeAll(",\"autoSwitchAwayFromArchived\":");
    try writeJsonBool(writer, state.preferences.auto_switch_away_from_archived);
    try writer.writeAll(",\"autoRefreshActiveEnabled\":");
    try writeJsonBool(writer, state.preferences.auto_refresh_active_enabled);
    try writer.writeAll(",\"autoRefreshActiveIntervalSec\":");
    try writer.print("{}", .{state.preferences.auto_refresh_active_interval_sec});
    try writer.writeAll(",\"usageRefreshDisplayMode\":");
    try writeJsonString(writer, state.preferences.usage_refresh_display_mode);
    try writer.writeAll(",\"view\":");
    try writer.writeAll(view_json);

    try writer.writeAll(",\"usageById\":{");
    for (state.usage_by_id.items, 0..) |entry, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writeJsonString(writer, entry.account_id);
        try writer.writeByte(':');
        try writeCreditsInfoJson(writer, &entry.credits);
    }
    try writer.writeAll("},\"savedAt\":");
    try writer.print("{}", .{state.saved_at});
    try writer.writeByte('}');

    return buffer.toOwnedSlice(allocator);
}

fn buildAccountsViewJson(allocator: std.mem.Allocator, state: *AppState) ![]u8 {
    try sanitizeStoreActiveAccount(allocator, &state.store);

    const current_auth = try loadCodexAuthJson(allocator, state.paths.codexAuthPath);
    defer if (current_auth) |auth| allocator.free(auth);

    const active_disk_account_id = if (current_auth) |auth| extractAccountIdFromAuthJson(allocator, auth) else null;
    defer if (active_disk_account_id) |account_id| allocator.free(account_id);

    const codex_auth_exists = current_auth != null;

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    const writer = buffer.writer(allocator);

    try writer.writeAll("{\"accounts\":[");

    for (state.store.accounts.items, 0..) |account, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeByte('{');
        try writer.writeAll("\"id\":");
        try writeJsonString(writer, account.id);
        try writer.writeAll(",\"accountId\":");
        try writeJsonOptionalString(writer, account.account_id);
        try writer.writeAll(",\"email\":");
        try writeJsonOptionalString(writer, account.email);
        try writer.writeAll(",\"state\":");
        try writeJsonString(writer, accountStateString(&account));
        try writer.writeByte('}');
    }

    try writer.writeAll("],\"activeAccountId\":");
    try writeJsonOptionalString(writer, state.store.active_account_id);
    try writer.writeAll(",\"activeDiskAccountId\":");
    try writeJsonOptionalString(writer, active_disk_account_id);
    try writer.writeAll(",\"codexAuthExists\":");
    try writeJsonBool(writer, codex_auth_exists);
    try writer.writeAll(",\"codexAuthPath\":");
    try writeJsonString(writer, state.paths.codexAuthPath);
    try writer.writeAll(",\"storePath\":");
    try writeJsonString(writer, state.paths.storePath);
    try writer.writeByte('}');

    return buffer.toOwnedSlice(allocator);
}

fn buildUiPreferencesResponseJson(allocator: std.mem.Allocator, preferences: *const UiPreferences) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    const writer = buffer.writer(allocator);

    try writer.writeByte('{');
    try writer.writeAll("\"theme\":");
    try writeJsonOptionalString(writer, preferences.theme);
    try writer.writeAll(",\"autoArchiveZeroQuota\":");
    try writeJsonBool(writer, preferences.auto_archive_zero_quota);
    try writer.writeAll(",\"autoUnarchiveNonZeroQuota\":");
    try writeJsonBool(writer, preferences.auto_unarchive_non_zero_quota);
    try writer.writeAll(",\"autoSwitchAwayFromArchived\":");
    try writeJsonBool(writer, preferences.auto_switch_away_from_archived);
    try writer.writeAll(",\"autoRefreshActiveEnabled\":");
    try writeJsonBool(writer, preferences.auto_refresh_active_enabled);
    try writer.writeAll(",\"autoRefreshActiveIntervalSec\":");
    try writer.print("{}", .{preferences.auto_refresh_active_interval_sec});
    try writer.writeAll(",\"usageRefreshDisplayMode\":");
    try writeJsonString(writer, preferences.usage_refresh_display_mode);
    try writer.writeByte('}');

    return buffer.toOwnedSlice(allocator);
}

fn buildUsageCacheJson(allocator: std.mem.Allocator, state: *AppState) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    const writer = buffer.writer(allocator);

    try writer.writeByte('{');
    for (state.usage_by_id.items, 0..) |entry, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writeJsonString(writer, entry.account_id);
        try writer.writeByte(':');
        try writeCreditsInfoJson(writer, &entry.credits);
    }
    try writer.writeByte('}');

    return buffer.toOwnedSlice(allocator);
}

fn persistStateFilesOnly(allocator: std.mem.Allocator, state: *AppState) !void {
    state.saved_at = nowEpochSeconds();

    const serialized_store = try serializeStoreState(allocator, &state.store);
    defer allocator.free(serialized_store);
    try writeTextFileAtomic(allocator, state.paths.storePath, serialized_store);

    const snapshot_json = try buildSnapshotJson(allocator, state);
    defer allocator.free(snapshot_json);
    try writeTextFileAtomic(allocator, state.paths.bootstrapStatePath, snapshot_json);
    const live_index_path = try embedded_index.writeLiveIndexFromBootstrapJson(allocator, snapshot_json);
    defer allocator.free(live_index_path);
}

fn buildRefreshUsageResponseJson(
    allocator: std.mem.Allocator,
    account_id: []const u8,
    credits: *const CreditsInfo,
    email: ?[]const u8,
) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    const writer = buffer.writer(allocator);

    try writer.writeAll("{\"accountId\":");
    try writeJsonString(writer, account_id);
    try writer.writeAll(",\"credits\":");
    try writeCreditsInfoJson(writer, credits);
    try writer.writeAll(",\"email\":");
    try writeJsonOptionalString(writer, email);
    try writer.writeByte('}');

    return buffer.toOwnedSlice(allocator);
}

fn makeCreditsInfo(
    allocator: std.mem.Allocator,
    checked_at: i64,
    status: CreditsStatus,
    message: []const u8,
) !CreditsInfo {
    return .{
        .available = null,
        .used = null,
        .total = null,
        .currency = try allocator.dupe(u8, "USD"),
        .source = .wham_usage,
        .mode = .balance,
        .unit = .USD,
        .plan_type = null,
        .is_paid_plan = false,
        .hourly_remaining_percent = null,
        .weekly_remaining_percent = null,
        .hourly_refresh_at = null,
        .weekly_refresh_at = null,
        .status = status,
        .message = try allocator.dupe(u8, message),
        .checked_at = checked_at,
    };
}

fn parseEpochSeconds(value: std.json.Value) ?i64 {
    const parsed = jsonGetI64(value) orelse return null;
    if (parsed > 1_000_000_000_000) {
        return @divFloor(parsed, 1000);
    }
    return parsed;
}

const RateLimitWindow = struct {
    used_percent: f64,
    window_seconds: i64,
    refresh_at: ?i64,
};

fn parseRateLimitWindowObject(
    windows: *std.ArrayListUnmanaged(RateLimitWindow),
    allocator: std.mem.Allocator,
    rate_limit_obj: std.json.ObjectMap,
    checked_at: i64,
) !void {
    const candidates = [_][]const u8{ "primary_window", "secondary_window", "primaryWindow", "secondaryWindow" };
    for (candidates) |field| {
        const window_value = rate_limit_obj.get(field) orelse continue;
        const window_obj = jsonGetObject(window_value) orelse continue;

        const used_percent_value = window_obj.get("used_percent") orelse window_obj.get("usedPercent") orelse continue;
        const window_seconds_value = window_obj.get("limit_window_seconds") orelse window_obj.get("limitWindowSeconds") orelse continue;

        const used_percent = jsonGetF64(used_percent_value) orelse continue;
        const window_seconds = jsonGetI64(window_seconds_value) orelse continue;

        var refresh_at: ?i64 = null;
        if (window_obj.get("next_reset_at")) |v| refresh_at = parseEpochSeconds(v);
        if (refresh_at == null) {
            if (window_obj.get("nextResetAt")) |v| refresh_at = parseEpochSeconds(v);
        }
        if (refresh_at == null) {
            if (window_obj.get("reset_at")) |v| refresh_at = parseEpochSeconds(v);
        }
        if (refresh_at == null) {
            if (window_obj.get("resetAt")) |v| refresh_at = parseEpochSeconds(v);
        }
        if (refresh_at == null) {
            if (window_obj.get("seconds_until_reset")) |v| {
                if (jsonGetI64(v)) |seconds| {
                    if (seconds >= 0) refresh_at = checked_at + seconds;
                }
            }
        }
        if (refresh_at == null and window_seconds > 0) {
            refresh_at = checked_at + window_seconds;
        }

        try windows.append(allocator, .{
            .used_percent = @max(0.0, @min(100.0, used_percent)),
            .window_seconds = window_seconds,
            .refresh_at = refresh_at,
        });
    }
}

fn pickWeeklyWindow(windows: []const RateLimitWindow) ?RateLimitWindow {
    if (windows.len == 0) return null;

    var weekly: ?RateLimitWindow = null;
    var best_distance: i64 = std.math.maxInt(i64);
    for (windows) |window| {
        if (window.window_seconds < 86400) continue;
        const distance: i64 = @intCast(@abs(window.window_seconds - 604800));
        if (distance < best_distance) {
            best_distance = distance;
            weekly = window;
        }
    }
    if (weekly != null) return weekly;

    var fallback = windows[0];
    for (windows[1..]) |window| {
        if (window.window_seconds > fallback.window_seconds) fallback = window;
    }
    return fallback;
}

fn pickHourlyWindow(windows: []const RateLimitWindow, weekly: ?RateLimitWindow) ?RateLimitWindow {
    if (windows.len == 0) return null;

    var best: ?RateLimitWindow = null;
    for (windows) |window| {
        if (weekly) |weekly_window| {
            if (window.window_seconds == weekly_window.window_seconds and window.used_percent == weekly_window.used_percent) {
                continue;
            }
        }
        if (window.window_seconds <= 43200) {
            if (best == null or window.window_seconds < best.?.window_seconds) best = window;
        }
    }
    if (best != null) return best;

    for (windows) |window| {
        if (weekly) |weekly_window| {
            if (window.window_seconds == weekly_window.window_seconds and window.used_percent == weekly_window.used_percent) {
                continue;
            }
        }
        if (best == null or window.window_seconds < best.?.window_seconds) best = window;
    }
    return best;
}

fn remainingFromWindow(window: ?RateLimitWindow) ?f64 {
    if (window) |value| return @max(0.0, @min(100.0, 100.0 - value.used_percent));
    return null;
}

fn refreshFromWindow(window: ?RateLimitWindow) ?i64 {
    if (window) |value| return value.refresh_at;
    return null;
}

fn parseWhamCredits(
    allocator: std.mem.Allocator,
    payload: std.json.ObjectMap,
    checked_at: i64,
) !CreditsInfo {
    var result = try makeCreditsInfo(allocator, checked_at, .err, "Usage endpoint returned no balance or usage data.");
    errdefer result.deinit(allocator);

    var windows = std.ArrayListUnmanaged(RateLimitWindow){};
    defer windows.deinit(allocator);

    if (payload.get("rate_limit")) |rate_limit| {
        if (jsonGetObject(rate_limit)) |rate_limit_obj| {
            try parseRateLimitWindowObject(&windows, allocator, rate_limit_obj, checked_at);
        }
    }
    if (payload.get("rateLimit")) |rate_limit| {
        if (jsonGetObject(rate_limit)) |rate_limit_obj| {
            try parseRateLimitWindowObject(&windows, allocator, rate_limit_obj, checked_at);
        }
    }
    if (payload.get("additional_rate_limits")) |additional| {
        if (jsonGetArray(additional)) |entries| {
            for (entries.items) |entry| {
                const entry_obj = jsonGetObject(entry) orelse continue;
                if (entry_obj.get("rate_limit")) |extra| {
                    if (jsonGetObject(extra)) |extra_obj| {
                        try parseRateLimitWindowObject(&windows, allocator, extra_obj, checked_at);
                    }
                }
            }
        }
    }

    const weekly_window = pickWeeklyWindow(windows.items);
    const hourly_window = pickHourlyWindow(windows.items, weekly_window);

    result.hourly_remaining_percent = remainingFromWindow(hourly_window);
    result.weekly_remaining_percent = remainingFromWindow(weekly_window);
    result.hourly_refresh_at = refreshFromWindow(hourly_window);
    result.weekly_refresh_at = refreshFromWindow(weekly_window);

    if (payload.get("plan_type")) |plan_value| {
        if (jsonGetString(plan_value)) |plan| {
            result.plan_type = try allocator.dupe(u8, plan);
            result.is_paid_plan = !std.ascii.eqlIgnoreCase(plan, "free");
        }
    }

    const credits_value = payload.get("credits");
    if (credits_value) |credits| {
        if (jsonGetObject(credits)) |credits_obj| {
            if (credits_obj.get("balance")) |balance_value| {
                if (jsonGetF64(balance_value)) |balance| {
                    result.available = balance;
                    result.status = .available;
                    allocator.free(result.message);
                    result.message = try allocator.dupe(u8, "Remaining credits loaded from Codex usage endpoint.");
                    return result;
                }
            }
        }
    }

    var used_percent: ?f64 = null;
    if (payload.get("rate_limit")) |rate_limit| {
        if (jsonGetObject(rate_limit)) |rate_limit_obj| {
            if (rate_limit_obj.get("primary_window")) |window_value| {
                if (jsonGetObject(window_value)) |window_obj| {
                    if (window_obj.get("used_percent")) |used_value| used_percent = jsonGetF64(used_value);
                    if (used_percent == null) {
                        if (window_obj.get("usedPercent")) |used_value| {
                            used_percent = jsonGetF64(used_value);
                        }
                    }
                }
            }
        }
    }

    if (used_percent) |used| {
        const clamped = @max(0.0, @min(100.0, used));
        result.available = 100.0 - clamped;
        result.used = clamped;
        result.total = 100.0;
        allocator.free(result.currency);
        result.currency = try allocator.dupe(u8, "%");
        result.mode = .percent_fallback;
        result.unit = .percent;
        result.status = .available;
        allocator.free(result.message);
        result.message = try allocator.dupe(u8, "Usage fallback loaded from rate-limit percent.");
    }

    return result;
}

fn fetchLegacyCreditsFromApiKey(allocator: std.mem.Allocator, api_key: []const u8, checked_at: i64) !CreditsInfo {
    const endpoints = [_][]const u8{
        "https://api.openai.com/dashboard/billing/credit_grants",
        "https://api.openai.com/v1/dashboard/billing/credit_grants",
    };

    const last_error = try allocator.dupe(u8, "No usable billing payload returned.");
    defer allocator.free(last_error);

    for (endpoints) |endpoint| {
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(allocator);

        const auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{api_key});
        defer allocator.free(auth_header);
        try argv.appendSlice(allocator, &.{ "curl", "-sS", "--location", "--write-out", "\n%{http_code}", "-H", auth_header, endpoint });

        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = argv.items,
            .max_output_bytes = 2 * 1024 * 1024,
        }) catch {
            continue;
        };
        defer allocator.free(result.stderr);
        defer allocator.free(result.stdout);

        const newline_index = std.mem.lastIndexOfScalar(u8, result.stdout, '\n') orelse continue;
        const body_slice = result.stdout[0..newline_index];
        const status_slice = std.mem.trim(u8, result.stdout[newline_index + 1 ..], " \r\n\t");
        const status_code = std.fmt.parseInt(u16, status_slice, 10) catch 599;
        if (status_code < 200 or status_code >= 300) {
            continue;
        }

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, body_slice, .{}) catch continue;
        defer parsed.deinit();
        const payload = jsonGetObject(parsed.value) orelse continue;
        const summary = if (payload.get("credit_summary")) |value| jsonGetObject(value) else null;

        const available = if (payload.get("total_available")) |v| jsonGetF64(v) else if (summary) |sum| if (sum.get("total_available")) |v| jsonGetF64(v) else null else null;
        const used = if (payload.get("total_used")) |v| jsonGetF64(v) else if (summary) |sum| if (sum.get("total_used")) |v| jsonGetF64(v) else null else null;
        const total = if (payload.get("total_granted")) |v| jsonGetF64(v) else if (summary) |sum| if (sum.get("total_granted")) |v| jsonGetF64(v) else null else null;

        if (available == null and used == null and total == null) continue;

        return .{
            .available = available,
            .used = used,
            .total = total,
            .currency = try allocator.dupe(u8, "USD"),
            .source = .legacy_credit_grants,
            .mode = .legacy,
            .unit = .USD,
            .plan_type = null,
            .is_paid_plan = false,
            .hourly_remaining_percent = null,
            .weekly_remaining_percent = null,
            .hourly_refresh_at = null,
            .weekly_refresh_at = null,
            .status = .available,
            .message = try allocator.dupe(u8, "Remaining credits loaded from billing endpoint."),
            .checked_at = checked_at,
        };
    }

    return .{
        .available = null,
        .used = null,
        .total = null,
        .currency = try allocator.dupe(u8, "USD"),
        .source = .legacy_credit_grants,
        .mode = .legacy,
        .unit = .USD,
        .plan_type = null,
        .is_paid_plan = false,
        .hourly_remaining_percent = null,
        .weekly_remaining_percent = null,
        .hourly_refresh_at = null,
        .weekly_refresh_at = null,
        .status = .err,
        .message = try allocator.dupe(u8, last_error),
        .checked_at = checked_at,
    };
}

fn fetchCreditsFromAuthJson(
    allocator: std.mem.Allocator,
    auth_json: []const u8,
    account_id_hint: ?[]const u8,
) !CreditsInfo {
    const checked_at = nowEpochSeconds();

    const access_token = extractAccessTokenFromAuthJson(allocator, auth_json);
    defer if (access_token) |token| allocator.free(token);
    if (access_token) |token| {
        const usage = fetchWhamUsage(allocator, token, account_id_hint) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "Failed to fetch usage: {s}", .{@errorName(err)});
            defer allocator.free(message);
            return makeCreditsInfo(allocator, checked_at, .err, message);
        };
        defer allocator.free(usage.body);

        if (usage.status < 200 or usage.status >= 300) {
            const detail = std.mem.trim(u8, usage.body, " \r\n\t");
            const message = try std.fmt.allocPrint(
                allocator,
                "Usage endpoint returned {}. {s}",
                .{ usage.status, if (detail.len > 0) detail else "No response body." },
            );
            defer allocator.free(message);
            return makeCreditsInfo(allocator, checked_at, .err, message);
        }

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, usage.body, .{}) catch {
            return makeCreditsInfo(allocator, checked_at, .err, "Usage endpoint returned invalid JSON.");
        };
        defer parsed.deinit();
        const payload = jsonGetObject(parsed.value) orelse {
            return makeCreditsInfo(allocator, checked_at, .err, "Usage endpoint returned invalid JSON payload.");
        };

        return parseWhamCredits(allocator, payload, checked_at);
    }

    const api_key = extractApiKeyFromAuthJson(allocator, auth_json);
    defer if (api_key) |key| allocator.free(key);
    if (api_key) |key| {
        return fetchLegacyCreditsFromApiKey(allocator, key, checked_at);
    }

    return makeCreditsInfo(allocator, checked_at, .unavailable, "No access token available for this account.");
}

fn fetchEmailFromOpenAiApi(allocator: std.mem.Allocator, access_token: []const u8) !?[]u8 {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);

    const auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{access_token});
    defer allocator.free(auth_header);

    try argv.appendSlice(allocator, &.{
        "curl",
        "-sS",
        "--location",
        "--write-out",
        "\n%{http_code}",
        "-H",
        auth_header,
        "-H",
        "User-Agent: codex-cli",
        "https://api.openai.com/v1/me",
    });

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 1024 * 1024,
    }) catch return null;
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) return null;
        },
        else => return null,
    }

    const newline_index = std.mem.lastIndexOfScalar(u8, result.stdout, '\n') orelse return null;
    const body_slice = result.stdout[0..newline_index];
    const status_slice = std.mem.trim(u8, result.stdout[newline_index + 1 ..], " \r\n\t");
    const status_code = std.fmt.parseInt(u16, status_slice, 10) catch 599;
    if (status_code < 200 or status_code >= 300) {
        return null;
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body_slice, .{}) catch return null;
    defer parsed.deinit();
    const root = jsonGetObject(parsed.value) orelse return null;
    const email_value = root.get("email") orelse return null;
    const email = jsonGetString(email_value) orelse return null;
    return try allocator.dupe(u8, email);
}

fn accountMatchesIdentity(account: *const ManagedAccount, account_id: ?[]const u8, email: ?[]const u8) bool {
    if (account_id != null and account.account_id != null and std.mem.eql(u8, account_id.?, account.account_id.?)) return true;
    if (email != null and account.email != null and std.mem.eql(u8, email.?, account.email.?)) return true;
    return false;
}

fn generateAccountId(allocator: std.mem.Allocator) ![]u8 {
    const random_value = std.crypto.random.int(u32);
    return std.fmt.allocPrint(allocator, "acct-{}-{x:0>8}", .{ std.time.milliTimestamp(), random_value });
}

fn upsertAccountFromAuth(
    allocator: std.mem.Allocator,
    store: *StoreState,
    auth_json: []const u8,
    label: ?[]const u8,
    set_active: bool,
) ![]const u8 {
    const now = nowEpochSeconds();
    const account_id = extractAccountIdFromAuthJson(allocator, auth_json);
    defer if (account_id) |value| allocator.free(value);
    const email = extractEmailFromAuthJson(allocator, auth_json);
    defer if (email) |value| allocator.free(value);

    var existing_index: ?usize = null;
    for (store.accounts.items, 0..) |account, idx| {
        if (accountMatchesIdentity(&account, account_id, email)) {
            existing_index = idx;
            break;
        }
    }

    if (existing_index) |idx| {
        var account = &store.accounts.items[idx];
        if (account.account_id) |value| allocator.free(value);
        account.account_id = if (account_id) |value| try allocator.dupe(u8, value) else null;
        if (account.email) |value| allocator.free(value);
        account.email = if (email) |value| try allocator.dupe(u8, value) else null;
        if (label) |new_label| {
            if (account.label) |value| allocator.free(value);
            account.label = try allocator.dupe(u8, new_label);
        }
        allocator.free(account.auth_json);
        account.auth_json = try allocator.dupe(u8, auth_json);
        account.archived = false;
        account.frozen = false;
        account.updated_at = now;
        if (set_active) {
            account.last_used_at = now;
            if (store.active_account_id) |value| allocator.free(value);
            store.active_account_id = try allocator.dupe(u8, account.id);
        }
        return account.id;
    }

    var account = ManagedAccount{
        .id = try generateAccountId(allocator),
        .label = if (label) |value| try allocator.dupe(u8, value) else null,
        .account_id = if (account_id) |value| try allocator.dupe(u8, value) else null,
        .email = if (email) |value| try allocator.dupe(u8, value) else null,
        .archived = false,
        .frozen = false,
        .auth_json = try allocator.dupe(u8, auth_json),
        .created_at = now,
        .updated_at = now,
        .last_used_at = if (set_active) now else null,
    };
    errdefer account.deinit(allocator);

    try store.accounts.append(allocator, account);
    if (set_active) {
        if (store.active_account_id) |value| allocator.free(value);
        store.active_account_id = try allocator.dupe(u8, account.id);
    }

    return store.accounts.items[store.accounts.items.len - 1].id;
}

fn setStoreActiveAccountId(allocator: std.mem.Allocator, store: *StoreState, account_id: ?[]const u8) !void {
    if (store.active_account_id) |existing| {
        allocator.free(existing);
        store.active_account_id = null;
    }
    if (account_id) |value| {
        store.active_account_id = try allocator.dupe(u8, value);
    }
}

fn switchActiveToFallback(allocator: std.mem.Allocator, state: *AppState, removed_id: ?[]const u8) !void {
    if (state.store.active_account_id) |active_id| {
        if (removed_id != null and !std.mem.eql(u8, active_id, removed_id.?)) {
            return;
        }
    } else {
        return;
    }

    for (state.store.accounts.items) |*candidate| {
        if (removed_id != null and std.mem.eql(u8, candidate.id, removed_id.?)) continue;
        if (candidate.archived or candidate.frozen) continue;

        try setStoreActiveAccountId(allocator, &state.store, candidate.id);
        candidate.last_used_at = nowEpochSeconds();
        candidate.updated_at = nowEpochSeconds();
        try writeCodexAuthPath(allocator, state.paths.codexAuthPath, candidate.auth_json);
        return;
    }

    try setStoreActiveAccountId(allocator, &state.store, null);
}

fn handleGetAppStateCommand(allocator: std.mem.Allocator) ![]u8 {
    return jsonError(allocator, "get_app_state is deprecated");
}

fn handleGetUsageCacheCommand(allocator: std.mem.Allocator) ![]u8 {
    managed_files_mutex.lock();
    defer managed_files_mutex.unlock();

    var state = try loadAppState(allocator);
    defer state.deinit(allocator);

    const usage_json = try buildUsageCacheJson(allocator, &state);
    defer allocator.free(usage_json);
    return jsonOkRaw(allocator, usage_json);
}

fn handleGetUiPreferencesCommand(allocator: std.mem.Allocator) ![]u8 {
    managed_files_mutex.lock();
    defer managed_files_mutex.unlock();

    var state = try loadAppState(allocator);
    defer state.deinit(allocator);

    const preferences_json = try buildUiPreferencesResponseJson(allocator, &state.preferences);
    defer allocator.free(preferences_json);
    return jsonOkRaw(allocator, preferences_json);
}

fn handleSwitchAccountCommand(allocator: std.mem.Allocator, account_id_raw: []const u8) ![]u8 {
    const account_id = trimOptionalString(account_id_raw) orelse return jsonError(allocator, "switch_account requires accountId");

    managed_files_mutex.lock();
    defer managed_files_mutex.unlock();

    var state = try loadAppState(allocator);
    defer state.deinit(allocator);

    const idx = accountIndex(&state.store, account_id) orelse return jsonError(allocator, "Account not found.");
    var account = &state.store.accounts.items[idx];
    if (account.archived or account.frozen) {
        return jsonError(allocator, "Cannot switch to a depleted or frozen account.");
    }

    const now = nowEpochSeconds();
    account.last_used_at = now;
    account.updated_at = now;
    try setStoreActiveAccountId(allocator, &state.store, account.id);
    try writeCodexAuthPath(allocator, state.paths.codexAuthPath, account.auth_json);

    try persistStateFilesOnly(allocator, &state);
    const view_json = try buildAccountsViewJson(allocator, &state);
    defer allocator.free(view_json);
    return jsonOkRaw(allocator, view_json);
}

fn handleMoveAccountCommand(
    allocator: std.mem.Allocator,
    account_id_raw: []const u8,
    target_bucket_raw: []const u8,
    target_index: i64,
    switch_away: bool,
) ![]u8 {
    const account_id = trimOptionalString(account_id_raw) orelse return jsonError(allocator, "move_account requires accountId");
    const bucket_string = trimOptionalString(target_bucket_raw) orelse return jsonError(allocator, "move_account requires targetBucket");
    const target_bucket = parseAccountBucket(bucket_string) orelse return jsonError(allocator, "targetBucket must be active, depleted, or frozen");

    managed_files_mutex.lock();
    defer managed_files_mutex.unlock();

    var state = try loadAppState(allocator);
    defer state.deinit(allocator);

    const source_idx = accountIndex(&state.store, account_id) orelse return jsonError(allocator, "Account not found.");
    var moved = state.store.accounts.orderedRemove(source_idx);
    errdefer moved.deinit(allocator);

    applyBucket(&moved, target_bucket);
    moved.updated_at = nowEpochSeconds();

    if (state.store.active_account_id != null and std.mem.eql(u8, state.store.active_account_id.?, moved.id) and target_bucket != .active) {
        if (switch_away) {
            try switchActiveToFallback(allocator, &state, moved.id);
        } else {
            try setStoreActiveAccountId(allocator, &state.store, null);
        }
    }

    var bucket_indices = std.ArrayListUnmanaged(usize){};
    defer bucket_indices.deinit(allocator);
    for (state.store.accounts.items, 0..) |account, idx| {
        if (accountBucket(&account) == target_bucket) {
            try bucket_indices.append(allocator, idx);
        }
    }

    const normalized_target_index: usize = blk: {
        if (target_index <= 0) break :blk 0;
        const as_usize: usize = @intCast(target_index);
        break :blk @min(as_usize, bucket_indices.items.len);
    };

    var insert_index: usize = state.store.accounts.items.len;
    if (normalized_target_index < bucket_indices.items.len) {
        insert_index = bucket_indices.items[normalized_target_index];
    } else if (bucket_indices.items.len > 0) {
        insert_index = bucket_indices.items[bucket_indices.items.len - 1] + 1;
    }

    try state.store.accounts.insert(allocator, insert_index, moved);

    try persistStateFilesOnly(allocator, &state);
    return jsonOk(allocator, @as(?u8, null));
}

fn handleRemoveAccountCommand(allocator: std.mem.Allocator, account_id_raw: []const u8) ![]u8 {
    const account_id = trimOptionalString(account_id_raw) orelse return jsonError(allocator, "remove_account requires accountId");

    managed_files_mutex.lock();
    defer managed_files_mutex.unlock();

    var state = try loadAppState(allocator);
    defer state.deinit(allocator);

    const idx = accountIndex(&state.store, account_id) orelse return jsonError(allocator, "Account not found.");
    var removed = state.store.accounts.orderedRemove(idx);
    removed.deinit(allocator);

    if (state.store.active_account_id != null and std.mem.eql(u8, state.store.active_account_id.?, account_id)) {
        try switchActiveToFallback(allocator, &state, account_id);
    }

    if (usageEntryIndex(state.usage_by_id.items, account_id)) |usage_idx| {
        var usage_entry = state.usage_by_id.orderedRemove(usage_idx);
        usage_entry.deinit(allocator);
    }

    try persistStateFilesOnly(allocator, &state);
    const view_json = try buildAccountsViewJson(allocator, &state);
    defer allocator.free(view_json);
    return jsonOkRaw(allocator, view_json);
}

fn handleImportCurrentAccountCommand(allocator: std.mem.Allocator, label_raw: ?[]const u8) ![]u8 {
    const normalized_label = trimOptionalString(label_raw);

    managed_files_mutex.lock();
    defer managed_files_mutex.unlock();

    var state = try loadAppState(allocator);
    defer state.deinit(allocator);

    const auth_json = try loadCodexAuthJson(allocator, state.paths.codexAuthPath) orelse {
        return jsonError(allocator, "Codex auth.json not found.");
    };
    defer allocator.free(auth_json);

    _ = try upsertAccountFromAuth(allocator, &state.store, auth_json, normalized_label, true);
    try persistStateFilesOnly(allocator, &state);
    const view_json = try buildAccountsViewJson(allocator, &state);
    defer allocator.free(view_json);
    return jsonOkRaw(allocator, view_json);
}

fn handleLoginWithApiKeyCommand(allocator: std.mem.Allocator, api_key_raw: []const u8, label_raw: ?[]const u8) ![]u8 {
    const api_key = trimOptionalString(api_key_raw) orelse return jsonError(allocator, "login_with_api_key requires apiKey");
    const label = trimOptionalString(label_raw);

    const auth_json = try std.fmt.allocPrint(allocator, "{{\"auth_mode\":\"apikey\",\"OPENAI_API_KEY\":{f}}}", .{
        std.json.fmt(api_key, .{}),
    });
    defer allocator.free(auth_json);

    managed_files_mutex.lock();
    defer managed_files_mutex.unlock();

    var state = try loadAppState(allocator);
    defer state.deinit(allocator);

    try writeCodexAuthPath(allocator, state.paths.codexAuthPath, auth_json);
    _ = try upsertAccountFromAuth(allocator, &state.store, auth_json, label, true);

    try persistStateFilesOnly(allocator, &state);
    const view_json = try buildAccountsViewJson(allocator, &state);
    defer allocator.free(view_json);
    return jsonOkRaw(allocator, view_json);
}

fn handleUpdateUiPreferencesCommand(allocator: std.mem.Allocator, request: RpcRequest) ![]u8 {
    managed_files_mutex.lock();
    defer managed_files_mutex.unlock();

    var state = try loadAppState(allocator);
    defer state.deinit(allocator);

    if (request.theme) |theme_raw| {
        const trimmed = std.mem.trim(u8, theme_raw, " \r\n\t");
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "null")) {
            if (state.preferences.theme) |value| allocator.free(value);
            state.preferences.theme = null;
        } else if (std.mem.eql(u8, trimmed, "light") or std.mem.eql(u8, trimmed, "dark")) {
            if (state.preferences.theme) |value| allocator.free(value);
            state.preferences.theme = try allocator.dupe(u8, trimmed);
        } else {
            return jsonError(allocator, "theme must be light or dark");
        }
    }
    if (request.autoArchiveZeroQuota) |value| state.preferences.auto_archive_zero_quota = value;
    if (request.autoUnarchiveNonZeroQuota) |value| state.preferences.auto_unarchive_non_zero_quota = value;
    if (request.autoSwitchAwayFromArchived) |value| state.preferences.auto_switch_away_from_archived = value;
    if (request.autoRefreshActiveEnabled) |value| state.preferences.auto_refresh_active_enabled = value;
    if (request.autoRefreshActiveIntervalSec) |value| {
        state.preferences.auto_refresh_active_interval_sec = normalizeAutoRefreshIntervalSec(value);
    }
    if (request.usageRefreshDisplayMode) |mode_raw| {
        const trimmed = std.mem.trim(u8, mode_raw, " \r\n\t");
        if (!std.mem.eql(u8, trimmed, "date") and !std.mem.eql(u8, trimmed, "remaining")) {
            return jsonError(allocator, "usageRefreshDisplayMode must be date or remaining");
        }
        allocator.free(state.preferences.usage_refresh_display_mode);
        state.preferences.usage_refresh_display_mode = try allocator.dupe(u8, trimmed);
    }

    try persistStateFilesOnly(allocator, &state);
    const preferences_json = try buildUiPreferencesResponseJson(allocator, &state.preferences);
    defer allocator.free(preferences_json);
    return jsonOkRaw(allocator, preferences_json);
}

fn handleRefreshAccountUsageCommand(allocator: std.mem.Allocator, account_id_raw: []const u8) ![]u8 {
    const account_id = trimOptionalString(account_id_raw) orelse return jsonError(allocator, "refresh_account_usage requires accountId");

    if (shouldDebounceRefresh(account_id)) {
        managed_files_mutex.lock();
        defer managed_files_mutex.unlock();
        var debounced_state = try loadAppState(allocator);
        defer debounced_state.deinit(allocator);

        const usage_idx = usageEntryIndex(debounced_state.usage_by_id.items, account_id) orelse {
            var unavailable = try makeCreditsInfo(allocator, nowEpochSeconds(), .unavailable, "No usage data available for this account.");
            defer unavailable.deinit(allocator);
            const email = blk: {
                const idx = accountIndex(&debounced_state.store, account_id) orelse break :blk null;
                break :blk debounced_state.store.accounts.items[idx].email;
            };
            const debounced_response = try buildRefreshUsageResponseJson(allocator, account_id, &unavailable, email);
            defer allocator.free(debounced_response);
            return jsonOkRaw(allocator, debounced_response);
        };

        const account_email = blk: {
            const idx = accountIndex(&debounced_state.store, account_id) orelse break :blk null;
            break :blk debounced_state.store.accounts.items[idx].email;
        };
        const debounced_response = try buildRefreshUsageResponseJson(
            allocator,
            account_id,
            &debounced_state.usage_by_id.items[usage_idx].credits,
            account_email,
        );
        defer allocator.free(debounced_response);
        return jsonOkRaw(allocator, debounced_response);
    }

    try setRefreshInflight(account_id, true);
    defer setRefreshInflight(account_id, false) catch {};

    var auth_json_copy: ?[]u8 = null;
    defer if (auth_json_copy) |auth| allocator.free(auth);
    var account_id_hint: ?[]u8 = null;
    defer if (account_id_hint) |value| allocator.free(value);
    var needs_email_backfill = false;
    var fetched_email: ?[]u8 = null;
    defer if (fetched_email) |email| allocator.free(email);

    managed_files_mutex.lock();
    {
        var state = try loadAppState(allocator);
        defer state.deinit(allocator);
        const idx = accountIndex(&state.store, account_id) orelse {
            managed_files_mutex.unlock();
            return jsonError(allocator, "Account not found.");
        };
        const account = state.store.accounts.items[idx];
        auth_json_copy = try allocator.dupe(u8, account.auth_json);
        if (account.account_id) |value| {
            account_id_hint = try allocator.dupe(u8, value);
        }
        needs_email_backfill = account.email == null;
    }
    managed_files_mutex.unlock();

    if (needs_email_backfill) {
        const access_token = extractAccessTokenFromAuthJson(allocator, auth_json_copy.?);
        defer if (access_token) |token| allocator.free(token);
        if (access_token) |token| {
            fetched_email = fetchEmailFromOpenAiApi(allocator, token) catch null;
        }
    }

    var refreshed_credits = try fetchCreditsFromAuthJson(allocator, auth_json_copy.?, account_id_hint);
    errdefer refreshed_credits.deinit(allocator);

    managed_files_mutex.lock();
    defer managed_files_mutex.unlock();

    var state = try loadAppState(allocator);
    defer state.deinit(allocator);
    const account_idx = accountIndex(&state.store, account_id) orelse return jsonError(allocator, "Account not found.");

    if (fetched_email) |email| {
        const account = &state.store.accounts.items[account_idx];
        if (account.email == null) {
            account.email = try allocator.dupe(u8, email);
        }
    }

    if (usageEntryIndex(state.usage_by_id.items, account_id)) |idx| {
        var old = state.usage_by_id.items[idx];
        old.credits.deinit(allocator);
        allocator.free(old.account_id);
        state.usage_by_id.items[idx] = .{
            .account_id = try allocator.dupe(u8, account_id),
            .credits = refreshed_credits,
        };
    } else {
        try state.usage_by_id.append(allocator, .{
            .account_id = try allocator.dupe(u8, account_id),
            .credits = refreshed_credits,
        });
    }

    // Ownership moved into state.usage_by_id.
    refreshed_credits = undefined;

    try persistStateFilesOnly(allocator, &state);

    const updated_usage_idx = usageEntryIndex(state.usage_by_id.items, account_id) orelse {
        return jsonError(allocator, "Internal usage update error.");
    };
    const response_json = try buildRefreshUsageResponseJson(
        allocator,
        account_id,
        &state.usage_by_id.items[updated_usage_idx].credits,
        state.store.accounts.items[account_idx].email,
    );
    defer allocator.free(response_json);
    return jsonOkRaw(allocator, response_json);
}

fn usageFetchKeyForRequest(allocator: std.mem.Allocator, access_token: []const u8, account_id: ?[]const u8) ![]u8 {
    if (account_id) |id| {
        const trimmed = std.mem.trim(u8, id, " \r\n\t");
        if (trimmed.len > 0) {
            return std.fmt.allocPrint(allocator, "account:{s}", .{trimmed});
        }
    }

    const hash = std.hash.Wyhash.hash(0, access_token);
    return std.fmt.allocPrint(allocator, "token:{x}", .{hash});
}

fn usageFetchEntryIndexByKeyLocked(key: []const u8) ?usize {
    for (usage_fetch_state.entries.items, 0..) |entry, idx| {
        if (std.mem.eql(u8, entry.key, key)) {
            return idx;
        }
    }
    return null;
}

fn usageFetchEntryIndexByRequestIdLocked(request_id: u64) ?usize {
    for (usage_fetch_state.entries.items, 0..) |entry, idx| {
        if (entry.last_request_id == request_id) {
            return idx;
        }
    }
    return null;
}

fn makeUsageFetchErrorBody(message: []const u8) []u8 {
    return std.heap.page_allocator.dupe(u8, message) catch blk: {
        const fallback = "usage fetch failed";
        const owned = std.heap.page_allocator.alloc(u8, fallback.len) catch @panic("out of memory creating usage error");
        @memcpy(owned, fallback);
        break :blk owned;
    };
}

fn usageFetchWorkerMain(args_in: UsageFetchWorkerArgs) void {
    var args = args_in;
    defer args.deinit();

    const usage = fetchWhamUsage(std.heap.page_allocator, args.access_token, args.account_id) catch |err| blk: {
        const message = std.fmt.allocPrint(std.heap.page_allocator, "wham fetch failed: {s}", .{@errorName(err)}) catch makeUsageFetchErrorBody("wham fetch failed");
        break :blk UsageResult{
            .status = 599,
            .body = message,
        };
    };

    const finished_at_ms = std.time.milliTimestamp();

    usage_fetch_state.mutex.lock();
    defer usage_fetch_state.mutex.unlock();

    const idx = usageFetchEntryIndexByKeyLocked(args.key) orelse {
        std.heap.page_allocator.free(usage.body);
        return;
    };
    var entry = &usage_fetch_state.entries.items[idx];

    if (entry.last_request_id != args.request_id) {
        std.heap.page_allocator.free(usage.body);
        return;
    }

    if (entry.last_body) |previous| {
        std.heap.page_allocator.free(previous);
    }

    // Keep the critical section short: network fetch runs outside mutex; lock only
    // while updating shared fetch/account state.
    entry.last_body = usage.body;
    entry.last_status = usage.status;
    entry.last_completed_ms = finished_at_ms;
    entry.inflight = false;
}

fn startWhamUsageFetch(
    allocator: std.mem.Allocator,
    access_token: []const u8,
    account_id: ?[]const u8,
) ![]u8 {
    const key = try usageFetchKeyForRequest(allocator, access_token, account_id);
    defer allocator.free(key);

    const now_ms = std.time.milliTimestamp();

    var request_id: u64 = 0;
    var cached_status: ?u16 = null;
    var cached_body_copy: ?[]u8 = null;
    var action: enum { running, completed, spawn } = .spawn;

    {
        usage_fetch_state.mutex.lock();
        defer usage_fetch_state.mutex.unlock();

        const idx = idx: {
            if (usageFetchEntryIndexByKeyLocked(key)) |existing| {
                break :idx existing;
            }

            const owned_key = try std.heap.page_allocator.dupe(u8, key);
            errdefer std.heap.page_allocator.free(owned_key);

            try usage_fetch_state.entries.append(std.heap.page_allocator, .{
                .key = owned_key,
            });
            break :idx usage_fetch_state.entries.items.len - 1;
        };

        var entry = &usage_fetch_state.entries.items[idx];

        if (entry.inflight) {
            request_id = entry.last_request_id;
            action = .running;
        } else {
            const can_use_cached = entry.last_body != null and
                entry.last_completed_ms > 0 and
                (now_ms - entry.last_completed_ms) < USAGE_FETCH_DEBOUNCE_MS;

            if (can_use_cached) {
                request_id = entry.last_request_id;
                cached_status = entry.last_status;
                cached_body_copy = if (entry.last_body) |body| try allocator.dupe(u8, body) else null;
                action = .completed;
            } else {
                request_id = usage_fetch_state.next_request_id;
                usage_fetch_state.next_request_id += 1;
                entry.last_request_id = request_id;
                entry.inflight = true;
                entry.last_started_ms = now_ms;
                action = .spawn;
            }
        }
    }

    switch (action) {
        .running => {
            return jsonOk(allocator, .{
                .state = "running",
                .requestId = request_id,
                .debounced = true,
            });
        },
        .completed => {
            defer if (cached_body_copy) |body| allocator.free(body);
            return jsonOk(allocator, .{
                .state = "completed",
                .requestId = request_id,
                .status = cached_status,
                .body = cached_body_copy,
                .debounced = true,
            });
        },
        .spawn => {},
    }

    var worker_args = try UsageFetchWorkerArgs.init(access_token, account_id, key, request_id);
    errdefer worker_args.deinit();

    const worker = std.Thread.spawn(.{}, usageFetchWorkerMain, .{worker_args}) catch |err| {
        usage_fetch_state.mutex.lock();
        defer usage_fetch_state.mutex.unlock();

        if (usageFetchEntryIndexByKeyLocked(key)) |idx_locked| {
            var entry_locked = &usage_fetch_state.entries.items[idx_locked];
            if (entry_locked.last_request_id == request_id) {
                entry_locked.inflight = false;
            }
        }

        return err;
    };
    worker.detach();

    return jsonOk(allocator, .{
        .state = "queued",
        .requestId = request_id,
        .debounced = false,
    });
}

fn pollWhamUsageFetch(allocator: std.mem.Allocator, request_id: u64) ![]u8 {
    var inflight = false;
    var status: ?u16 = null;
    var body_copy: ?[]u8 = null;
    var found = false;

    {
        usage_fetch_state.mutex.lock();
        defer usage_fetch_state.mutex.unlock();

        if (usageFetchEntryIndexByRequestIdLocked(request_id)) |idx| {
            found = true;
            const entry = &usage_fetch_state.entries.items[idx];
            inflight = entry.inflight;
            status = entry.last_status;
            body_copy = if (!entry.inflight and entry.last_body != null)
                try allocator.dupe(u8, entry.last_body.?)
            else
                null;
        }
    }

    if (!found) {
        return jsonOk(allocator, .{
            .state = "unknown",
            .requestId = request_id,
        });
    }

    if (inflight) {
        return jsonOk(allocator, .{
            .state = "running",
            .requestId = request_id,
        });
    }

    defer if (body_copy) |body| allocator.free(body);
    return jsonOk(allocator, .{
        .state = if (body_copy != null) "completed" else "unknown",
        .requestId = request_id,
        .status = status,
        .body = body_copy,
    });
}

fn fetchWhamUsage(
    allocator: std.mem.Allocator,
    access_token: []const u8,
    account_id: ?[]const u8,
) !UsageResult {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);

    try argv.appendSlice(allocator, &.{
        "curl",
        "-sS",
        "--location",
        "--write-out",
        "\n%{http_code}",
        "-H",
        "User-Agent: codex-cli",
    });

    const auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{access_token});
    defer allocator.free(auth_header);
    try argv.appendSlice(allocator, &.{ "-H", auth_header });

    var account_header: ?[]u8 = null;
    defer if (account_header) |header| allocator.free(header);

    if (account_id) |id| {
        if (id.len > 0) {
            const header = try std.fmt.allocPrint(allocator, "ChatGPT-Account-Id: {s}", .{id});
            account_header = header;
            try argv.appendSlice(allocator, &.{ "-H", header });
        }
    }

    try argv.append(allocator, "https://chatgpt.com/backend-api/wham/usage");

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 2 * 1024 * 1024,
    }) catch |err| {
        const message = try std.fmt.allocPrint(allocator, "curl spawn failed: {s}", .{@errorName(err)});
        return .{ .status = 599, .body = message };
    };
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                const stderr_text = std.mem.trim(u8, result.stderr, " \r\n\t");
                const message = if (stderr_text.len == 0)
                    try allocator.dupe(u8, "curl failed")
                else
                    try allocator.dupe(u8, stderr_text);
                return .{ .status = 599, .body = message };
            }
        },
        else => {
            return .{ .status = 599, .body = try allocator.dupe(u8, "curl terminated unexpectedly") };
        },
    }

    const newline_index = std.mem.lastIndexOfScalar(u8, result.stdout, '\n') orelse {
        return .{ .status = 599, .body = try allocator.dupe(u8, "curl returned malformed response") };
    };

    const body_slice = result.stdout[0..newline_index];
    const status_slice = std.mem.trim(u8, result.stdout[newline_index + 1 ..], " \r\n\t");
    const status_code = std.fmt.parseInt(u16, status_slice, 10) catch 599;

    return .{
        .status = status_code,
        .body = try allocator.dupe(u8, body_slice),
    };
}

fn writeHttpResponse(stream: std.net.Stream, status: []const u8, body: []const u8) void {
    var header_buffer: [512]u8 = undefined;
    const header = std.fmt.bufPrint(
        &header_buffer,
        "HTTP/1.1 {s}\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: {}\r\n\r\n",
        .{ status, body.len },
    ) catch return;

    stream.writeAll(header) catch {};
    stream.writeAll(body) catch {};
}

fn extractRequestTarget(request: []const u8) ?[]const u8 {
    const first_line_end = std.mem.indexOfScalar(u8, request, '\n') orelse request.len;
    const first_line = std.mem.trimRight(u8, request[0..first_line_end], "\r");

    var parts = std.mem.tokenizeScalar(u8, first_line, ' ');
    const method = parts.next() orelse return null;
    const target = parts.next() orelse return null;

    if (!std.mem.eql(u8, method, "GET")) {
        return null;
    }

    return target;
}

const OAuthThreadArgs = struct {
    timeout_seconds: u64,
    external_cancel: *std.atomic.Value(bool),
    issuer: []u8,
    client_id: []u8,
    redirect_uri: []u8,
    oauth_state: []u8,
    code_verifier: []u8,
    label: ?[]u8 = null,

    fn init(
        issuer: []const u8,
        client_id: []const u8,
        redirect_uri: []const u8,
        oauth_state: []const u8,
        code_verifier: []const u8,
        label: ?[]const u8,
        timeout_seconds: u64,
        external_cancel: *std.atomic.Value(bool),
    ) !OAuthThreadArgs {
        const issuer_copy = try std.heap.page_allocator.dupe(u8, issuer);
        errdefer std.heap.page_allocator.free(issuer_copy);
        const client_id_copy = try std.heap.page_allocator.dupe(u8, client_id);
        errdefer std.heap.page_allocator.free(client_id_copy);
        const redirect_uri_copy = try std.heap.page_allocator.dupe(u8, redirect_uri);
        errdefer std.heap.page_allocator.free(redirect_uri_copy);
        const oauth_state_copy = try std.heap.page_allocator.dupe(u8, oauth_state);
        errdefer std.heap.page_allocator.free(oauth_state_copy);
        const code_verifier_copy = try std.heap.page_allocator.dupe(u8, code_verifier);
        errdefer std.heap.page_allocator.free(code_verifier_copy);
        const label_copy = if (label) |value| try std.heap.page_allocator.dupe(u8, value) else null;
        errdefer if (label_copy) |value| std.heap.page_allocator.free(value);

        return .{
            .timeout_seconds = timeout_seconds,
            .external_cancel = external_cancel,
            .issuer = issuer_copy,
            .client_id = client_id_copy,
            .redirect_uri = redirect_uri_copy,
            .oauth_state = oauth_state_copy,
            .code_verifier = code_verifier_copy,
            .label = label_copy,
        };
    }

    fn deinit(self: *OAuthThreadArgs) void {
        std.heap.page_allocator.free(self.issuer);
        std.heap.page_allocator.free(self.client_id);
        std.heap.page_allocator.free(self.redirect_uri);
        std.heap.page_allocator.free(self.oauth_state);
        std.heap.page_allocator.free(self.code_verifier);
        if (self.label) |value| {
            std.heap.page_allocator.free(value);
        }
    }
};

const OAuthTokenPair = struct {
    id_token: []u8,
    access_token: []u8,
    refresh_token: []u8,

    fn deinit(self: *OAuthTokenPair, allocator: std.mem.Allocator) void {
        allocator.free(self.id_token);
        allocator.free(self.access_token);
        allocator.free(self.refresh_token);
    }
};

const OAuthCallbackQuery = struct {
    code: []u8,
    state: ?[]u8 = null,
    auth_error: ?[]u8 = null,
    auth_error_description: ?[]u8 = null,

    fn deinit(self: *OAuthCallbackQuery, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        if (self.state) |value| allocator.free(value);
        if (self.auth_error) |value| allocator.free(value);
        if (self.auth_error_description) |value| allocator.free(value);
    }
};

fn clearOAuthListenerResultLocked() void {
    if (oauth_listener_state.callback_url) |url| {
        std.heap.page_allocator.free(url);
        oauth_listener_state.callback_url = null;
    }
    if (oauth_listener_state.ready_account) |*account| {
        account.deinit(std.heap.page_allocator);
        oauth_listener_state.ready_account = null;
    }
    if (oauth_listener_state.error_name) |err_name| {
        std.heap.page_allocator.free(err_name);
        oauth_listener_state.error_name = null;
    }
}

fn joinOAuthListenerThreadLocked() void {
    if (oauth_listener_state.thread) |thread| {
        thread.join();
        oauth_listener_state.thread = null;
    }
}

fn decodeHexNibble(byte: u8) ?u8 {
    if (byte >= '0' and byte <= '9') return byte - '0';
    if (byte >= 'a' and byte <= 'f') return byte - 'a' + 10;
    if (byte >= 'A' and byte <= 'F') return byte - 'A' + 10;
    return null;
}

fn decodeUrlComponent(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    var idx: usize = 0;
    while (idx < value.len) : (idx += 1) {
        const current = value[idx];
        if (current == '+') {
            try buffer.append(allocator, ' ');
            continue;
        }
        if (current == '%' and idx + 2 < value.len) {
            const high = decodeHexNibble(value[idx + 1]) orelse {
                try buffer.append(allocator, current);
                continue;
            };
            const low = decodeHexNibble(value[idx + 2]) orelse {
                try buffer.append(allocator, current);
                continue;
            };
            try buffer.append(allocator, (high << 4) | low);
            idx += 2;
            continue;
        }
        try buffer.append(allocator, current);
    }

    return buffer.toOwnedSlice(allocator);
}

fn getDecodedQueryParamValue(allocator: std.mem.Allocator, query: []const u8, key: []const u8) !?[]u8 {
    var parts = std.mem.splitScalar(u8, query, '&');
    while (parts.next()) |segment| {
        if (segment.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, segment, '=') orelse segment.len;
        const raw_key = segment[0..eq];
        const raw_value = if (eq < segment.len) segment[eq + 1 ..] else "";

        const decoded_key = try decodeUrlComponent(allocator, raw_key);
        defer allocator.free(decoded_key);
        if (!std.mem.eql(u8, decoded_key, key)) continue;

        return try decodeUrlComponent(allocator, raw_value);
    }
    return null;
}

fn parseOAuthCallbackQuery(allocator: std.mem.Allocator, callback_url: []const u8) !OAuthCallbackQuery {
    const query_start = std.mem.indexOfScalar(u8, callback_url, '?') orelse return error.CallbackMissingQuery;
    const query_end = std.mem.indexOfScalarPos(u8, callback_url, query_start + 1, '#') orelse callback_url.len;
    if (query_end <= query_start + 1) return error.CallbackMissingQuery;
    const query = callback_url[query_start + 1 .. query_end];

    const code = try getDecodedQueryParamValue(allocator, query, "code");
    const oauth_state = try getDecodedQueryParamValue(allocator, query, "state");
    errdefer if (oauth_state) |value| allocator.free(value);
    const auth_error = try getDecodedQueryParamValue(allocator, query, "error");
    errdefer if (auth_error) |value| allocator.free(value);
    const auth_error_description = try getDecodedQueryParamValue(allocator, query, "error_description");
    errdefer if (auth_error_description) |value| allocator.free(value);

    if (auth_error != null and code == null) {
        return .{
            .code = try allocator.dupe(u8, ""),
            .state = oauth_state,
            .auth_error = auth_error,
            .auth_error_description = auth_error_description,
        };
    }

    const parsed_code = code orelse return error.CallbackMissingAuthorizationCode;
    return .{
        .code = parsed_code,
        .state = oauth_state,
        .auth_error = auth_error,
        .auth_error_description = auth_error_description,
    };
}

fn appendCurlFormField(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    owned_fields: *std.ArrayList([]u8),
    key: []const u8,
    value: []const u8,
) !void {
    const field = try std.fmt.allocPrint(allocator, "{s}={s}", .{ key, value });
    try owned_fields.append(allocator, field);
    try argv.appendSlice(allocator, &.{ "--data-urlencode", field });
}

fn runCurlWithStatus(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    max_output_bytes: usize,
) !UsageResult {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = max_output_bytes,
    }) catch return error.CurlSpawnFailed;
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) return error.CurlCommandFailed;
        },
        else => return error.CurlCommandFailed,
    }

    const newline_index = std.mem.lastIndexOfScalar(u8, result.stdout, '\n') orelse return error.CurlMalformedResponse;
    const body_slice = result.stdout[0..newline_index];
    const status_slice = std.mem.trim(u8, result.stdout[newline_index + 1 ..], " \r\n\t");
    const status_code = std.fmt.parseInt(u16, status_slice, 10) catch return error.CurlMalformedResponse;
    return .{
        .status = status_code,
        .body = try allocator.dupe(u8, body_slice),
    };
}

fn exchangeAuthorizationCodeForTokens(
    allocator: std.mem.Allocator,
    issuer: []const u8,
    client_id: []const u8,
    redirect_uri: []const u8,
    code: []const u8,
    code_verifier: []const u8,
) !OAuthTokenPair {
    const endpoint = try std.fmt.allocPrint(allocator, "{s}/oauth/token", .{issuer});
    defer allocator.free(endpoint);

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    var owned_fields = std.ArrayList([]u8).empty;
    defer {
        for (owned_fields.items) |field| allocator.free(field);
        owned_fields.deinit(allocator);
    }

    try argv.appendSlice(allocator, &.{
        "curl",
        "-sS",
        "--location",
        "--write-out",
        "\n%{http_code}",
        "-H",
        "Content-Type: application/x-www-form-urlencoded",
    });
    try appendCurlFormField(allocator, &argv, &owned_fields, "grant_type", "authorization_code");
    try appendCurlFormField(allocator, &argv, &owned_fields, "code", code);
    try appendCurlFormField(allocator, &argv, &owned_fields, "redirect_uri", redirect_uri);
    try appendCurlFormField(allocator, &argv, &owned_fields, "client_id", client_id);
    try appendCurlFormField(allocator, &argv, &owned_fields, "code_verifier", code_verifier);
    try argv.append(allocator, endpoint);

    const response = try runCurlWithStatus(allocator, argv.items, 2 * 1024 * 1024);
    defer allocator.free(response.body);
    if (response.status < 200 or response.status >= 300) {
        return error.AuthorizationCodeExchangeFailed;
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response.body, .{}) catch return error.AuthorizationCodeExchangeFailed;
    defer parsed.deinit();
    const payload = jsonGetObject(parsed.value) orelse return error.AuthorizationCodeExchangeFailed;

    const id_token = if (payload.get("id_token")) |value| jsonGetString(value) else null;
    const access_token = if (payload.get("access_token")) |value| jsonGetString(value) else null;
    const refresh_token = if (payload.get("refresh_token")) |value| jsonGetString(value) else null;
    if (id_token == null or access_token == null or refresh_token == null) {
        return error.AuthorizationCodeExchangeFailed;
    }

    return .{
        .id_token = try allocator.dupe(u8, id_token.?),
        .access_token = try allocator.dupe(u8, access_token.?),
        .refresh_token = try allocator.dupe(u8, refresh_token.?),
    };
}

fn exchangeApiKeyFromIdToken(
    allocator: std.mem.Allocator,
    issuer: []const u8,
    client_id: []const u8,
    id_token: []const u8,
) !?[]u8 {
    const endpoint = try std.fmt.allocPrint(allocator, "{s}/oauth/token", .{issuer});
    defer allocator.free(endpoint);

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    var owned_fields = std.ArrayList([]u8).empty;
    defer {
        for (owned_fields.items) |field| allocator.free(field);
        owned_fields.deinit(allocator);
    }

    try argv.appendSlice(allocator, &.{
        "curl",
        "-sS",
        "--location",
        "--write-out",
        "\n%{http_code}",
        "-H",
        "Content-Type: application/x-www-form-urlencoded",
    });
    try appendCurlFormField(allocator, &argv, &owned_fields, "grant_type", TOKEN_EXCHANGE_GRANT);
    try appendCurlFormField(allocator, &argv, &owned_fields, "client_id", client_id);
    try appendCurlFormField(allocator, &argv, &owned_fields, "requested_token", "openai-api-key");
    try appendCurlFormField(allocator, &argv, &owned_fields, "subject_token", id_token);
    try appendCurlFormField(allocator, &argv, &owned_fields, "subject_token_type", ID_TOKEN_TYPE);
    try argv.append(allocator, endpoint);

    const response = runCurlWithStatus(allocator, argv.items, 2 * 1024 * 1024) catch return null;
    defer allocator.free(response.body);
    if (response.status < 200 or response.status >= 300) return null;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response.body, .{}) catch return null;
    defer parsed.deinit();
    const payload = jsonGetObject(parsed.value) orelse return null;
    const access_token = if (payload.get("access_token")) |value| jsonGetString(value) else null;
    if (access_token == null) return null;
    return try allocator.dupe(u8, access_token.?);
}

fn buildChatgptAuthPayloadJson(
    allocator: std.mem.Allocator,
    tokens: *const OAuthTokenPair,
    api_key: ?[]const u8,
) ![]u8 {
    const account_id = extractAccountIdFromIdToken(allocator, tokens.id_token);
    defer if (account_id) |value| allocator.free(value);

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    const writer = buffer.writer(allocator);

    try writer.writeAll("{\"auth_mode\":\"chatgpt\",\"tokens\":{\"id_token\":");
    try writeJsonString(writer, tokens.id_token);
    try writer.writeAll(",\"access_token\":");
    try writeJsonString(writer, tokens.access_token);
    try writer.writeAll(",\"refresh_token\":");
    try writeJsonString(writer, tokens.refresh_token);
    try writer.writeAll(",\"account_id\":");
    try writeJsonOptionalString(writer, account_id);
    try writer.writeAll("},\"last_refresh\":");

    const last_refresh = try std.fmt.allocPrint(allocator, "{}", .{std.time.timestamp()});
    defer allocator.free(last_refresh);
    try writeJsonString(writer, last_refresh);

    if (api_key) |value| {
        try writer.writeAll(",\"OPENAI_API_KEY\":");
        try writeJsonString(writer, value);
    }

    try writer.writeByte('}');
    return buffer.toOwnedSlice(allocator);
}

fn completeOAuthLoginFromCallback(allocator: std.mem.Allocator, args: *const OAuthThreadArgs, callback_url: []const u8) !OAuthReadyAccount {
    var callback_query = try parseOAuthCallbackQuery(allocator, callback_url);
    defer callback_query.deinit(allocator);

    if (callback_query.auth_error != null) {
        return error.OAuthAuthorizationFailed;
    }

    const callback_state = callback_query.state orelse return error.OAuthStateMissing;
    if (!std.mem.eql(u8, callback_state, args.oauth_state)) {
        return error.OAuthStateMismatch;
    }

    var tokens = try exchangeAuthorizationCodeForTokens(
        allocator,
        args.issuer,
        args.client_id,
        args.redirect_uri,
        callback_query.code,
        args.code_verifier,
    );
    defer tokens.deinit(allocator);

    const api_key = try exchangeApiKeyFromIdToken(allocator, args.issuer, args.client_id, tokens.id_token);
    defer if (api_key) |value| allocator.free(value);

    const auth_json = try buildChatgptAuthPayloadJson(allocator, &tokens, api_key);
    defer allocator.free(auth_json);

    const existing_email = extractEmailFromAuthJson(allocator, auth_json);
    defer if (existing_email) |value| allocator.free(value);
    const fetched_email = if (existing_email == null)
        (fetchEmailFromOpenAiApi(allocator, tokens.access_token) catch null)
    else
        null;
    defer if (fetched_email) |value| allocator.free(value);

    managed_files_mutex.lock();
    defer managed_files_mutex.unlock();

    var state = try loadAppState(allocator);
    defer state.deinit(allocator);

    try writeCodexAuthPath(allocator, state.paths.codexAuthPath, auth_json);
    const managed_account_id = try upsertAccountFromAuth(allocator, &state.store, auth_json, args.label, true);
    const account_idx = accountIndex(&state.store, managed_account_id) orelse return error.AccountNotFound;
    var managed_account = &state.store.accounts.items[account_idx];

    if (managed_account.email == null and fetched_email != null) {
        managed_account.email = try allocator.dupe(u8, fetched_email.?);
    }

    try persistStateFilesOnly(allocator, &state);

    return .{
        .id = try allocator.dupe(u8, managed_account.id),
        .accountId = if (managed_account.account_id) |value| try allocator.dupe(u8, value) else null,
        .email = if (managed_account.email) |value| try allocator.dupe(u8, value) else null,
        .state = accountStateString(managed_account),
    };
}

fn startOAuthCallbackListener(
    timeout_seconds: u64,
    external_cancel: *std.atomic.Value(bool),
    issuer: []const u8,
    client_id: []const u8,
    redirect_uri: []const u8,
    oauth_state: []const u8,
    code_verifier: []const u8,
    label: ?[]const u8,
) !void {
    oauth_listener_state.mutex.lock();
    defer oauth_listener_state.mutex.unlock();

    if (oauth_listener_state.running) {
        return error.CallbackListenerAlreadyRunning;
    }

    joinOAuthListenerThreadLocked();
    clearOAuthListenerResultLocked();

    oauth_listener_state.cancel.store(false, .seq_cst);
    external_cancel.store(false, .seq_cst);
    oauth_listener_state.running = true;

    var args = try OAuthThreadArgs.init(
        issuer,
        client_id,
        redirect_uri,
        oauth_state,
        code_verifier,
        label,
        timeout_seconds,
        external_cancel,
    );

    oauth_listener_state.thread = std.Thread.spawn(.{}, oauthCallbackThreadMain, .{args}) catch |err| {
        args.deinit();
        oauth_listener_state.running = false;
        return err;
    };
}

fn pollOAuthCallbackListener() !OAuthPollResult {
    oauth_listener_state.mutex.lock();
    defer oauth_listener_state.mutex.unlock();

    if (oauth_listener_state.running) {
        return .{ .status = "running" };
    }
    joinOAuthListenerThreadLocked();

    if (oauth_listener_state.ready_account) |account| {
        return .{
            .status = "ready",
            .account = account,
        };
    }

    if (oauth_listener_state.error_name) |err_name| {
        return .{
            .status = "error",
            .@"error" = err_name,
        };
    }

    return .{ .status = "idle" };
}

fn waitForOAuthCallbackResult(allocator: std.mem.Allocator) ![]u8 {
    oauth_listener_state.mutex.lock();
    defer oauth_listener_state.mutex.unlock();

    while (oauth_listener_state.running) {
        oauth_listener_state.cond.wait(&oauth_listener_state.mutex);
    }
    joinOAuthListenerThreadLocked();

    if (oauth_listener_state.callback_url) |url| {
        return allocator.dupe(u8, url);
    }

    if (oauth_listener_state.error_name) |err_name| {
        if (std.mem.eql(u8, err_name, "CallbackListenerStopped")) {
            return error.CallbackListenerStopped;
        }
        if (std.mem.eql(u8, err_name, "CallbackListenerTimeout")) {
            return error.CallbackListenerTimeout;
        }
        if (std.mem.eql(u8, err_name, "CallbackListenerSocketError")) {
            return error.CallbackListenerSocketError;
        }
        return error.CallbackListenerFailed;
    }

    return error.CallbackListenerUnavailable;
}

fn waitForOAuthReadyAccountResult(allocator: std.mem.Allocator) !OAuthReadyAccount {
    oauth_listener_state.mutex.lock();
    defer oauth_listener_state.mutex.unlock();

    while (oauth_listener_state.running) {
        oauth_listener_state.cond.wait(&oauth_listener_state.mutex);
    }
    joinOAuthListenerThreadLocked();

    if (oauth_listener_state.ready_account) |account| {
        return .{
            .id = try allocator.dupe(u8, account.id),
            .accountId = if (account.accountId) |value| try allocator.dupe(u8, value) else null,
            .email = if (account.email) |value| try allocator.dupe(u8, value) else null,
            .state = account.state,
        };
    }

    if (oauth_listener_state.error_name) |err_name| {
        if (std.mem.eql(u8, err_name, "CallbackListenerStopped")) {
            return error.CallbackListenerStopped;
        }
        if (std.mem.eql(u8, err_name, "CallbackListenerTimeout")) {
            return error.CallbackListenerTimeout;
        }
        if (std.mem.eql(u8, err_name, "CallbackListenerSocketError")) {
            return error.CallbackListenerSocketError;
        }
        return error.CallbackListenerFailed;
    }

    return error.CallbackListenerUnavailable;
}

fn cancelOAuthCallbackListener(external_cancel: *std.atomic.Value(bool)) void {
    oauth_listener_state.cancel.store(true, .seq_cst);
    external_cancel.store(true, .seq_cst);
}

fn oauthCallbackThreadMain(args: OAuthThreadArgs) void {
    var owned_args = args;
    defer owned_args.deinit();

    const callback_url = waitForOAuthCallback(
        std.heap.page_allocator,
        owned_args.timeout_seconds,
        &oauth_listener_state.cancel,
    ) catch |err| {
        oauth_listener_state.mutex.lock();
        clearOAuthListenerResultLocked();
        oauth_listener_state.error_name = std.heap.page_allocator.dupe(u8, @errorName(err)) catch null;
        oauth_listener_state.running = false;
        oauth_listener_state.cond.broadcast();
        oauth_listener_state.mutex.unlock();
        owned_args.external_cancel.store(false, .seq_cst);
        return;
    };

    const oauth_account = completeOAuthLoginFromCallback(std.heap.page_allocator, &owned_args, callback_url) catch |err| {
        std.heap.page_allocator.free(callback_url);
        oauth_listener_state.mutex.lock();
        clearOAuthListenerResultLocked();
        oauth_listener_state.error_name = std.heap.page_allocator.dupe(u8, @errorName(err)) catch null;
        oauth_listener_state.running = false;
        oauth_listener_state.cond.broadcast();
        oauth_listener_state.mutex.unlock();
        owned_args.external_cancel.store(false, .seq_cst);
        return;
    };

    oauth_listener_state.mutex.lock();
    clearOAuthListenerResultLocked();
    oauth_listener_state.callback_url = callback_url;
    oauth_listener_state.ready_account = oauth_account;
    oauth_listener_state.running = false;
    oauth_listener_state.cond.broadcast();
    oauth_listener_state.mutex.unlock();

    owned_args.external_cancel.store(false, .seq_cst);
}

fn waitForOAuthCallback(
    allocator: std.mem.Allocator,
    timeout_seconds: u64,
    cancel_ptr: *std.atomic.Value(bool),
) ![]u8 {
    cancel_ptr.store(false, .seq_cst);

    const address = try std.net.Address.parseIp4("127.0.0.1", 1455);
    var server = try address.listen(.{
        .reuse_address = true,
        .force_nonblocking = true,
    });
    defer server.deinit();

    const timeout_ms_total_u64 = timeout_seconds * 1000;
    const timeout_ms_total_i64 = std.math.cast(i64, timeout_ms_total_u64) orelse std.math.maxInt(i64);
    const deadline_ms = std.time.milliTimestamp() + timeout_ms_total_i64;

    accept_loop: while (true) {
        if (cancel_ptr.load(.seq_cst)) {
            return error.CallbackListenerStopped;
        }

        const accept_timeout_ms = computePollTimeoutMs(deadline_ms);
        if (accept_timeout_ms < 0) {
            return error.CallbackListenerTimeout;
        }

        var accept_fds = [_]std.posix.pollfd{
            .{
                .fd = server.stream.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
        };

        const accept_ready = try std.posix.poll(&accept_fds, accept_timeout_ms);
        if (accept_ready == 0) {
            continue;
        }

        if ((accept_fds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0) {
            return error.CallbackListenerSocketError;
        }

        const connection = server.accept() catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };

        var conn = connection;
        defer conn.stream.close();

        var buffer: [8192]u8 = undefined;
        while (true) {
            if (cancel_ptr.load(.seq_cst)) {
                return error.CallbackListenerStopped;
            }

            const read_timeout_ms = computePollTimeoutMs(deadline_ms);
            if (read_timeout_ms < 0) {
                return error.CallbackListenerTimeout;
            }

            var read_fds = [_]std.posix.pollfd{
                .{
                    .fd = conn.stream.handle,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                },
            };

            const read_ready = try std.posix.poll(&read_fds, read_timeout_ms);
            if (read_ready == 0) {
                continue;
            }

            if ((read_fds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL)) != 0) {
                continue :accept_loop;
            }

            const read_size = conn.stream.read(&buffer) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => continue :accept_loop,
            };
            if (read_size == 0) {
                continue :accept_loop;
            }

            const request = buffer[0..read_size];
            const maybe_target = extractRequestTarget(request);

            if (maybe_target) |target| {
                if (std.mem.startsWith(u8, target, "/auth/callback")) {
                    writeHttpResponse(conn.stream, "200 OK", OAUTH_CALLBACK_SUCCESS_HTML);
                    return std.fmt.allocPrint(allocator, "http://localhost:1455{s}", .{target});
                }

                writeHttpResponse(conn.stream, "404 Not Found", "<html><body>Not Found</body></html>");
                continue :accept_loop;
            }

            writeHttpResponse(conn.stream, "400 Bad Request", "<html><body>Invalid callback request.</body></html>");
            continue :accept_loop;
        }
    }
}

fn computePollTimeoutMs(deadline_ms: i64) i32 {
    const now = std.time.milliTimestamp();
    if (now >= deadline_ms) {
        return -1;
    }

    const remaining = deadline_ms - now;
    const slice_ms: i64 = 250;
    const next = @min(remaining, slice_ms);
    return @intCast(next);
}

pub fn openUrl(url: []const u8, allocator: std.mem.Allocator) !void {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);

    switch (builtin.os.tag) {
        .windows => {
            try argv.appendSlice(allocator, &.{ "rundll32", "url.dll,FileProtocolHandler", url });
        },
        .macos => {
            try argv.appendSlice(allocator, &.{ "open", url });
        },
        else => {
            try argv.appendSlice(allocator, &.{ "xdg-open", url });
        },
    }

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    _ = child.wait() catch {};
}

fn expectRpcErrorContains(response: []const u8, needle: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), response, .{});
    const root = parsed.object;

    const ok_value = root.get("ok") orelse return error.MissingOkField;
    try std.testing.expect(ok_value == .bool);
    try std.testing.expect(!ok_value.bool);

    const error_value = root.get("error") orelse return error.MissingErrorField;
    try std.testing.expect(error_value == .string);
    try std.testing.expect(std.mem.containsAtLeast(u8, error_value.string, 1, needle));
}

test "rpcFromText rejects invalid JSON payload" {
    var cancel = std.atomic.Value(bool).init(false);
    const response = try rpcFromText(std.testing.allocator, "{", &cancel);
    defer std.testing.allocator.free(response);

    try expectRpcErrorContains(response, "invalid RPC payload");
}

test "rpcFromText returns unknown op error for unsupported operation" {
    var cancel = std.atomic.Value(bool).init(false);
    const response = try rpcFromText(std.testing.allocator, "{\"op\":\"noop\"}", &cancel);
    defer std.testing.allocator.free(response);

    try expectRpcErrorContains(response, "unknown RPC op");
}

test "rpcHandleRequest path join requires at least one segment" {
    var cancel = std.atomic.Value(bool).init(false);
    const response = try rpcHandleRequest(
        std.testing.allocator,
        .{
            .op = "path:join",
            .paths = &.{},
        },
        &cancel,
    );
    defer std.testing.allocator.free(response);

    try expectRpcErrorContains(response, "path join requires at least one segment");
}

test "rpcHandleRequest cancel listener command sets cancel flag" {
    var cancel = std.atomic.Value(bool).init(false);
    const response = try rpcHandleRequest(
        std.testing.allocator,
        .{
            .op = "invoke:cancel_oauth_callback_listener",
        },
        &cancel,
    );
    defer std.testing.allocator.free(response);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), response, .{});
    const root = parsed.object;
    const ok_value = root.get("ok") orelse return error.MissingOkField;
    try std.testing.expect(ok_value == .bool);
    try std.testing.expect(ok_value.bool);
    try std.testing.expect(cancel.load(.seq_cst));
}

test "extractRequestTarget returns callback target for valid GET request" {
    const request =
        "GET /auth/callback?code=test&state=abc HTTP/1.1\r\n" ++
        "Host: localhost:1455\r\n\r\n";
    const target = extractRequestTarget(request) orelse return error.ExpectedTarget;
    try std.testing.expectEqualStrings("/auth/callback?code=test&state=abc", target);
}

test "extractRequestTarget rejects non-GET methods" {
    const request =
        "POST /auth/callback HTTP/1.1\r\n" ++
        "Host: localhost:1455\r\n\r\n";
    try std.testing.expectEqual(@as(?[]const u8, null), extractRequestTarget(request));
}
