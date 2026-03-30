const std = @import("std");
const builtin = @import("builtin");
const embedded_index = @import("embedded_index.zig");
const process_io: std.Io = if (builtin.is_test) std.testing.io else std.Options.debug_io;
var process_environ_map: ?*std.process.Environ.Map = null;

// Locks an I/O mutex using the process I/O context shared by this module.
inline fn lockIoMutex(mutex: *std.Io.Mutex) void {
    mutex.lockUncancelable(process_io);
}

// Unlocks an I/O mutex using the process I/O context shared by this module.
inline fn unlockIoMutex(mutex: *std.Io.Mutex) void {
    mutex.unlock(process_io);
}

// Wakes all waiters on an I/O condition variable.
inline fn broadcastIoCondition(cond: *std.Io.Condition) void {
    cond.broadcast(process_io);
}

// Returns the current wall-clock time in milliseconds.
inline fn nowMilliseconds() i64 {
    return std.Io.Clock.real.now(process_io).toMilliseconds();
}

/// Stores the startup environment map so backend env resolution and spawned helpers work without
/// relying on global libc process state.
pub fn setEnvironMap(environ_map: *std.process.Environ.Map) void {
    process_environ_map = environ_map;
}

const APP_ID = "com.codex.manager";
const CODEX_DIR = ".codex";
const AUTH_FILE = "auth.json";
const STORE_FILE = "accounts.json";
const BOOTSTRAP_STATE_FILE = "bootstrap-state.json";
const TOKEN_EXCHANGE_GRANT = "urn:ietf:params:oauth:grant-type:token-exchange";
const ID_TOKEN_TYPE = "urn:ietf:params:oauth:token-type:id_token";
const OAUTH_CALLBACK_LISTEN_HOST = "127.0.0.1";
const OAUTH_CALLBACK_PUBLIC_HOST = "localhost";
const OAUTH_CALLBACK_PORT: u16 = 1455;
const OAUTH_CALLBACK_BIND_RETRY_ATTEMPTS: u32 = 10;
const OAUTH_CALLBACK_BIND_RETRY_DELAY_MS: u64 = 200;
const OAUTH_CANCEL_REQUEST_TIMEOUT_MS: i64 = 2_000;
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
    theme: ?[]const u8 = null,
    label: ?[]const u8 = null,
    apiKey: ?[]const u8 = null,
    issuer: ?[]const u8 = null,
    clientId: ?[]const u8 = null,
    redirectUri: ?[]const u8 = null,
    oauthState: ?[]const u8 = null,
    codeVerifier: ?[]const u8 = null,
    url: ?[]const u8 = null,
    timeoutSeconds: ?u64 = null,
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

    // Cleans up resources owned by this value.
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

    // Cleans up resources owned by this value.
    fn deinit(self: *OAuthReadyAccount, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.accountId) |value| allocator.free(value);
        if (self.email) |value| allocator.free(value);
    }
};

const OAuthListenerState = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
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

    // Cleans up resources owned by this value.
    fn deinit(self: *OAuthPollResult, allocator: std.mem.Allocator) void {
        if (self.account) |*account| {
            account.deinit(allocator);
            self.account = null;
        }
        if (self.@"error") |err_value| {
            allocator.free(err_value);
            self.@"error" = null;
        }
    }
};

var oauth_listener_state = OAuthListenerState{};

const USAGE_FETCH_DEBOUNCE_MS: i64 = 15 * 1000;

var managed_files_mutex: std.Io.Mutex = .init;
var refresh_debounce_state: std.Io.Mutex = .init;
var refresh_debounce_entries: std.ArrayListUnmanaged(struct {
    account_id: []u8,
    inflight: bool,
    last_started_ms: i64,
}) = .empty;

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

    // Cleans up resources owned by this value.
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

    // Cleans up resources owned by this value.
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

    // Cleans up resources owned by this value.
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
    accounts: std.ArrayListUnmanaged(ManagedAccount) = .empty,

    // Cleans up resources owned by this value.
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

    // Cleans up resources owned by this value.
    fn deinit(self: *UiPreferences, allocator: std.mem.Allocator) void {
        if (self.theme) |value| allocator.free(value);
        allocator.free(self.usage_refresh_display_mode);
    }
};

const AppState = struct {
    paths: ManagedPaths,
    store: StoreState,
    preferences: UiPreferences,
    usage_by_id: std.ArrayListUnmanaged(UsageCacheEntry) = .empty,
    saved_at: i64 = 0,

    // Cleans up resources owned by this value.
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

/// Executes a backend RPC request and returns a JSON payload owned by `allocator`.
///
/// The caller is responsible for freeing the returned slice. Cancellation-sensitive flows such as
/// the OAuth callback listener use `cancel_ptr` to coordinate stop requests across threads.
pub fn handleRpcRequest(allocator: std.mem.Allocator, request: RpcRequest, cancel_ptr: *std.atomic.Value(bool)) ![]u8 {
    return rpcHandleRequest(allocator, request, cancel_ptr);
}

// Json error.
fn jsonError(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(.{ .@"error" = message }, .{})});
}

// Json ok.
fn jsonOk(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})});
}

// Json ok raw.
fn jsonOkRaw(allocator: std.mem.Allocator, raw_value: []const u8) ![]u8 {
    return allocator.dupe(u8, raw_value);
}

// Rpc handle request.
fn rpcHandleRequest(allocator: std.mem.Allocator, request: RpcRequest, cancel_ptr: *std.atomic.Value(bool)) ![]u8 {
    if (std.mem.eql(u8, request.op, "shell:open_url")) {
        const url = request.url orelse return jsonError(allocator, "open_url requires url");
        openUrl(url, allocator) catch |err| {
            return jsonError(allocator, @errorName(err));
        };
        return jsonOk(allocator, @as(?u8, null));
    }

    if (std.mem.startsWith(u8, request.op, "invoke:")) {
        const command = request.op["invoke:".len..];

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
            const timeout_seconds = request.timeoutSeconds orelse 0;
            const issuer = trimOptionalString(request.issuer) orelse return jsonError(allocator, "start_oauth_callback_listener requires issuer");
            const client_id = trimOptionalString(request.clientId) orelse return jsonError(allocator, "start_oauth_callback_listener requires clientId");
            const redirect_uri = trimOptionalString(request.redirectUri) orelse return jsonError(allocator, "start_oauth_callback_listener requires redirectUri");
            const oauth_state = trimOptionalString(request.oauthState) orelse return jsonError(allocator, "start_oauth_callback_listener requires oauthState");
            const code_verifier = trimOptionalString(request.codeVerifier);

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
            var polled = pollOAuthCallbackListener(allocator) catch |err| {
                return jsonError(allocator, @errorName(err));
            };
            defer polled.deinit(allocator);
            return jsonOk(allocator, polled);
        }

        if (std.mem.eql(u8, command, "cancel_oauth_callback_listener")) {
            cancelOAuthCallbackListener(cancel_ptr);
            cancel_ptr.store(true, .seq_cst);
            return jsonOk(allocator, true);
        }

        return jsonError(allocator, "unknown invoke command");
    }

    return jsonError(allocator, "unknown RPC op");
}

// Path exists.
fn pathExists(path: []const u8) bool {
    std.Io.Dir.accessAbsolute(process_io, path, .{}) catch return false;
    return true;
}

// Returns get env var owned compat.
fn getEnvVarOwnedCompat(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    if (process_environ_map) |environ_map| {
        if (environ_map.get(key)) |value| {
            return allocator.dupe(u8, value);
        }
    }

    if (builtin.link_libc) {
        const key_z = try allocator.dupeZ(u8, key);
        defer allocator.free(key_z);

        const value_z = std.c.getenv(key_z.ptr) orelse return error.EnvironmentVariableNotFound;
        return allocator.dupe(u8, std.mem.span(value_z));
    }

    if (builtin.os.tag == .windows or builtin.os.tag == .wasi or builtin.os.tag == .freestanding or builtin.os.tag == .other) {
        return std.process.Environ.getAlloc(.{ .block = .global }, allocator, key);
    }

    return error.EnvironmentVariableNotFound;
}

// Returns get home dir.
fn getHomeDir(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        return getEnvVarOwnedCompat(allocator, "USERPROFILE");
    }

    return getEnvVarOwnedCompat(allocator, "HOME");
}

// Returns get app local data dir.
fn getAppLocalDataDir(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        const appdata = try getEnvVarOwnedCompat(allocator, "APPDATA");
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

// Returns get managed paths.
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

// Reads read optional text file.
fn readOptionalTextFile(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    if (!pathExists(path)) {
        return null;
    }
    const text = try readTextFile(allocator, path);
    return text;
}

// Reads read text file.
fn readTextFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(process_io, path, allocator, .limited(16 * 1024 * 1024));
}

// Writes write text file atomic.
fn writeTextFileAtomic(allocator: std.mem.Allocator, path: []const u8, contents: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try std.Io.Dir.cwd().createDirPath(process_io, parent);
    }

    const temp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(temp_path);

    const temp_file = try std.Io.Dir.createFileAbsolute(process_io, temp_path, .{ .truncate = true });
    defer temp_file.close(process_io);
    try temp_file.writeStreamingAll(process_io, contents);
    try temp_file.sync(process_io);

    try std.Io.Dir.renameAbsolute(temp_path, path, process_io);
}

