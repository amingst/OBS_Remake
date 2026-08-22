package audio

import "vendor:windows/wasapi"
import "core:log"
import "core:sys/windows"
import "core:strings"

// Singleton Instance of audio device enumerator
@(private) g_enumerator: ^wasapi.IMMDeviceEnumerator
@(private)
get_enumerator :: proc() -> ^wasapi.IMMDeviceEnumerator {
    if g_enumerator != nil do return g_enumerator

    if hr := windows.CoInitializeEx(nil, .APARTMENTTHREADED); windows.FAILED(hr) && hr != RPC_E_CHANGED_MODE {
        log.errorf("CoInitializeEx failed: 0x%08X", u32(hr))
        return nil
    }
        if hr := windows.CoCreateInstance(
        wasapi.CLSID_MMDeviceEnumerator,
        nil,
        windows.CLSCTX_ALL,
        wasapi.IID_IMMDeviceEnumerator,
        (^rawptr)(&g_enumerator),
    ); windows.FAILED(hr) {
        log.errorf("CoCreateInstance(MMDeviceEnumerator) failed: 0x%08X", u32(hr))
        return nil
    }

    return g_enumerator
}

shutdown :: proc() {
    if g_enumerator != nil {
        g_enumerator->Release()
        g_enumerator = nil
        log.debug("audio enumerator released")
    }
    if len(g_streams) > 0 {
        log.warnf("audio shutdown with %v stream(s) still referenced", len(g_streams))
    }

    for id, entry in g_streams {
        log.debug("Releasing device with id %v", id)
        close_stream(entry.stream)
        free(entry.stream)
    }
    delete(g_streams)
}

@(private="file") RPC_E_CHANGED_MODE  :: windows.HRESULT(-2147417850) // 0x80010106
@(private="file") DEVICE_STATE_ACTIVE :: u32(0x00000001)
@(private="file") STGM_READ           :: u32(0)

// core:sys/windows declares PROPVARIANT as an opaque 16-byte blob (a lone
// DECIMAL, with a note that the fuller definition is ignored), which is enough
// to pass to GetValue and PropVariantClear but gives no way to read the value
// back. This is our own layout over the same bytes: a type tag, three reserved
// words, and the union -- of which we only ever touch the pointer case.
@(private="file")
Prop_Variant :: struct {
    vt:         u16,
    reserved1:  u16,
    reserved2:  u16,
    reserved3:  u16,
    val:        rawptr,
}
#assert(size_of(Prop_Variant) == size_of(windows.PROPVARIANT))

@(private="file") VT_LPWSTR :: u16(31)

// is_loopback distinguishes a render endpoint (speakers, captured by opening
// the stream with AUDCLNT_STREAMFLAGS_LOOPBACK) from a capture endpoint (a mic,
// opened normally). Both are inputs as far as this app is concerned, which is
// why the flag names the mechanism rather than a direction.
Device_Info :: struct {
    id:          string,   // owned; endpoint ID, stable across reboots
    name:        string,   // owned; friendly name
    is_loopback: bool,
    is_default:  bool,
}

enumerate_devices :: proc() -> []Device_Info {
    enumerator := get_enumerator()
    if enumerator == nil do return nil

    infos := make([dynamic]Device_Info)
    enumerate_endpoints(enumerator, .Capture, false, &infos)
    enumerate_endpoints(enumerator, .Render,  true,  &infos)
    log.infof("found %v audio device(s)", len(infos))
    return infos[:]
}

destroy_devices :: proc(devs: []Device_Info) {
    for d in devs {
        delete(d.id)
        delete(d.name)
    }
    delete(devs)
}

