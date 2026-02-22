const std = @import("std");

pub const Bundle = enum {
    web,
    desktop,
};

pub const Asset = struct {
    content_type: []const u8,
    body: []const u8,
};

const WEB_INDEX_HTML = @embedFile("../frontend/dist-web/index.html");
const DESKTOP_INDEX_HTML = @embedFile("../frontend/dist-desktop/index.html");

pub fn assetForPath(path: []const u8, bundle: Bundle) ?Asset {
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html") or std.mem.eql(u8, path, "index.html")) {
        return switch (bundle) {
            .web => .{ .content_type = "text/html; charset=utf-8", .body = WEB_INDEX_HTML },
            .desktop => .{ .content_type = "text/html; charset=utf-8", .body = DESKTOP_INDEX_HTML },
        };
    }

    return null;
}
