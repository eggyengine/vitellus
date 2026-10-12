//! Zig 0.16 cannot compile its stderr writer for Emscripten, so the default log function and panic
//! handler fail to build there. Route both to the browser console from the root file:
//!
//!     pub const std_options = vit.web.std_options;
//!     pub const panic = vit.web.panic;
//!
//! On other targets both are Zig's defaults.
const std = @import("std");
const web = @import("builtin").os.tag == .emscripten;

pub const std_options: std.Options = if (web) .{ .logFn = consoleLog } else .{};
pub const panic = if (web) std.debug.FullPanic(consolePanic) else std.debug.FullPanic(std.debug.defaultPanic);

extern fn emscripten_console_log(message: [*:0]const u8) void;
extern fn emscripten_console_error(message: [*:0]const u8) void;

fn consoleLog(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    const prefix = "[" ++ @tagName(level) ++ "] " ++ (if (scope == .default) "" else @tagName(scope) ++ ": ");
    const message = std.fmt.bufPrintZ(&buffer, prefix ++ format, args) catch "[log message too long]";
    if (@intFromEnum(level) <= @intFromEnum(std.log.Level.warn)) emscripten_console_error(message) else emscripten_console_log(message);
}

fn consolePanic(message: []const u8, _: ?usize) noreturn {
    std.log.err("panic: {s}", .{message});
    @trap();
}
