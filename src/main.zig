const std = @import("std");
const webui = @import("webui");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("stdlib.h");
});

const assets = @import("assets.zig");
const rpc = @import("rpc.zig");

const DEFAULT_WIDTH: u32 = 1000;
const DEFAULT_HEIGHT: u32 = 760;
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
var app_window: ?webui = null;
var window_is_fullscreen: bool = false;
var oauth_listener_cancel = std.atomic.Value(bool).init(false);
var active_bundle: assets.Bundle = .web;
var templates_initialized = false;
var web_index_template: ?IndexTemplate = null;
var desktop_index_template: ?IndexTemplate = null;

pub fn main() !void {
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            @panic("memory leak detected");
        }
    }

    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const web_mode = hasArg(args, "--web") and !hasArg(args, "--desktop");

    if (builtin.os.tag == .linux and !web_mode) {
        // Work around flaky EGL/DMABUF paths on some Linux+WebKitGTK stacks.
        _ = c.setenv("WEBKIT_DISABLE_DMABUF_RENDERER", "1", 0);
        _ = c.setenv("WEBKIT_DISABLE_COMPOSITING_MODE", "1", 0);
    }

    var window = webui.newWindow();
    app_window = window;
    initIndexTemplates();

    webui.setConfig(.multi_client, web_mode);
    webui.setConfig(.use_cookies, true);
    // WebUI 2.5 beta can race in websocket event cleanup under concurrent callbacks.
    // Force serialized event handling to avoid heap corruption/crashes.
    webui.setConfig(.ui_event_blocking, true);

    // Keep browser/profile storage persistent across runs (theme, local state).
    window.setProfile("codex-manager", ".codex-manager-profile");
    window.setSize(DEFAULT_WIDTH, DEFAULT_HEIGHT);
    window.setEventBlocking(true);

    _ = try window.bind("cm_rpc", cmRpc);

    if (web_mode) {
        active_bundle = .web;
        window.setFileHandler(customFileHandler);
        _ = window.setPort(14555) catch {};

        const url = try window.startServer("index.html");
        const open_url_owned: ?[]const u8 = toLoopbackUrl(allocator, url) catch null;
        const open_url = open_url_owned orelse url;
        defer if (open_url_owned) |value| allocator.free(value);
        const open_url_z = try allocator.dupeZ(u8, open_url);
        defer allocator.free(open_url_z);
        std.debug.print("Codex Manager web mode URL: {s}\n", .{open_url});
        webui.openUrl(open_url_z);
    } else {
        active_bundle = .desktop;
        window.setFrameless(true);
        window.setCloseHandlerWv(cmWindowCloseHandler);

        _ = try window.bind("cm_window_minimize", cmWindowMinimize);
        _ = try window.bind("cm_window_toggle_fullscreen", cmWindowToggleFullscreen);
        _ = try window.bind("cm_window_is_fullscreen", cmWindowIsFullscreen);
        _ = try window.bind("cm_window_toggle_maximize", cmWindowToggleMaximize);
        _ = try window.bind("cm_window_is_maximized", cmWindowIsMaximized);
        _ = try window.bind("cm_window_close", cmWindowClose);
        _ = try window.bind("cm_window_start_drag", cmWindowStartDrag);

        // Avoid large inline HTML in showWv; serve desktop bundle over local WebUI server.
        window.setFileHandler(customFileHandler);
        const desktop_url = try window.startServer("index.html");
        const desktop_loopback_owned: ?[]const u8 = toLoopbackUrl(allocator, desktop_url) catch null;
        const desktop_loopback_url = desktop_loopback_owned orelse desktop_url;
        defer if (desktop_loopback_owned) |value| allocator.free(value);
        const desktop_loopback_z = try allocator.dupeZ(u8, desktop_loopback_url);
        defer allocator.free(desktop_loopback_z);
        std.debug.print("Codex Manager desktop URL: {s}\n", .{desktop_loopback_url});
        window.showWv(desktop_loopback_z) catch |err| {
            std.debug.print(
                "Desktop WebView unavailable ({s}); falling back to browser window.\n",
                .{@errorName(err)},
            );
            webui.openUrl(desktop_loopback_z);
        };
    }

    webui.wait();
    webui.clean();
}

fn hasArg(args: []const []const u8, needle: []const u8) bool {
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, needle)) {
            return true;
        }
    }

    return false;
}

fn toLoopbackUrl(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    const parsed = std.Uri.parse(url) catch return error.InvalidUrl;
    const port = parsed.port orelse return error.InvalidUrl;
    const path = if (parsed.path.percent_encoded.len == 0) "/index.html" else parsed.path.percent_encoded;
    return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}{s}", .{ port, path });
}

fn cmRpc(e: *webui.Event) void {
    rpc.handleRpcEvent(e, gpa.allocator(), &oauth_listener_cancel);
}

