const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var body_buf = std.ArrayList(u8).empty;
    defer body_buf.deinit(allocator);

    const uri = try std.Uri.parse("https://httpbin.org/get");

    var req = try client.request(.GET, uri, .{
        .headers = .{
            .user_agent = .{ .override = "codex-cli" },
            .accept_encoding = .omit,
        },
    });
    defer req.deinit();

    try req.sendBodiless();

    var redirect_buf: [2048]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    var transfer_buf: [4096]u8 = undefined;
    var body_reader = response.reader(&transfer_buf);

    try body_reader.appendRemaining(allocator, &body_buf, std.io.Limit.unlimited);

    std.debug.print("Status: {d}\nBody: {s}\n", .{ response.head.status, body_buf.items });
}