// Deletes a file if it exists and treats a missing path as already-clean state.
fn deleteFileIfExists(path: []const u8) !void {
    std.Io.Dir.deleteFileAbsolute(process_io, path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
}

// Now epoch seconds.
fn nowEpochSeconds() i64 {
    return @divFloor(nowMilliseconds(), 1000);
}

// Trims trim optional string.
fn trimOptionalString(value: ?[]const u8) ?[]const u8 {
    const raw = value orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \r\n\t");
    if (trimmed.len == 0) return null;
    return trimmed;
}

// Normalizes normalize auto refresh interval sec.
fn normalizeAutoRefreshIntervalSec(value: ?u64) u64 {
    const raw = value orelse AUTO_REFRESH_ACTIVE_DEFAULT_INTERVAL_SEC;
    if (raw < AUTO_REFRESH_ACTIVE_MIN_INTERVAL_SEC) return AUTO_REFRESH_ACTIVE_MIN_INTERVAL_SEC;
    if (raw > AUTO_REFRESH_ACTIVE_MAX_INTERVAL_SEC) return AUTO_REFRESH_ACTIVE_MAX_INTERVAL_SEC;
    return raw;
}

// Json get object.
fn jsonGetObject(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

// Json get array.
fn jsonGetArray(value: std.json.Value) ?std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => null,
    };
}

// Json get string.
fn jsonGetString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |s| if (std.mem.trim(u8, s, " \r\n\t").len > 0) s else null,
        else => null,
    };
}

// Json get bool.
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

// Json get f64.
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

// Json get i64.
fn jsonGetI64(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |n| n,
        .float => |n| @intFromFloat(@floor(n)),
        .string => |s| std.fmt.parseInt(i64, std.mem.trim(u8, s, " \r\n\t"), 10) catch null,
        else => null,
    };
}

// Dup maybe string.
fn dupMaybeString(allocator: std.mem.Allocator, input: ?[]const u8) !?[]u8 {
    const value = input orelse return null;
    return try allocator.dupe(u8, value);
}

// Parses parse account bucket.
fn parseAccountBucket(value: []const u8) ?AccountBucket {
    if (std.mem.eql(u8, value, "active")) return .active;
    if (std.mem.eql(u8, value, "depleted")) return .depleted;
    if (std.mem.eql(u8, value, "frozen")) return .frozen;
    return null;
}

// Credits source string.
fn creditsSourceString(value: CreditsSource) []const u8 {
    return switch (value) {
        .wham_usage => "wham_usage",
        .legacy_credit_grants => "legacy_credit_grants",
    };
}

// Credits mode string.
fn creditsModeString(value: CreditsMode) []const u8 {
    return switch (value) {
        .balance => "balance",
        .percent_fallback => "percent_fallback",
        .legacy => "legacy",
    };
}

// Credits unit string.
fn creditsUnitString(value: CreditsUnit) []const u8 {
    return switch (value) {
        .USD => "USD",
        .percent => "%",
    };
}

// Credits status string.
fn creditsStatusString(value: CreditsStatus) []const u8 {
    return switch (value) {
        .available => "available",
        .unavailable => "unavailable",
        .err => "error",
    };
}

// Writes write json string.
fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.print("{f}", .{std.json.fmt(value, .{})});
}

// Writes write json optional string.
fn writeJsonOptionalString(writer: anytype, value: ?[]const u8) !void {
    if (value) |text| {
        try writeJsonString(writer, text);
    } else {
        try writer.writeAll("null");
    }
}

// Writes write json optional i64.
fn writeJsonOptionalI64(writer: anytype, value: ?i64) !void {
    if (value) |n| {
        try writer.print("{}", .{n});
    } else {
        try writer.writeAll("null");
    }
}

// Writes write json optional f64.
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

// Writes write json bool.
fn writeJsonBool(writer: anytype, value: bool) !void {
    try writer.writeAll(if (value) "true" else "false");
}

// Sets set refresh inflight.
fn setRefreshInflight(account_id: []const u8, inflight: bool) !void {
    lockIoMutex(&refresh_debounce_state);
    defer unlockIoMutex(&refresh_debounce_state);

    const now_ms = nowMilliseconds();

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

// Determines should debounce refresh.
fn shouldDebounceRefresh(account_id: []const u8) bool {
    lockIoMutex(&refresh_debounce_state);
    defer unlockIoMutex(&refresh_debounce_state);

    const now_ms = nowMilliseconds();
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

// Checks is refresh inflight.
fn isRefreshInflight(account_id: []const u8) bool {
    lockIoMutex(&refresh_debounce_state);
    defer unlockIoMutex(&refresh_debounce_state);

    for (refresh_debounce_entries.items) |entry| {
        if (std.mem.eql(u8, entry.account_id, account_id)) {
            return entry.inflight;
        }
    }
    return false;
}

// Loads load store state.
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
            .archived = false,
            .frozen = false,
            .auth_json = auth_json,
        };
        errdefer account.deinit(allocator);

        if (account_obj.get("state")) |state_value| {
            if (jsonGetString(state_value)) |state| {
                if (std.mem.eql(u8, state, "archived")) {
                    account.archived = true;
                } else if (std.mem.eql(u8, state, "frozen")) {
                    account.frozen = true;
                }
            }
        } else {
            // One-way migration path from older persisted format.
            account.archived = if (account_obj.get("archived")) |v| jsonGetBool(v) orelse false else false;
            account.frozen = if (account_obj.get("frozen")) |v| jsonGetBool(v) orelse false else false;
        }

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

// Parses parse credits info.
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

// Loads load preferences and usage.
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

    var usage = std.ArrayListUnmanaged(UsageCacheEntry).empty;
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

// Loads load app state.
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

// Usage entry index.
fn usageEntryIndex(usage: []const UsageCacheEntry, account_id: []const u8) ?usize {
    for (usage, 0..) |entry, idx| {
        if (std.mem.eql(u8, entry.account_id, account_id)) return idx;
    }
    return null;
}

// Account index.
fn accountIndex(store: *const StoreState, account_id: []const u8) ?usize {
    for (store.accounts.items, 0..) |account, idx| {
        if (std.mem.eql(u8, account.id, account_id)) return idx;
    }
    return null;
}

// Account bucket.
fn accountBucket(account: *const ManagedAccount) AccountBucket {
    if (account.frozen) return .frozen;
    if (account.archived) return .depleted;
    return .active;
}

// Applies apply bucket.
fn applyBucket(account: *ManagedAccount, bucket: AccountBucket) void {
    account.archived = bucket == .depleted;
    account.frozen = bucket == .frozen;
}

// Account state string.
fn accountStateString(account: *const ManagedAccount) []const u8 {
    if (account.frozen) return "frozen";
    if (account.archived) return "archived";
    return "active";
}

// Sanitize store active account.
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

// Loads load codex auth json.
fn loadCodexAuthJson(allocator: std.mem.Allocator, codex_auth_path: []const u8) !?[]u8 {
    return readOptionalTextFile(allocator, codex_auth_path);
}

// Writes write codex auth path.
fn writeCodexAuthPath(allocator: std.mem.Allocator, codex_auth_path: []const u8, contents: []const u8) !void {
    try writeTextFileAtomic(allocator, codex_auth_path, contents);
}

// Extracts extract access token from auth json.
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

// Extracts extract api key from auth json.
fn extractApiKeyFromAuthJson(allocator: std.mem.Allocator, auth_json: []const u8) ?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, auth_json, .{}) catch return null;
    defer parsed.deinit();

    const root = jsonGetObject(parsed.value) orelse return null;
    const value = root.get("OPENAI_API_KEY") orelse return null;
    const api_key = jsonGetString(value) orelse return null;
    return allocator.dupe(u8, api_key) catch null;
}

// Extracts extract account id from auth json.
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

// Extracts extract email from id token.
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

// Extracts extract account id from id token.
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

// Extracts extract organization id from id token.
fn extractOrganizationIdFromIdToken(allocator: std.mem.Allocator, id_token: []const u8) ?[]u8 {
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

    if (auth.get("organizations")) |organizations_value| {
        const organizations = jsonGetArray(organizations_value) orelse return null;
        if (organizations.items.len > 0) {
            const first_org = jsonGetObject(organizations.items[0]) orelse return null;
            const org_id_value = first_org.get("id") orelse return null;
            const org_id = jsonGetString(org_id_value) orelse return null;
            return allocator.dupe(u8, org_id) catch null;
        }
    }

    if (auth.get("organization_id")) |org_id_value| {
        const org_id = jsonGetString(org_id_value) orelse return null;
        return allocator.dupe(u8, org_id) catch null;
    }

    return null;
}

// Extracts extract email from auth json.
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

// Serializes serialize store state.
fn serializeStoreState(allocator: std.mem.Allocator, store: *const StoreState) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;

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
        try writer.writeAll(",\"state\":");
        try writeJsonString(writer, accountStateString(&account));
        try writer.writeAll(",\"auth\":");
        try writer.writeAll(account.auth_json);
        try writer.writeByte('}');
    }

    try writer.writeAll("]}");
    return out.toOwnedSlice();
}

// Writes write credits info json.
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