fn initIndexTemplates() void {
    if (templates_initialized) {
        return;
    }
    templates_initialized = true;

    if (assets.assetForPath("index.html", .web)) |asset| {
        web_index_template = splitIndexTemplate(asset.body);
    }

    if (assets.assetForPath("index.html", .desktop)) |asset| {
        desktop_index_template = splitIndexTemplate(asset.body);
    }
}

fn splitIndexTemplate(html: []const u8) ?IndexTemplate {
    const marker_index = std.mem.indexOf(u8, html, BOOTSTRAP_PLACEHOLDER) orelse return null;
    return .{
        .prefix = html[0..marker_index],
        .suffix = html[marker_index + BOOTSTRAP_PLACEHOLDER.len ..],
    };
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

fn indexTemplateForBundle(bundle: assets.Bundle) ?IndexTemplate {
    return switch (bundle) {
        .web => web_index_template,
        .desktop => desktop_index_template,
    };
}

fn makeDynamicIndexResponse(bundle: assets.Bundle) ?[]const u8 {
    const template = indexTemplateForBundle(bundle) orelse return null;
    const allocator = gpa.allocator();

    const state_json = loadBootstrapStateJson(allocator) catch return null;
    defer allocator.free(state_json);

    const encoded_len = std.base64.standard.Encoder.calcSize(state_json.len);
    const encoded_state = allocator.alloc(u8, encoded_len) catch return null;
    defer allocator.free(encoded_state);
    _ = std.base64.standard.Encoder.encode(encoded_state, state_json);

    const html = std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
        template.prefix,
        encoded_state,
        template.suffix,
    }) catch return null;
    defer allocator.free(html);

    return makeHttpResponse("200 OK", "text/html; charset=utf-8", html);
}

fn toWebUiManaged(bytes: []const u8) ?[]const u8 {
    const out = webui.malloc(bytes.len) catch return null;
    std.mem.copyForwards(u8, out, bytes);
    return out;
}

fn makeHttpResponse(status: []const u8, content_type: []const u8, body: []const u8) ?[]const u8 {
    const allocator = gpa.allocator();
    const header = std.fmt.allocPrint(
        allocator,
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: {}\r\n\r\n",
        .{ status, content_type, body.len },
    ) catch return null;
    defer allocator.free(header);

    const merged = std.fmt.allocPrint(allocator, "{s}{s}", .{ header, body }) catch return null;
    defer allocator.free(merged);

    return toWebUiManaged(merged);
}

fn customFileHandler(filename: []const u8) ?[]const u8 {
    const path = stripQuery(filename);

    if (isIndexPath(path)) {
        if (makeDynamicIndexResponse(active_bundle)) |response| {
            return response;
        }
    }

    if (assets.assetForPath(path, active_bundle)) |asset| {
        return makeHttpResponse("200 OK", asset.content_type, asset.body);
    }

    if (std.mem.eql(u8, path, "/webui.js")) {
        // Let WebUI serve its runtime bridge script.
        return null;
    }

    // Let WebUI handle internal endpoints such as websocket transport.
    return null;
}

fn sendOk(e: *webui.Event, value: anytype) void {
    const allocator = gpa.allocator();
    const json = std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(.{ .ok = true, .value = value }, .{})}) catch {
        e.returnString("{\"ok\":false,\"error\":\"internal serialization error\"}");
        return;
    };
    defer allocator.free(json);

    const json_z = allocator.dupeZ(u8, json) catch {
        e.returnString("{\"ok\":false,\"error\":\"internal allocation error\"}");
        return;
    };
    defer allocator.free(json_z);

    e.returnString(json_z);
}

fn cmWindowMinimize(e: *webui.Event) void {
    if (app_window) |window| {
        window.minimize();
    }
    sendOk(e, @as(?u8, null));
}

fn cmWindowToggleMaximize(e: *webui.Event) void {
    cmWindowToggleFullscreen(e);
}

fn cmWindowToggleFullscreen(e: *webui.Event) void {
    if (app_window) |window| {
        if (window_is_fullscreen) {
            window.setKiosk(false);
            window_is_fullscreen = false;
        } else {
            window.setKiosk(true);
            window_is_fullscreen = true;
        }
    }

    sendOk(e, window_is_fullscreen);
}

fn cmWindowIsMaximized(e: *webui.Event) void {
    cmWindowIsFullscreen(e);
}

fn cmWindowIsFullscreen(e: *webui.Event) void {
    sendOk(e, window_is_fullscreen);
}

fn cmWindowClose(e: *webui.Event) void {
    _ = e;
    exitNow();
}

fn cmWindowStartDrag(e: *webui.Event) void {
    // Dragging is handled via CSS app-region in the frontend.
    sendOk(e, @as(?u8, null));
}

fn cmWindowCloseHandler(_: usize) bool {
    exitNow();
}

fn exitNow() noreturn {
    std.process.exit(0);
}
