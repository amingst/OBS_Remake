package render

import "core:fmt"
import "vendor:directx/d3d11"

Target :: struct {
    texture: ^d3d11.ITexture2D,
    rtv:     ^d3d11.IRenderTargetView,
    srv:     ^d3d11.IShaderResourceView,
    width, height: u32,
}

create_target :: proc(device: ^d3d11.IDevice, w, h: u32) -> (Target, bool) {
    desc := d3d11.TEXTURE2D_DESC{
        Width      = w,
        Height     = h,
        MipLevels  = 1,
        ArraySize  = 1,
        Format     = .R8G8B8A8_UNORM,
        SampleDesc = {Count = 1},
        Usage      = .DEFAULT,
        BindFlags  = {.RENDER_TARGET, .SHADER_RESOURCE},
    }

    target := Target{width = w, height = h}

    if hr := device->CreateTexture2D(&desc, nil, &target.texture); hr != 0 {
        // TODO(log): .Error replace this eprintfln -- include w/h/format/BindFlags; this is where capture-size changes will fail on other GPUs.
        fmt.eprintfln("render: CreateTexture2D(%v x %v) failed: HRESULT 0x%08X", w, h, u32(hr))
        destroy_target(&target)
        return {}, false
    }

    if hr := device->CreateRenderTargetView((^d3d11.IResource)(target.texture), nil, &target.rtv); hr != 0 {
        // TODO(log): .Error replace this eprintfln -- usually means BindFlags lost .RENDER_TARGET.
        fmt.eprintfln("render: CreateRenderTargetView failed: HRESULT 0x%08X", u32(hr))
        destroy_target(&target)
        return {}, false
    }

    if hr := device->CreateShaderResourceView((^d3d11.IResource)(target.texture), nil, &target.srv); hr != 0 {
        // TODO(log): .Error replace this eprintfln -- usually means BindFlags lost .SHADER_RESOURCE.
        fmt.eprintfln("render: CreateShaderResourceView failed: HRESULT 0x%08X", u32(hr))
        destroy_target(&target)
        return {}, false
    }

    // TODO(log): .Info render target created (w x h, format) -- one-time, worth having in every log.
    return target, true
}

destroy_target :: proc(target: ^Target) {
    if target == nil { return }
    // TODO(log): .Debug releasing target (w x h); will fire per-recreation once capture resizes targets.
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

draw_scene :: proc(ctx: ^d3d11.IDeviceContext, target: ^Target, clear: [4]f32) {
    // TODO(log): .Error RATE-LIMITED -- silent per-frame bail; needs a log-once-per-state-change guard, which means state somewhere (Target field or package global).
    if ctx == nil || target == nil || target.rtv == nil { return }

    color := clear
    ctx->OMSetRenderTargets(1, &target.rtv, nil)
    ctx->ClearRenderTargetView(target.rtv, &color)
}