// Builds build snapshot json.
fn buildSnapshotJson(allocator: std.mem.Allocator, state: *AppState) ![]u8 {
    try sanitizeStoreActiveAccount(allocator, &state.store);
    const view_json = try buildAccountsViewJson(allocator, state);
    defer allocator.free(view_json);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;

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

    return out.toOwnedSlice();
}

// Builds build accounts view json.
fn buildAccountsViewJson(allocator: std.mem.Allocator, state: *AppState) ![]u8 {
    try sanitizeStoreActiveAccount(allocator, &state.store);

    const current_auth = try loadCodexAuthJson(allocator, state.paths.codexAuthPath);
    defer if (current_auth) |auth| allocator.free(auth);

    const active_disk_account_id = if (current_auth) |auth| extractAccountIdFromAuthJson(allocator, auth) else null;
    defer if (active_disk_account_id) |account_id| allocator.free(account_id);

    const codex_auth_exists = current_auth != null;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;

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

    return out.toOwnedSlice();
}

// Persist state files only.
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

// Builds build refresh usage response json.
fn buildRefreshUsageResponseJson(
    allocator: std.mem.Allocator,
    account_id: []const u8,
    credits: *const CreditsInfo,
    email: ?[]const u8,
    in_flight: bool,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\"accountId\":");
    try writeJsonString(writer, account_id);
    try writer.writeAll(",\"credits\":");
    try writeCreditsInfoJson(writer, credits);
    try writer.writeAll(",\"email\":");
    try writeJsonOptionalString(writer, email);
    try writer.writeAll(",\"inFlight\":");
    try writeJsonBool(writer, in_flight);
    try writer.writeByte('}');

    return out.toOwnedSlice();
}

// Creates make credits info.
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

// Parses parse epoch seconds.
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

// Parses parse rate limit window object.
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

// Pick weekly window.
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

// Pick hourly window.
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

// Remaining from window.
fn remainingFromWindow(window: ?RateLimitWindow) ?f64 {
    if (window) |value| return @max(0.0, @min(100.0, 100.0 - value.used_percent));
    return null;
}

// Refresh from window.
fn refreshFromWindow(window: ?RateLimitWindow) ?i64 {
    if (window) |value| return value.refresh_at;
    return null;
}

// Parses parse wham credits.
fn parseWhamCredits(
    allocator: std.mem.Allocator,
    payload: std.json.ObjectMap,
    checked_at: i64,
) !CreditsInfo {
    var result = try makeCreditsInfo(allocator, checked_at, .err, "Usage endpoint returned no balance or usage data.");
    errdefer result.deinit(allocator);

    var windows = std.ArrayListUnmanaged(RateLimitWindow).empty;
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

// Appends append url encoded.
fn appendUrlEncoded(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), raw: []const u8) !void {
    for (raw) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.', '~' => try buf.append(allocator, c),
            else => {
                var hex: [3]u8 = undefined;
                _ = try std.fmt.bufPrint(&hex, "%{X:0>2}", .{c});
                try buf.appendSlice(allocator, &hex);
            },
        }
    }
}

// Appends append form field.
fn appendFormField(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), key: []const u8, value: []const u8) !void {
    if (buf.items.len > 0) try buf.append(allocator, '&');
    try appendUrlEncoded(allocator, buf, key);
    try buf.append(allocator, '=');
    try appendUrlEncoded(allocator, buf, value);
}

// Http fetch.
fn httpFetch(
    allocator: std.mem.Allocator,
    method: std.http.Method,
    uri_string: []const u8,
    headers: []const std.http.Header,
    body: ?[]const u8,
) !UsageResult {
    const uri = std.Uri.parse(uri_string) catch return .{ .status = 599, .body = try allocator.dupe(u8, "invalid uri") };

    var client = std.http.Client{
        .allocator = allocator,
        .io = process_io,
    };
    defer client.deinit();

    var req = client.request(method, uri, .{
        .headers = .{
            .user_agent = .{ .override = "codex-cli" },
            .accept_encoding = .omit,
        },
        .extra_headers = headers,
    }) catch return .{ .status = 599, .body = try allocator.dupe(u8, "http prepare fail") };
    defer req.deinit();

    return sendHttpRequest(allocator, &req, body);
}

// Http fetch without user agent.
fn httpFetchWithoutUserAgent(
    allocator: std.mem.Allocator,
    method: std.http.Method,
    uri_string: []const u8,
    headers: []const std.http.Header,
    body: ?[]const u8,
) !UsageResult {
    const uri = std.Uri.parse(uri_string) catch return .{ .status = 599, .body = try allocator.dupe(u8, "invalid uri") };

    var client = std.http.Client{
        .allocator = allocator,
        .io = process_io,
    };
    defer client.deinit();

    var req = client.request(method, uri, .{
        .headers = .{
            .accept_encoding = .omit,
        },
        .extra_headers = headers,
    }) catch return .{ .status = 599, .body = try allocator.dupe(u8, "http prepare fail") };
    defer req.deinit();

    return sendHttpRequest(allocator, &req, body);
}

// Send http request.
fn sendHttpRequest(
    allocator: std.mem.Allocator,
    req: *std.http.Client.Request,
    body: ?[]const u8,
) !UsageResult {
    if (body) |b| {
        var transfer_buf: [4096]u8 = undefined;
        req.transfer_encoding = .{ .content_length = b.len };
        var bw = req.sendBodyUnflushed(&transfer_buf) catch return .{ .status = 599, .body = try allocator.dupe(u8, "http flush fail") };
        bw.writer.writeAll(b) catch return .{ .status = 599, .body = try allocator.dupe(u8, "http write fail") };
        bw.end() catch return .{ .status = 599, .body = try allocator.dupe(u8, "http finish fail") };
        req.connection.?.flush() catch return .{ .status = 599, .body = try allocator.dupe(u8, "http socket fail") };
    } else {
        req.sendBodiless() catch return .{ .status = 599, .body = try allocator.dupe(u8, "http fetch fail") };
    }

    var redirect_buf: [2048]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return .{ .status = 599, .body = try allocator.dupe(u8, "http parse fail") };

    var transfer_buf: [8192]u8 = undefined;
    var body_reader = response.reader(&transfer_buf);

    var body_buf = std.ArrayList(u8).empty;
    defer body_buf.deinit(allocator);

    body_reader.appendRemaining(allocator, &body_buf, std.Io.Limit.unlimited) catch {};

    return .{
        .status = @intFromEnum(response.head.status),
        .body = try body_buf.toOwnedSlice(allocator),
    };
}

// Fetches fetch legacy credits from api key.
fn fetchLegacyCreditsFromApiKey(allocator: std.mem.Allocator, api_key: []const u8, checked_at: i64) !CreditsInfo {
    const endpoints = [_][]const u8{
        "https://api.openai.com/dashboard/billing/credit_grants",
        "https://api.openai.com/v1/dashboard/billing/credit_grants",
    };

    const last_error = try allocator.dupe(u8, "No usable billing payload returned.");
    defer allocator.free(last_error);

    for (endpoints) |endpoint| {
        const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
        defer allocator.free(auth_header);

        var request_headers = [_]std.http.Header{
            .{ .name = "Authorization", .value = auth_header },
        };

        const result = httpFetch(allocator, .GET, endpoint, &request_headers, null) catch continue;
        defer allocator.free(result.body);

        if (result.status < 200 or result.status >= 300) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, result.body, .{}) catch continue;
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

// Fetches fetch credits from auth json.
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

// Fetches fetch email from open ai api.
fn fetchEmailFromOpenAiApi(allocator: std.mem.Allocator, access_token: []const u8) !?[]u8 {
    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{access_token});
    defer allocator.free(auth_header);

    var request_headers = [_]std.http.Header{
        .{ .name = "Authorization", .value = auth_header },
    };

    const result = httpFetch(allocator, .GET, "https://api.openai.com/v1/me", &request_headers, null) catch return null;
    defer allocator.free(result.body);

    if (result.status < 200 or result.status >= 300) return null;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, result.body, .{}) catch return null;
    defer parsed.deinit();
    const root = jsonGetObject(parsed.value) orelse return null;
    const email_value = root.get("email") orelse return null;
    const email = jsonGetString(email_value) orelse return null;
    return try allocator.dupe(u8, email);
}

// Account matches identity.
fn accountMatchesIdentity(account: *const ManagedAccount, account_id: ?[]const u8, email: ?[]const u8) bool {
    if (account_id != null and account.account_id != null and std.mem.eql(u8, account_id.?, account.account_id.?)) return true;
    if (email != null and account.email != null and std.mem.eql(u8, email.?, account.email.?)) return true;
    return false;
}

// Generate account id.
fn generateAccountId(allocator: std.mem.Allocator) ![]u8 {
    const random_value = (std.Random.IoSource{ .io = process_io }).interface().int(u32);
    return std.fmt.allocPrint(allocator, "acct-{}-{x:0>8}", .{ nowMilliseconds(), random_value });
}

// Upsert account from auth.
fn upsertAccountFromAuth(
    allocator: std.mem.Allocator,
    store: *StoreState,
    auth_json: []const u8,
    label: ?[]const u8,
    set_active: bool,
) ![]const u8 {
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
        if (set_active) {
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
    };
    errdefer account.deinit(allocator);

    try store.accounts.append(allocator, account);
    if (set_active) {
        if (store.active_account_id) |value| allocator.free(value);
        store.active_account_id = try allocator.dupe(u8, account.id);
    }

    return store.accounts.items[store.accounts.items.len - 1].id;
}

