const std = @import("std");
const c = @import("spirv_cross");
const errors = @import("error.zig");
pub const hlsl = @import("compilers/hlsl.zig");

pub const SPIRVcError = errors.SPIRVcError;
pub const check = errors.check;

pub const Backend = struct {
    pub const None = BackendType(c.SPVC_BACKEND_NONE, Compiler);
    pub const Glsl = BackendType(c.SPVC_BACKEND_GLSL, Compiler);
    pub const Hlsl = BackendType(c.SPVC_BACKEND_HLSL, hlsl.Compiler);
    pub const Msl = BackendType(c.SPVC_BACKEND_MSL, Compiler);
    pub const Cpp = BackendType(c.SPVC_BACKEND_CPP, Compiler);
    pub const Json = BackendType(c.SPVC_BACKEND_JSON, Compiler);

    pub const GLSL = Glsl;
    pub const HLSL = Hlsl;
    pub const MSL = Msl;
    pub const CPP = Cpp;
    pub const JSON = Json;
};

fn BackendType(comptime c_backend: c.spvc_backend, comptime CompilerType: type) type {
    return struct {
        pub const backend = c_backend;
        pub const Compiler = CompilerType;
    };
}

pub fn backendToC(comptime BackendType_: type) c.spvc_backend {
    if (!@hasDecl(BackendType_, "backend")) {
        @compileError("backend type must declare `pub const backend: c.spvc_backend`");
    }

    return BackendType_.backend;
}

pub fn CompilerFor(comptime BackendType_: type) type {
    if (!@hasDecl(BackendType_, "Compiler")) {
        @compileError("backend type must declare `pub const Compiler: type`");
    }

    return BackendType_.Compiler;
}

pub const CaptureMode = enum(c.spvc_capture_mode) {
    copy = c.SPVC_CAPTURE_MODE_COPY,
    take_ownership = c.SPVC_CAPTURE_MODE_TAKE_OWNERSHIP,

    pub fn toC(self: CaptureMode) c.spvc_capture_mode {
        return @intFromEnum(self);
    }
};

pub const Compiler = struct {
    inner: c.spvc_compiler = undefined,
};

pub const HLSLCompiler = hlsl.Compiler;

test "backend types expose compiler wrappers" {
    try std.testing.expectEqual(@as(c.spvc_backend, c.SPVC_BACKEND_HLSL), backendToC(Backend.Hlsl));
    try std.testing.expect(@hasDecl(CompilerFor(Backend.Hlsl), "setRootConstantsLayout"));
}
