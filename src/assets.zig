const std = @import("std");

pub const Bundle = enum {
    web,
    desktop,
};

pub const Asset = struct {
    content_type: []const u8,
    body: []const u8,
};

const INDEX_HTML = @embedFile("../frontend/dist/index.html");

pub fn assetForPath(path: []const u8) ?Asset {
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html") or std.mem.eql(u8, path, "index.html")) {
        return .{ .content_type = "text/html; charset=utf-8", .body = INDEX_HTML };
    }

    return null;
}
