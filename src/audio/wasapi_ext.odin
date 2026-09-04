package audio

import "core:sys/windows"
import "vendor:windows/wasapi"
import "core:log"
import "core:thread"
import "base:intrinsics"
import "../applog"


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
    event:       windows.HANDLE,
    sample_rate: u32,
    channels:    u16,
    is_loopback: bool,
    peak:        f32,
    ring: Ring,
    thread: ^thread.Thread,
    running: bool,
}

open_stream  :: proc(s: ^Stream, device_id: string, is_loopback: bool) -> bool {
    enumerator := get_enumerator()
    if enumerator == nil do return false

    wid := windows.utf8_to_wstring(device_id, context.temp_allocator)
    device: ^wasapi.IMMDevice
    if hr := enumerator->GetDevice(wid, &device); windows.FAILED(hr) {
        log.errorf("GetDevice(%v) failed: 0x%08X", device_id, u32(hr))
        return false
    }

    client: ^wasapi.IAudioClient
    if hr := device->Activate(
        wasapi.IID_IAudioClient,
        windows.CLSCTX_ALL,
        nil,
        (^rawptr)(&client),
    ); windows.FAILED(hr) {
        log.errorf("Activate(IAudioClient) failed for %q: 0x%08X", device_id, u32(hr))
        device->Release()
        device = nil
        return false
    }

    wfx: ^wasapi.WAVEFORMATEX
    if hr := client->GetMixFormat(&wfx); windows.FAILED(hr) {
        log.errorf("GetMixFormat failed for %q: 0x%08X", device_id, u32(hr))
        client->Release()
        client = nil
        device->Release()
        device = nil
        return false
    }
    defer windows.CoTaskMemFree(wfx)
    flags := u32(wasapi.AUDCLNT_FLAG.STREAM_EVENTCALLBACK)
    if is_loopback do flags |= u32(wasapi.AUDCLNT_FLAG.STREAM_LOOPBACK)
    BUFFER_DURATION :: 100_000   // 10ms in 100ns units

    event := windows.CreateEventW(nil, false, false, nil)
    if event == nil {
        log.errorf("CreateEventW failed for %q: %v", device_id, windows.GetLastError())
        client->Release()
        device->Release()
        return false
    }

    if hr := client->Initialize(.SHARED, flags, BUFFER_DURATION, 0, wfx, nil); windows.FAILED(hr) {
        log.errorf("Initialize failed for %q: 0x%08X", device_id, u32(hr))
        client->Release()
        device->Release()
        windows.CloseHandle(event)
        return false
    }

    if hr := client->SetEventHandle(event); windows.FAILED(hr) {
        log.errorf("SetEventHandle failed for %q: 0x%08X", device_id, u32(hr))
        windows.CloseHandle(event)
        client->Release()
        device->Release()
        return false
    }

    capture: ^IAudioCaptureClient
    if hr := client->GetService(IID_IAudioCaptureClient, (^rawptr)(&capture)); windows.FAILED(hr) {
        log.errorf("GetService(IAudioCaptureClient) failed for %q: 0x%08X", device_id, u32(hr))
        client->Release()
        device->Release()
        windows.CloseHandle(event)
        return false
    }

    if hr := client->Start(); windows.FAILED(hr) {
        log.errorf("Start failed for %q: 0x%08X", device_id, u32(hr))
        capture->Release()
        client->Release()
        device->Release()
        windows.CloseHandle(event)
        return false
    }

    log.infof("stream open: %q %v Hz %v ch loopback=%v",
        device_id, wfx.nSamplesPerSec, wfx.nChannels, is_loopback)

    s.device = device
    s.client = client
    s.capture = capture
    s.event = event
    s.sample_rate = wfx.nSamplesPerSec
    s.channels = wfx.nChannels
    s.is_loopback = is_loopback
    ring_init(&s.ring, 65536)

    intrinsics.atomic_store_explicit(&s.running, true, .Release)
    s.thread = thread.create(stream_thread)
    if s.thread == nil {
        log.error("could not create audio thread")
    } else {
        s.thread.data = s
        thread.start(s.thread)
    }
    return true
}

close_stream :: proc(s: ^Stream) {
    // Thread needs to be released before anything else
    // causes random corruption instead of a crash
    if s.thread != nil {
        intrinsics.atomic_store_explicit(&s.running, false, .Release)
        windows.SetEvent(s.event)
        thread.join(s.thread)
        thread.destroy(s.thread)
        s.thread = nil
    }


    if s.client != nil do s.client->Stop()
    if s.capture != nil { s.capture->Release(); s.capture = nil }
    if s.client  != nil { s.client->Release();  s.client  = nil }
    if s.device  != nil { s.device->Release();  s.device  = nil }
    if s.event   != nil { windows.CloseHandle(s.event); s.event = nil }
    ring_destroy(&s.ring)
    log.debug("audio stream closed")
}

@(private="file")
drain_packets :: proc(s: ^Stream) {
    if s.capture == nil do return
    for {
        packet: u32
        if hr := s.capture->GetNextPacketSize(&packet); windows.FAILED(hr) do return
        if packet == 0 do break

        data: [^]u8
        frames: u32
        flags: u32

        if hr := s.capture->GetBuffer(&data, &frames, &flags, nil, nil); windows.FAILED(hr) do return
        if flags & 0x2 == 0 && data != nil {
            samples := (cast([^]f32)data)[:frames * u32(s.channels)]
            if n := ring_write(&s.ring, samples); n < len(samples) {
                log.warnf("audio ring overflow: dropped %v samples", len(samples) - n)
            }
        }

        s.capture->ReleaseBuffer(frames)
    }
}

@(private="file")
stream_thread :: proc(t: ^thread.Thread) {
    s := (^Stream)(t.data)

    // thread.create starts with a fresh default context -- context.logger is
    // NOT inherited from the spawning thread, so every log call in this proc
    // was silently discarded before this was added. audio_log_ctx is a local
    // of this proc (not the spawning proc) so the pointer make_logger stashes
    // in the Logger stays valid for the thread's whole lifetime.
    audio_log_ctx := applog.Log_Context{sink = g_log_sink, tag = {.Audio, 0}}
    context.logger = applog.make_logger(&audio_log_ctx)

    windows.CoInitializeEx(nil, .MULTITHREADED)
    defer windows.CoUninitialize()

    for intrinsics.atomic_load_explicit(&s.running, .Acquire) {
        if windows.WaitForSingleObject(s.event, 200) != windows.WAIT_OBJECT_0 do continue
        drain_packets(s)
        // core:log's frontend formats via tprintf, allocating from the
        // per-thread temp arena. drain_packets can log (ring-overflow
        // warning) every iteration of this long-lived loop, so it must be
        // cleared here or it grows without bound -- invisible to the
        // tracking allocator since core:context.temp_allocator isn't it.
        free_all(context.temp_allocator)
    }

    log.debug("audio thread exiting")
}