// Sets set store active account id.
fn setStoreActiveAccountId(allocator: std.mem.Allocator, store: *StoreState, account_id: ?[]const u8) !void {
    if (store.active_account_id) |existing| {
        allocator.free(existing);
        store.active_account_id = null;
    }
    if (account_id) |value| {
        store.active_account_id = try allocator.dupe(u8, value);
    }
}

// Returns the first active fallback account that can replace a removed or archived active account.
fn nextFallbackActiveAccount(store: *StoreState, removed_id: ?[]const u8) ?*ManagedAccount {
    for (store.accounts.items) |*candidate| {
        if (removed_id != null and std.mem.eql(u8, candidate.id, removed_id.?)) continue;
        if (candidate.archived or candidate.frozen) continue;
        return candidate;
    }
    return null;
}

// Switches switch active to fallback.
fn switchActiveToFallback(allocator: std.mem.Allocator, state: *AppState, removed_id: ?[]const u8) !void {
    if (state.store.active_account_id) |active_id| {
        if (removed_id != null and !std.mem.eql(u8, active_id, removed_id.?)) {
            return;
        }
    } else {
        return;
    }

    if (nextFallbackActiveAccount(&state.store, removed_id)) |candidate| {
        try setStoreActiveAccountId(allocator, &state.store, candidate.id);
        try writeCodexAuthPath(allocator, state.paths.codexAuthPath, candidate.auth_json);
        return;
    }

    try setStoreActiveAccountId(allocator, &state.store, null);
    try deleteFileIfExists(state.paths.codexAuthPath);
}

// Handles handle switch account command.
fn handleSwitchAccountCommand(allocator: std.mem.Allocator, account_id_raw: []const u8) ![]u8 {
    const account_id = trimOptionalString(account_id_raw) orelse return jsonError(allocator, "switch_account requires accountId");

    lockIoMutex(&managed_files_mutex);
    defer unlockIoMutex(&managed_files_mutex);

    var state = try loadAppState(allocator);
    defer state.deinit(allocator);

    const idx = accountIndex(&state.store, account_id) orelse return jsonError(allocator, "Account not found.");
    const account = &state.store.accounts.items[idx];
    if (account.archived or account.frozen) {
        return jsonError(allocator, "Cannot switch to a depleted or frozen account.");
    }

    try setStoreActiveAccountId(allocator, &state.store, account.id);
    try writeCodexAuthPath(allocator, state.paths.codexAuthPath, account.auth_json);

    try persistStateFilesOnly(allocator, &state);
    const view_json = try buildAccountsViewJson(allocator, &state);
    defer allocator.free(view_json);
    return jsonOkRaw(allocator, view_json);
}

// Handles handle move account command.
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

    lockIoMutex(&managed_files_mutex);
    defer unlockIoMutex(&managed_files_mutex);

    var state = try loadAppState(allocator);
    defer state.deinit(allocator);

    const source_idx = accountIndex(&state.store, account_id) orelse return jsonError(allocator, "Account not found.");
    var moved = state.store.accounts.orderedRemove(source_idx);
    errdefer moved.deinit(allocator);

    applyBucket(&moved, target_bucket);

    if (state.store.active_account_id != null and std.mem.eql(u8, state.store.active_account_id.?, moved.id) and target_bucket != .active) {
        if (switch_away) {
            try switchActiveToFallback(allocator, &state, moved.id);
        } else {
            try setStoreActiveAccountId(allocator, &state.store, null);
            try deleteFileIfExists(state.paths.codexAuthPath);
        }
    }

    var bucket_indices = std.ArrayListUnmanaged(usize).empty;
    defer bucket_indices.deinit(allocator);
    for (state.store.accounts.items, 0..) |account, idx| {
        if (accountBucket(&account) == target_bucket) {
            try bucket_indices.append(allocator, idx);
        }
    }

    const normalized_target_index: usize = blk: {
        if (target_index <= 0) break :blk 0;
        const as_usize = std.math.cast(usize, target_index) orelse std.math.maxInt(usize);
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

// Handles handle remove account command.
fn handleRemoveAccountCommand(allocator: std.mem.Allocator, account_id_raw: []const u8) ![]u8 {
    const account_id = trimOptionalString(account_id_raw) orelse return jsonError(allocator, "remove_account requires accountId");

    lockIoMutex(&managed_files_mutex);
    defer unlockIoMutex(&managed_files_mutex);

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

// Handles handle import current account command.
fn handleImportCurrentAccountCommand(allocator: std.mem.Allocator, label_raw: ?[]const u8) ![]u8 {
    const normalized_label = trimOptionalString(label_raw);

    lockIoMutex(&managed_files_mutex);
    defer unlockIoMutex(&managed_files_mutex);

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

// Handles handle login with api key command.
fn handleLoginWithApiKeyCommand(allocator: std.mem.Allocator, api_key_raw: []const u8, label_raw: ?[]const u8) ![]u8 {
    const api_key = trimOptionalString(api_key_raw) orelse return jsonError(allocator, "login_with_api_key requires apiKey");
    const label = trimOptionalString(label_raw);

    const auth_json = try std.fmt.allocPrint(allocator, "{{\"auth_mode\":\"apikey\",\"OPENAI_API_KEY\":{f}}}", .{
        std.json.fmt(api_key, .{}),
    });
    defer allocator.free(auth_json);

    lockIoMutex(&managed_files_mutex);
    defer unlockIoMutex(&managed_files_mutex);

    var state = try loadAppState(allocator);
    defer state.deinit(allocator);

    try writeCodexAuthPath(allocator, state.paths.codexAuthPath, auth_json);
    _ = try upsertAccountFromAuth(allocator, &state.store, auth_json, label, true);

    try persistStateFilesOnly(allocator, &state);
    const view_json = try buildAccountsViewJson(allocator, &state);
    defer allocator.free(view_json);
    return jsonOkRaw(allocator, view_json);
}

// Handles handle update ui preferences command.
fn handleUpdateUiPreferencesCommand(allocator: std.mem.Allocator, request: RpcRequest) ![]u8 {
    lockIoMutex(&managed_files_mutex);
    defer unlockIoMutex(&managed_files_mutex);

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
    return jsonOk(allocator, @as(?u8, null));
}

const RefreshThreadArgs = struct {
    account_id: []const u8,
};

// Background refresh account usage.
fn backgroundRefreshAccountUsage(args: RefreshThreadArgs) void {
    const allocator = std.heap.page_allocator;
    const account_id = args.account_id;
    defer allocator.free(account_id);

    // Ensure inflight is cleared when done
    defer setRefreshInflight(account_id, false) catch {};

    var auth_json_copy: ?[]u8 = null;
    defer if (auth_json_copy) |auth| allocator.free(auth);
    var account_id_hint: ?[]u8 = null;
    defer if (account_id_hint) |value| allocator.free(value);
    var needs_email_backfill = false;
    var fetched_email: ?[]u8 = null;
    defer if (fetched_email) |email| allocator.free(email);

    lockIoMutex(&managed_files_mutex);
    {
        defer unlockIoMutex(&managed_files_mutex);
        var state = loadAppState(allocator) catch return;
        defer state.deinit(allocator);
        const idx = accountIndex(&state.store, account_id) orelse return;
        const account = state.store.accounts.items[idx];
        auth_json_copy = allocator.dupe(u8, account.auth_json) catch return;
        if (account.account_id) |value| {
            account_id_hint = allocator.dupe(u8, value) catch return;
        }
        needs_email_backfill = account.email == null;
    }

    if (needs_email_backfill) {
        const access_token = extractAccessTokenFromAuthJson(allocator, auth_json_copy.?);
        defer if (access_token) |token| allocator.free(token);
        if (access_token) |token| {
            fetched_email = fetchEmailFromOpenAiApi(allocator, token) catch null;
        }
    }

    var refreshed_credits = fetchCreditsFromAuthJson(allocator, auth_json_copy.?, account_id_hint) catch return;
    errdefer refreshed_credits.deinit(allocator);

    lockIoMutex(&managed_files_mutex);
    defer unlockIoMutex(&managed_files_mutex);

    var state = loadAppState(allocator) catch return;
    defer state.deinit(allocator);
    const account_idx = accountIndex(&state.store, account_id) orelse return;

    if (fetched_email) |email| {
        const account = &state.store.accounts.items[account_idx];
        if (account.email == null) {
            account.email = allocator.dupe(u8, email) catch return;
        }
    }

    if (usageEntryIndex(state.usage_by_id.items, account_id)) |idx| {
        var old = state.usage_by_id.items[idx];
        old.credits.deinit(allocator);
        allocator.free(old.account_id);
        state.usage_by_id.items[idx] = .{
            .account_id = allocator.dupe(u8, account_id) catch return,
            .credits = refreshed_credits,
        };
    } else {
        state.usage_by_id.append(allocator, .{
            .account_id = allocator.dupe(u8, account_id) catch return,
            .credits = refreshed_credits,
        }) catch return;
    }

    // Ownership moved into state.usage_by_id.
    refreshed_credits = undefined;

    persistStateFilesOnly(allocator, &state) catch {};
}

// Handles handle refresh account usage command.
fn handleRefreshAccountUsageCommand(allocator: std.mem.Allocator, account_id_raw: []const u8) ![]u8 {
    const account_id = trimOptionalString(account_id_raw) orelse return jsonError(allocator, "refresh_account_usage requires accountId");

    const should_debounce = shouldDebounceRefresh(account_id);
    var in_flight = isRefreshInflight(account_id);

    if (!should_debounce) {
        try setRefreshInflight(account_id, true);
        in_flight = true;
        const thread_account_id = allocator.dupe(u8, account_id) catch {
            try setRefreshInflight(account_id, false);
            return jsonError(allocator, "Internal memory error.");
        };
        const thread = std.Thread.spawn(.{}, backgroundRefreshAccountUsage, .{RefreshThreadArgs{ .account_id = thread_account_id }}) catch {
            allocator.free(thread_account_id);
            try setRefreshInflight(account_id, false);
            return jsonError(allocator, "Failed to spawn refresh thread.");
        };
        thread.detach();
    }

    lockIoMutex(&managed_files_mutex);
    defer unlockIoMutex(&managed_files_mutex);
    var state = try loadAppState(allocator);
    defer state.deinit(allocator);

    const usage_idx = usageEntryIndex(state.usage_by_id.items, account_id) orelse {
        var unavailable = try makeCreditsInfo(allocator, nowEpochSeconds(), .unavailable, "No usage data available for this account.");
        defer unavailable.deinit(allocator);
        const email = blk: {
            const idx = accountIndex(&state.store, account_id) orelse break :blk null;
            break :blk state.store.accounts.items[idx].email;
        };
        const response = try buildRefreshUsageResponseJson(allocator, account_id, &unavailable, email, in_flight);
        defer allocator.free(response);
        return jsonOkRaw(allocator, response);
    };

    const account_email = blk: {
        const idx = accountIndex(&state.store, account_id) orelse break :blk null;
        break :blk state.store.accounts.items[idx].email;
    };
    const response = try buildRefreshUsageResponseJson(
        allocator,
        account_id,
        &state.usage_by_id.items[usage_idx].credits,
        account_email,
        in_flight,
    );
    defer allocator.free(response);
    return jsonOkRaw(allocator, response);
}

// Fetches fetch wham usage.
fn fetchWhamUsage(
    allocator: std.mem.Allocator,
    access_token: []const u8,
    account_id: ?[]const u8,
) !UsageResult {
    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{access_token});
    defer allocator.free(auth_header);

    var header_list = std.ArrayList(std.http.Header).empty;
    defer header_list.deinit(allocator);

    try header_list.append(allocator, .{ .name = "Authorization", .value = auth_header });

    var account_header: ?[]u8 = null;
    defer if (account_header) |header| allocator.free(header);

    if (account_id) |id| {
        if (id.len > 0) {
            account_header = try allocator.dupe(u8, id);
            try header_list.append(allocator, .{ .name = "ChatGPT-Account-Id", .value = account_header.? });
        }
    }

    return httpFetch(allocator, .GET, "https://chatgpt.com/backend-api/wham/usage", header_list.items, null);
}

// Writes write http response.
fn writeHttpResponse(stream: std.Io.net.Stream, status: []const u8, body: []const u8) void {
    var header_buffer: [512]u8 = undefined;
    const header = std.fmt.bufPrint(
        &header_buffer,
        "HTTP/1.1 {s}\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: {}\r\n\r\n",
        .{ status, body.len },
    ) catch return;

    var writer = stream.writer(process_io, &.{});
    writer.interface.writeAll(header) catch {};
    writer.interface.writeAll(body) catch {};
}

// Extracts extract request target.
fn extractRequestTarget(request: []const u8) ?[]const u8 {
    const first_line_end = std.mem.indexOfScalar(u8, request, '\n') orelse request.len;
    const first_line = std.mem.trimEnd(u8, request[0..first_line_end], "\r");

    var parts = std.mem.tokenizeScalar(u8, first_line, ' ');
    const method = parts.next() orelse return null;
    const target = parts.next() orelse return null;

    if (!std.mem.eql(u8, method, "GET")) {
        return null;
    }

    return target;
}

// Checks is oauth callback target.
fn isOAuthCallbackTarget(target: []const u8) bool {
    if (!std.mem.startsWith(u8, target, "/auth/callback")) {
        return false;
    }
    if (target.len == "/auth/callback".len) {
        return true;
    }

    const separator = target["/auth/callback".len];
    return separator == '?' or separator == '#';
}

// Checks is oauth cancel target.
fn isOAuthCancelTarget(target: []const u8) bool {
    if (!std.mem.startsWith(u8, target, "/cancel")) {
        return false;
    }
    if (target.len == "/cancel".len) {
        return true;
    }

    const separator = target["/cancel".len];
    return separator == '?' or separator == '#';
}

// Send oauth cancel request.
fn sendOAuthCancelRequest(port: u16) !void {
    const address = try std.Io.net.IpAddress.parseIp4(OAUTH_CALLBACK_LISTEN_HOST, port);
    var stream = try address.connect(process_io, .{
        .mode = .stream,
        .timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(OAUTH_CANCEL_REQUEST_TIMEOUT_MS),
            .clock = .real,
        } },
    });
    defer stream.close(process_io);

    var host_buffer: [64]u8 = undefined;
    const host_header = try std.fmt.bufPrint(&host_buffer, "Host: {s}:{}\r\n", .{
        OAUTH_CALLBACK_LISTEN_HOST,
        port,
    });

    var writer = stream.writer(process_io, &.{});
    try writer.interface.writeAll("GET /cancel HTTP/1.1\r\n");
    try writer.interface.writeAll(host_header);
    try writer.interface.writeAll("Connection: close\r\n\r\n");

    var reader_buffer: [64]u8 = undefined;
    var reader = stream.reader(process_io, &reader_buffer);
    _ = reader.interface.readSliceShort(&reader_buffer) catch {};
}

