#version 450

layout(location = 0) out vec3 vert_pos;

vec2 vertices[3] = vec2[](
    vec2(-0.6, -0.6),
    vec2( 0.6, -0.6),
    vec2( 0.0,  0.6)
);

void main() {
    vec2 position = vertices[gl_VertexIndex];
    gl_Position = vec4(position, 0.0, 1.0);
    vert_pos = vec3(position, 0.0);
}
