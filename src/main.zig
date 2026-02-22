const std = @import("std");
const webui = @import("webui");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("stdlib.h");
});

const assets = @import("assets.zig");
const rpc_webui = @import("rpc_webui.zig");

const DEFAULT_WIDTH: u32 = 1000;
const DEFAULT_HEIGHT: u32 = 760;
const APP_ID = "com.codex.manager";
const BOOTSTRAP_STATE_FILE = "bootstrap-state.json";
const BOOTSTRAP_PLACEHOLDER = "REPLACE_THIS_VARIABLE_WHEN_SENDING";
const DEFAULT_BOOTSTRAP_STATE_JSON =
    \\{"theme":null,"showWindowBar":false,"view":null,"usageById":{},"savedAt":0}
;

const IndexTemplate = struct {
    prefix: []const u8,
    suffix: []const u8,
};

var app_window: ?webui = null;
var window_is_fullscreen: bool = false;
var window_state_lock = std.Thread.Mutex{};
var oauth_listener_cancel = std.atomic.Value(bool).init(false);
var active_bundle: assets.Bundle = .web;
var show_custom_window_bar = false;
var templates_initialized = false;
var index_template: ?IndexTemplate = null;

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const force_web_mode = hasArg(args, "--web") and !hasArg(args, "--desktop");

    if (builtin.os.tag == .linux and !force_web_mode) {
        // Work around flaky EGL/DMABUF paths on some Linux+WebKitGTK stacks.
        _ = c.setenv("WEBKIT_DISABLE_DMABUF_RENDERER", "1", 0);
        _ = c.setenv("WEBKIT_DISABLE_COMPOSITING_MODE", "1", 0);
    }

    var window = webui.newWindow();
    app_window = window;
    initIndexTemplates();

    webui.setConfig(.multi_client, true);
    webui.setConfig(.use_cookies, true);
    // Allow concurrent RPC handling; long-running operations (OAuth listener)
    // must not block unrelated commands such as credits refresh.
    webui.setConfig(.ui_event_blocking, false);

    // Keep browser/profile storage persistent across runs (theme, local state).
    window.setProfile("codex-manager", ".codex-manager-profile");
    window.setSize(DEFAULT_WIDTH, DEFAULT_HEIGHT);
    window.setEventBlocking(false);

    _ = try window.bind("cm_rpc", cmRpc);

    // Serve app assets from a single embedded frontend bundle.
    window.setFileHandler(customFileHandler);
    _ = window.setPort(14555) catch {};
    const url = try window.startServer("index.html");
    const loopback_owned: ?[]const u8 = toLoopbackUrl(allocator, url) catch null;
    const loopback_url = loopback_owned orelse url;
    defer if (loopback_owned) |value| allocator.free(value);
    const loopback_url_z = try allocator.dupeZ(u8, loopback_url);
    defer allocator.free(loopback_url_z);

    if (force_web_mode) {
        active_bundle = .web;
        show_custom_window_bar = false;
        std.debug.print("Codex Manager web mode URL: {s}\n", .{loopback_url});
        webui.openUrl(loopback_url_z);
    } else {
        // Default mode is desktop; if WebView dependencies are unavailable, fall back to browser.
        active_bundle = .desktop;
        // Linux WebUI drag/minimize/maximize in frameless mode is unstable upstream.
        // Keep native OS chrome there; use custom HTML chrome on other desktop OSes.
        const use_custom_window_chrome = builtin.os.tag != .linux;
        show_custom_window_bar = use_custom_window_chrome;
        if (!use_custom_window_chrome) {
            std.debug.print("Linux desktop: using native window chrome (frameless drag is unstable in current WebUI build)\n", .{});
        }
        if (use_custom_window_chrome) {
            window.setFrameless(true);
        }
        window.setCloseHandlerWv(cmWindowCloseHandler);

        if (use_custom_window_chrome) {
            _ = try window.bind("cm_window_minimize", cmWindowMinimize);
            _ = try window.bind("cm_window_toggle_fullscreen", cmWindowToggleFullscreen);
            _ = try window.bind("cm_window_is_fullscreen", cmWindowIsFullscreen);
            _ = try window.bind("cm_window_close", cmWindowClose);
        }

        std.debug.print("Codex Manager desktop URL: {s}\n", .{loopback_url});
        window.showWv(loopback_url_z) catch |err| {
            active_bundle = .web;
            show_custom_window_bar = false;
            std.debug.print(
                "Desktop WebView unavailable ({s}); falling back to browser mode at {s}\n",
                .{ @errorName(err), loopback_url },
            );
            webui.openUrl(loopback_url_z);
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
    rpc_webui.handleRpcEvent(e, std.heap.c_allocator, &oauth_listener_cancel);
}

fn initIndexTemplates() void {
    if (templates_initialized) {
        return;
    }
    templates_initialized = true;

    if (assets.assetForPath("index.html")) |asset| {
        index_template = splitIndexTemplate(asset.body);
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

fn fallbackBootstrapStateJson(allocator: std.mem.Allocator, show_window_bar: bool) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"theme\":null,\"showWindowBar\":{s},\"view\":null,\"usageById\":{{}},\"savedAt\":0}}",
        .{if (show_window_bar) "true" else "false"},
    );
}

fn makeDynamicIndexResponse(bundle: assets.Bundle) ?[]const u8 {
    const template = index_template orelse return null;
    const allocator = std.heap.c_allocator;

    const state_json = loadBootstrapStateJson(allocator) catch return null;
    defer allocator.free(state_json);
    _ = bundle;
    const show_window_bar = show_custom_window_bar;

    const injected_state_json = blk: {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, state_json, .{}) catch {
            break :blk fallbackBootstrapStateJson(allocator, show_window_bar) catch return null;
        };
        defer parsed.deinit();

        switch (parsed.value) {
            .object => |*obj| {
                obj.put("showWindowBar", .{ .bool = show_window_bar }) catch {
                    break :blk fallbackBootstrapStateJson(allocator, show_window_bar) catch return null;
                };
            },
            else => break :blk fallbackBootstrapStateJson(allocator, show_window_bar) catch return null,
        }

        break :blk std.fmt.allocPrint(allocator, "{f}", .{
            std.json.fmt(parsed.value, .{}),
        }) catch return null;
    };
    defer allocator.free(injected_state_json);

    const encoded_len = std.base64.standard.Encoder.calcSize(injected_state_json.len);
    const encoded_state = allocator.alloc(u8, encoded_len) catch return null;
    defer allocator.free(encoded_state);
    _ = std.base64.standard.Encoder.encode(encoded_state, injected_state_json);

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
    const allocator = std.heap.c_allocator;
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

    if (assets.assetForPath(path)) |asset| {
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
    const allocator = std.heap.c_allocator;
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
    window_state_lock.lock();
    defer window_state_lock.unlock();
    if (app_window) |window| {
        window.minimize();
    }
    sendOk(e, @as(?u8, null));
}

fn cmWindowToggleFullscreen(e: *webui.Event) void {
    window_state_lock.lock();
    defer window_state_lock.unlock();

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

fn cmWindowIsFullscreen(e: *webui.Event) void {
    window_state_lock.lock();
    defer window_state_lock.unlock();
    sendOk(e, window_is_fullscreen);
}

fn cmWindowClose(e: *webui.Event) void {
    _ = e;
    exitNow();
}

fn cmWindowCloseHandler(_: usize) bool {
    exitNow();
}

fn exitNow() noreturn {
    std.process.exit(0);
}
