const std = @import("std");
const builtin = @import("builtin");

const assets = @import("assets.zig");
const rpc = @import("rpc.zig");

const APP_ID = "com.codex.manager";
const BOOTSTRAP_STATE_FILE = "bootstrap-state.json";
const BOOTSTRAP_PLACEHOLDER = "REPLACE_THIS_VARIABLE_WHEN_SENDING";
const DEFAULT_BOOTSTRAP_STATE_JSON =
    \\{"theme":null,"view":null,"usageById":{},"savedAt":0}
;

const IndexTemplate = struct {
    prefix: []const u8,
    suffix: []const u8,
};

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var oauth_listener_cancel = std.atomic.Value(bool).init(false);
var web_index_template: ?IndexTemplate = null;

pub fn main() !void {
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            @panic("memory leak detected");
        }
    }

    const allocator = gpa.allocator();
    initIndexTemplate();

    var server = try startServer();
    defer server.deinit();

    const port = server.listen_address.getPort();
    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/index.html", .{port});
    defer allocator.free(url);

    std.debug.print("Codex Manager URL: {s}\n", .{url});
    rpc.openUrl(url, allocator) catch |err| {
        std.debug.print("Could not auto-open browser ({s}). Open this URL manually: {s}\n", .{ @errorName(err), url });
    };

    while (true) {
        const connection = server.accept() catch |err| {
            std.debug.print("HTTP accept failed: {s}\n", .{@errorName(err)});
            continue;
        };
        var conn = connection;
        defer conn.stream.close();
        handleConnection(conn.stream, allocator);
    }
}

fn startServer() !std.net.Server {
    const preferred = try std.net.Address.parseIp4("127.0.0.1", 14555);
    return preferred.listen(.{
        .reuse_address = true,
    }) catch |err| switch (err) {
        error.AddressInUse => blk: {
            const random_addr = try std.net.Address.parseIp4("127.0.0.1", 0);
            break :blk try random_addr.listen(.{ .reuse_address = true });
        },
        else => err,
    };
}

fn initIndexTemplate() void {
    if (assets.assetForPath("index.html", .web)) |asset| {
        web_index_template = splitIndexTemplate(asset.body);
    }
}

fn splitIndexTemplate(html: []const u8) ?IndexTemplate {
    const marker_index = std.mem.indexOf(u8, html, BOOTSTRAP_PLACEHOLDER) orelse return null;
    return .{
        .prefix = html[0..marker_index],
        .suffix = html[marker_index + BOOTSTRAP_PLACEHOLDER.len ..],
    };
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

fn getBootstrapStatePath(allocator: std.mem.Allocator) ![]u8 {
    const app_dir = try getAppLocalDataDir(allocator);
    defer allocator.free(app_dir);
    return std.fs.path.join(allocator, &.{ app_dir, BOOTSTRAP_STATE_FILE });
}

fn loadBootstrapStateJson(allocator: std.mem.Allocator) ![]u8 {
    const state_path = getBootstrapStatePath(allocator) catch {
        return allocator.dupe(u8, DEFAULT_BOOTSTRAP_STATE_JSON);
    };
    defer allocator.free(state_path);

    if (!pathExists(state_path)) {
        return allocator.dupe(u8, DEFAULT_BOOTSTRAP_STATE_JSON);
    }

    const file = std.fs.openFileAbsolute(state_path, .{}) catch {
        return allocator.dupe(u8, DEFAULT_BOOTSTRAP_STATE_JSON);
    };
    defer file.close();

    const raw = file.readToEndAlloc(allocator, 8 * 1024 * 1024) catch {
        return allocator.dupe(u8, DEFAULT_BOOTSTRAP_STATE_JSON);
    };

    const trimmed = std.mem.trim(u8, raw, " \r\n\t");
    if (trimmed.len == 0) {
        allocator.free(raw);
        return allocator.dupe(u8, DEFAULT_BOOTSTRAP_STATE_JSON);
    }

    if (trimmed.ptr == raw.ptr and trimmed.len == raw.len) {
        return raw;
    }

    const normalized = allocator.dupe(u8, trimmed) catch {
        allocator.free(raw);
        return allocator.dupe(u8, DEFAULT_BOOTSTRAP_STATE_JSON);
    };
    allocator.free(raw);
    return normalized;
}

fn makeDynamicIndex(allocator: std.mem.Allocator) ?[]u8 {
    const template = web_index_template orelse return null;
    const state_json = loadBootstrapStateJson(allocator) catch return null;
    defer allocator.free(state_json);

    const encoded_len = std.base64.standard.Encoder.calcSize(state_json.len);
    const encoded_state = allocator.alloc(u8, encoded_len) catch return null;
    defer allocator.free(encoded_state);
    _ = std.base64.standard.Encoder.encode(encoded_state, state_json);

    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
        template.prefix,
        encoded_state,
        template.suffix,
    }) catch null;
}

fn stripQuery(path: []const u8) []const u8 {
    const q = std.mem.indexOfScalar(u8, path, '?') orelse return path;
    return path[0..q];
}

