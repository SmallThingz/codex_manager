const std = @import("std");
const webui = @import("webui");
const builtin = @import("builtin");

const assets = @import("assets.zig");
const rpc = @import("rpc.zig");

const DEFAULT_WIDTH: u32 = 1000;
const DEFAULT_HEIGHT: u32 = 760;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var app_window: ?webui = null;
var window_is_fullscreen: bool = false;
var oauth_listener_cancel = std.atomic.Value(bool).init(false);
var active_bundle: assets.Bundle = .web;

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

    const web_mode = !hasArg(args, "--desktop") or hasArg(args, "--web");

    var window = webui.newWindow();
    app_window = window;

    webui.setConfig(.multi_client, web_mode);
    webui.setConfig(.use_cookies, true);

    // Keep browser/profile storage persistent across runs (theme, local state).
    window.setProfile("codex-manager", ".codex-manager-profile");
    window.setSize(DEFAULT_WIDTH, DEFAULT_HEIGHT);
    window.setCenter();

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

fn stripQuery(path: []const u8) []const u8 {
    const q = std.mem.indexOfScalar(u8, path, '?') orelse return path;
    return path[0..q];
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
    if (builtin.os.tag == .linux and gtkWindowAction("gtk_window_iconify")) {
        sendOk(e, @as(?u8, null));
        return;
    }

    if (app_window) |window| {
        window.minimize();
    }
    sendOk(e, @as(?u8, null));
}

fn cmWindowToggleMaximize(e: *webui.Event) void {
    cmWindowToggleFullscreen(e);
}

fn cmWindowToggleFullscreen(e: *webui.Event) void {
    if (builtin.os.tag == .linux) {
        const next_fullscreen = !window_is_fullscreen;
        const symbol: [:0]const u8 = if (next_fullscreen)
            "gtk_window_fullscreen"
        else
            "gtk_window_unfullscreen";

        if (gtkWindowAction(symbol)) {
            window_is_fullscreen = next_fullscreen;
            sendOk(e, window_is_fullscreen);
            return;
        }
    }

    if (app_window) |window| {
        if (window_is_fullscreen) {
            window.setSize(DEFAULT_WIDTH, DEFAULT_HEIGHT);
            window.setCenter();
            window_is_fullscreen = false;
        } else {
            window.maximize();
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

fn gtkWindowAction(symbol: [:0]const u8) bool {
    if (builtin.os.tag != .linux) {
        return false;
    }

    const window = app_window orelse return false;
    const handle = window.getHwnd() catch return false;

    var lib = std.DynLib.open("libgtk-3.so.0") catch return false;
    defer lib.close();

    const GtkWindowFn = *const fn (*anyopaque) callconv(.c) void;
    const action = lib.lookup(GtkWindowFn, symbol) orelse return false;
    action(handle);
    return true;
}