// Bind oauth callback server.
fn bindOAuthCallbackServer(port: u16) !std.Io.net.Server {
    const address = try std.Io.net.IpAddress.parseIp4(OAUTH_CALLBACK_LISTEN_HOST, port);
    var cancel_attempted = false;
    var attempts: u32 = 0;

    while (true) {
        return address.listen(process_io, .{
            .reuse_address = true,
        }) catch |err| switch (err) {
            error.AddressInUse => {
                attempts += 1;
                if (!cancel_attempted) {
                    cancel_attempted = true;
                    sendOAuthCancelRequest(port) catch {};
                }

                if (attempts >= OAUTH_CALLBACK_BIND_RETRY_ATTEMPTS) {
                    return error.AddressInUse;
                }

                std.Io.sleep(process_io, .fromMilliseconds(OAUTH_CALLBACK_BIND_RETRY_DELAY_MS), .awake) catch {};
                continue;
            },
            else => return err,
        };
    }
}

const OAuthThreadArgs = struct {
    timeout_seconds: u64,
    external_cancel: *std.atomic.Value(bool),
    issuer: []u8,
    client_id: []u8,
    redirect_uri: []u8,
    oauth_state: []u8,
    code_verifier: ?[]u8 = null,
    label: ?[]u8 = null,

    // Initializes and returns this value.
    fn init(
        issuer: []const u8,
        client_id: []const u8,
        redirect_uri: []const u8,
        oauth_state: []const u8,
        code_verifier: ?[]const u8,
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
        const code_verifier_copy = if (code_verifier) |value|
            try std.heap.page_allocator.dupe(u8, value)
        else
            null;
        errdefer if (code_verifier_copy) |value| std.heap.page_allocator.free(value);
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

    // Cleans up resources owned by this value.
    fn deinit(self: *OAuthThreadArgs) void {
        std.heap.page_allocator.free(self.issuer);
        std.heap.page_allocator.free(self.client_id);
        std.heap.page_allocator.free(self.redirect_uri);
        std.heap.page_allocator.free(self.oauth_state);
        if (self.code_verifier) |value| {
            std.heap.page_allocator.free(value);
        }
        if (self.label) |value| {
            std.heap.page_allocator.free(value);
        }
    }
};

const OAuthTokenPair = struct {
    id_token: []u8,
    access_token: []u8,
    refresh_token: []u8,

    // Cleans up resources owned by this value.
    fn deinit(self: *OAuthTokenPair, allocator: std.mem.Allocator) void {
        allocator.free(self.id_token);
        allocator.free(self.access_token);
        allocator.free(self.refresh_token);
    }
};

const OAuthCallbackQuery = struct {
    code: ?[]u8 = null,
    state: ?[]u8 = null,
    auth_error: ?[]u8 = null,
    auth_error_description: ?[]u8 = null,

    // Cleans up resources owned by this value.
    fn deinit(self: *OAuthCallbackQuery, allocator: std.mem.Allocator) void {
        if (self.code) |value| allocator.free(value);
        if (self.state) |value| allocator.free(value);
        if (self.auth_error) |value| allocator.free(value);
        if (self.auth_error_description) |value| allocator.free(value);
    }
};

// Clears clear oauth listener result locked.
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

// Joins join oauth listener thread locked.
fn joinOAuthListenerThreadLocked() void {
    if (oauth_listener_state.thread) |thread| {
        thread.join();
        oauth_listener_state.thread = null;
    }
}

// Decodes decode hex nibble.
fn decodeHexNibble(byte: u8) ?u8 {
    if (byte >= '0' and byte <= '9') return byte - '0';
    if (byte >= 'a' and byte <= 'f') return byte - 'a' + 10;
    if (byte >= 'A' and byte <= 'F') return byte - 'A' + 10;
    return null;
}

// Decodes decode url component.
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

// Returns get decoded query param value.
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

// Parses parse oauth callback query.
fn parseOAuthCallbackQuery(allocator: std.mem.Allocator, callback_url: []const u8) !OAuthCallbackQuery {
    const query_start = std.mem.indexOfScalar(u8, callback_url, '?') orelse return error.CallbackMissingQuery;
    const query_end = std.mem.indexOfScalarPos(u8, callback_url, query_start + 1, '#') orelse callback_url.len;
    if (query_end <= query_start + 1) return error.CallbackMissingQuery;
    const query = callback_url[query_start + 1 .. query_end];

    const code = try getDecodedQueryParamValue(allocator, query, "code");
    errdefer if (code) |value| allocator.free(value);
    const oauth_state = try getDecodedQueryParamValue(allocator, query, "state");
    errdefer if (oauth_state) |value| allocator.free(value);
    const auth_error = try getDecodedQueryParamValue(allocator, query, "error");
    errdefer if (auth_error) |value| allocator.free(value);
    const auth_error_description = try getDecodedQueryParamValue(allocator, query, "error_description");
    errdefer if (auth_error_description) |value| allocator.free(value);

    if (auth_error != null and code == null) {
        return .{
            .code = null,
            .state = oauth_state,
            .auth_error = auth_error,
            .auth_error_description = auth_error_description,
        };
    }

    if (code == null) return error.CallbackMissingAuthorizationCode;
    return .{
        .code = code,
        .state = oauth_state,
        .auth_error = auth_error,
        .auth_error_description = auth_error_description,
    };
}

// Exchange authorization code for tokens.
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

    var body_buf = std.ArrayList(u8).empty;
    defer body_buf.deinit(allocator);

    try appendFormField(allocator, &body_buf, "grant_type", "authorization_code");
    try appendFormField(allocator, &body_buf, "code", code);
    try appendFormField(allocator, &body_buf, "redirect_uri", redirect_uri);
    try appendFormField(allocator, &body_buf, "client_id", client_id);
    try appendFormField(allocator, &body_buf, "code_verifier", code_verifier);

    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
    };

    const response = try httpFetchWithoutUserAgent(allocator, .POST, endpoint, &headers, body_buf.items);
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

