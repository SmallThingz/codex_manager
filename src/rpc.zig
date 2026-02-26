const std = @import("std");
const builtin = @import("builtin");

const APP_ID = "com.codex.manager";
const CODEX_DIR = ".codex";
const AUTH_FILE = "auth.json";
const STORE_FILE = "accounts.json";
const BOOTSTRAP_STATE_FILE = "bootstrap-state.json";
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
    url: ?[]const u8 = null,
    recursive: ?bool = null,
    timeoutSeconds: ?u64 = null,
    accessToken: ?[]const u8 = null,
    accountId: ?[]const u8 = null,
};

const UsageResult = struct {
    status: u16,
    body: []const u8,
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

const OAuthListenerState = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    thread: ?std.Thread = null,
    running: bool = false,
    callback_url: ?[]u8 = null,
    error_name: ?[]u8 = null,
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

const OAuthPollResult = struct {
    status: []const u8,
    callbackUrl: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

var oauth_listener_state = OAuthListenerState{};

pub fn handleRpcText(allocator: std.mem.Allocator, request_text: []const u8, cancel_ptr: *std.atomic.Value(bool)) ![]u8 {
    return rpcFromText(allocator, request_text, cancel_ptr);
}

fn jsonError(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(.{ .ok = false, .@"error" = message }, .{})});
}

fn jsonOk(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(.{ .ok = true, .value = value }, .{})});
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

        if (std.mem.eql(u8, command, "get_managed_paths")) {
            var managed_paths = getManagedPaths(allocator) catch |err| {
                return jsonError(allocator, @errorName(err));
            };
            defer managed_paths.deinit(allocator);

            return jsonOk(allocator, .{
                .codexHome = managed_paths.codexHome,
                .codexAuthPath = managed_paths.codexAuthPath,
                .storeDir = managed_paths.storeDir,
                .storePath = managed_paths.storePath,
                .bootstrapStatePath = managed_paths.bootstrapStatePath,
            });
        }

        if (std.mem.eql(u8, command, "read_managed_store")) {
            const raw = readManagedStore(allocator) catch |err| {
                return jsonError(allocator, @errorName(err));
            };
            defer if (raw) |text| allocator.free(text);
            return jsonOk(allocator, raw);
        }

        if (std.mem.eql(u8, command, "write_managed_store")) {
            const contents = request.contents orelse return jsonError(allocator, "write_managed_store requires contents");
            writeManagedStore(contents, allocator) catch |err| {
                return jsonError(allocator, @errorName(err));
            };
            return jsonOk(allocator, @as(?u8, null));
        }

        if (std.mem.eql(u8, command, "read_codex_auth")) {
            const raw = readCodexAuth(allocator) catch |err| {
                return jsonError(allocator, @errorName(err));
            };
            defer if (raw) |text| allocator.free(text);
            return jsonOk(allocator, raw);
        }

        if (std.mem.eql(u8, command, "write_codex_auth")) {
            const contents = request.contents orelse return jsonError(allocator, "write_codex_auth requires contents");
            writeCodexAuth(contents, allocator) catch |err| {
                return jsonError(allocator, @errorName(err));
            };
            return jsonOk(allocator, @as(?u8, null));
        }

        if (std.mem.eql(u8, command, "read_bootstrap_state")) {
            const raw = readBootstrapState(allocator) catch |err| {
                return jsonError(allocator, @errorName(err));
            };
            defer if (raw) |text| allocator.free(text);
            return jsonOk(allocator, raw);
        }

        if (std.mem.eql(u8, command, "write_bootstrap_state")) {
            const contents = request.contents orelse return jsonError(allocator, "write_bootstrap_state requires contents");
            writeBootstrapState(contents, allocator) catch |err| {
                return jsonError(allocator, @errorName(err));
            };
            return jsonOk(allocator, @as(?u8, null));
        }

        if (std.mem.eql(u8, command, "start_oauth_callback_listener")) {
            const timeout_seconds = request.timeoutSeconds orelse 180;
            startOAuthCallbackListener(timeout_seconds, cancel_ptr) catch |err| {
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
            startOAuthCallbackListener(timeout_seconds, cancel_ptr) catch |err| {
                if (err != error.CallbackListenerAlreadyRunning) {
                    return jsonError(allocator, @errorName(err));
                }
            };

            const callback_url = waitForOAuthCallbackResult(allocator) catch |err| {
                return jsonError(allocator, @errorName(err));
            };
            defer allocator.free(callback_url);
            return jsonOk(allocator, callback_url);
        }

        if (std.mem.eql(u8, command, "cancel_oauth_callback_listener")) {
            cancelOAuthCallbackListener(cancel_ptr);
            cancel_ptr.store(true, .seq_cst);
            return jsonOk(allocator, true);
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
};

fn clearOAuthListenerResultLocked() void {
    if (oauth_listener_state.callback_url) |url| {
        std.heap.page_allocator.free(url);
        oauth_listener_state.callback_url = null;
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

fn startOAuthCallbackListener(timeout_seconds: u64, external_cancel: *std.atomic.Value(bool)) !void {
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

    const args = OAuthThreadArgs{
        .timeout_seconds = timeout_seconds,
        .external_cancel = external_cancel,
    };

    oauth_listener_state.thread = std.Thread.spawn(.{}, oauthCallbackThreadMain, .{args}) catch |err| {
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

    if (oauth_listener_state.callback_url) |url| {
        return .{
            .status = "ready",
            .callbackUrl = url,
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

fn cancelOAuthCallbackListener(external_cancel: *std.atomic.Value(bool)) void {
    oauth_listener_state.cancel.store(true, .seq_cst);
    external_cancel.store(true, .seq_cst);
}

fn oauthCallbackThreadMain(args: OAuthThreadArgs) void {
    const callback_url = waitForOAuthCallback(
        std.heap.page_allocator,
        args.timeout_seconds,
        &oauth_listener_state.cancel,
    ) catch |err| {
        oauth_listener_state.mutex.lock();
        clearOAuthListenerResultLocked();
        oauth_listener_state.error_name = std.heap.page_allocator.dupe(u8, @errorName(err)) catch null;
        oauth_listener_state.running = false;
        oauth_listener_state.cond.broadcast();
        oauth_listener_state.mutex.unlock();
        args.external_cancel.store(false, .seq_cst);
        return;
    };

    oauth_listener_state.mutex.lock();
    clearOAuthListenerResultLocked();
    oauth_listener_state.callback_url = callback_url;
    oauth_listener_state.running = false;
    oauth_listener_state.cond.broadcast();
    oauth_listener_state.mutex.unlock();

    args.external_cancel.store(false, .seq_cst);
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
