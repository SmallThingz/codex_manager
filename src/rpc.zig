const std = @import("std");
const builtin = @import("builtin");
const webui = @import("webui");

const APP_ID = "com.codex.manager";

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

pub fn handleRpcEvent(e: *webui.Event, allocator: std.mem.Allocator, cancel_ptr: *std.atomic.Value(bool)) void {
    const response = rpcFromText(allocator, e.getString(), cancel_ptr) catch {
        sendError(e, allocator, "internal RPC failure");
        return;
    };
    defer allocator.free(response);
    returnJsonToEvent(e, allocator, response);
}

fn jsonError(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(.{ .ok = false, .@"error" = message }, .{})});
}

fn jsonOk(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(.{ .ok = true, .value = value }, .{})});
}

fn returnJsonToEvent(e: *webui.Event, allocator: std.mem.Allocator, json_text: []const u8) void {
    const json_z = allocator.dupeZ(u8, json_text) catch {
        e.returnString("{\"ok\":false,\"error\":\"internal allocation error\"}");
        return;
    };
    defer allocator.free(json_z);

    e.returnString(json_z);
}

fn sendError(e: *webui.Event, allocator: std.mem.Allocator, message: []const u8) void {
    const json = jsonError(allocator, message) catch {
        e.returnString("{\"ok\":false,\"error\":\"internal serialization error\"}");
        return;
    };
    defer allocator.free(json);
    returnJsonToEvent(e, allocator, json);
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
        const url_z = allocator.dupeZ(u8, url) catch |err| {
            return jsonError(allocator, @errorName(err));
        };
        defer allocator.free(url_z);

        webui.openUrl(url_z);
        return jsonOk(allocator, @as(?u8, null));
    }

    if (std.mem.startsWith(u8, request.op, "invoke:")) {
        const command = request.op["invoke:".len..];

        if (std.mem.eql(u8, command, "wait_for_oauth_callback")) {
            const timeout_seconds = request.timeoutSeconds orelse 180;
            const callback_url = waitForOAuthCallback(allocator, timeout_seconds, cancel_ptr) catch |err| {
                return jsonError(allocator, @errorName(err));
            };
            defer allocator.free(callback_url);
            return jsonOk(allocator, callback_url);
        }

        if (std.mem.eql(u8, command, "cancel_oauth_callback_listener")) {
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

    var remaining_ms: i64 = @intCast(timeout_seconds * 1000);

    accept_loop: while (remaining_ms > 0) {
        if (cancel_ptr.load(.seq_cst)) {
            return error.CallbackListenerStopped;
        }

        const connection = server.accept() catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(100 * std.time.ns_per_ms);
                remaining_ms -= 100;
                continue;
            },
            else => return err,
        };

        var conn = connection;
        defer conn.stream.close();

        var buffer: [8192]u8 = undefined;
        while (remaining_ms > 0) {
            if (cancel_ptr.load(.seq_cst)) {
                return error.CallbackListenerStopped;
            }

            const read_size = conn.stream.read(&buffer) catch |err| switch (err) {
                error.WouldBlock => {
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    remaining_ms -= 10;
                    continue;
                },
                else => continue :accept_loop,
            };
            if (read_size == 0) {
                continue :accept_loop;
            }

            const request = buffer[0..read_size];
            const maybe_target = extractRequestTarget(request);

            if (maybe_target) |target| {
                if (std.mem.startsWith(u8, target, "/auth/callback")) {
                    writeHttpResponse(conn.stream, "200 OK", "<html><body><h3>Login completed. You can return to Codex Account Manager.</h3></body></html>");
                    return std.fmt.allocPrint(allocator, "http://localhost:1455{s}", .{target});
                }

                writeHttpResponse(conn.stream, "404 Not Found", "<html><body>Not Found</body></html>");
                continue :accept_loop;
            }

            writeHttpResponse(conn.stream, "400 Bad Request", "<html><body>Invalid callback request.</body></html>");
            continue :accept_loop;
        }
    }

    return error.CallbackListenerTimeout;
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
