const std = @import("std");
const webui = @import("webui");
const builtin = @import("builtin");

const assets = @import("assets.zig");
const rpc_webui = @import("rpc_webui.zig");

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
var templates_initialized = false;
var index_template: ?IndexTemplate = null;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const launch_request = try parseLaunchRequest(args);
    initIndexTemplates();
    rpc_webui.setCancelPointer(&oauth_listener_cancel);

    const window_style: webui.WindowStyle = .{
        .size = .{ .width = DEFAULT_WIDTH, .height = DEFAULT_HEIGHT },
    };

    const page_html = makeDynamicIndexHtml(allocator) orelse return error.IndexHtmlUnavailable;
    defer allocator.free(page_html);

    try runModeService(allocator, page_html, window_style, launch_request);
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
    page_html: []const u8,
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

    try service.show(.{ .html = page_html });

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

    while (!service.shouldExit()) {
        try service.run();
        std.Thread.sleep(16 * std.time.ns_per_ms);
    }
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

fn fallbackBootstrapStateJson(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, DEFAULT_BOOTSTRAP_STATE_JSON);
}

fn makeDynamicIndexHtml(allocator: std.mem.Allocator) ?[]u8 {
    const template = index_template orelse return null;

    const state_json = loadBootstrapStateJson(allocator) catch return null;
    defer allocator.free(state_json);

    const injected_state_json = blk: {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, state_json, .{}) catch {
            break :blk fallbackBootstrapStateJson(allocator) catch return null;
        };
        defer parsed.deinit();

        switch (parsed.value) {
            .object => {},
            else => break :blk fallbackBootstrapStateJson(allocator) catch return null,
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

    return ensureModuleWebUiScript(allocator, html) catch null;
}

fn ensureModuleWebUiScript(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    const script_tag = "<script src=\"/webui_bridge.js\"></script>";
    const legacy_module_tag = "<script type=\"module\" src=\"/webui_bridge.js\"></script>";
    const legacy_old_tag = "<script src=\"/webui.js\"></script>";
    const legacy_old_module_tag = "<script type=\"module\" src=\"/webui.js\"></script>";

    if (std.mem.indexOf(u8, html, script_tag) != null) {
        return allocator.dupe(u8, html);
    }

    if (std.mem.indexOf(u8, html, legacy_module_tag)) |legacy_idx| {
        return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
            html[0..legacy_idx],
            script_tag,
            html[legacy_idx + legacy_module_tag.len ..],
        });
    }

    if (std.mem.indexOf(u8, html, legacy_old_tag)) |legacy_idx| {
        return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
            html[0..legacy_idx],
            script_tag,
            html[legacy_idx + legacy_old_tag.len ..],
        });
    }

    if (std.mem.indexOf(u8, html, legacy_old_module_tag)) |legacy_idx| {
        return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
            html[0..legacy_idx],
            script_tag,
            html[legacy_idx + legacy_old_module_tag.len ..],
        });
    }

    if (std.mem.indexOf(u8, html, "</head>")) |head_idx| {
        return std.fmt.allocPrint(allocator, "{s}{s}\n{s}", .{
            html[0..head_idx],
            script_tag,
            html[head_idx..],
        });
    }

    return std.fmt.allocPrint(allocator, "{s}\n{s}\n", .{ html, script_tag });
}
