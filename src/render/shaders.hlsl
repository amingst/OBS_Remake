cbuffer QuadConstants : register(b0)
{
    float2 scale;
    float2 offset;
    float4 color;
};

Texture2D    tex  : register(t0);
SamplerState samp : register(s0);

struct VS_Input
{
    float2 pos : POSITION;
    float2 uv : TEXCOORD;
};

struct VS_Output
{
    float4 pos : SV_Position;
    float2 uv : TEXCOORD;
};

VS_Output vs_main(VS_Input input)
{
    VS_Output output;
    output.pos = float4(input.pos * scale + offset, 0.0, 1.0);
    output.uv = input.uv;
    return output;
}

float4 ps_main(VS_Output input) : SV_Target
{
    return tex.Sample(samp, input.uv) * color;
}