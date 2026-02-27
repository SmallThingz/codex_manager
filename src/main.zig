const std = @import("std");
const builtin = @import("builtin");
const webui = @import("webui");

const embedded_index = @import("embedded_index.zig");
const rpc_webui = @import("rpc_webui.zig");

const DEFAULT_WIDTH: u32 = 1000;
const DEFAULT_HEIGHT: u32 = 760;
const BROWSER_IDLE_SHUTDOWN_DELAY_MS: i64 = 3000;

const LaunchRequest = struct {
    surfaces: [3]?webui.LaunchSurface = .{ null, null, null },
    len: usize = 0,

    fn append(self: *LaunchRequest, surface: webui.LaunchSurface) void {
        if (self.contains(surface)) return;
        if (self.len >= self.surfaces.len) return;
        self.surfaces[self.len] = surface;
        self.len += 1;
    }

    fn contains(self: *const LaunchRequest, surface: webui.LaunchSurface) bool {
        for (self.surfaces[0..self.len]) |entry| {
            if (entry == surface) return true;
        }
        return false;
    }
};

var oauth_listener_cancel = std.atomic.Value(bool).init(false);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (builtin.mode == .Debug) {
            _ = gpa.deinit();
        }
    }

    const allocator = if (builtin.mode == .Debug)
        gpa.allocator()
    else
        std.heap.smp_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const launch_request = try parseLaunchRequest(args);
    rpc_webui.setCancelPointer(&oauth_listener_cancel);

    const window_style: webui.WindowStyle = .{
        .size = .{ .width = DEFAULT_WIDTH, .height = DEFAULT_HEIGHT },
    };

    const live_index_path = try embedded_index.refreshLiveIndexFromBootstrapFile(allocator);
    defer allocator.free(live_index_path);

    try runModeService(allocator, live_index_path, window_style, launch_request);
}

fn parseLaunchRequest(args: []const []const u8) !LaunchRequest {
    var request: LaunchRequest = .{};

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--webview")) {
            request.append(.native_webview);
            continue;
        }
        if (std.mem.eql(u8, arg, "--browser")) {
            request.append(.browser_window);
            continue;
        }
        if (std.mem.eql(u8, arg, "--web")) {
            request.append(.web_url);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            std.debug.print(
                "Unsupported flag: {s}. Supported launch flags: --webview --browser --web\n",
                .{arg},
            );
            return error.InvalidLaunchFlag;
        }
    }

    if (request.len == 0) {
        request.append(.native_webview);
        request.append(.browser_window);
        request.append(.web_url);
    }

    return request;
}

fn runModeService(
    allocator: std.mem.Allocator,
    page_file_path: []const u8,
    window_style: webui.WindowStyle,
    launch_request: LaunchRequest,
) !void {
    const first_surface = launch_request.surfaces[0] orelse .native_webview;
    const launch_policy: webui.LaunchPolicy = .{
        .first = first_surface,
        .second = launch_request.surfaces[1],
        .third = launch_request.surfaces[2],
        // Keep strict app-mode requirement only for explicit native-only mode.
        .app_mode_required = launch_request.len == 1 and first_surface == .native_webview,
    };

    const browser_launch: webui.BrowserLaunchOptions = .{
        .surface_mode = switch (first_surface) {
            .native_webview => .native_webview_host,
            .browser_window => .app_window,
            .web_url => .tab,
        },
        .fallback_mode = if (launch_request.len == 1 and first_surface == .native_webview)
            .strict
        else
            .allow_system,
    };

    var service = try webui.Service.init(allocator, rpc_webui.RpcBridgeMethods, .{
        .app = .{
            .launch_policy = launch_policy,
            .browser_launch = browser_launch,
        },
        .window = .{
            .title = "Codex Manager",
            .style = window_style,
        },
        .rpc = .{
            // Threaded dispatcher keeps RPC work off the HTTP connection thread.
            .dispatcher_mode = .threaded,
            .threaded_poll_interval_ns = 1 * std.time.ns_per_ms,
        },
    });
    defer service.deinit();

    try service.show(.{ .file = page_file_path });

    const render_state = service.runtimeRenderState();
    if (launch_request.len == 1 and first_surface == .native_webview and render_state.active_surface != .native_webview) {
        std.debug.print(
            "Codex Manager native webview launch failed: active_surface={s} fallback_applied={any}\n",
            .{ @tagName(render_state.active_surface), render_state.fallback_applied },
        );
        return error.NativeWebviewUnavailable;
    }

    // `web_url` requires explicit browser open; native/browser-window modes are managed by webui.
    if (render_state.active_surface == .web_url) {
        service.openInBrowserWithOptions(.{
            .surface_mode = .tab,
            .fallback_mode = .allow_system,
        }) catch |err| {
            std.debug.print("Codex Manager web URL launch failed: {s}\n", .{@errorName(err)});
        };
    }

    const local_url = service.browserUrl() catch null;
    defer if (local_url) |url| allocator.free(url);

    if (local_url) |url| {
        std.debug.print("Codex Manager URL: {s}\n", .{url});
    }

    var browser_shutdown_deadline_ms: ?i64 = null;
    while (true) {
        try service.run();
        if (!service.shouldExit()) {
            browser_shutdown_deadline_ms = null;
            std.Thread.sleep(16 * std.time.ns_per_ms);
            continue;
        }

        const active_surface = service.runtimeRenderState().active_surface;
        const browser_surface = active_surface == .browser_window or active_surface == .web_url;
        if (browser_surface) {
            const now_ms = std.time.milliTimestamp();
            if (browser_shutdown_deadline_ms == null) {
                browser_shutdown_deadline_ms = now_ms + BROWSER_IDLE_SHUTDOWN_DELAY_MS;
            }
            if (now_ms < browser_shutdown_deadline_ms.?) {
                std.Thread.sleep(16 * std.time.ns_per_ms);
                continue;
            }
        }

        break;
    }
}
