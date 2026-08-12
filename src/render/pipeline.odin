package render

import "vendor:directx/d3d11"
import "vendor:directx/d3d_compiler"
import "core:log"

@(private)
SHADERS_DATA :: #load("shaders.hlsl")

Pipeline :: struct {
    vs:            ^d3d11.IVertexShader,
    ps:            ^d3d11.IPixelShader,
    input_layout:  ^d3d11.IInputLayout,
    vertex_buffer: ^d3d11.IBuffer,
    const_buffer:  ^d3d11.IBuffer,
    blend_state:   ^d3d11.IBlendState,
}

Quad_Constants :: struct {
    scale:  [2]f32,
    offset: [2]f32,
    color:  [4]f32,
}

create_pipeline :: proc(device: ^d3d11.IDevice) -> (Pipeline, bool) {
    p: Pipeline

    vs_blob, vs_ok := compile("vs_main", "vs_5_0")
    if !vs_ok do return p, false
    defer vs_blob->Release()

    ps_blob, ps_ok := compile("ps_main", "ps_5_0")
    if !ps_ok do return p, false
    defer ps_blob->Release()

    if hr := device->CreateVertexShader(vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), nil, &p.vs); hr != 0 {
        log.errorf("CreateVertexShader failed: HRESULT 0x%08X", u32(hr))
        destroy_pipeline(&p)
        return p, false
    }

    if hr := device->CreatePixelShader(ps_blob->GetBufferPointer(), ps_blob->GetBufferSize(), nil, &p.ps); hr != 0 {
        log.errorf("CreatePixelShader failed: HRESULT 0x%08X", u32(hr))
        destroy_pipeline(&p)
        return p, false
    }

    elements := [1]d3d11.INPUT_ELEMENT_DESC{
    {
        SemanticName      = "POSITION",
        SemanticIndex     = 0,
        Format            = .R32G32_FLOAT,
        InputSlot         = 0,
        AlignedByteOffset = 0,
        InputSlotClass    = .VERTEX_DATA,
        InstanceDataStepRate = 0,
    },
}

    if hr := device->CreateInputLayout(
        &elements[0], 1,
        vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(),
        &p.input_layout,
    ); hr != 0 {
        log.errorf("CreateInputLayout failed: HRESULT 0x%08X", u32(hr))
        destroy_pipeline(&p)
        return p, false
    }

    verts := [4][2]f32{
        {0, 0},
        {1, 0},
        {0, 1},
        {1, 1},
    }

    vb_desc := d3d11.BUFFER_DESC{
        ByteWidth = size_of(verts),
        Usage     = .IMMUTABLE,
        BindFlags = {.VERTEX_BUFFER},
    }
    vb_data := d3d11.SUBRESOURCE_DATA{ pSysMem = &verts[0] }

    if hr := device->CreateBuffer(&vb_desc, &vb_data, &p.vertex_buffer); hr != 0 {
        log.errorf("CreateBuffer(vertex) failed: HRESULT 0x%08X", u32(hr))
        destroy_pipeline(&p)
        return p, false
    }

    cb_desc := d3d11.BUFFER_DESC{
        ByteWidth      = size_of(Quad_Constants),
        Usage          = .DYNAMIC,
        BindFlags      = {.CONSTANT_BUFFER},
        CPUAccessFlags = {.WRITE},
    }

    if hr := device->CreateBuffer(&cb_desc, nil, &p.const_buffer); hr != 0 {
        log.errorf("CreateBuffer(constant, %v bytes) failed: HRESULT 0x%08X", size_of(Quad_Constants), u32(hr))
        destroy_pipeline(&p)
        return p, false
    }

    blend_desc := d3d11.BLEND_DESC{}
    blend_desc.RenderTarget[0] = {
        BlendEnable           = true,
        SrcBlend              = .SRC_ALPHA,
        DestBlend             = .INV_SRC_ALPHA,
        BlendOp               = .ADD,
        SrcBlendAlpha         = .ONE,
        DestBlendAlpha        = .INV_SRC_ALPHA,
        BlendOpAlpha          = .ADD,
        RenderTargetWriteMask = u8(d3d11.COLOR_WRITE_ENABLE_ALL),
    }

    if hr := device->CreateBlendState(&blend_desc, &p.blend_state); hr != 0 {
        log.errorf("CreateBlendState failed: HRESULT 0x%08X", u32(hr))
        destroy_pipeline(&p)
        return p, false
    }

    log.info("shaders created")
    return p, true
}

destroy_pipeline :: proc(p: ^Pipeline) {
    if p == nil { return }
    if p.blend_state != nil   { p.blend_state->Release();   p.blend_state = nil }
    if p.const_buffer != nil  { p.const_buffer->Release();  p.const_buffer = nil }
    if p.vertex_buffer != nil { p.vertex_buffer->Release(); p.vertex_buffer = nil }
    if p.input_layout != nil  { p.input_layout->Release();  p.input_layout = nil }
    if p.ps != nil            { p.ps->Release();            p.ps = nil }
    if p.vs != nil            { p.vs->Release();            p.vs = nil }
}

@(private)
compile :: proc(entry, profile: cstring) -> (^d3d11.IBlob, bool) {
    code, errors: ^d3d11.IBlob
    hr := d3d_compiler.Compile(
        raw_data(SHADERS_DATA), len(SHADERS_DATA),
        nil, nil, nil,
        entry, profile,
        0, 0, &code, &errors,
    )
    if hr != 0 {
        if errors != nil {
            msg := cstring(errors->GetBufferPointer())
            log.errorf("shader %v failed: %v", entry, msg)
            errors->Release()
        } else {
            log.errorf("shader %v failed: HRESULT 0x%08X", entry, u32(hr))
        }
        return nil, false
    }
    return code, true
}