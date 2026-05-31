const std = @import("std");
pub const c = @import("spirv_cross");

pub const context = @import("context.zig");
pub const compiler = @import("compiler.zig");
pub const hlsl = compiler.hlsl;

pub const Context = context.Context;
pub const Compiler = compiler.Compiler;

test {
    std.testing.refAllDecls(context);
    std.testing.refAllDecls(compiler);
}
