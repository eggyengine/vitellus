---
sidebar_position: 3
title: Synchronisation
---

# Synchronisation

Vitellus has two synchronisation primitives:

- **`Semaphore`** orders work on the GPU. Use it between swapchain acquire, queue submission and present.
- **`Fence`** is a timeline fence that the CPU can wait on. Its value only goes up. A submission can signal it to a new value, and `fence.wait(value, timeout_ns)` blocks the CPU until the fence reaches that value.

## Frames in flight

The [triangle guide](../guide/first-triangle.md) calls `queue.waitIdle()` every frame, so the CPU sits idle while the GPU draws. To avoid that, give each frame in flight its own command pool and acquire semaphore. Then number your submissions on a single timeline fence:

```zig
const frames_in_flight = 2;

const FrameSlot = struct {
    pool: vit.CommandPool,
    acquired: vit.Semaphore,
    cmd: ?vit.CommandBuffer = null,
    /// Timeline value of the last submission that used this slot.
    frame: u64 = 0,
};

var slots: [frames_in_flight]FrameSlot = ...;
var slot_index: usize = 0;
const gpu_done = try vit.Fence.init(device, .{});
var submitted: u64 = 0;

fn frame() !void {
    const slot = &slots[slot_index];

    // Wait for the GPU to finish the frame that used this slot last.
    _ = try gpu_done.wait(slot.frame, null);
    if (slot.cmd) |old| old.deinit();
    slot.cmd = null;
    try slot.pool.reset();

    const image = try swapchain.acquireNextImage(slot.acquired);
    const cmd = try vit.CommandBuffer.init(slot.pool, .{});
    slot.cmd = cmd;
    // ... record ...
    try cmd.finish();

    submitted += 1;
    try queue.submit(.{
        .command_buffers = &.{cmd},
        .wait_semaphores = &.{slot.acquired},
        .signal_semaphores = &.{render_done[image.index]},
        .signal_fences = &.{.{ .fence = gpu_done, .value = submitted }},
    });
    slot.frame = submitted;
    slot_index = (slot_index + 1) % frames_in_flight;

    _ = try swapchain.present(&.{render_done[image.index]});
}
```

Any buffer that the CPU writes every frame, such as a uniform buffer, also needs one copy per slot. Otherwise you could overwrite data that the GPU is still reading.

## Rules of thumb

- Keep a command buffer alive until the fence value of its submission has passed.
- Before you resize a swapchain or destroy a resource that the GPU may still use, call `queue.waitIdle()`.
- Call `queue.waitIdle()` once more before shutdown, and only then start calling `deinit`.
