const vit = @import("vitellus");

pub const Vertex = struct {
    position: [3]f32,
    color: [3]f32,
    texCoord: [2]f32,

    pub fn desc() vit.VertexBufferLayout {
        return vit.VertexBufferLayout{
            .arrayStride = @sizeOf(Vertex),
            .stepMode = .vertex,
            .attributes = &.{
                vit.VertexAttribute{
                    .format = vit.VertexFormat.float32x3,
                    .offset = @offsetOf(Vertex, "position"),
                    .shaderLocation = 0,
                },
                vit.VertexAttribute{
                    .format = vit.VertexFormat.float32x3,
                    .offset = @offsetOf(Vertex, "color"),
                    .shaderLocation = 1,
                },
                vit.VertexAttribute{
                    .format = vit.VertexFormat.float32x2,
                    .offset = @offsetOf(Vertex, "texCoord"),
                    .shaderLocation = 2,
                },
            },
        };
    }
};

pub const VERTICES = [_]Vertex{
    // Front face
    .{ .position = .{ -0.5, -0.5, 0.5 }, .color = .{ 1.0, 0.0, 0.0 }, .texCoord = .{ 0.0, 1.0 } },
    .{ .position = .{ 0.5, -0.5, 0.5 }, .color = .{ 1.0, 0.0, 0.0 }, .texCoord = .{ 1.0, 1.0 } },
    .{ .position = .{ 0.5, 0.5, 0.5 }, .color = .{ 1.0, 0.0, 0.0 }, .texCoord = .{ 1.0, 0.0 } },
    .{ .position = .{ -0.5, 0.5, 0.5 }, .color = .{ 1.0, 0.0, 0.0 }, .texCoord = .{ 0.0, 0.0 } },

    // Back face
    .{ .position = .{ 0.5, -0.5, -0.5 }, .color = .{ 0.0, 1.0, 0.0 }, .texCoord = .{ 0.0, 1.0 } },
    .{ .position = .{ -0.5, -0.5, -0.5 }, .color = .{ 0.0, 1.0, 0.0 }, .texCoord = .{ 1.0, 1.0 } },
    .{ .position = .{ -0.5, 0.5, -0.5 }, .color = .{ 0.0, 1.0, 0.0 }, .texCoord = .{ 1.0, 0.0 } },
    .{ .position = .{ 0.5, 0.5, -0.5 }, .color = .{ 0.0, 1.0, 0.0 }, .texCoord = .{ 0.0, 0.0 } },

    // Top face
    .{ .position = .{ -0.5, 0.5, 0.5 }, .color = .{ 0.0, 0.0, 1.0 }, .texCoord = .{ 0.0, 1.0 } },
    .{ .position = .{ 0.5, 0.5, 0.5 }, .color = .{ 0.0, 0.0, 1.0 }, .texCoord = .{ 1.0, 1.0 } },
    .{ .position = .{ 0.5, 0.5, -0.5 }, .color = .{ 0.0, 0.0, 1.0 }, .texCoord = .{ 1.0, 0.0 } },
    .{ .position = .{ -0.5, 0.5, -0.5 }, .color = .{ 0.0, 0.0, 1.0 }, .texCoord = .{ 0.0, 0.0 } },

    // Bottom face
    .{ .position = .{ -0.5, -0.5, -0.5 }, .color = .{ 1.0, 1.0, 0.0 }, .texCoord = .{ 0.0, 1.0 } },
    .{ .position = .{ 0.5, -0.5, -0.5 }, .color = .{ 1.0, 1.0, 0.0 }, .texCoord = .{ 1.0, 1.0 } },
    .{ .position = .{ 0.5, -0.5, 0.5 }, .color = .{ 1.0, 1.0, 0.0 }, .texCoord = .{ 1.0, 0.0 } },
    .{ .position = .{ -0.5, -0.5, 0.5 }, .color = .{ 1.0, 1.0, 0.0 }, .texCoord = .{ 0.0, 0.0 } },

    // Right face
    .{ .position = .{ 0.5, -0.5, 0.5 }, .color = .{ 1.0, 0.0, 1.0 }, .texCoord = .{ 0.0, 1.0 } },
    .{ .position = .{ 0.5, -0.5, -0.5 }, .color = .{ 1.0, 0.0, 1.0 }, .texCoord = .{ 1.0, 1.0 } },
    .{ .position = .{ 0.5, 0.5, -0.5 }, .color = .{ 1.0, 0.0, 1.0 }, .texCoord = .{ 1.0, 0.0 } },
    .{ .position = .{ 0.5, 0.5, 0.5 }, .color = .{ 1.0, 0.0, 1.0 }, .texCoord = .{ 0.0, 0.0 } },

    // Left face
    .{ .position = .{ -0.5, -0.5, -0.5 }, .color = .{ 0.0, 1.0, 1.0 }, .texCoord = .{ 0.0, 1.0 } },
    .{ .position = .{ -0.5, -0.5, 0.5 }, .color = .{ 0.0, 1.0, 1.0 }, .texCoord = .{ 1.0, 1.0 } },
    .{ .position = .{ -0.5, 0.5, 0.5 }, .color = .{ 0.0, 1.0, 1.0 }, .texCoord = .{ 1.0, 0.0 } },
    .{ .position = .{ -0.5, 0.5, -0.5 }, .color = .{ 0.0, 1.0, 1.0 }, .texCoord = .{ 0.0, 0.0 } },
};

pub const INDICES = [_]u16{
    // Front
    0,  1,  2,  0,  2,  3,
    // Back
    4,  5,  6,  4,  6,  7,
    // Top
    8,  9,  10, 8,  10, 11,
    // Bottom
    12, 13, 14, 12, 14, 15,
    // Right
    16, 17, 18, 16, 18, 19,
    // Left
    20, 21, 22, 20, 22, 23,
};
