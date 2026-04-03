const std = @import("std");
const rpc = @import("rpc.zig");

const RawJson = struct {
    data: []const u8,

    /// Emits the already-serialized JSON payload directly into webui's JSON writer.
    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginWriteRaw();
        try jws.writer.writeAll(self.data);
        jws.endWriteRaw();
    }
};

pub const RpcBridgeMethods = struct {
    /// Dispatches a bridge RPC call through the backend and copies the JSON result into a
    /// thread-local response buffer that webui can safely consume.
    pub fn cm_rpc(request: rpc.RpcRequest) RawJson {
        const cancel_ptr = bridge_cancel_ptr orelse {
            return .{ .data = "{\"error\":\"RPC bridge not initialized\"}" };
        };

        const rpc_response = rpc.handleRpcRequest(std.heap.page_allocator, request, cancel_ptr) catch {
            return .{ .data = "{\"error\":\"internal RPC failure\"}" };
        };
        defer std.heap.page_allocator.free(rpc_response);

        if (rpc_response.len > bridge_response_storage.len) {
            return .{ .data = "{\"error\":\"RPC response exceeds bridge buffer\"}" };
        }

        @memcpy(bridge_response_storage[0..rpc_response.len], rpc_response);
        bridge_response_len = rpc_response.len;
        return .{ .data = bridge_response_storage[0..bridge_response_len] };
    }
};

var bridge_cancel_ptr: ?*std.atomic.Value(bool) = null;
threadlocal var bridge_response_storage: [8 * 1024 * 1024]u8 = undefined;
threadlocal var bridge_response_len: usize = 0;

/// Registers the cancellation flag shared with the OAuth callback listener thread.
pub fn setCancelPointer(cancel_ptr: *std.atomic.Value(bool)) void {
    bridge_cancel_ptr = cancel_ptr;
}

/// Forwards the captured process environment map into the RPC layer used by the bridge.
pub fn setEnvironMap(environ_map: *std.process.Environ.Map) void {
    rpc.setEnvironMap(environ_map);
}
