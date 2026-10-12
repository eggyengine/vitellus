//! WebGPU backend for the browser, on Emscripten's `emdawnwebgpu` port.
//!
//! WebGPU's adapter, device and completion requests are asynchronous. The backend blocks on
//! them with `wgpuInstanceWaitAny`, which in the browser needs the app linked with
//! `-sASYNCIFY` (or `-sJSPI`).
//!
//! Present is implicit: the browser shows the canvas texture once control returns to it, so
//! `present` only releases the frame's texture. Barriers, semaphores and command pools have
//! no WebGPU counterpart and are no-ops; queue order already serialises the work.

pub const utils = @import("webgpu/utils.zig");
pub const instance = @import("webgpu/instance.zig");
pub const adapter = @import("webgpu/adapter.zig");
pub const device = @import("webgpu/device.zig");
pub const shader = @import("webgpu/shader.zig");
pub const resource = @import("webgpu/resource.zig");
pub const queue = @import("webgpu/queue.zig");
pub const sync = @import("webgpu/sync.zig");
pub const swapchain = @import("webgpu/swapchain.zig");
pub const command = @import("webgpu/command.zig");

pub const createInstance = instance.createInstance;
