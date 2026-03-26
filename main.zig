const std = @import("std");
const app = @import("src/main.zig");

/// Forwards process startup into the application entry point in `src/main.zig`.
pub fn main(init: std.process.Init) !void {
    return app.main(init);
}