// Exchange api key from id token.
fn exchangeApiKeyFromIdToken(
    allocator: std.mem.Allocator,
    issuer: []const u8,
    client_id: []const u8,
    id_token: []const u8,
) !?[]u8 {
    const endpoint = try std.fmt.allocPrint(allocator, "{s}/oauth/token", .{issuer});
    defer allocator.free(endpoint);

    var body_buf = std.ArrayList(u8).empty;
    defer body_buf.deinit(allocator);

    try appendFormField(allocator, &body_buf, "grant_type", TOKEN_EXCHANGE_GRANT);
    try appendFormField(allocator, &body_buf, "client_id", client_id);
    try appendFormField(allocator, &body_buf, "requested_token", "openai-api-key");
    try appendFormField(allocator, &body_buf, "subject_token", id_token);
    try appendFormField(allocator, &body_buf, "subject_token_type", ID_TOKEN_TYPE);

    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
    };

    const response = httpFetchWithoutUserAgent(allocator, .POST, endpoint, &headers, body_buf.items) catch return null;
    defer allocator.free(response.body);
    if (response.status < 200 or response.status >= 300) return null;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response.body, .{}) catch return null;
    defer parsed.deinit();
    const payload = jsonGetObject(parsed.value) orelse return null;
    const access_token = if (payload.get("access_token")) |value| jsonGetString(value) else null;
    if (access_token == null) return null;
    return try allocator.dupe(u8, access_token.?);
}

// Builds build chatgpt auth payload json.
fn buildChatgptAuthPayloadJson(
    allocator: std.mem.Allocator,
    tokens: *const OAuthTokenPair,
    api_key: ?[]const u8,
) ![]u8 {
    const account_id = extractAccountIdFromIdToken(allocator, tokens.id_token);
    defer if (account_id) |value| allocator.free(value);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\"auth_mode\":\"chatgpt\",\"tokens\":{\"id_token\":");
    try writeJsonString(writer, tokens.id_token);
    try writer.writeAll(",\"access_token\":");
    try writeJsonString(writer, tokens.access_token);
    try writer.writeAll(",\"refresh_token\":");
    try writeJsonString(writer, tokens.refresh_token);
    try writer.writeAll(",\"account_id\":");
    try writeJsonOptionalString(writer, account_id);
    try writer.writeAll("},\"last_refresh\":");

    const last_refresh = try formatIso8601UtcMillis(allocator, nowMilliseconds());
    defer allocator.free(last_refresh);
    try writeJsonString(writer, last_refresh);

    if (api_key) |value| {
        try writer.writeAll(",\"OPENAI_API_KEY\":");
        try writeJsonString(writer, value);
    }

    try writer.writeByte('}');
    return out.toOwnedSlice();
}

// Formats format iso8601 utc millis.
fn formatIso8601UtcMillis(allocator: std.mem.Allocator, timestamp_ms: i64) ![]u8 {
    const clamped_ms: i64 = if (timestamp_ms < 0) 0 else timestamp_ms;
    const seconds_since_epoch: u64 = @intCast(@divTrunc(clamped_ms, 1000));
    const millis: u16 = @intCast(@mod(clamped_ms, 1000));

    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = seconds_since_epoch };
    const epoch_day = epoch_seconds.getEpochDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
            millis,
        },
    );
}