fn isIndexPath(path: []const u8) bool {
    return std.mem.eql(u8, path, "/") or
        std.mem.eql(u8, path, "/index.html") or
        std.mem.eql(u8, path, "index.html");
}

fn handleConnection(stream: std.net.Stream, allocator: std.mem.Allocator) void {
    const raw_request = readHttpRequest(stream, allocator) catch {
        writeHttpResponse(stream, "400 Bad Request", "text/plain; charset=utf-8", "Invalid request", null);
        return;
    };
    defer allocator.free(raw_request);

    const parsed = parseHttpRequest(raw_request) catch {
        writeHttpResponse(stream, "400 Bad Request", "text/plain; charset=utf-8", "Malformed request", null);
        return;
    };

    if (std.mem.eql(u8, parsed.method, "OPTIONS")) {
        writeHttpResponse(
            stream,
            "204 No Content",
            "text/plain; charset=utf-8",
            "",
            "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: Content-Type\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\n",
        );
        return;
    }

    const path = stripQuery(parsed.target);
    if (std.mem.eql(u8, parsed.method, "POST") and std.mem.eql(u8, path, "/rpc")) {
        const rpc_json = rpc.handleRpcText(allocator, parsed.body, &oauth_listener_cancel) catch {
            const fallback = "{\"ok\":false,\"error\":\"internal RPC failure\"}";
            writeHttpResponse(
                stream,
                "500 Internal Server Error",
                "application/json; charset=utf-8",
                fallback,
                "Access-Control-Allow-Origin: *\r\n",
            );
            return;
        };
        defer allocator.free(rpc_json);
        writeHttpResponse(
            stream,
            "200 OK",
            "application/json; charset=utf-8",
            rpc_json,
            "Access-Control-Allow-Origin: *\r\n",
        );
        return;
    }

    if (!std.mem.eql(u8, parsed.method, "GET")) {
        writeHttpResponse(stream, "405 Method Not Allowed", "text/plain; charset=utf-8", "Method Not Allowed", null);
        return;
    }

    if (isIndexPath(path)) {
        if (makeDynamicIndex(allocator)) |html| {
            defer allocator.free(html);
            writeHttpResponse(stream, "200 OK", "text/html; charset=utf-8", html, null);
            return;
        }
    }

    if (assets.assetForPath(path, .web)) |asset| {
        writeHttpResponse(stream, "200 OK", asset.content_type, asset.body, null);
        return;
    }

    writeHttpResponse(stream, "404 Not Found", "text/plain; charset=utf-8", "Not Found", null);
}

fn readHttpRequest(stream: std.net.Stream, allocator: std.mem.Allocator) ![]u8 {
    var buffer = try allocator.alloc(u8, 1024 * 1024);
    errdefer allocator.free(buffer);

    var total: usize = 0;
    while (total < buffer.len) {
        const bytes_read = try stream.read(buffer[total..]);
        if (bytes_read == 0) {
            break;
        }
        total += bytes_read;

        if (httpRequestComplete(buffer[0..total])) {
            break;
        }
    }

    if (total == 0) {
        return error.EmptyRequest;
    }

    const out = try allocator.dupe(u8, buffer[0..total]);
    allocator.free(buffer);
    return out;
}

fn httpRequestComplete(request: []const u8) bool {
    const header_end = std.mem.indexOf(u8, request, "\r\n\r\n") orelse return false;
    const body_start = header_end + 4;
    const header = request[0..header_end];
    const content_length = parseContentLength(header) orelse 0;
    return request.len >= body_start + content_length;
}

const ParsedRequest = struct {
    method: []const u8,
    target: []const u8,
    body: []const u8,
};

fn parseHttpRequest(request: []const u8) !ParsedRequest {
    const header_end = std.mem.indexOf(u8, request, "\r\n\r\n") orelse return error.InvalidRequest;
    const body_start = header_end + 4;

    const first_line_end = std.mem.indexOfScalar(u8, request, '\n') orelse return error.InvalidRequest;
    const first_line = std.mem.trimRight(u8, request[0..first_line_end], "\r");
    var parts = std.mem.tokenizeScalar(u8, first_line, ' ');
    const method = parts.next() orelse return error.InvalidRequest;
    const target = parts.next() orelse return error.InvalidRequest;

    return .{
        .method = method,
        .target = target,
        .body = request[body_start..],
    };
}

fn parseContentLength(headers: []const u8) ?usize {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "Content-Length:")) {
            const value = std.mem.trim(u8, line["Content-Length:".len..], " \t");
            return std.fmt.parseInt(usize, value, 10) catch null;
        }
    }
    return null;
}

fn writeHttpResponse(
    stream: std.net.Stream,
    status: []const u8,
    content_type: []const u8,
    body: []const u8,
    extra_headers: ?[]const u8,
) void {
    var header_buffer: [1024]u8 = undefined;
    const header = std.fmt.bufPrint(
        &header_buffer,
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: {}\r\n{s}\r\n",
        .{
            status,
            content_type,
            body.len,
            extra_headers orelse "",
        },
    ) catch return;

    stream.writeAll(header) catch {};
    stream.writeAll(body) catch {};
}
