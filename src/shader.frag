#version 450

layout(location = 0) in vec3 vert_pos;
layout(location = 0) out vec4 out_color;

void main() {
    vec3 color = vec3(vert_pos.xy * 0.5 + 0.5, 1.0);
    out_color = vec4(color, 1.0);
}
