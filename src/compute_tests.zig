//! Compute work of the kind training a model needs, run end to end on whichever backend is present.
const std = @import("std");
const vit = @import("vitellus");
const SlangShaderModule = @import("slangc.zig").SlangShaderModule;
const options = @import("slang_options");

// C = relu(A × B) for n×n matrices: a matmul tiled through workgroup memory, then an in-place
// pass over its output. Storage buffers are byte-address buffers (raw views on DirectX 12), and
// each binding's register matches its binding number, as Vitellus lays them out.
const source =
    \\struct Sizes { uint n; };
    \\[[vk::binding(0, 0)]] ConstantBuffer<Sizes> sizes : register(b0, space0);
    \\[[vk::binding(1, 0)]] ByteAddressBuffer a : register(t1, space0);
    \\[[vk::binding(2, 0)]] ByteAddressBuffer b : register(t2, space0);
    \\[[vk::binding(3, 0)]] RWByteAddressBuffer c : register(u3, space0);
    \\
    \\static const uint tile = 16;
    \\groupshared float tile_a[tile][tile];
    \\groupshared float tile_b[tile][tile];
    \\
    \\float load(ByteAddressBuffer m, uint row, uint column) {
    \\    uint n = sizes.n;
    \\    return row < n && column < n ? asfloat(m.Load((row * n + column) * 4)) : 0;
    \\}
    \\
    \\[shader("compute")] [numthreads(16, 16, 1)]
    \\void matmul(uint3 id : SV_DispatchThreadID, uint3 local : SV_GroupThreadID) {
    \\    uint n = sizes.n;
    \\    float sum = 0;
    \\    for (uint start = 0; start < n; start += tile) {
    \\        tile_a[local.y][local.x] = load(a, id.y, start + local.x);
    \\        tile_b[local.y][local.x] = load(b, start + local.y, id.x);
    \\        GroupMemoryBarrierWithGroupSync();
    \\        for (uint k = 0; k < tile; k++) sum += tile_a[local.y][k] * tile_b[k][local.x];
    \\        GroupMemoryBarrierWithGroupSync();
    \\    }
    \\    if (id.x < n && id.y < n) c.Store((id.y * n + id.x) * 4, asuint(sum));
    \\}
    \\
    \\[shader("compute")] [numthreads(64, 1, 1)]
    \\void relu(uint3 id : SV_DispatchThreadID) {
    \\    uint n = sizes.n;
    \\    if (id.x >= n * n) return;
    \\    c.Store(id.x * 4, asuint(max(asfloat(c.Load(id.x * 4)), 0.0)));
    \\}
;

