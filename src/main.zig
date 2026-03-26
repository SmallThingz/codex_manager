const std = @import("std");
const webui = @import("webui");

const embedded_index = @import("embedded_index.zig");
const rpc_webui = @import("rpc_webui.zig");

const DEFAULT_WIDTH: u32 = 1000;
const DEFAULT_HEIGHT: u32 = 760;

const LaunchRequest = struct {
    surfaces: [3]?webui.LaunchSurface = .{ null, null, null },
    len: usize = 0,

    // Append.
    fn append(self: *LaunchRequest, surface: webui.LaunchSurface) void {
        if (self.contains(surface)) return;
        if (self.len >= self.surfaces.len) return;
        self.surfaces[self.len] = surface;
        self.len += 1;
    }

    // Contains.
    fn contains(self: *const LaunchRequest, surface: webui.LaunchSurface) bool {
        for (self.surfaces[0..self.len]) |entry| {
            if (entry == surface) return true;
        }
        return false;
    }
};

var oauth_listener_cancel = std.atomic.Value(bool).init(false);

/// Boots the desktop/web launcher, prepares the live HTML payload, and runs the selected webui
/// surface order until shutdown.
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    embedded_index.setEnvironMap(init.environ_map);
    rpc_webui.setEnvironMap(init.environ_map);
    const launch_request = try parseLaunchRequest(init.minimal.args, allocator);
    rpc_webui.setCancelPointer(&oauth_listener_cancel);

    const window_style: webui.WindowStyle = .{
        .size = .{ .width = DEFAULT_WIDTH, .height = DEFAULT_HEIGHT },
    };

    const live_index_path = try embedded_index.refreshLiveIndexFromBootstrapFile(allocator);
    defer allocator.free(live_index_path);

    try runModeService(allocator, init.io, live_index_path, window_style, launch_request);
}

// Parses parse launch request.
fn parseLaunchRequest(args: std.process.Args, allocator: std.mem.Allocator) !LaunchRequest {
    var request: LaunchRequest = .{};
    var arg_it = try std.process.Args.Iterator.initAllocator(args, allocator);
    defer arg_it.deinit();

    _ = arg_it.next();
    while (arg_it.next()) |arg_z| {
        const arg: []const u8 = arg_z;
        if (std.mem.eql(u8, arg, "--webview") or std.mem.eql(u8, arg, "-w")) {
            request.append(.native_webview);
            continue;
        }
        if (std.mem.eql(u8, arg, "--browser") or std.mem.eql(u8, arg, "-b")) {
            request.append(.browser_window);
            continue;
        }
        if (std.mem.eql(u8, arg, "--web") or std.mem.eql(u8, arg, "-u")) {
            request.append(.web_url);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print(
                "Unsupported flag: {s}. Supported launch flags: --webview/-w --browser/-b --web/-u\n",
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

// Runs run mode service.
fn runModeService(
    allocator: std.mem.Allocator,
    io: std.Io,
    page_file_path: []const u8,
    window_style: webui.WindowStyle,
    launch_request: LaunchRequest,
) !void {
    const first_surface = launch_request.surfaces[0] orelse .native_webview;
    const strict_native_only = launch_request.len == 1 and first_surface == .native_webview;
    const launch_policy: webui.LaunchPolicy = .{
        .first = first_surface,
        .second = launch_request.surfaces[1],
        .third = launch_request.surfaces[2],
        // Keep strict app-mode requirement only for explicit native-only mode.
        .app_mode_required = strict_native_only,
    };

    const browser_launch: webui.BrowserLaunchOptions = .{
        .surface_mode = switch (first_surface) {
            .native_webview => .native_webview_host,
            .browser_window => .app_window,
            .web_url => .tab,
        },
        .fallback_mode = if (strict_native_only)
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

    if (strict_native_only) {
        try ensureNativeWebviewAvailable(&service, allocator);
    }

    try service.show(.{ .file = page_file_path });

    const render_state = service.runtimeRenderState();
    if (strict_native_only and (render_state.active_surface != .native_webview or render_state.fallback_applied)) {
        std.debug.print(
            "Codex Manager native webview launch failed after show: active_surface={s} fallback_applied={any}\n",
            .{
                @tagName(render_state.active_surface),
                render_state.fallback_applied,
            },
        );
        return error.NativeWebviewUnavailable;
    }

    const local_url = service.browserUrl() catch null;
    defer if (local_url) |url| allocator.free(url);

    if (local_url) |url| {
        std.debug.print("Codex Manager URL: {s}\n", .{url});
    }

    try service.run();
    while (!service.shouldExit()) {
        std.Io.sleep(io, .fromMilliseconds(16), .awake) catch {};
    }
    service.shutdown();
}

// Ensure native webview available.
fn ensureNativeWebviewAvailable(service: *webui.Service, allocator: std.mem.Allocator) !void {
    const capabilities = service.probeCapabilities();
    if (capabilities.surface_if_shown != .native_webview or capabilities.fallback_expected) {
        std.debug.print(
            "Codex Manager native webview preflight failed: surface_if_shown={s} fallback_expected={any}\n",
            .{
                @tagName(capabilities.surface_if_shown),
                capabilities.fallback_expected,
            },
        );
        try logMissingNativeRequirements(service, allocator);
        return error.NativeWebviewUnavailable;
    }

    try logMissingNativeRequirements(service, allocator);
}

// Log missing native requirements.
fn logMissingNativeRequirements(service: *webui.Service, allocator: std.mem.Allocator) !void {
    const requirements = try service.listRuntimeRequirements(allocator);
    defer allocator.free(requirements);

    var missing_required = false;
    for (requirements) |requirement| {
        if (requirement.required and !requirement.available) {
            missing_required = true;
            std.debug.print(
                "Codex Manager native runtime missing: {s} ({s})\n",
                .{
                    requirement.name,
                    requirement.details orelse "required runtime dependency unavailable",
                },
            );
        }
    }

    if (missing_required) {
        return error.NativeWebviewUnavailable;
    }
}
