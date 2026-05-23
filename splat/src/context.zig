const std = @import("std");
const c = @import("spirv_cross");

const compiler = @import("compiler.zig");
const errors = @import("error.zig");

pub const SPIRVcError = errors.SPIRVcError;
pub const check = errors.check;

pub const ParsedIr = struct {
    inner: c.spvc_parsed_ir,
};

pub const ParseSpirvError = SPIRVcError || std.Io.Reader.LimitedAllocError;

pub const Context = struct {
    inner: c.spvc_context = undefined,
    is_debug_callback_set: bool = false,

    pub fn init() SPIRVcError!Context {
        var self: @This() = undefined;
        const result = c.spvc_context_create(&self.inner);
        try check(result);

        c.spvc_context_set_error_callback(self.inner, defaultDebugCallback, null);
        self.is_debug_callback_set = true;

        return self;
    }

    pub fn deinit(self: *@This()) void {
        self.releaseAllocations();
        c.spvc_context_destroy(self.inner);
    }

    pub fn releaseAllocations(self: *@This()) void {
        c.spvc_context_release_allocations(self.inner);
    }

    pub fn parseSpirv(
        self: *@This(),
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
        limit: std.Io.Limit,
    ) ParseSpirvError!ParsedIr {
        const words = try readSpirvWords(allocator, reader, limit);
        defer allocator.free(words);

        return self.parseSpirvWords(words);
    }

    pub fn parseSpirvWords(self: *@This(), spirv: []const c.SpvId) SPIRVcError!ParsedIr {
        var parsed_ir: c.spvc_parsed_ir = undefined;

        try check(c.spvc_context_parse_spirv(
            self.inner,
            spirv.ptr,
            spirv.len,
            &parsed_ir,
        ));

        return .{
            .inner = parsed_ir,
        };
    }

    pub fn createCompiler(
        self: *@This(),
        comptime Backend: type,
        parsed_ir: ParsedIr,
        mode: compiler.CaptureMode,
    ) SPIRVcError!compiler.CompilerFor(Backend) {
        var comp: c.spvc_compiler = undefined;

        try check(c.spvc_context_create_compiler(
            self.inner,
            compiler.backendToC(Backend),
            parsed_ir.inner,
            mode.toC(),
            &comp,
        ));

        return .{ .inner = comp };
    }

    pub fn setDebugCallback(
        self: *@This(),
        comptime Userdata: type,
        userdata: *Userdata,
        comptime callback: fn (*Userdata, []const u8) void,
    ) void {
        const Trampoline = struct {
            fn call(raw_userdata: ?*anyopaque, raw_error: [*c]const u8) callconv(.c) void {
                const typed_userdata: *Userdata = @ptrCast(@alignCast(raw_userdata.?));
                callback(typed_userdata, std.mem.span(raw_error));
            }
        };

        c.spvc_context_set_error_callback(self.inner, Trampoline.call, userdata);
        self.is_debug_callback_set = true;
    }

    pub fn clearDebugCallback(self: *@This()) void {
        c.spvc_context_set_error_callback(self.inner, null, null);
        self.is_debug_callback_set = false;
    }
};

fn readSpirvWords(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    limit: std.Io.Limit,
) ParseSpirvError![]c.SpvId {
    const bytes = try reader.allocRemaining(allocator, limit);
    defer allocator.free(bytes);

    if (bytes.len % @sizeOf(c.SpvId) != 0) {
        return error.InvalidSpirv;
    }

    var byte_reader: std.Io.Reader = .fixed(bytes);
    const words = try allocator.alloc(c.SpvId, bytes.len / @sizeOf(c.SpvId));
    errdefer allocator.free(words);

    for (words) |*word| {
        word.* = byte_reader.takeInt(c.SpvId, .little) catch |err| switch (err) {
            error.EndOfStream => unreachable,
            error.ReadFailed => return error.ReadFailed,
        };
    }

    return words;
}

fn defaultDebugCallback(_: ?*anyopaque, raw_error: [*c]const u8) callconv(.c) void {
    std.debug.print("SPIRV-Cross: {s}\n", .{std.mem.span(raw_error)});
}

// --- tests ---

test "simple low-level" {
    var ctx: c.spvc_context = undefined;
    try std.testing.expectEqual(c.SPVC_SUCCESS, c.spvc_context_create(&ctx));
    defer c.spvc_context_destroy(ctx);
}

test "simple" {
    var ctx = try Context.init();
    defer ctx.deinit();
}

const DebugState = struct {
    called: bool = false,
    message: []const u8 = "",

    fn callback(self: *@This(), message: []const u8) void {
        self.called = true;
        self.message = message;
    }
};

test "debug callback" {
    var ctx = try Context.init();
    defer ctx.deinit();

    var state = DebugState{};
    ctx.setDebugCallback(DebugState, &state, DebugState.callback);
    ctx.clearDebugCallback();
}

test "read SPIR-V words from reader" {
    const bytes = [_]u8{
        0x03, 0x02, 0x23, 0x07,
        0x00, 0x00, 0x01, 0x00,
    };
    var reader: std.Io.Reader = .fixed(&bytes);

    const words = try readSpirvWords(std.testing.allocator, &reader, .unlimited);
    defer std.testing.allocator.free(words);

    try std.testing.expectEqualSlices(c.SpvId, &.{
        0x07230203,
        0x00010000,
    }, words);
}

test "reject partial SPIR-V word stream" {
    var reader: std.Io.Reader = .fixed(&.{ 0x03, 0x02, 0x23 });
    try std.testing.expectError(
        error.InvalidSpirv,
        readSpirvWords(std.testing.allocator, &reader, .unlimited),
    );
}
