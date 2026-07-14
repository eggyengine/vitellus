struct VertexOutput {
    float4 position : SV_Position;
    float3 color : COLOR0;
};

VertexOutput vsMain(uint vertex_id : SV_VertexID) {
    const float2 positions[3] = {
        float2( 0.0,  0.6),
        float2( 0.6, -0.6),
        float2(-0.6, -0.6),
    };

    const float3 colors[3] = {
        float3(1.0, 0.1, 0.1),
        float3(0.1, 1.0, 0.1),
        float3(0.1, 0.3, 1.0),
    };

    VertexOutput output;
    output.position = float4(positions[vertex_id], 0.0, 1.0);
    output.color = colors[vertex_id];
    return output;
}

float4 psMain(VertexOutput input) : SV_Target0 {
    return float4(input.color, 1.0);
}

