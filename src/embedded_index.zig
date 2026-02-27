const std = @import("std");
const builtin = @import("builtin");

const APP_ID = "com.codex.manager";
const BOOTSTRAP_STATE_FILE = "bootstrap-state.json";
const LIVE_INDEX_FILE = "index-live.html";
const BOOTSTRAP_PLACEHOLDER = "REPLACE_THIS_VARIABLE_WHEN_SENDING";
const DEFAULT_BOOTSTRAP_STATE_JSON =
    \\{"theme":null,"view":null,"usageById":{},"savedAt":0}
;
const INDEX_HTML = @embedFile("../frontend/dist/index.html");

const IndexTemplate = struct {
    prefix: []const u8,
    suffix: []const u8,
};

const INDEX_TEMPLATE: IndexTemplate = splitIndexTemplate(INDEX_HTML) orelse @compileError(
    "frontend/dist/index.html is missing bootstrap placeholder",
);

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

fn bootstrapStatePath(allocator: std.mem.Allocator) ![]u8 {
    const app_dir = try getAppLocalDataDir(allocator);
    defer allocator.free(app_dir);
    return std.fs.path.join(allocator, &.{ app_dir, BOOTSTRAP_STATE_FILE });
}

pub fn liveIndexPath(allocator: std.mem.Allocator) ![]u8 {
    const app_dir = try getAppLocalDataDir(allocator);
    defer allocator.free(app_dir);
    return std.fs.path.join(allocator, &.{ app_dir, LIVE_INDEX_FILE });
}

fn writeTextFileAtomic(allocator: std.mem.Allocator, path: []const u8, contents: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try std.fs.cwd().makePath(parent);
    }

    const temp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(temp_path);

    const temp_file = try std.fs.createFileAbsolute(temp_path, .{ .truncate = true });
    defer temp_file.close();
    try temp_file.writeAll(contents);
    try temp_file.sync();

    std.fs.renameAbsolute(temp_path, path) catch |err| switch (err) {
        error.PathAlreadyExists => {
            try std.fs.deleteFileAbsolute(path);
            try std.fs.renameAbsolute(temp_path, path);
        },
        else => return err,
    };
}

fn readBootstrapStateJsonOrDefault(allocator: std.mem.Allocator) ![]u8 {
    const state_path = bootstrapStatePath(allocator) catch {
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

fn canonicalizeBootstrapJson(allocator: std.mem.Allocator, bootstrap_json: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bootstrap_json, .{}) catch {
        return fallbackBootstrapStateJson(allocator);
    };
    defer parsed.deinit();

    switch (parsed.value) {
        .object => {},
        else => return fallbackBootstrapStateJson(allocator),
    }

    return std.fmt.allocPrint(allocator, "{f}", .{
        std.json.fmt(parsed.value, .{}),
    });
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

pub fn writeLiveIndexFromBootstrapJson(allocator: std.mem.Allocator, bootstrap_json: []const u8) ![]u8 {
    const html = try buildLiveIndexHtml(allocator, bootstrap_json);
    defer allocator.free(html);

    const path = try liveIndexPath(allocator);
    errdefer allocator.free(path);
    try writeTextFileAtomic(allocator, path, html);
    return path;
}

pub fn refreshLiveIndexFromBootstrapFile(allocator: std.mem.Allocator) ![]u8 {
    const bootstrap_json = try readBootstrapStateJsonOrDefault(allocator);
    defer allocator.free(bootstrap_json);
    return writeLiveIndexFromBootstrapJson(allocator, bootstrap_json);
}
