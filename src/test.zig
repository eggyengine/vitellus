const vit = @import("root.zig");
const std = @import("std");

var io: std.Io = std.testing.io;
var adapter: vit.Adapter = undefined;
var device: vit.Device = undefined;

fn setup() !void {
    var adapterF = vit.GPU.requestAdapter(io, .{});
    defer _ = adapterF.cancel(io) catch {};
    adapter = try adapterF.await(io);

    var deviceF = adapter.requestDevice(io, .{});
    defer _ = deviceF.cancel(io) catch {};
    device = try deviceF.await(io);
}

test "example 4.5" {
    // the exact same code as setup()
    var adapterF = vit.GPU.requestAdapter(io, .{});
    defer _ = adapterF.cancel(io) catch {};
    adapter = try adapterF.await(io);

    var deviceF = adapter.requestDevice(io, .{});
    defer _ = deviceF.cancel(io) catch {};
    device = try deviceF.await(io);
}

test "example 8.4" {
    try setup();

    const entry0 = vit.BindGroupLayout.Entry{
        .binding = 0,
        .visibility = vit.BindGroupLayout.ShaderStage.VERTEX |
            vit.BindGroupLayout.ShaderStage.FRAGMENT,
        .buffer = .{},
    };

    const entry1 = vit.BindGroupLayout.Entry{
        .binding = 1,
        .visibility = vit.BindGroupLayout.ShaderStage.FRAGMENT,
        .texture = .{},
    };

    const entry2 = vit.BindGroupLayout.Entry{
        .binding = 2,
        .visibility = vit.BindGroupLayout.ShaderStage.FRAGMENT,
        .sampler = .{},
    };

    const entries = [_]*const vit.BindGroupLayout.Entry{
        &entry0,
        &entry1,
        &entry2,
    };

    const bind_group_layout = device.createBindGroupLayout(.{
        .entries = &entries,
    });

    var buffer: vit.Buffer = undefined;
    var texture: vit.Texture = undefined;
    var sampler = device.createSampler(null);

    const bind_group_entry0 = vit.BindGroup.Entry{
        .binding = 0,
        .resource = .{ .bufferBinding = .{ .buffer = &buffer } },
    };

    const bind_group_entry1 = vit.BindGroup.Entry{
        .binding = 1,
        .resource = .{ .texture = &texture },
    };

    const bind_group_entry2 = vit.BindGroup.Entry{
        .binding = 2,
        .resource = .{ .sampler = &sampler },
    };

    const bind_group_entries = [_]vit.BindGroup.Entry{
        bind_group_entry0,
        bind_group_entry1,
        bind_group_entry2,
    };

    const bind_group = device.createBindGroup(.{
        .layout = &bind_group_layout,
        .entries = &bind_group_entries,
    });

    const bind_group_layouts = [_]?*const vit.BindGroupLayout{
        &bind_group_layout,
    };

    const pipeline_layout = device.createPipelineLayout(.{
        .bindGroupLayouts = &bind_group_layouts,
    });

    _ = bind_group;
    _ = pipeline_layout;
}

test "example 26" {
    try setup();

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

    const shader_module = device.createShaderModule(.{ .code = shader_content });
    _ = shader_module;
}
