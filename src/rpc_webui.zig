const std = @import("std");
const rpc = @import("rpc.zig");

pub const RpcBridgeMethods = struct {
    pub fn call(target_fn: []const u8, request_text: []const u8) []const u8 {
        if (!std.mem.eql(u8, target_fn, "cm_rpc")) {
            return "{\"ok\":false,\"error\":\"unknown bridge function\"}";
        }

        const cancel_ptr = bridge_cancel_ptr orelse {
            return "{\"ok\":false,\"error\":\"RPC bridge not initialized\"}";
        };

        const rpc_response = rpc.handleRpcText(std.heap.page_allocator, request_text, cancel_ptr) catch {
            return "{\"ok\":false,\"error\":\"internal RPC failure\"}";
        };
        defer std.heap.page_allocator.free(rpc_response);

        bridge_response_lock.lock();
        defer bridge_response_lock.unlock();

        if (rpc_response.len > bridge_response_storage.len) {
            return "{\"ok\":false,\"error\":\"RPC response exceeds bridge buffer\"}";
        }

        @memcpy(bridge_response_storage[0..rpc_response.len], rpc_response);
        bridge_response_len = rpc_response.len;
        return bridge_response_storage[0..bridge_response_len];
    }
};

var bridge_cancel_ptr: ?*std.atomic.Value(bool) = null;
var bridge_response_lock: std.Thread.Mutex = .{};
var bridge_response_storage: [8 * 1024 * 1024]u8 = undefined;
var bridge_response_len: usize = 0;

pub fn setCancelPointer(cancel_ptr: *std.atomic.Value(bool)) void {
    bridge_cancel_ptr = cancel_ptr;
}
