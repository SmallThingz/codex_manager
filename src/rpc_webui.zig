const std = @import("std");
const webui = @import("webui");
const rpc = @import("rpc.zig");

const RawJson = struct {
    data: []const u8,
    owned: bool = false,

    /// Emits the already-serialized JSON payload directly into webui's JSON writer.
    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        defer if (self.owned) std.heap.page_allocator.free(self.data);
        try jws.beginWriteRaw();
        try jws.writer.writeAll(self.data);
        jws.endWriteRaw();
    }
};

pub const RpcBridgeMethods = struct {
    /// Dispatches a bridge RPC call through the backend and hands ownership of the serialized JSON
    /// buffer to `jsonStringify`, which frees it after webui has consumed the payload.
    pub fn cm_rpc(request: rpc.RpcRequest) RawJson {
        const cancel_ptr = bridge_cancel_ptr orelse {
            return .{ .data = "{\"error\":\"RPC bridge not initialized\"}" };
        };

        const rpc_response = rpc.handleRpcRequest(std.heap.page_allocator, request, cancel_ptr) catch {
            return .{ .data = "{\"error\":\"internal RPC failure\"}" };
        };
        return .{
            .data = rpc_response,
            .owned = true,
        };
    }
};

var bridge_cancel_ptr: ?*std.atomic.Value(bool) = null;
var bridge_service: ?*webui.Service = null;

/// Pushes a completed usage-refresh payload to all connected frontend clients over webui's WS
/// frontend-RPC channel.
fn pushUsageRefreshCompletion(_: ?*anyopaque, payload_json: []const u8) void {
    const service = bridge_service orelse return;
    service.callFrontendAll("cm.handleUsageRefreshCompletion", .{payload_json}) catch |err| switch (err) {
        error.NoTargetConnections => {},
        else => {},
    };
}

/// Registers the cancellation flag shared with the OAuth callback listener thread.
pub fn setCancelPointer(cancel_ptr: *std.atomic.Value(bool)) void {
    bridge_cancel_ptr = cancel_ptr;
}

/// Registers the active webui service so backend workers can push completion events to the page.
pub fn setService(service: ?*webui.Service) void {
    bridge_service = service;
    rpc.setUsageRefreshNotifier(if (service != null) pushUsageRefreshCompletion else null, null);
}

/// Forwards the captured process environment map into the RPC layer used by the bridge.
pub fn setEnvironMap(environ_map: *std.process.Environ.Map) void {
    rpc.setEnvironMap(environ_map);
}
