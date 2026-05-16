const std = @import("std");

/// A test function with test documentation
pub fn hello() void {
    std.debug.print("Hello Splat!", .{});
}
