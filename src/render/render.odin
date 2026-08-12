package render

import "core:log"
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
        log.errorf("CreateTexture2D(%vx%v, R8G8B8A8_UNORM, RENDER_TARGET|SHADER_RESOURCE) failed: HRESULT 0x%08X", w, h, u32(hr))
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

    log.infof("render target created: %vx%v R8G8B8A8_UNORM", w, h)
    return target, true
}

destroy_target :: proc(target: ^Target) {
    if target == nil { return }
    log.debugf("releasing render target (%vx%v)", target.width, target.height)
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

draw_scene :: proc(ctx: ^d3d11.IDeviceContext, target: ^Target, clear: [4]f32) {
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
}
