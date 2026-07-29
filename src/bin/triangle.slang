struct VertexOutput {
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
};

struct VertexInput {
    float2 position : TEXCOORD0;
    float2 uv : TEXCOORD1;
};

struct Scene {
    column_major float4x4 model;
    column_major float4x4 view;
    column_major float4x4 proj;
};

[[vk::binding(0, 0)]]
ConstantBuffer<Scene> scene;

[[vk::binding(1, 0)]]
Sampler2D image;

[shader("vertex")]
VertexOutput vsMain(VertexInput input) {
    VertexOutput output;

    float4 localPosition = float4(input.position, 0.0, 1.0);
    output.position =
        mul(scene.proj, mul(scene.view, mul(scene.model, localPosition)));

    output.uv = input.uv;
    return output;
}

[shader("fragment")]
float4 psMain(VertexOutput input) : SV_Target0 {
    return image.Sample(input.uv);
}
