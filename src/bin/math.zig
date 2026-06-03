const emath = @import("eggenvector");

pub const Transform = struct {
    position: emath.Vec3 = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
    rotation: emath.Quat = emath.Quat.identity(),

    pub fn toMatrix(self: @This()) emath.Mat4 {
        const rot = self.rotation.toMatrix();
        const trans = emath.translation4x4(f32, self.position.x, self.position.y, self.position.z);
        return emath.multiply4x4(f32, trans, rot);
    }

    pub fn toViewMatrix(self: @This()) emath.Mat4 {
        const inv_rot = self.rotation.conjugate().toMatrix();
        const inv_trans = emath.translation4x4(f32, -self.position.x, -self.position.y, -self.position.z);
        return emath.multiply4x4(f32, inv_rot, inv_trans);
    }
};
