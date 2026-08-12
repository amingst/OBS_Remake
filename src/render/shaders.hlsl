cbuffer QuadConstants : register(b0)
{
    float2 scale;
    float2 offset;
    float4 color;
};

struct VS_Input
{
    float2 pos : POSITION;
};

struct VS_Output
{
    float4 pos : SV_Position;
};

VS_Output vs_main(VS_Input input)
{
    VS_Output output;
    output.pos = float4(input.pos * scale + offset, 0.0, 1.0);
    return output;
}

float4 ps_main(VS_Output input) : SV_Target
{
    return color;
}