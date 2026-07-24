struct VertexInput {
    float2 position : TEXCOORD0;
    float2 uv : TEXCOORD1;
};

struct VertexOutput {
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
};

Sampler2D image;

[shader("vertex")]
VertexOutput vsMain(VertexInput input) {
    VertexOutput output;
    output.position = float4(input.position, 0.0, 1.0);
    output.uv = input.uv;
    return output;
}

[shader("fragment")]
float4 psMain(VertexOutput input) : SV_Target0 {
    return image.Sample(input.uv);
}