test "a tiled matmul and an in-place pass over its output match the CPU" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const instance = vit.Instance.init(gpa, .{ .validation = .none }) catch return error.SkipZigTest;
    defer instance.deinit();
    const adapter = vit.Adapter.init(instance, .{}) catch return error.SkipZigTest;
    defer adapter.deinit();
    const device = try vit.Device.init(adapter, .{});
    defer device.deinit();
    const queue = try vit.Queue.init(device, .{});
    defer queue.deinit();

    // Inputs with negative products, so the ReLU pass changes something.
    const n = 64;
    var a: [n * n]f32 = undefined;
    var b: [n * n]f32 = undefined;
    for (&a, &b, 0..) |*x, *y, i| {
        x.* = (@as(f32, @floatFromInt(i % 7)) - 3) * 0.25;
        y.* = (@as(f32, @floatFromInt(i % 5)) - 2) * 0.5;
    }
    var expected: [n * n]f32 = undefined;
    for (0..n) |row| for (0..n) |column| {
        var sum: f32 = 0;
        for (0..n) |k| sum += a[row * n + k] * b[k * n + column];
        expected[row * n + column] = @max(sum, 0);
    };

    const sizes = [4]u32{ n, 0, 0, 0 };
    const uniform = try vit.Buffer.init(device, .{ .size = 256, .usage = .{ .uniform = true }, .memory = .upload, .initial_data = std.mem.asBytes(&sizes) });
    defer uniform.deinit();
    const a_buffer = try vit.Buffer.init(device, .{ .size = @sizeOf(@TypeOf(a)), .usage = .{ .storage = true }, .initial_data = std.mem.asBytes(&a) });
    defer a_buffer.deinit();
    const b_buffer = try vit.Buffer.init(device, .{ .size = @sizeOf(@TypeOf(b)), .usage = .{ .storage = true }, .initial_data = std.mem.asBytes(&b) });
    defer b_buffer.deinit();
    const c_buffer = try vit.Buffer.init(device, .{ .size = @sizeOf(@TypeOf(a)), .usage = .{ .storage = true, .transfer_src = true } });
    defer c_buffer.deinit();
    const readback = try vit.Buffer.init(device, .{ .size = @sizeOf(@TypeOf(a)), .usage = .{ .transfer_dst = true }, .memory = .readback });
    defer readback.deinit();

    const layout = try vit.hal.binding.BindGroupLayout.init(device, .{ .entries = &.{
        .{ .binding = 0, .kind = .{ .buffer = .{ .kind = .uniform } }, .visibility = .{ .compute = true } },
        .{ .binding = 1, .kind = .{ .buffer = .{ .kind = .storage_read } }, .visibility = .{ .compute = true } },
        .{ .binding = 2, .kind = .{ .buffer = .{ .kind = .storage_read } }, .visibility = .{ .compute = true } },
        .{ .binding = 3, .kind = .{ .buffer = .{ .kind = .storage_read_write } }, .visibility = .{ .compute = true } },
    } });
    defer layout.deinit();
    const group = try vit.hal.binding.BindGroup.init(device, .{ .layout = layout, .entries = &.{
        .{ .binding = 0, .resource = .{ .buffer = .{ .buffer = uniform } } },
        .{ .binding = 1, .resource = .{ .buffer = .{ .buffer = a_buffer } } },
        .{ .binding = 2, .resource = .{ .buffer = .{ .buffer = b_buffer } } },
        .{ .binding = 3, .resource = .{ .buffer = .{ .buffer = c_buffer } } },
    } });
    defer group.deinit();
    const pipeline_layout = try vit.PipelineLayout.init(device, .{ .bind_group_layouts = &.{layout} });
    defer pipeline_layout.deinit();

    const matmul_shader = try vit.Shader.init(device, .{ .stage = .compute, .source = SlangShaderModule.init(.{ .code = source, .entry_point = "matmul" }) });
    defer matmul_shader.deinit();
    const relu_shader = try vit.Shader.init(device, .{ .stage = .compute, .source = SlangShaderModule.init(.{ .code = source, .entry_point = "relu" }) });
    defer relu_shader.deinit();
    const matmul = try vit.ComputePipeline.init(device, .{ .compute = matmul_shader, .layout = pipeline_layout });
    defer matmul.deinit();
    const relu = try vit.ComputePipeline.init(device, .{ .compute = relu_shader, .layout = pipeline_layout });
    defer relu.deinit();

    const pool = try vit.CommandPool.init(device, .{});
    defer pool.deinit();
    const cmd = try vit.CommandBuffer.init(pool, .{});
    defer cmd.deinit();
    try cmd.barrier(&.{
        .{ .buffer = .{ .buffer = a_buffer, .before = .common, .after = .storage_read } },
        .{ .buffer = .{ .buffer = b_buffer, .before = .common, .after = .storage_read } },
        .{ .buffer = .{ .buffer = c_buffer, .before = .common, .after = .storage_write } },
    });
    try cmd.beginComputePass("matmul");
    cmd.setComputePipeline(matmul);
    cmd.setBindGroup(0, group, &.{});
    cmd.dispatch(n / 16, n / 16, 1);
    cmd.endComputePass();
    // The ReLU pass reads what the matmul wrote.
    try cmd.barrier(&.{.{ .buffer = .{ .buffer = c_buffer, .before = .storage_write, .after = .storage_write } }});
    try cmd.beginComputePass("relu");
    cmd.setComputePipeline(relu);
    cmd.setBindGroup(0, group, &.{});
    cmd.dispatch(n * n / 64, 1, 1);
    cmd.endComputePass();
    try cmd.barrier(&.{
        .{ .buffer = .{ .buffer = c_buffer, .before = .storage_write, .after = .copy_source } },
        .{ .buffer = .{ .buffer = readback, .before = .common, .after = .copy_destination } },
    });
    try cmd.copyBuffer(.{ .source = c_buffer, .destination = readback, .size = @sizeOf(@TypeOf(a)) });
    try cmd.barrier(&.{.{ .buffer = .{ .buffer = readback, .before = .copy_destination, .after = .host_read } }});
    try cmd.finish();
    try queue.submit(.{ .command_buffers = &.{cmd} });
    try queue.waitIdle();

    const read = try readback.map(.read, .{ .size = @sizeOf(@TypeOf(a)) });
    defer readback.unmap(null);
    const result = std.mem.bytesAsSlice(f32, read[0..@sizeOf(@TypeOf(a))]);
    for (expected, result) |want, got| try std.testing.expectApproxEqAbs(want, got, 1e-3);
}
