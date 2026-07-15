//! Shader stages, binary formats, and pluggable compilation modules.

const std = @import("std");
const Backend = @import("settings.zig").Backend;

/// Programmable pipeline stage targeted by a shader.
pub const ShaderStage = enum {
    vertex,
    fragment,
    compute,
};

/// Backend-ready shader binary representation.
pub const ShaderBinaryFormat = enum {
    dxil,
    spirv,
    metallib,
};

/// Information supplied by the selected graphics backend to a shader module.
pub const ShaderCompileRequest = struct {
    backend: Backend,
    stage: ShaderStage,
    label: ?[]const u8 = null,
};

/// Backend-ready shader code returned by a `ShaderModule`.
///
/// `bytes` must be allocated with the allocator passed to `ShaderModule.compile`.
/// The graphics backend owns the result and calls `deinit` after consuming it.
/// `entry_point` remains borrowed from the module for that same duration.
pub const CompiledShader = struct {
    format: ShaderBinaryFormat,
    bytes: []u8,
    entry_point: []const u8 = "main",

    /// Frees the owned bytecode with the allocator used to compile it.
    pub fn deinit(self: CompiledShader, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

/// Type-erased shader compiler interface.
///
/// Modules are stored inline so temporary module values remain valid for the
/// duration of `createShader`. Custom implementations expose themselves with
/// `ShaderModule.init(value)` and implement this method:
///
/// ```zig
/// pub fn compile(
///     self: *const MyShaderModule,
///     allocator: std.mem.Allocator,
///     request: ShaderCompileRequest,
/// ) !CompiledShader
/// ```
pub const ShaderModule = struct {
    const inline_capacity = 64;
    const inline_alignment = 16;

    storage: [inline_capacity]u8 align(inline_alignment) = [_]u8{0} ** inline_capacity,
    vtable: *const VTable,

    pub const VTable = struct {
        compileFn: *const fn (
            context: *const anyopaque,
            allocator: std.mem.Allocator,
            request: ShaderCompileRequest,
        ) anyerror!CompiledShader,
    };

    /// Stores a compiler implementation inline, or stores a borrowed pointer
    /// when `value` is a pointer.
    pub fn init(value: anytype) ShaderModule {
        const T = @TypeOf(value);
        const Implementation = switch (@typeInfo(T)) {
            .pointer => |pointer| pointer.child,
            else => T,
        };

        comptime {
            if (@sizeOf(T) > inline_capacity) {
                @compileError("shader module is too large for inline storage; wrap it in a pointer");
            }
            if (@alignOf(T) > inline_alignment) {
                @compileError("shader module is over-aligned; wrap it in a pointer");
            }
            if (!@hasDecl(Implementation, "compile")) {
                @compileError("shader module must implement compile");
            }
        }

        const Adapter = struct {
            fn compile(
                context: *const anyopaque,
                allocator: std.mem.Allocator,
                request: ShaderCompileRequest,
            ) anyerror!CompiledShader {
                const module: *const T = @ptrCast(@alignCast(context));
                return module.*.compile(allocator, request);
            }
        };

        var result = ShaderModule{
            .vtable = &.{ .compileFn = Adapter.compile },
        };
        const context: *T = @ptrCast(@alignCast(&result.storage));
        context.* = value;
        return result;
    }

    /// Compiles this module for the backend and stage in `request`.
    pub fn compile(
        self: *const ShaderModule,
        allocator: std.mem.Allocator,
        request: ShaderCompileRequest,
    ) !CompiledShader {
        return self.vtable.compileFn(&self.storage, allocator, request);
    }
};

/// A convenient module for already compiled backend-specific shader code.
pub const BinaryShaderModule = struct {
    /// Borrowed precompiled shader data and its target backend.
    pub const Descriptor = struct {
        backend: Backend,
        format: ShaderBinaryFormat,
        bytes: []const u8,
        entry_point: []const u8 = "main",
    };

    const Context = struct {
        backend: Backend,
        format: ShaderBinaryFormat,
        bytes: []const u8,
        entry_point: []const u8,

        pub fn compile(
            self: *const Context,
            allocator: std.mem.Allocator,
            request: ShaderCompileRequest,
        ) anyerror!CompiledShader {
            if (request.backend != self.backend) return error.UnsupportedShaderBackend;
            return .{
                .format = self.format,
                .bytes = try allocator.dupe(u8, self.bytes),
                .entry_point = self.entry_point,
            };
        }
    };

    /// Wraps precompiled backend bytecode as a `ShaderModule`.
    pub fn init(desc: Descriptor) ShaderModule {
        return ShaderModule.init(Context{
            .backend = desc.backend,
            .format = desc.format,
            .bytes = desc.bytes,
            .entry_point = desc.entry_point,
        });
    }
};

/// Shader stage, optional debug label, and source compiler.
pub const ShaderDescriptor = struct {
    label: ?[]const u8 = null,
    stage: ShaderStage,
    source: ShaderModule,
};

/// Opaque backend shader handle.
pub const Shader = struct {
    handle: u64 = 0,

    pub fn destroy(self: Shader, device: anytype) void {
        device.destroyShader(self);
    }
};

test "custom shader modules compile through the interface vtable" {
    const CustomModule = struct {
        source: []const u8,

        pub fn compile(
            self: *const @This(),
            allocator: std.mem.Allocator,
            request: ShaderCompileRequest,
        ) !CompiledShader {
            try std.testing.expectEqual(Backend.vulkan, request.backend);
            try std.testing.expectEqual(ShaderStage.vertex, request.stage);
            return .{
                .format = .spirv,
                .bytes = try allocator.dupe(u8, self.source),
                .entry_point = "customMain",
            };
        }
    };

    const module = ShaderModule.init(CustomModule{ .source = "compiled" });
    var compiled = try module.compile(std.testing.allocator, .{
        .backend = .vulkan,
        .stage = .vertex,
    });
    defer compiled.deinit(std.testing.allocator);

    try std.testing.expectEqual(ShaderBinaryFormat.spirv, compiled.format);
    try std.testing.expectEqualStrings("compiled", compiled.bytes);
    try std.testing.expectEqualStrings("customMain", compiled.entry_point);
}

test "large custom shader modules can be borrowed by pointer" {
    const LargeModule = struct {
        payload: [128]u8,

        pub fn compile(
            self: *const @This(),
            allocator: std.mem.Allocator,
            _: ShaderCompileRequest,
        ) !CompiledShader {
            return .{
                .format = .dxil,
                .bytes = try allocator.dupe(u8, self.payload[0..4]),
            };
        }
    };

    const implementation = LargeModule{ .payload = [_]u8{7} ** 128 };
    const module = ShaderModule.init(&implementation);
    var compiled = try module.compile(std.testing.allocator, .{
        .backend = .dx12,
        .stage = .compute,
    });
    defer compiled.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &.{ 7, 7, 7, 7 }, compiled.bytes);
}
