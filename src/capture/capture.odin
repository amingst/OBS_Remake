package capture

import "core:log"
import "core:strings"
import win32 "core:sys/windows"
import "vendor:directx/dxgi"
import "vendor:directx/d3d11"

Output_Info :: struct {
    adapter_index: u32,
    output_index: u32,
    device_name: string,
    width, height: i32,
    attached: bool,
    adapter_luid: dxgi.LUID,
}

destroy_outputs :: proc(outputs: []Output_Info) {
    for o in outputs {
        delete(o.device_name)
    }
    delete(outputs)
}

log_device_adapter :: proc(device: ^d3d11.IDevice) {
    dxgi_device: ^dxgi.IDevice
    if hr := device->QueryInterface(dxgi.IDevice_UUID, (^rawptr)(&dxgi_device)); hr < 0 {
        log.errorf("QueryInterface(IDXGIDevice) failed: HRESULT 0x%08X", u32(hr))
        return
    }

    adapter: ^dxgi.IAdapter
    if hr := dxgi_device->GetAdapter(&adapter); hr < 0 {
        log.errorf("GetAdapter failed: HRESULT 0x%08X", u32(hr))
        dxgi_device->Release()
        return
    }

    desc: dxgi.ADAPTER_DESC
    if hr := adapter->GetDesc(&desc); hr < 0 {
        log.errorf("GetDesc failed: HRESULT 0x%08X", u32(hr))
        adapter->Release()
        dxgi_device->Release()
        return
    }

    name, err := win32.utf16_to_utf8(desc.Description[:], context.temp_allocator)
    if err != nil {
        log.errorf("device adapter: name conversion failed: %v", err)
        name = "<unknown>"
    }

    log.infof("d3d11 device is on adapter %q luid=%v", name, desc.AdapterLuid)

    adapter->Release()
    dxgi_device->Release()
}

enumerate_outputs :: proc(device: ^d3d11.IDevice) -> []Output_Info {
    factory: ^dxgi.IFactory1
    if hr := dxgi.CreateDXGIFactory1(dxgi.IFactory1_UUID, (^rawptr)(&factory)); hr < 0 {
        log.errorf("CreateDXGIFactory1 failed: HRESULT 0x%08X", u32(hr))
        return nil
    }
    defer factory->Release()

    infos := make([dynamic]Output_Info)

    log.debug("Enumerating outputs")
    for i: u32 = 0; ; i += 1 {
        adapter: ^dxgi.IAdapter1
        hr := factory->EnumAdapters1(i, &adapter)
        if hr == dxgi.ERROR_NOT_FOUND do break
        if hr < 0 {
            log.errorf("EnumAdapters1(%v) failed: 0x%08X", i, u32(hr))
            break
        }

        desc: dxgi.ADAPTER_DESC1
        if hr = adapter->GetDesc1(&desc); hr < 0 {
            log.errorf("GetDesc1(%v) failed: 0x%08X", i, u32(hr))
            continue
        }

        name, err := win32.utf16_to_utf8(desc.Description[:], context.temp_allocator)
        if err != nil {
            log.errorf("adapter %v: name conversion failed: %v", i, err)
            name = "<unknown>"
        }

        log.infof("adapter %v: %q vram=%vMB luid=%v software=%v",
            i, name, desc.DedicatedVideoMemory / (1024*1024),
            desc.AdapterLuid, .SOFTWARE in desc.Flags)

        // The Basic Render Driver can't be duplicated, so it has no business
        // showing up in a source picker.
        if .SOFTWARE in desc.Flags {
            adapter->Release()
            continue
        }

        for j: u32 = 0; ; j += 1 {
            output: ^dxgi.IOutput
            ohr := adapter->EnumOutputs(j, &output)
            if ohr == dxgi.ERROR_NOT_FOUND do break

            if ohr < 0 {
                log.errorf("EnumOutputs(%v,%v) failed: 0x%08X", i, j, u32(ohr))
                break
            }

            odesc: dxgi.OUTPUT_DESC
            if ohr = output->GetDesc(&odesc); ohr < 0 {
                log.errorf("GetDesc(%v,%v) failed: 0x%08X", i, j, u32(ohr))
                continue
            }

            dev_name, derr := win32.utf16_to_utf8(odesc.DeviceName[:], context.temp_allocator)
            if derr != nil {
                log.errorf("device %v: name conversion failed: %v", i, derr)
                dev_name = "<unknown>"
            }
            log.infof("Name: %v | Desktop Coordinates: %v | Attached To Desktop: %v", dev_name, odesc.DesktopCoordinates, odesc.AttachedToDesktop)

            append(&infos, Output_Info{
                adapter_index = i,
                output_index  = j,
                device_name   = strings.clone(dev_name),
                width         = odesc.DesktopCoordinates.right - odesc.DesktopCoordinates.left,
                height        = odesc.DesktopCoordinates.bottom - odesc.DesktopCoordinates.top,
                attached      = bool(odesc.AttachedToDesktop),
                adapter_luid  = desc.AdapterLuid,
            })

            output->Release()
        }

        adapter->Release()
    }

    return infos[:]
}

