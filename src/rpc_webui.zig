const std = @import("std");
const rpc = @import("rpc.zig");

const RawJson = struct {
    data: []const u8,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginWriteRaw();
        try jws.writer.writeAll(self.data);
        jws.endWriteRaw();
    }
};

pub const RpcBridgeMethods = struct {
    pub fn cm_rpc(request_text: []const u8) RawJson {
        const cancel_ptr = bridge_cancel_ptr orelse {
            return .{ .data = "{\"ok\":false,\"error\":\"RPC bridge not initialized\"}" };
        };

        const rpc_response = rpc.handleRpcText(std.heap.page_allocator, request_text, cancel_ptr) catch {
            return .{ .data = "{\"ok\":false,\"error\":\"internal RPC failure\"}" };
        };
        defer std.heap.page_allocator.free(rpc_response);

        if (rpc_response.len > bridge_response_storage.len) {
            return .{ .data = "{\"ok\":false,\"error\":\"RPC response exceeds bridge buffer\"}" };
        }

        @memcpy(bridge_response_storage[0..rpc_response.len], rpc_response);
        bridge_response_len = rpc_response.len;
        return .{ .data = bridge_response_storage[0..bridge_response_len] };
    }
};

var bridge_cancel_ptr: ?*std.atomic.Value(bool) = null;
threadlocal var bridge_response_storage: [8 * 1024 * 1024]u8 = undefined;
threadlocal var bridge_response_len: usize = 0;

pub fn setCancelPointer(cancel_ptr: *std.atomic.Value(bool)) void {
    bridge_cancel_ptr = cancel_ptr;
}
