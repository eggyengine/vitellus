const std = @import("std");
const windows = std.os.windows;
const logz = @import("logz");

const c = @cImport({
    @cDefine("COBJMACROS", "1");
    @cDefine("WIN32_LEAN_AND_MEAN", "1");

    @cInclude("windows.h");
    @cInclude("d3d12.h");
    @cInclude("dxgi.h");
});

pub const HResultError = error{
    HResultFailed,
};

pub fn hr(
    result: c.HRESULT,
    comptime src: std.builtin.SourceLocation,
) HResultError!void {
    if (result >= 0) return;

    std.log.err("HRESULT failed at {s}:{d} in {s}: 0x{x:0>8}", .{
        src.file,
        src.line,
        src.fn_name,
        @as(u32, @bitCast(result)),
    });

    return error.HResultFailed;
}
