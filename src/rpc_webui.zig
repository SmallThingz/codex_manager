const std = @import("std");
const webui = @import("webui");
const rpc = @import("rpc.zig");

pub fn handleRpcEvent(e: *webui.Event, allocator: std.mem.Allocator, cancel_ptr: *std.atomic.Value(bool)) void {
    const response = rpc.handleRpcText(allocator, e.getString(), cancel_ptr) catch {
        return sendError(e, allocator, "internal RPC failure");
    };
    defer allocator.free(response);
    returnJsonToEvent(e, allocator, response);
}

fn returnJsonToEvent(e: *webui.Event, allocator: std.mem.Allocator, json_text: []const u8) void {
    const json_z = allocator.dupeZ(u8, json_text) catch {
        e.returnString("{\"ok\":false,\"error\":\"internal allocation error\"}");
        return;
    };
    defer allocator.free(json_z);
    e.returnString(json_z);
}

fn sendError(e: *webui.Event, allocator: std.mem.Allocator, message: []const u8) void {
    const json = std.fmt.allocPrint(allocator, "{f}", .{
        std.json.fmt(.{ .ok = false, .@"error" = message }, .{}),
    }) catch {
        e.returnString("{\"ok\":false,\"error\":\"internal serialization error\"}");
        return;
    };
    defer allocator.free(json);
    returnJsonToEvent(e, allocator, json);
}
