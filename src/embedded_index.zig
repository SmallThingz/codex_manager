const std = @import("std");
const builtin = @import("builtin");
const process_io: std.Io = if (builtin.is_test) std.testing.io else std.Options.debug_io;
var process_environ_map: ?*std.process.Environ.Map = null;

const APP_ID = "com.codex.manager";
const BOOTSTRAP_STATE_FILE = "bootstrap-state.json";
const LIVE_INDEX_FILE = "index-live.html";
const BOOTSTRAP_PLACEHOLDER = "REPLACE_THIS_VARIABLE_WHEN_SENDING";
const DEFAULT_BOOTSTRAP_STATE_JSON =
    \\{"theme":null,"view":null,"usageById":{},"savedAt":0}
;
const INDEX_HTML = @embedFile("generated_index.html");

const IndexTemplate = struct {
    prefix: []const u8,
    suffix: []const u8,
};

const INDEX_TEMPLATE: IndexTemplate = splitIndexTemplate(INDEX_HTML) orelse @compileError(
    "frontend/dist/index.html is missing bootstrap placeholder",
);

/// Stores the startup environment map so no-libc builds can still resolve environment variables.
pub fn setEnvironMap(environ_map: *std.process.Environ.Map) void {
    process_environ_map = environ_map;
}

/// Splits the built HTML shell around the bootstrap placeholder inserted at build time.
fn splitIndexTemplate(html: []const u8) ?IndexTemplate {
    const marker_index = std.mem.indexOf(u8, html, BOOTSTRAP_PLACEHOLDER) orelse return null;
    return .{
        .prefix = html[0..marker_index],
        .suffix = html[marker_index + BOOTSTRAP_PLACEHOLDER.len ..],
    };
}

/// Reads an environment variable into owned memory across libc and no-libc targets.
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

/// Resolves the per-user application data directory used for bootstrap-state and live HTML.
fn getAppLocalDataDir(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        const appdata = try getEnvVarOwnedCompat(allocator, "APPDATA");
        defer allocator.free(appdata);
        return std.fs.path.join(allocator, &.{ appdata, APP_ID });
    }

    const home = try getEnvVarOwnedCompat(allocator, "HOME");
    defer allocator.free(home);

    if (builtin.os.tag == .macos) {
        return std.fs.path.join(allocator, &.{ home, "Library", "Application Support", APP_ID });
    }

    return std.fs.path.join(allocator, &.{ home, ".local", "share", APP_ID });
}

/// Returns the path to the generated live `index.html` that webui serves at runtime.
pub fn liveIndexPath(allocator: std.mem.Allocator) ![]u8 {
    const app_dir = try getAppLocalDataDir(allocator);
    defer allocator.free(app_dir);
    return std.fs.path.join(allocator, &.{ app_dir, LIVE_INDEX_FILE });
}

/// Writes a file by replacing it atomically so readers never observe a partial HTML snapshot.
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

/// Loads the persisted bootstrap-state JSON, normalizing empty/missing files to the default payload.
fn readBootstrapStateJsonOrDefault(allocator: std.mem.Allocator) ![]u8 {
    const state_path = blk: {
        const app_dir = getAppLocalDataDir(allocator) catch break :blk null;
        defer allocator.free(app_dir);
        break :blk try std.fs.path.join(allocator, &.{ app_dir, BOOTSTRAP_STATE_FILE });
    } orelse return allocator.dupe(u8, DEFAULT_BOOTSTRAP_STATE_JSON);
    defer allocator.free(state_path);

    std.Io.Dir.accessAbsolute(process_io, state_path, .{}) catch {
        return allocator.dupe(u8, DEFAULT_BOOTSTRAP_STATE_JSON);
    };

    const raw = std.Io.Dir.cwd().readFileAlloc(process_io, state_path, allocator, .limited(8 * 1024 * 1024)) catch {
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

/// Canonicalizes bootstrap JSON so the generated live HTML always embeds valid compact JSON.
fn canonicalizeBootstrapJson(allocator: std.mem.Allocator, bootstrap_json: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bootstrap_json, .{}) catch {
        return allocator.dupe(u8, DEFAULT_BOOTSTRAP_STATE_JSON);
    };
    defer parsed.deinit();

    switch (parsed.value) {
        .object => {},
        else => return allocator.dupe(u8, DEFAULT_BOOTSTRAP_STATE_JSON),
    }

    return std.fmt.allocPrint(allocator, "{f}", .{
        std.json.fmt(parsed.value, .{}),
    });
}

/// Injects the webui bridge script tag when the built frontend omitted it.
fn ensureModuleWebUiScript(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    const script_tag = "<script src=\"/webui/bridge.js\"></script>";

    if (std.mem.indexOf(u8, html, script_tag) != null) {
        return allocator.dupe(u8, html);
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

/// Injects the current bootstrap JSON into the built frontend HTML and returns the live page.
pub fn buildLiveIndexHtml(allocator: std.mem.Allocator, bootstrap_json: []const u8) ![]u8 {
    const canonical_json = try canonicalizeBootstrapJson(allocator, bootstrap_json);
    defer allocator.free(canonical_json);

    const encoded_len = std.base64.standard.Encoder.calcSize(canonical_json.len);
    const encoded_state = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded_state);
    _ = std.base64.standard.Encoder.encode(encoded_state, canonical_json);

    const html = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
        INDEX_TEMPLATE.prefix,
        encoded_state,
        INDEX_TEMPLATE.suffix,
    });
    defer allocator.free(html);

    return ensureModuleWebUiScript(allocator, html);
}

/// Writes the generated live HTML to disk and returns its final path.
pub fn writeLiveIndexFromBootstrapJson(allocator: std.mem.Allocator, bootstrap_json: []const u8) ![]u8 {
    const html = try buildLiveIndexHtml(allocator, bootstrap_json);
    defer allocator.free(html);

    const path = try liveIndexPath(allocator);
    errdefer allocator.free(path);
    try writeTextFileAtomic(allocator, path, html);
    return path;
}

/// Rebuilds the live HTML from the persisted bootstrap-state file and returns the output path.
pub fn refreshLiveIndexFromBootstrapFile(allocator: std.mem.Allocator) ![]u8 {
    const bootstrap_json = try readBootstrapStateJsonOrDefault(allocator);
    defer allocator.free(bootstrap_json);
    return writeLiveIndexFromBootstrapJson(allocator, bootstrap_json);
}
