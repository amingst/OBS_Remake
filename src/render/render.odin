package render

import "core:log"
import "vendor:directx/d3d11"

Target :: struct {
    texture: ^d3d11.ITexture2D,
    rtv:     ^d3d11.IRenderTargetView,
    srv:     ^d3d11.IShaderResourceView,
    staging: ^d3d11.ITexture2D,
    width, height: u32,
}

Quad :: struct {
    x, y, w, h: f32,
    color:      [4]f32,
    texture: ^d3d11.IShaderResourceView
}

create_target :: proc(device: ^d3d11.IDevice, w, h: u32) -> (Target, bool) {
    desc := d3d11.TEXTURE2D_DESC{
        Width      = w,
        Height     = h,
        MipLevels  = 1,
        ArraySize  = 1,
        Format     = .B8G8R8A8_UNORM,
        SampleDesc = {Count = 1},
        Usage      = .DEFAULT,
        BindFlags  = {.RENDER_TARGET, .SHADER_RESOURCE},
    }

    // Separate CPU-readable copy for encoder readback: a DEFAULT-usage render
    // target can't be Mapped, so frames go CopyResource -> staging -> Map.
    staging_desc := d3d11.TEXTURE2D_DESC{
        Width      = w,
        Height     = h,
        MipLevels  = 1,
        ArraySize  = 1,
        Format     = .B8G8R8A8_UNORM,
        SampleDesc = {Count = 1},
        Usage      = .STAGING,
        // Staging resources can't be bound to the pipeline, so no BindFlags.
        CPUAccessFlags = {.READ},
    }

    target := Target{width = w, height = h}

    if hr := device->CreateTexture2D(&desc, nil, &target.texture); hr != 0 {
        log.errorf("CreateTexture2D(%vx%v) failed: 0x%08X", w, h, u32(hr))
        destroy_target(&target)
        return {}, false
    }

    if hr := device->CreateTexture2D(&staging_desc, nil, &target.staging); hr != 0 {
        log.errorf("staging CreateTexture2D(%vx%v) failed: 0x%08X", w, h, u32(hr))
        destroy_target(&target)
        return {}, false
    }

    if hr := device->CreateRenderTargetView((^d3d11.IResource)(target.texture), nil, &target.rtv); hr != 0 {
        log.errorf("CreateRenderTargetView failed: HRESULT 0x%08X (BindFlags may be missing RENDER_TARGET)", u32(hr))
        destroy_target(&target)
        return {}, false
    }

    if hr := device->CreateShaderResourceView((^d3d11.IResource)(target.texture), nil, &target.srv); hr != 0 {
        log.errorf("CreateShaderResourceView failed: HRESULT 0x%08X (BindFlags may be missing SHADER_RESOURCE)", u32(hr))
        destroy_target(&target)
        return {}, false
    }

    log.infof("render target created: %vx%v .B8G8R8A8_UNORM", w, h)
    return target, true
}

destroy_target :: proc(target: ^Target) {
    if target == nil { return }
    log.debugf("releasing render target (%vx%v)", target.width, target.height)
    
    if target.staging != nil {
        target.staging->Release()
        target.staging = nil
    }
    
    if target.srv != nil {
        target.srv->Release()
        target.srv = nil
    }
    if target.rtv != nil {
        target.rtv->Release()
        target.rtv = nil
    }
    if target.texture != nil {
        target.texture->Release()
        target.texture = nil
    }
}

@(private) _draw_scene_warned := false

draw_scene :: proc(ctx: ^d3d11.IDeviceContext, target: ^Target, pipeline: ^Pipeline, quads: []Quad, clear: [4]f32) {
    if ctx == nil || target == nil || target.rtv == nil {
        if !_draw_scene_warned {
            log.error("draw_scene: skipping draw (nil context, target, or rtv)")
            _draw_scene_warned = true
        }
        return
    }
    _draw_scene_warned = false

    color := clear
    ctx->OMSetRenderTargets(1, &target.rtv, nil)
    ctx->ClearRenderTargetView(target.rtv, &color)

    vp := d3d11.VIEWPORT{
        Width    = f32(target.width),
        Height   = f32(target.height),
        MinDepth = 0,
        MaxDepth = 1,
    }
    ctx->RSSetViewports(1, &vp)

    ctx->IASetInputLayout(pipeline.input_layout)
    stride := u32(size_of(Vertex))
    offset := u32(0)
    ctx->IASetVertexBuffers(0, 1, &pipeline.vertex_buffer, &stride, &offset)
    ctx->IASetPrimitiveTopology(.TRIANGLESTRIP)
    ctx->VSSetShader(pipeline.vs, nil, 0)
    ctx->PSSetShader(pipeline.ps, nil, 0)
    ctx->VSSetConstantBuffers(0, 1, &pipeline.const_buffer)
    ctx->PSSetConstantBuffers(0, 1, &pipeline.const_buffer)
    blend_factor := [4]f32{0, 0, 0, 0}
    ctx->OMSetBlendState(pipeline.blend_state, &blend_factor, 0xFFFFFFFF)
    ctx->PSSetSamplers(0, 1, &pipeline.sampler)

    W := f32(target.width)
    H := f32(target.height)
    for quad in quads {
        // log.debugf("quad x=%v y=%v w=%v h=%v color=%v", quad.x, quad.y, quad.w, quad.h, quad.color)
        consts := Quad_Constants{
            scale  = { 2 * quad.w / W, -2 * quad.h / H },
            offset = { 2 * quad.x / W - 1, 1 - 2 * quad.y / H },
            color  = quad.color,
        }

        mapped: d3d11.MAPPED_SUBRESOURCE
        if hr := ctx->Map(pipeline.const_buffer, 0, .WRITE_DISCARD, {}, &mapped); hr != 0 {
            continue
        }
        (^Quad_Constants)(mapped.pData)^ = consts
        ctx->Unmap(pipeline.const_buffer, 0)

        srv := quad.texture
        if srv == nil do srv = pipeline.white_srv
        ctx->PSSetShaderResources(0, 1, &srv)
        ctx->Draw(4, 0)
    }
}

read_target :: proc(
    ctx: ^d3d11.IDeviceContext,
    target: ^Target,
    dst: []u8,
    flip_vertical := false,
) -> bool {
    if target.staging == nil do return false

    row_bytes := int(target.width) * 4
    if len(dst) < row_bytes * int(target.height) {
        log.errorf("read_target: dst too small (%v bytes, need %v)",
            len(dst), row_bytes * int(target.height))
        return false
    }

    ctx->CopyResource(
        (^d3d11.IResource)(target.staging),
        (^d3d11.IResource)(target.texture)
    )
    mapped: d3d11.MAPPED_SUBRESOURCE
    if hr := ctx->Map(
        (^d3d11.IResource)(target.staging),
        0,
        .READ,
        {},
        &mapped
    ); hr < 0 {
        log.errorf("Map(staging) failed: 0x%08X", u32(hr))
        return false
    }
    defer ctx->Unmap((^d3d11.IResource)(target.staging), 0)

    // RowPitch is not necessarily width*4 -- D3D pads rows for alignment, so
    // copying the whole thing in one memcpy would shear the image. Flipping
    // costs nothing extra here since the loop already goes row by row --
    // just write row y to height-1-y instead of y.
    src := ([^]u8)(mapped.pData)
    for y in 0..<int(target.height) {
        src_off := y * int(mapped.RowPitch)
        dst_row := flip_vertical ? int(target.height) - 1 - y : y
        dst_off := dst_row * row_bytes
        copy(dst[dst_off:dst_off+row_bytes], src[src_off:src_off+row_bytes])
    }

    return true
}