start_duplication :: proc(device: ^d3d11.IDevice, adapter_index, output_index: u32) -> (^dxgi.IOutputDuplication, bool) {
    output := find_output(adapter_index, output_index)
    if output == nil do return nil, false

    output1: ^dxgi.IOutput1
    if hr := output->QueryInterface(dxgi.IOutput1_UUID, (^rawptr)(&output1)); hr < 0 {
        log.errorf("QueryInterface(IDXGIOutput1) failed: 0x%08X", u32(hr))
        output->Release()
        return nil, false
    }
    output->Release()

    dupl: ^dxgi.IOutputDuplication
    hr := output1->DuplicateOutput((^dxgi.IUnknown)(device), &dupl)
    output1->Release()

    if hr < 0 {
        switch hr {
            case dxgi.ERROR_NOT_CURRENTLY_AVAILABLE:
                log.error("DuplicateOutput: too many existing duplications, or output already captured")
            case dxgi.ERROR_UNSUPPORTED:
                log.error("DuplicateOutput: unsupported — device and output are likely on different adapters")
            case:
                log.errorf("DuplicateOutput failed: 0x%08X", u32(hr))
        }
        return nil, false
    }

    log.infof("duplication started on adapter %v output %v", adapter_index, output_index)
    return dupl, true
}

stop_duplication :: proc(dupl: ^dxgi.IOutputDuplication) {
    if dupl == nil do return
    dupl->Release()
    log.debug("duplication stopped")
}

create_capture_texture :: proc(device: ^d3d11.IDevice, w, h: u32) -> (^d3d11.ITexture2D, ^d3d11.IShaderResourceView, bool) {
    desc := d3d11.TEXTURE2D_DESC {
        Width = w,
        Height = h,
        MipLevels = 1,
        ArraySize = 1,
        Format = .B8G8R8A8_UNORM,
        SampleDesc = {Count = 1},
        Usage = .DEFAULT,
        BindFlags = { .SHADER_RESOURCE },
    }

    texture: ^d3d11.ITexture2D
    if hr := device->CreateTexture2D(&desc, nil, &texture); hr < 0 {
        log.errorf("capture CreateTexture2D(%vx%v) failed: 0x%08X", w, h, u32(hr))
        return nil, nil, false
    }

    srv: ^d3d11.IShaderResourceView
    if hr := device->CreateShaderResourceView((^d3d11.IResource)(texture), nil, &srv); hr < 0 {
        log.errorf("capture CreateShaderResourceView failed: 0x%08X", u32(hr))
        texture->Release()
        return nil, nil, false
    }

    log.infof("capture texture created: %vx%v B8G8R8A8_UNORM", w, h)
    return texture, srv, true
}

acquire_frame :: proc(ctx: ^d3d11.IDeviceContext, dupl: ^dxgi.IOutputDuplication, dest: ^d3d11.ITexture2D) -> (ok: bool, lost: bool, got_frame: bool) {
    info: dxgi.OUTDUPL_FRAME_INFO
    resource: ^dxgi.IResource

    hr := dupl->AcquireNextFrame(0, &info, &resource)
    if hr == dxgi.ERROR_WAIT_TIMEOUT do return true, false, false
    if hr == dxgi.ERROR_ACCESS_LOST  do return false, true, false
    if hr < 0 {
        log.errorf("AcquireNextFrame failed: 0x%08X", u32(hr))
        return false, false, false
    }
    src_tex: ^d3d11.ITexture2D
    qhr := resource->QueryInterface(d3d11.ITexture2D_UUID, (^rawptr)(&src_tex))
    resource->Release()

    if qhr < 0 {
        log.errorf("frame QueryInterface(ITexture2D) failed: 0x%08X", u32(qhr))
        dupl->ReleaseFrame()
        return false, false, false
    }

    ctx->CopyResource((^d3d11.IResource)(dest), (^d3d11.IResource)(src_tex))
    src_tex->Release()
    dupl->ReleaseFrame()
    return true, false, true
}

@(private)
find_output :: proc(adapter_index, output_index: u32) -> ^dxgi.IOutput {
    factory: ^dxgi.IFactory1
    if hr := dxgi.CreateDXGIFactory1(dxgi.IFactory1_UUID, (^rawptr)(&factory)); hr < 0 {
        log.errorf("CreateDXGIFactory1 failed: HRESULT 0x%08X", u32(hr))
        return nil
    }

    adapter: ^dxgi.IAdapter1
    if hr := factory->EnumAdapters1(adapter_index, &adapter); hr < 0 {
        log.errorf("EnumAdapters1(%v) failed: 0x%08X", adapter_index, u32(hr))
        factory->Release()
        return nil
    }
    factory->Release()

    output: ^dxgi.IOutput
    if hr := adapter->EnumOutputs(output_index, &output); hr < 0 {
        log.errorf("EnumOutputs(%v,%v) failed: 0x%08X", adapter_index, output_index, u32(hr))
        adapter->Release()
        return nil
    }
    adapter->Release()

    return output
}
