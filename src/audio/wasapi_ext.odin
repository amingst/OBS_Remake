package audio

import "core:sys/windows"
import "vendor:windows/wasapi"
import "core:log"


AUDCLNT_STREAMFLAGS_LOOPBACK :: u32(0x00020000)

IID_IAudioCaptureClient := &windows.IID{
    0xC8ADBD64, 0xE71E, 0x48a0, {0xA4, 0xDE, 0x18, 0x5C, 0x39, 0x5C, 0xD3, 0x17},
}

IAudioCaptureClient :: struct #raw_union {
    using iaudiocaptureclient_vtable: ^IAudioCaptureClient_VTable,
}

IAudioCaptureClient_VTable :: struct {
    QueryInterface: proc "system" (this: ^IAudioCaptureClient, riid: ^windows.IID, ppvObject: ^rawptr) -> windows.HRESULT,
    AddRef:         proc "system" (this: ^IAudioCaptureClient) -> windows.ULONG,
    Release:        proc "system" (this: ^IAudioCaptureClient) -> windows.ULONG,

    GetBuffer: proc "system" (
        this:               ^IAudioCaptureClient,
        ppData:             ^[^]u8,
        pNumFramesToRead:   ^u32,
        pdwFlags:           ^u32,
        pu64DevicePosition: ^u64,
        pu64QPCPosition:    ^u64,
    ) -> windows.HRESULT,

    ReleaseBuffer: proc "system" (
        this:          ^IAudioCaptureClient,
        NumFramesRead: u32,
    ) -> windows.HRESULT,

    GetNextPacketSize: proc "system" (
        this:                   ^IAudioCaptureClient,
        pNumFramesInNextPacket: ^u32,
    ) -> windows.HRESULT,
}

Stream :: struct {
    device:      ^wasapi.IMMDevice,
    client:      ^wasapi.IAudioClient,
    capture:     ^IAudioCaptureClient,
    sample_rate: u32,
    channels:    u16,
    is_loopback: bool,
    peak:        f32,
}

open_stream  :: proc(dev: Device_Info) -> (Stream, bool) {
    enumerator := get_enumerator()
    if enumerator == nil do return {}, false

    wid := windows.utf8_to_wstring(dev.id, context.temp_allocator)
    device: ^wasapi.IMMDevice
    if hr := enumerator->GetDevice(wid, &device); windows.FAILED(hr) {
        log.errorf("GetDevice(%v) failed: 0x%08X", dev.id, u32(hr))
        return {}, false
    }

    client: ^wasapi.IAudioClient
    if hr := device->Activate(
        wasapi.IID_IAudioClient,
        windows.CLSCTX_ALL,
        nil,
        (^rawptr)(&client),
    ); windows.FAILED(hr) {
        log.errorf("Activate(IAudioClient) failed for %q: 0x%08X", dev.name, u32(hr))
        device->Release()
        device = nil
        return {}, false
    }

    wfx: ^wasapi.WAVEFORMATEX
    if hr := client->GetMixFormat(&wfx); windows.FAILED(hr) {
        log.errorf("GetMixFormat failed for %q: 0x%08X", dev.name, u32(hr))
        client->Release()
        client = nil
        device->Release()
        device = nil
        return {}, false
    }
    defer windows.CoTaskMemFree(wfx)
        flags: u32 = dev.is_loopback ? AUDCLNT_STREAMFLAGS_LOOPBACK : 0
    BUFFER_DURATION :: 100_000   // 10ms in 100ns units

    if hr := client->Initialize(.SHARED, flags, BUFFER_DURATION, 0, wfx, nil); windows.FAILED(hr) {
        log.errorf("Initialize failed for %q: 0x%08X", dev.name, u32(hr))
        client->Release()
        device->Release()
        return {}, false
    }

    capture: ^IAudioCaptureClient
    if hr := client->GetService(IID_IAudioCaptureClient, (^rawptr)(&capture)); windows.FAILED(hr) {
        log.errorf("GetService(IAudioCaptureClient) failed for %q: 0x%08X", dev.name, u32(hr))
        client->Release()
        device->Release()
        return {}, false
    }

    if hr := client->Start(); windows.FAILED(hr) {
        log.errorf("Start failed for %q: 0x%08X", dev.name, u32(hr))
        capture->Release()
        client->Release()
        device->Release()
        return {}, false
    }

    log.infof("stream open: %q %v Hz %v ch loopback=%v",
        dev.name, wfx.nSamplesPerSec, wfx.nChannels, dev.is_loopback)

    return Stream{
        device      = device,
        client      = client,
        capture     = capture,
        sample_rate = wfx.nSamplesPerSec,
        channels    = wfx.nChannels,
        is_loopback = dev.is_loopback,
    }, true
}

close_stream :: proc(s: ^Stream) {
    if s.client != nil do s.client->Stop()
    if s.capture != nil { s.capture->Release(); s.capture = nil }
    if s.client  != nil { s.client->Release();  s.client  = nil }
    if s.device  != nil { s.device->Release();  s.device  = nil }
    log.debug("audio stream closed")
}

poll_stream  :: proc(s: ^Stream) {
    if s.capture == nil do return
    for {
        packet: u32
        if hr := s.capture->GetNextPacketSize(&packet); windows.FAILED(hr) do return
        if packet == 0 do break   // nothing waiting

        data: [^]u8
        frames: u32
        flags: u32
        if hr := s.capture->GetBuffer(&data, &frames, &flags, nil, nil); windows.FAILED(hr) do return

        // 32-bit float, interleaved. AUDCLNT_BUFFERFLAGS_SILENT (0x2) means the
        // buffer contents are undefined and should be treated as zeroes.
        if flags & 0x2 == 0 && data != nil {
            samples := (cast([^]f32)data)[:frames * u32(s.channels)]
            for v in samples {
                a := abs(v)
                if a > s.peak do s.peak = a
            }
        }

        s.capture->ReleaseBuffer(frames)
    }
}