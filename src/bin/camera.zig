const vit = @import("vitellus");
const std = @import("std");
const sdl3 = @import("sdl3");
const emath = @import("eggenvector");
const Transform = @import("math.zig").Transform;

pub const InputState = struct {
    forward: bool = false,
    backward: bool = false,
    left: bool = false,
    right: bool = false,
    up: bool = false,
    down: bool = false,
    sprint: bool = false,
    mouse_look: bool = false,
};

pub const UniformBufferObject = struct { model: emath.Mat4, view: emath.Mat4, proj: emath.Mat4 };

pub const camera_descriptor_set_layout_entry = vit.DescriptorSetLayout.Entry{
    .binding = 0,
    .visibility = vit.DescriptorSetLayout.ShaderStage.VERTEX,
    .buffer = .{
        .type = .uniform,
        .hasDynamicOffset = false,
        .minBindingSize = @sizeOf(UniformBufferObject),
    },
};

pub fn setCameraKey(input: *InputState, scan: sdl3.Scancode, is_down: bool) void {
    switch (scan) {
        .w => input.forward = is_down,
        .s => input.backward = is_down,
        .a => input.left = is_down,
        .d => input.right = is_down,
        .space, .e => input.up = is_down,
        .q => input.down = is_down,
        .left_shift, .right_shift => input.sprint = is_down,
        else => {},
    }
}

pub const Camera = struct {
    transform: Transform = .{ .position = .{ .x = 0.0, .y = 0.0, .z = 2.0 } },
    fov_y: f32 = std.math.pi / 4.0,
    near: f32 = 0.1,
    far: f32 = 10.0,
    yaw: f32 = 0.0,
    pitch: f32 = 0.0,
    move_speed: f32 = 2.5,
    sprint_multiplier: f32 = 3.0,
    mouse_sensitivity: f32 = 0.0025,

    pub fn update(self: *@This(), input: InputState, dt: f32) void {
        var direction = emath.Vec3.zero;

        if (input.forward) direction = direction.add(emath.Vec3.forward);
        if (input.backward) direction = direction.add(emath.Vec3.back);
        if (input.left) direction = direction.add(emath.Vec3.left);
        if (input.right) direction = direction.add(emath.Vec3.right);
        if (input.up) direction = direction.add(emath.Vec3.up);
        if (input.down) direction = direction.add(emath.Vec3.down);

        if (direction.lengthSquared() > 0.0) {
            const speed = self.move_speed * if (input.sprint) self.sprint_multiplier else 1.0;
            const delta = self.transform.rotation.rotateVector(direction.normalize()).scale(speed * dt);
            self.transform.position = self.transform.position.add(delta);
        }
    }

    pub fn look(self: *@This(), x_rel: f32, y_rel: f32) void {
        self.yaw -= x_rel * self.mouse_sensitivity;
        self.pitch -= y_rel * self.mouse_sensitivity;
        self.pitch = std.math.clamp(self.pitch, -std.math.pi / 2.0 + 0.01, std.math.pi / 2.0 - 0.01);

        const yaw_rotation = emath.Quat.fromAxisAngle(emath.Vec3.up, self.yaw);
        const pitch_rotation = emath.Quat.fromAxisAngle(emath.Vec3.right, self.pitch);
        self.transform.rotation = yaw_rotation.mul(pitch_rotation).normalize();
    }

    pub fn uniforms(self: @This(), model_transform: Transform, width: u32, height: u32) UniformBufferObject {
        const aspect = if (height == 0) 1.0 else @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
        return .{
            .model = model_transform.toMatrix(),
            .view = self.transform.toViewMatrix(),
            .proj = emath.perspective(self.fov_y, aspect, self.near, self.far),
        };
    }
};

pub fn createResources(state: anytype, texture_layout_entry: *const vit.DescriptorSetLayout.Entry) !void {
    state.camera_descriptor_set_layout = try state.device.createDescriptorSetLayout(.{
        .label = "camera descriptor set layout",
        .entries = &.{ &camera_descriptor_set_layout_entry, texture_layout_entry },
    });
    errdefer state.camera_descriptor_set_layout.deinit();

    var uniform_buffer = try state.device.createBuffer(.{
        .label = "Camera Uniform Buffer",
        .size = @sizeOf(UniformBufferObject),
        .usage = vit.Buffer.Usage.UNIFORM | vit.Buffer.Usage.COPY_DST,
        .mappedAtCreation = false,
    });

    errdefer uniform_buffer.deinit();

    const initial_ubo = state.camera.uniforms(state.model_transform, state.config.width, state.config.height);
    const initial_bytes = std.mem.asBytes(&initial_ubo);
    state.queue.writeBuffer(&uniform_buffer, 0, initial_bytes[0..], 0, null);
    state.uniform_buffer = uniform_buffer;

    state.descriptor_set = try state.device.createDescriptorSet(.{
        .label = "camera descriptor set",
        .layout = &state.camera_descriptor_set_layout,
        .entries = &.{ .{
            .binding = 0,
            .resource = .{ .bufferBinding = .{ .buffer = &state.uniform_buffer } },
        }, .{
            .binding = 1,
            .resource = .{ .combinedImageSampler = .{
                .view = &state.tex.view,
                .sampler = &state.tex.sampler,
            } },
        } },
    });
}
