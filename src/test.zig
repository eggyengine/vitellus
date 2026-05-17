const vit = @import("root.zig");
const std = @import("std");
const candler = @import("candler");

var io: std.Io = std.testing.io;
var instance: vit.Instance = undefined;
var adapter: vit.Adapter = undefined;
var device: vit.Device = undefined;

const DummyWindow = struct {
    pub fn windowHandle(_: @This()) candler.HandleError!candler.WindowHandle {
        const ptr: *anyopaque = @ptrFromInt(1);
        return candler.WindowHandle.borrowRaw(candler.WaylandWindowHandle.new(ptr).intoRaw());
    }

    pub fn displayHandle(_: @This()) candler.HandleError!candler.DisplayHandle {
        const ptr: *anyopaque = @ptrFromInt(1);
        return candler.DisplayHandle.borrowRaw(candler.WaylandDisplayHandle.new(ptr).intoRaw());
    }
};

fn setup() !void {
    instance = try vit.Instance.initFromPotentialBackends(.{ .noop = true }, .{ .allocator = std.testing.allocator });

    // const surface = instance.createSurface(vit.windowing.sdl3.Sdl3Window.init(window: (unknown type)))

    var adapterF = instance.requestAdapter(io, .{});
    defer _ = adapterF.cancel(io) catch {};
    adapter = try adapterF.await(io);

    var deviceF = adapter.requestDevice(io, .{});
    defer _ = deviceF.cancel(io) catch {};
    device, _ = try deviceF.await(io);
}

fn teardown() void {
    device.destroy();
    instance.deinit();
}

test "example 4.5" {
    // the exact same code as setup()
    instance = try vit.Instance.initFromPotentialBackends(.{ .noop = true }, .{ .allocator = std.testing.allocator });
    defer instance.deinit();

    var adapterF = instance.requestAdapter(io, .{});
    defer _ = adapterF.cancel(io) catch {};
    adapter = try adapterF.await(io);

    var deviceF = adapter.requestDevice(io, .{});
    defer _ = deviceF.cancel(io) catch {};
    device, _ = try deviceF.await(io);
    defer device.destroy();
}

test "enumerate adapters and filter by surface support" {
    instance = try vit.Instance.initFromPotentialBackends(.{ .noop = true }, .{
        .allocator = std.testing.allocator,
    });
    defer instance.deinit();

    var surface = try instance.createSurface(DummyWindow{});
    defer surface.deinit();

    const adapters = try instance.enumerateAdapters(.{});
    defer std.testing.allocator.free(adapters);

    var supported: ?vit.Adapter = null;
    for (adapters) |candidate| {
        if (candidate.isSurfaceSupported(&surface)) {
            supported = candidate;
            break;
        }
    }

    try std.testing.expect(supported != null);
}

test "example 8.4" {
    try setup();
    defer teardown();

    const entries = [_]*const vit.BindGroupLayout.Entry{
        &.{
            .binding = 0,
            .visibility = vit.BindGroupLayout.ShaderStage.VERTEX |
                vit.BindGroupLayout.ShaderStage.FRAGMENT,
            .buffer = .{},
        },
        &.{
            .binding = 1,
            .visibility = vit.BindGroupLayout.ShaderStage.FRAGMENT,
            .texture = .{},
        },
        &.{
            .binding = 2,
            .visibility = vit.BindGroupLayout.ShaderStage.FRAGMENT,
            .sampler = .{},
        },
    };

    const bind_group_layout = device.createBindGroupLayout(.{
        .entries = &entries,
    });

    var buffer: vit.Buffer = undefined;
    var texture: vit.Texture = undefined;
    var sampler = device.createSampler(null);

    const bind_group = device.createBindGroup(.{
        .layout = &bind_group_layout,
        .entries = &.{ .{
            .binding = 0,
            .resource = .{ .bufferBinding = .{ .buffer = &buffer } },
        }, .{
            .binding = 1,
            .resource = .{ .texture = &texture },
        }, .{
            .binding = 2,
            .resource = .{ .sampler = &sampler },
        } },
    });

    const bind_group_layouts = [_]?*const vit.BindGroupLayout{
        &bind_group_layout,
    };

    var pipeline_layout = device.createPipelineLayout(.{
        .bindGroupLayouts = &bind_group_layouts,
    });
    defer pipeline_layout.destroy();

    _ = bind_group;
}

test "example 26" {
    try setup();
    defer teardown();

    const shader_content =
        \\\ var<private> pos : array<vec2<f32>, 3> = array<vec2<f32>, 3>(
        \\\    vec2(-1.0, -1.0), vec2(-1.0, 3.0), vec2(3.0, -1.0));
        \\\
        \\\ @vertex
        \\\ fn vertexMain(@builtin(vertex_index) vertexIndex : u32) -> @builtin(position) vec4<f32> {
        \\\     return vec4(pos[vertexIndex], 1.0, 1.0);
        \\\ }
        \\\
        \\\ @fragment
        \\\ fn fragmentMain() -> @location(0) vec4<f32> {
        \\\     return vec4(1.0, 0.0, 0.0, 1.0);
        \\\ }
    ;

    var shader_module = device.createShaderModule(.{ .code = shader_content });
    defer shader_module.destroy();
}
