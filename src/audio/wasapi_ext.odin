package audio

import "core:sys/windows"
import "core:time"
import "vendor:windows/wasapi"
import "core:log"
import "core:thread"
import "base:intrinsics"
import "../applog"


IID_IAudioCaptureClient := &windows.IID{
    0xC8ADBD64, 0xE71E, 0x48a0, {0xA4, 0xDE, 0x18, 0x5C, 0x39, 0x5C, 0xD3, 0x17},
}

// {00000001-0000-0010-8000-00aa00389b71}
KSDATAFORMAT_SUBTYPE_PCM := windows.GUID{0x00000001, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}}

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
    starved_since: time.Time,
    starvation_logged: bool,
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

    // Log the sample format to confirm the f32 cast in drain_packets is valid.
    if wfx.wFormatTag == .EXTENSIBLE && wfx.cbSize >= 22 {
        wfxe := (^wasapi.WAVEFORMATEXTENSIBLE)(wfx)
        sf := wfxe.SubFormat
        if sf == wasapi.KSDATAFORMAT_SUBTYPE_IEEE_FLOAT {
            log.infof("stream %q: SubFormat=KSDATAFORMAT_SUBTYPE_IEEE_FLOAT", device_id)
        } else if sf == KSDATAFORMAT_SUBTYPE_PCM {
            log.infof("stream %q: SubFormat=KSDATAFORMAT_SUBTYPE_PCM", device_id)
        } else {
            log.infof("stream %q: SubFormat={%08X-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X}",
                device_id,
                sf.Data1, sf.Data2, sf.Data3,
                sf.Data4[0], sf.Data4[1], sf.Data4[2], sf.Data4[3],
                sf.Data4[4], sf.Data4[5], sf.Data4[6], sf.Data4[7])
        }
    } else {
        log.infof("stream %q: wFormatTag=0x%04X (not EXTENSIBLE)", device_id, u16(wfx.wFormatTag))
    }

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

        count := frames * u32(s.channels)
        if flags & 0x2 != 0 {
            // AUDCLNT_BUFFERFLAGS_SILENT — write zeros to keep the ring advancing.
            silence: [4096]f32
            for written := u32(0); written < count; {
                n := min(int(count - written), len(silence))
                w := ring_write(&s.ring, silence[:n])
                written += u32(w)
                if w < n do break
            }
        } else if data != nil {
            samples := (cast([^]f32)data)[:count]
            if n := ring_write(&s.ring, samples); n < len(samples) {
                //log.debugf("audio ring overflow: dropped %v samples", len(samples) - n)
            }
        }

        s.capture->ReleaseBuffer(frames)
    }
}

@(private="file")
stream_thread :: proc(t: ^thread.Thread) {
    s := (^Stream)(t.data)

    // thread.create doesn't inherit the spawning thread's context.logger.
    audio_log_ctx := applog.Log_Context{sink = g_log_sink, tag = {.Audio, 0}}
    context.logger = applog.make_logger(&audio_log_ctx)

    windows.CoInitializeEx(nil, .MULTITHREADED)
    defer windows.CoUninitialize()

    for intrinsics.atomic_load_explicit(&s.running, .Acquire) {
        if windows.WaitForSingleObject(s.event, 200) != windows.WAIT_OBJECT_0 do continue
        drain_packets(s)
        mix_signal_data()
        // Clear the per-thread temp arena core:log allocates into each iteration.
        free_all(context.temp_allocator)
    }

    log.debug("audio thread exiting")
}