@(private="file")
enumerate_endpoints :: proc(
    enumerator: ^wasapi.IMMDeviceEnumerator,
    flow: wasapi.EDataFlow,
    is_loopback: bool,
    infos: ^[dynamic]Device_Info,
) {
    collection: ^wasapi.IMMDeviceCollection
    if hr := enumerator->EnumAudioEndpoints(flow, DEVICE_STATE_ACTIVE,
        ([^]wasapi.IMMDeviceCollection)(&collection)); windows.FAILED(hr) {
        log.errorf("EnumAudioEndpoints(%v) failed: 0x%08X", flow, u32(hr))
        return
    }
    defer collection->Release()

    count: u32
    if hr := collection->GetCount(&count); windows.FAILED(hr) {
        log.errorf("GetCount(%v) failed: 0x%08X", flow, u32(hr))
        return
    }

    for i: u32 = 0; i < count; i += 1 {
        device: ^wasapi.IMMDevice
        if hr := collection->Item(i, &device); windows.FAILED(hr) {
            log.errorf("Item(%v, %v) failed: 0x%08X", flow, i, u32(hr))
            continue
        }

        id_wstr: windows.LPWSTR
        if hr := device->GetId(&id_wstr); windows.FAILED(hr) {
            log.errorf("GetId(%v, %v) failed: 0x%08X", flow, i, u32(hr))
            device->Release()
            continue
        }

        props: ^windows.IPropertyStore
        if hr := device->OpenPropertyStore(STGM_READ, &props); windows.FAILED(hr) {
            log.errorf("OpenPropertyStore(%v, %v) failed: 0x%08X", flow, i, u32(hr))
            windows.CoTaskMemFree(id_wstr)
            device->Release()
            continue
        }

        pv: Prop_Variant
        if hr := props->GetValue(&PKEY_Device_FriendlyName, (^windows.PROPVARIANT)(&pv)); windows.FAILED(hr) {
            log.errorf("GetValue(FriendlyName, %v, %v) failed: 0x%08X", flow, i, u32(hr))
            windows.CoTaskMemFree(id_wstr)
            props->Release()
            device->Release()
            continue
        }

        id, id_err := windows.wstring_to_utf8(windows.wstring(id_wstr), -1, context.temp_allocator)
        if id_err != nil {
            log.errorf("device %v/%v: id conversion failed: %v", flow, i, id_err)
            id = ""
        }

        name := "<unknown>"
        if pv.vt == VT_LPWSTR && pv.val != nil {
            if s, err := windows.wstring_to_utf8(windows.wstring(pv.val), -1, context.temp_allocator); err == nil {
                name = s
            }
        }
        windows.PropVariantClear((^windows.PROPVARIANT)(&pv))

        if id != "" {
            log.infof("audio device: %q loopback=%v (%v)", name, is_loopback, id)
            append(infos, Device_Info{
                id          = strings.clone(id),
                name        = strings.clone(name),
                is_loopback = is_loopback,
            })
        }

        windows.CoTaskMemFree(id_wstr)
        props->Release()
        device->Release()
    }
}

log_device_format :: proc(dev: Device_Info) {
    enumerator := get_enumerator()
    if enumerator == nil do return

    // Temp-allocator memory: freed wholesale at the end of the frame, never
    // individually.
    wid := windows.utf8_to_wstring(dev.id, context.temp_allocator)

    device: ^wasapi.IMMDevice
    if hr := enumerator->GetDevice(wid, &device); windows.FAILED(hr) {
        log.errorf("GetDevice(%v) failed: 0x%08X", dev.id, u32(hr))
        return
    }
    // Deferred right after the acquire, so every path below releases it and no
    // error branch has to remember. Safe here because this proc has no loops
    // and returns once.
    defer device->Release()

    client: ^wasapi.IAudioClient
    if hr := device->Activate(
        wasapi.IID_IAudioClient,
        windows.CLSCTX_ALL,
        nil,
        (^rawptr)(&client),
    ); windows.FAILED(hr) {
        log.errorf("Activate(IAudioClient) failed for %q: 0x%08X", dev.name, u32(hr))
        return
    }
    defer client->Release()

    wfx: ^wasapi.WAVEFORMATEX
    if hr := client->GetMixFormat(&wfx); windows.FAILED(hr) {
        log.errorf("GetMixFormat failed for %q: 0x%08X", dev.name, u32(hr))
        return
    }
    defer windows.CoTaskMemFree(wfx)

    log.infof("%q: %v Hz, %v ch, %v-bit, tag=0x%04X, block=%v",
        dev.name, wfx.nSamplesPerSec, wfx.nChannels,
        wfx.wBitsPerSample, wfx.wFormatTag, wfx.nBlockAlign)
}

@(private="file")
PKEY_Device_FriendlyName := windows.PROPERTYKEY{
    fmtid = {0xa45c254e, 0xdf1c, 0x4efd, {0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0}},
    pid   = 14,
}