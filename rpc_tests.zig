const std = @import("std");

test {
    std.testing.refAllDecls(@import("src/rpc.zig"));
}
