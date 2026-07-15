struct VertexInput {
    float2 position : TEXCOORD0;
    float3 color : TEXCOORD1;
};

struct VertexOutput {
    float4 position : SV_Position;
    float3 color : COLOR0;
};

cbuffer Scene : register(b0, space0) {
    float4 tint;
};

VertexOutput vsMain(VertexInput input) {
    VertexOutput output;
    output.position = float4(input.position, 0.0, 1.0);
    output.color = input.color;
    return output;
}

float4 psMain(VertexOutput input) : SV_Target0 {
    return float4(input.color, 1.0) * tint;
}