// Complete oauth login from callback.
fn completeOAuthLoginFromCallback(allocator: std.mem.Allocator, args: *const OAuthThreadArgs, callback_url: []const u8) !OAuthReadyAccount {
    var callback_query = try parseOAuthCallbackQuery(allocator, callback_url);
    defer callback_query.deinit(allocator);

    const callback_state = callback_query.state orelse return error.OAuthStateMismatch;
    if (!std.mem.eql(u8, callback_state, args.oauth_state)) {
        return error.OAuthStateMismatch;
    }

    if (callback_query.auth_error != null) {
        return error.OAuthAuthorizationFailed;
    }

    const authorization_code = callback_query.code orelse return error.CallbackMissingAuthorizationCode;
    const code_verifier = args.code_verifier orelse return error.AuthorizationCodeExchangeFailed;
    var tokens = try exchangeAuthorizationCodeForTokens(
        allocator,
        args.issuer,
        args.client_id,
        args.redirect_uri,
        authorization_code,
        code_verifier,
    );
    defer tokens.deinit(allocator);

    const api_key = try exchangeApiKeyFromIdToken(
        allocator,
        args.issuer,
        args.client_id,
        tokens.id_token,
    );
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

    lockIoMutex(&managed_files_mutex);
    defer unlockIoMutex(&managed_files_mutex);

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

// Start oauth callback listener.
fn startOAuthCallbackListener(
    timeout_seconds: u64,
    external_cancel: *std.atomic.Value(bool),
    issuer: []const u8,
    client_id: []const u8,
    redirect_uri: []const u8,
    oauth_state: []const u8,
    code_verifier: ?[]const u8,
    label: ?[]const u8,
) !void {
    lockIoMutex(&oauth_listener_state.mutex);
    defer unlockIoMutex(&oauth_listener_state.mutex);

    if (oauth_listener_state.running) {
        return error.CallbackListenerAlreadyRunning;
    }

    joinOAuthListenerThreadLocked();
    clearOAuthListenerResultLocked();

    oauth_listener_state.cancel.store(false, .seq_cst);
    external_cancel.store(false, .seq_cst);
    oauth_listener_state.running = true;
    std.debug.print("OAuth callback listener URL: {s}\n", .{redirect_uri});

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

// Polls poll oauth callback listener.
fn pollOAuthCallbackListener(allocator: std.mem.Allocator) !OAuthPollResult {
    lockIoMutex(&oauth_listener_state.mutex);
    defer unlockIoMutex(&oauth_listener_state.mutex);

    if (oauth_listener_state.running) {
        return .{ .status = "running" };
    }
    joinOAuthListenerThreadLocked();

    if (oauth_listener_state.ready_account) |account| {
        const id_copy = try allocator.dupe(u8, account.id);
        errdefer allocator.free(id_copy);
        const account_id_copy = if (account.accountId) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (account_id_copy) |value| allocator.free(value);
        const email_copy = if (account.email) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (email_copy) |value| allocator.free(value);

        return .{
            .status = "ready",
            .account = .{
                .id = id_copy,
                .accountId = account_id_copy,
                .email = email_copy,
                .state = account.state,
            },
        };
    }

    if (oauth_listener_state.error_name) |err_name| {
        return .{
            .status = "error",
            .@"error" = try allocator.dupe(u8, err_name),
        };
    }

    return .{ .status = "idle" };
}

// Cancel oauth callback listener.
fn cancelOAuthCallbackListener(external_cancel: *std.atomic.Value(bool)) void {
    oauth_listener_state.cancel.store(true, .seq_cst);
    external_cancel.store(true, .seq_cst);
}

// Oauth callback thread main.
fn oauthCallbackThreadMain(args: OAuthThreadArgs) void {
    var owned_args = args;
    defer owned_args.deinit();

    const callback_url = waitForOAuthCallback(
        std.heap.page_allocator,
        owned_args.timeout_seconds,
        &oauth_listener_state.cancel,
    ) catch |err| {
        lockIoMutex(&oauth_listener_state.mutex);
        clearOAuthListenerResultLocked();
        oauth_listener_state.error_name = std.heap.page_allocator.dupe(u8, @errorName(err)) catch null;
        oauth_listener_state.running = false;
        broadcastIoCondition(&oauth_listener_state.cond);
        unlockIoMutex(&oauth_listener_state.mutex);
        owned_args.external_cancel.store(false, .seq_cst);
        return;
    };

    const oauth_account = completeOAuthLoginFromCallback(std.heap.page_allocator, &owned_args, callback_url) catch |err| {
        std.heap.page_allocator.free(callback_url);
        lockIoMutex(&oauth_listener_state.mutex);
        clearOAuthListenerResultLocked();
        oauth_listener_state.error_name = std.heap.page_allocator.dupe(u8, @errorName(err)) catch null;
        oauth_listener_state.running = false;
        broadcastIoCondition(&oauth_listener_state.cond);
        unlockIoMutex(&oauth_listener_state.mutex);
        owned_args.external_cancel.store(false, .seq_cst);
        return;
    };

    lockIoMutex(&oauth_listener_state.mutex);
    clearOAuthListenerResultLocked();
    oauth_listener_state.callback_url = callback_url;
    oauth_listener_state.ready_account = oauth_account;
    oauth_listener_state.running = false;
    broadcastIoCondition(&oauth_listener_state.cond);
    unlockIoMutex(&oauth_listener_state.mutex);

    owned_args.external_cancel.store(false, .seq_cst);
}

// Wait for oauth callback.
fn waitForOAuthCallback(
    allocator: std.mem.Allocator,
    timeout_seconds: u64,
    cancel_ptr: *std.atomic.Value(bool),
) ![]u8 {
    cancel_ptr.store(false, .seq_cst);

    var server = try bindOAuthCallbackServer(OAUTH_CALLBACK_PORT);
    defer server.deinit(process_io);

    const deadline_ms: ?i64 = if (timeout_seconds == 0) null else blk: {
        const timeout_ms_total_u64 = timeout_seconds * 1000;
        const timeout_ms_total_i64 = std.math.cast(i64, timeout_ms_total_u64) orelse std.math.maxInt(i64);
        break :blk nowMilliseconds() + timeout_ms_total_i64;
    };

    accept_loop: while (true) {
        if (cancel_ptr.load(.seq_cst)) {
            return error.CallbackListenerStopped;
        }

        const accept_timeout_ms = computePollTimeoutMs(deadline_ms);
        if (accept_timeout_ms < 0) {
            return error.CallbackListenerTimeout;
        }

        const accept_poll = try pollSocketReadable(server.socket.handle, accept_timeout_ms);
        if (!accept_poll.ready) {
            continue;
        }

        if (socketPollHasError(accept_poll.revents)) {
            return error.CallbackListenerSocketError;
        }

        const connection = server.accept(process_io) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };

        var conn = connection;
        defer conn.close(process_io);
        var conn_reader = conn.reader(process_io, &.{});

        var request_buffer = std.ArrayList(u8).empty;
        defer request_buffer.deinit(allocator);
        var chunk: [4096]u8 = undefined;
        while (true) {
            if (cancel_ptr.load(.seq_cst)) {
                return error.CallbackListenerStopped;
            }

            const read_timeout_ms = computePollTimeoutMs(deadline_ms);
            if (read_timeout_ms < 0) {
                return error.CallbackListenerTimeout;
            }

            const read_poll = try pollSocketReadable(conn.socket.handle, read_timeout_ms);
            if (!read_poll.ready) {
                continue;
            }

            if (socketPollHasDisconnect(read_poll.revents)) {
                continue :accept_loop;
            }

            const read_size = conn_reader.interface.readSliceShort(&chunk) catch continue :accept_loop;
            if (read_size == 0) {
                continue :accept_loop;
            }

            try request_buffer.appendSlice(allocator, chunk[0..read_size]);
            if (request_buffer.items.len > 64 * 1024) {
                writeHttpResponse(conn, "413 Payload Too Large", "<html><body>Callback request too large.</body></html>");
                continue :accept_loop;
            }

            if (std.mem.indexOfScalar(u8, request_buffer.items, '\n') == null) {
                continue;
            }

            const maybe_target = extractRequestTarget(request_buffer.items);

            if (maybe_target) |target| {
                if (isOAuthCancelTarget(target)) {
                    writeHttpResponse(conn, "200 OK", "<html><body>Login cancelled</body></html>");
                    return error.CallbackListenerStopped;
                }

                if (isOAuthCallbackTarget(target)) {
                    writeHttpResponse(conn, "200 OK", OAUTH_CALLBACK_SUCCESS_HTML);
                    return std.fmt.allocPrint(allocator, "http://{s}:{}{s}", .{
                        OAUTH_CALLBACK_PUBLIC_HOST,
                        OAUTH_CALLBACK_PORT,
                        target,
                    });
                }

                writeHttpResponse(conn, "404 Not Found", "<html><body>Not Found</body></html>");
                continue :accept_loop;
            }

            writeHttpResponse(conn, "400 Bad Request", "<html><body>Invalid callback request.</body></html>");
            continue :accept_loop;
        }
    }
}

const SocketPollResult = struct {
    ready: bool,
    revents: i16,
};

// Polls poll socket readable.
fn pollSocketReadable(socket: std.posix.socket_t, timeout_ms: i32) !SocketPollResult {
    if (builtin.os.tag == .windows) {
        return .{
            .ready = true,
            .revents = 0,
        };
    }

    var fds = [_]std.posix.pollfd{
        .{
            .fd = socket,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };
    const rc = try std.posix.poll(&fds, timeout_ms);
    return .{
        .ready = rc != 0,
        .revents = fds[0].revents,
    };
}

// Socket poll has error.
fn socketPollHasError(revents: i16) bool {
    if (builtin.os.tag == .windows) {
        return false;
    }

    const err_mask: i16 = std.posix.POLL.ERR | std.posix.POLL.NVAL;
    return (revents & err_mask) != 0;
}

// Socket poll has disconnect.
fn socketPollHasDisconnect(revents: i16) bool {
    if (builtin.os.tag == .windows) {
        return false;
    }

    const err_mask: i16 = std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL;
    return (revents & err_mask) != 0;
}

// Computes compute poll timeout ms.
fn computePollTimeoutMs(deadline_ms: ?i64) i32 {
    if (deadline_ms == null) {
        return 250;
    }

    const deadline = deadline_ms.?;
    const now = nowMilliseconds();
    if (now >= deadline) {
        return -1;
    }

    const remaining = deadline - now;
    const slice_ms: i64 = 250;
    const next = @min(remaining, slice_ms);
    return @intCast(next);
}

/// Opens `url` with the platform launcher and returns an error only when every known launcher path
/// fails.
///
/// The environment captured at startup is propagated to child launcher processes so GUI-session
/// context such as desktop bus variables remains available in no-libc builds.
pub fn openUrl(url: []const u8, allocator: std.mem.Allocator) !void {
    _ = allocator;

    switch (builtin.os.tag) {
        .windows => {
            if (try runOpenUrlCommand(&.{ "rundll32", "url.dll,FileProtocolHandler", url })) return;
            return error.OpenUrlFailed;
        },
        .macos => {
            if (try runOpenUrlCommand(&.{ "/usr/bin/open", url })) return;
            if (try runOpenUrlCommand(&.{ "open", url })) return;
            return error.OpenUrlFailed;
        },
        else => {
            // Prefer absolute paths first to avoid PATH scanning failures being
            // reported as misleading spawn errors.
            if (try runOpenUrlCommand(&.{ "/usr/bin/xdg-open", url })) return;
            if (try runOpenUrlCommand(&.{ "/bin/xdg-open", url })) return;
            if (try runOpenUrlCommand(&.{ "/usr/bin/gio", "open", url })) return;
            if (try runOpenUrlCommand(&.{ "/bin/gio", "open", url })) return;
            if (try runOpenUrlCommand(&.{ "xdg-open", url })) return;
            if (try runOpenUrlCommand(&.{ "gio", "open", url })) return;
            if (try runOpenUrlCommand(&.{ "sensible-browser", url })) return;
            return error.OpenUrlFailed;
        },
    }
}

// Runs run open url command.
fn runOpenUrlCommand(argv: []const []const u8) !bool {
    var child = std.process.spawn(process_io, .{
        .argv = argv,
        .environ_map = openUrlChildEnvironMap(),
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        if (isOpenUrlLauncherUnavailableError(err)) return false;
        return err;
    };

    const term = child.wait(process_io) catch |err| switch (err) {
        error.AccessDenied => return false,
        else => return err,
    };

    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

// Opens open url child environ map.
fn openUrlChildEnvironMap() ?*const std.process.Environ.Map {
    if (process_environ_map) |environ_map| {
        return environ_map;
    }

    return null;
}

// Checks is open url launcher unavailable error.
fn isOpenUrlLauncherUnavailableError(err: anyerror) bool {
    return switch (err) {
        error.FileNotFound,
        error.InvalidExe,
        error.AccessDenied,
        error.PermissionDenied,
        error.OutOfMemory,
        error.SystemResources,
        error.NameTooLong,
        error.InvalidWtf8,
        error.InvalidBatchScriptArg,
        => true,
        else => false,
    };
}

// Expect rpc error contains.
fn expectRpcErrorContains(response: []const u8, needle: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), response, .{});
    const root = parsed.object;

    const error_value = root.get("error") orelse return error.MissingErrorField;
    try std.testing.expect(error_value == .string);
    try std.testing.expect(std.mem.containsAtLeast(u8, error_value.string, 1, needle));
}

test "rpcHandleRequest returns unknown op error for unsupported operation" {
    var cancel = std.atomic.Value(bool).init(false);
    const response = try rpcHandleRequest(
        std.testing.allocator,
        .{
            .op = "noop",
        },
        &cancel,
    );
    defer std.testing.allocator.free(response);

    try expectRpcErrorContains(response, "unknown RPC op");
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
    try std.testing.expect(parsed == .bool);
    try std.testing.expect(parsed.bool);
    try std.testing.expect(cancel.load(.seq_cst));
}

test "openUrl uses configured environ map for launcher child process" {
    const previous = process_environ_map;
    defer process_environ_map = previous;

    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();

    process_environ_map = &map;
    try std.testing.expect(openUrlChildEnvironMap() != null);
    try std.testing.expect(openUrlChildEnvironMap().? == &map);
}

test "openUrl child environ map is null when no environ map configured" {
    const previous = process_environ_map;
    defer process_environ_map = previous;

    process_environ_map = null;
    try std.testing.expect(openUrlChildEnvironMap() == null);
}

test "isOpenUrlLauncherUnavailableError treats misleading launcher failures as recoverable" {
    try std.testing.expect(isOpenUrlLauncherUnavailableError(error.OutOfMemory));
    try std.testing.expect(isOpenUrlLauncherUnavailableError(error.FileNotFound));
    try std.testing.expect(isOpenUrlLauncherUnavailableError(error.SystemResources));
}

test "isOpenUrlLauncherUnavailableError does not hide unrelated errors" {
    try std.testing.expect(!isOpenUrlLauncherUnavailableError(error.CallbackListenerTimeout));
}

test "nextFallbackActiveAccount skips removed archived and frozen accounts" {
    var accounts = [_]ManagedAccount{
        .{
            .id = @constCast("acct-1"),
            .archived = false,
            .frozen = false,
            .auth_json = @constCast("{}"),
        },
        .{
            .id = @constCast("acct-2"),
            .archived = true,
            .frozen = false,
            .auth_json = @constCast("{}"),
        },
        .{
            .id = @constCast("acct-3"),
            .archived = false,
            .frozen = false,
            .auth_json = @constCast("{}"),
        },
    };
    var store = StoreState{
        .accounts = .{
            .items = accounts[0..],
            .capacity = accounts.len,
        },
    };

    const fallback = nextFallbackActiveAccount(&store, "acct-1") orelse return error.ExpectedFallbackAccount;
    try std.testing.expectEqualStrings("acct-3", fallback.id);
}

test "nextFallbackActiveAccount returns null when no active replacement exists" {
    var accounts = [_]ManagedAccount{
        .{
            .id = @constCast("acct-1"),
            .archived = true,
            .frozen = false,
            .auth_json = @constCast("{}"),
        },
        .{
            .id = @constCast("acct-2"),
            .archived = false,
            .frozen = true,
            .auth_json = @constCast("{}"),
        },
    };
    var store = StoreState{
        .accounts = .{
            .items = accounts[0..],
            .capacity = accounts.len,
        },
    };

    try std.testing.expect(nextFallbackActiveAccount(&store, "acct-1") == null);
}

test "computePollTimeoutMs returns polling slice when timeout is disabled" {
    const timeout_ms = computePollTimeoutMs(null);
    try std.testing.expect(timeout_ms > 0);
    try std.testing.expect(timeout_ms <= 250);
}

test "computePollTimeoutMs returns timeout when deadline passed" {
    const timeout_ms = computePollTimeoutMs(nowMilliseconds() - 1);
    try std.testing.expectEqual(@as(i32, -1), timeout_ms);
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

test "isOAuthCallbackTarget matches only exact callback path" {
    try std.testing.expect(isOAuthCallbackTarget("/auth/callback"));
    try std.testing.expect(isOAuthCallbackTarget("/auth/callback?code=test&state=abc"));
    try std.testing.expect(!isOAuthCallbackTarget("/auth/callbackx?code=test&state=abc"));
}

test "isOAuthCancelTarget matches only exact cancel path" {
    try std.testing.expect(isOAuthCancelTarget("/cancel"));
    try std.testing.expect(isOAuthCancelTarget("/cancel?source=retry"));
    try std.testing.expect(!isOAuthCancelTarget("/cancelled"));
    try std.testing.expect(!isOAuthCancelTarget("/auth/cancel"));
}

test "oauth callback listener constants match upstream codex flow" {
    try std.testing.expectEqualStrings("127.0.0.1", OAUTH_CALLBACK_LISTEN_HOST);
    try std.testing.expectEqualStrings("localhost", OAUTH_CALLBACK_PUBLIC_HOST);
    try std.testing.expectEqual(@as(u16, 1455), OAUTH_CALLBACK_PORT);
}

test "parseOAuthCallbackQuery accepts oauth error callback with state" {
    var parsed = try parseOAuthCallbackQuery(
        std.testing.allocator,
        "http://localhost:1455/auth/callback?state=xyz&error=access_denied&error_description=missing_codex_entitlement",
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expect(parsed.code == null);
    try std.testing.expect(parsed.state != null);
    try std.testing.expectEqualStrings("xyz", parsed.state.?);
    try std.testing.expect(parsed.auth_error != null);
    try std.testing.expectEqualStrings("access_denied", parsed.auth_error.?);
    try std.testing.expect(parsed.auth_error_description != null);
    try std.testing.expectEqualStrings("missing_codex_entitlement", parsed.auth_error_description.?);
}

test "parseOAuthCallbackQuery accepts authorization code callback" {
    var parsed = try parseOAuthCallbackQuery(
        std.testing.allocator,
        "http://localhost:1455/auth/callback?code=abc123&state=xyz",
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expect(parsed.code != null);
    try std.testing.expectEqualStrings("abc123", parsed.code.?);
    try std.testing.expect(parsed.state != null);
    try std.testing.expectEqualStrings("xyz", parsed.state.?);
    try std.testing.expect(parsed.auth_error == null);
}

test "formatIso8601UtcMillis renders UTC timestamp with milliseconds" {
    const formatted = try formatIso8601UtcMillis(std.testing.allocator, 0);
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00.000Z", formatted);
}

test "json utilities" {
    try std.testing.expectEqual(true, jsonGetBool(.{ .bool = true }) orelse false);
    try std.testing.expectEqual(true, jsonGetBool(.{ .integer = 1 }) orelse false);
    try std.testing.expectEqual(false, jsonGetBool(.{ .integer = 0 }) orelse true);
    try std.testing.expectEqual(true, jsonGetBool(.{ .string = "true" }) orelse false);
    try std.testing.expectEqual(false, jsonGetBool(.{ .string = "0" }) orelse true);
    try std.testing.expectEqual(@as(?bool, null), jsonGetBool(.{ .integer = 2 }));

    try std.testing.expectEqual(@as(?f64, 1.5), jsonGetF64(.{ .float = 1.5 }));
    try std.testing.expectEqual(@as(?f64, 2.0), jsonGetF64(.{ .integer = 2 }));
    try std.testing.expectEqual(@as(?f64, 3.14), jsonGetF64(.{ .string = "3.14" }));

    try std.testing.expectEqual(@as(?i64, 42), jsonGetI64(.{ .integer = 42 }));
    try std.testing.expectEqual(@as(?i64, 42), jsonGetI64(.{ .float = 42.9 }));
    try std.testing.expectEqual(@as(?i64, 42), jsonGetI64(.{ .string = "42" }));
}

test "trimOptionalString trims whitespace" {
    try std.testing.expectEqualStrings("test", trimOptionalString(" test ") orelse return error.Fail);
    try std.testing.expectEqual(@as(?[]const u8, null), trimOptionalString("   "));
    try std.testing.expectEqual(@as(?[]const u8, null), trimOptionalString(null));
}

test "parseAccountBucket returns correct buckets" {
    try std.testing.expectEqual(AccountBucket.active, parseAccountBucket("active"));
    try std.testing.expectEqual(AccountBucket.depleted, parseAccountBucket("depleted"));
    try std.testing.expectEqual(AccountBucket.frozen, parseAccountBucket("frozen"));
    try std.testing.expectEqual(@as(?AccountBucket, null), parseAccountBucket("unknown"));
}

test "normalizeAutoRefreshIntervalSec applies bounds" {
    try std.testing.expectEqual(@as(u64, 300), normalizeAutoRefreshIntervalSec(null));
    try std.testing.expectEqual(@as(u64, 15), normalizeAutoRefreshIntervalSec(10));
    try std.testing.expectEqual(@as(u64, 21600), normalizeAutoRefreshIntervalSec(21601));
    try std.testing.expectEqual(@as(u64, 60), normalizeAutoRefreshIntervalSec(60));
}
