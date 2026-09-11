package mf

// Bindings for the interfaces/functions needed to drive MFCreateMPEG4MediaSink
// as a pure muxer for already-encoded H.264/AAC, plus thin (policy-free)
// wrappers around the mechanical steps proven out in
// experiments/mp4_sink_probe/. No consumer/ring/threading logic here -- that
// lives in src/mp4/sink.odin, which calls the procs below.
//
// Every vtable slot order was read directly out of, and must stay in sync
// with:
//   C:\Program Files (x86)\Windows Kits\10\Include\10.0.26100.0\um\mfidl.h
//   C:\Program Files (x86)\Windows Kits\10\Include\10.0.26100.0\um\mfobjects.h
// Do not reorder / alphabetize / trust memory here.

import "core:log"
import "core:mem"
import "core:sys/windows"

// ---------------------------------------------------------------------
// IMFStreamSink : IMFMediaEventGenerator : IUnknown
// vtable = IUnknown(3) + IMFMediaEventGenerator-own(4) + IMFStreamSink-own(6) = 13 slots.
// ---------------------------------------------------------------------

IMFStreamSink_VTable :: struct {
    QueryInterface: proc "stdcall" (this: ^IMFStreamSink, riid: ^windows.GUID, ppv: ^rawptr) -> windows.HRESULT,
    AddRef:         proc "stdcall" (this: ^IMFStreamSink) -> u32,
    Release:        proc "stdcall" (this: ^IMFStreamSink) -> u32,

    // IMFMediaEventGenerator block. GetEvent is used synchronously (blocking,
    // dwFlags=0) both to wait out MF_E_NOTACCEPTING and to wait for
    // MEStreamSinkStarted after the presentation clock starts.
    GetEvent: proc "stdcall" (this: ^IMFStreamSink, flags: u32, event: ^^IMFMediaEvent) -> windows.HRESULT,
    BeginGetEvent: rawptr,
    EndGetEvent:   rawptr,
    QueueEvent:    rawptr,

    GetMediaSink:        rawptr,
    GetIdentifier:       rawptr,
    GetMediaTypeHandler: proc "stdcall" (this: ^IMFStreamSink, handler: ^^IMFMediaTypeHandler) -> windows.HRESULT,
    ProcessSample: proc "stdcall" (this: ^IMFStreamSink, sample: ^IMFSample) -> windows.HRESULT,
    PlaceMarker: rawptr, // confirmed failing (MF_E_INVALIDREQUEST) on this sink; never called
    Flush:       rawptr,
}

IMFStreamSink :: struct { using vtbl: ^IMFStreamSink_VTable }

MF_EVENT_FLAG_NONE :: 0

// IMFMediaEvent : IMFAttributes : IUnknown. GetType is the only method this
// package needs (to recognize MEStreamSinkStarted); everything else rides on
// the shared IMFAttributes_VTable(T) shape used elsewhere in this package.
IMFMediaEvent_VTable :: struct {
    QueryInterface: proc "stdcall" (this: ^IMFMediaEvent, riid: ^windows.GUID, ppv: ^rawptr) -> windows.HRESULT,
    AddRef:         proc "stdcall" (this: ^IMFMediaEvent) -> u32,
    Release:        proc "stdcall" (this: ^IMFMediaEvent) -> u32,

    using attrs: IMFAttributes_VTable(IMFMediaEvent),

    GetType: proc "stdcall" (this: ^IMFMediaEvent, event_type: ^u32) -> windows.HRESULT,
    GetExtendedType: rawptr,
    GetStatus:       rawptr,
    GetValue:        rawptr,
}

IMFMediaEvent :: struct { using vtbl: ^IMFMediaEvent_VTable }

// MediaEventType values this package cares about (mfobjects.h ~4133).
MEStreamSinkStarted :: 301

// ---------------------------------------------------------------------
// IMFMediaTypeHandler : IUnknown. vtable = IUnknown(3) + own(6) = 9 slots.
// ---------------------------------------------------------------------

IMFMediaTypeHandler_VTable :: struct {
    QueryInterface: proc "stdcall" (this: ^IMFMediaTypeHandler, riid: ^windows.GUID, ppv: ^rawptr) -> windows.HRESULT,
    AddRef:         proc "stdcall" (this: ^IMFMediaTypeHandler) -> u32,
    Release:        proc "stdcall" (this: ^IMFMediaTypeHandler) -> u32,

    IsMediaTypeSupported: rawptr,
    GetMediaTypeCount:    rawptr,
    GetMediaTypeByIndex:  rawptr,
    SetCurrentMediaType: proc "stdcall" (this: ^IMFMediaTypeHandler, media_type: ^IMFMediaType) -> windows.HRESULT,
    GetCurrentMediaType:  rawptr,
    GetMajorType: proc "stdcall" (this: ^IMFMediaTypeHandler, major_type: ^windows.GUID) -> windows.HRESULT,
}

IMFMediaTypeHandler :: struct { using vtbl: ^IMFMediaTypeHandler_VTable }

// ---------------------------------------------------------------------
// IMFMediaSink : IUnknown. vtable = IUnknown(3) + own(8) = 11 slots.
// ---------------------------------------------------------------------

IMFMediaSink_VTable :: struct {
    QueryInterface: proc "stdcall" (this: ^IMFMediaSink, riid: ^windows.GUID, ppv: ^rawptr) -> windows.HRESULT,
    AddRef:         proc "stdcall" (this: ^IMFMediaSink) -> u32,
    Release:        proc "stdcall" (this: ^IMFMediaSink) -> u32,

    GetCharacteristics: proc "stdcall" (this: ^IMFMediaSink, characteristics: ^u32) -> windows.HRESULT,
    AddStreamSink:    rawptr,
    RemoveStreamSink: rawptr,
    GetStreamSinkCount: proc "stdcall" (this: ^IMFMediaSink, count: ^u32) -> windows.HRESULT,
    GetStreamSinkByIndex: proc "stdcall" (this: ^IMFMediaSink, index: u32, stream_sink: ^^IMFStreamSink) -> windows.HRESULT,
    GetStreamSinkById: rawptr,
    SetPresentationClock: proc "stdcall" (this: ^IMFMediaSink, clock: ^IMFPresentationClock) -> windows.HRESULT,
    GetPresentationClock: rawptr,
    Shutdown: proc "stdcall" (this: ^IMFMediaSink) -> windows.HRESULT,
}

IMFMediaSink :: struct { using vtbl: ^IMFMediaSink_VTable }

// ---------------------------------------------------------------------
// IMFPresentationClock : IMFClock : IUnknown. vtable = 8 + own(8) = 16 slots.
// Only SetTimeSource/Start/Stop are typed; the rest are unused placeholders.
// ---------------------------------------------------------------------

IMFPresentationClock_VTable :: struct {
    QueryInterface: proc "stdcall" (this: ^IMFPresentationClock, riid: ^windows.GUID, ppv: ^rawptr) -> windows.HRESULT,
    AddRef:         proc "stdcall" (this: ^IMFPresentationClock) -> u32,
    Release:        proc "stdcall" (this: ^IMFPresentationClock) -> u32,

    GetClockCharacteristics: rawptr,
    GetCorrelatedTime:       rawptr,
    GetContinuityKey:        rawptr,
    GetState:                rawptr,
    GetProperties:           rawptr,

    SetTimeSource: proc "stdcall" (this: ^IMFPresentationClock, time_source: ^windows.IUnknown) -> windows.HRESULT,
    GetTimeSource:        rawptr,
    GetTime:              rawptr,
    AddClockStateSink:    rawptr,
    RemoveClockStateSink: rawptr,
    Start: proc "stdcall" (this: ^IMFPresentationClock, start_offset: i64) -> windows.HRESULT,
    Stop:  proc "stdcall" (this: ^IMFPresentationClock) -> windows.HRESULT,
    Pause: rawptr,
}

IMFPresentationClock :: struct { using vtbl: ^IMFPresentationClock_VTable }

// ---------------------------------------------------------------------
// IMFFinalizableMediaSink : IMFMediaSink : IUnknown.
// vtable = IUnknown(3) + IMFMediaSink-own(8) + own(2) = 13 slots.
// ---------------------------------------------------------------------

IMFFinalizableMediaSink_VTable :: struct {
    QueryInterface: proc "stdcall" (this: ^IMFFinalizableMediaSink, riid: ^windows.GUID, ppv: ^rawptr) -> windows.HRESULT,
    AddRef:         proc "stdcall" (this: ^IMFFinalizableMediaSink) -> u32,
    Release:        proc "stdcall" (this: ^IMFFinalizableMediaSink) -> u32,

    GetCharacteristics:   rawptr,
    AddStreamSink:        rawptr,
    RemoveStreamSink:     rawptr,
    GetStreamSinkCount:   rawptr,
    GetStreamSinkByIndex: rawptr,
    GetStreamSinkById:    rawptr,
    SetPresentationClock: rawptr,
    GetPresentationClock: rawptr,
    Shutdown: rawptr,

    BeginFinalize: proc "stdcall" (this: ^IMFFinalizableMediaSink, callback: ^IMFAsyncCallback, state: rawptr) -> windows.HRESULT,
    EndFinalize:   proc "stdcall" (this: ^IMFFinalizableMediaSink, result: rawptr) -> windows.HRESULT,
}

IMFFinalizableMediaSink :: struct { using vtbl: ^IMFFinalizableMediaSink_VTable }

// ---------------------------------------------------------------------
// IMFAsyncCallback : IUnknown. vtable = IUnknown(3) + own(2) = 5 slots.
// This package implements one minimal synchronous-wait instance of it, used
// only to receive BeginFinalize's completion.
// ---------------------------------------------------------------------

IMFAsyncCallback_VTable :: struct {
    QueryInterface: proc "stdcall" (this: ^IMFAsyncCallback, riid: ^windows.GUID, ppv: ^rawptr) -> windows.HRESULT,
    AddRef:         proc "stdcall" (this: ^IMFAsyncCallback) -> u32,
    Release:        proc "stdcall" (this: ^IMFAsyncCallback) -> u32,

    GetParameters: proc "stdcall" (this: ^IMFAsyncCallback, flags: ^u32, queue: ^u32) -> windows.HRESULT,
    Invoke: proc "stdcall" (this: ^IMFAsyncCallback, result: rawptr) -> windows.HRESULT,
}

IMFAsyncCallback :: struct {
    using vtbl: ^IMFAsyncCallback_VTable,
    done_event:   windows.HANDLE,
    // IMFAsyncResult* handed to Invoke, AddRef'd there -- EndFinalize requires
    // this exact pointer per MSDN (NULL is documented invalid).
    async_result: ^windows.IUnknown,
}

// ---------------------------------------------------------------------
// IMFByteStream : IUnknown. vtable = IUnknown(3) + own(14) = 17 slots.
// ---------------------------------------------------------------------

IMFByteStream_VTable :: struct {
    QueryInterface: proc "stdcall" (this: ^IMFByteStream, riid: ^windows.GUID, ppv: ^rawptr) -> windows.HRESULT,
    AddRef:         proc "stdcall" (this: ^IMFByteStream) -> u32,
    Release:        proc "stdcall" (this: ^IMFByteStream) -> u32,

    GetCapabilities: rawptr,
    GetLength:       rawptr,
    SetLength:       rawptr,
    GetCurrentPosition: rawptr,
    SetCurrentPosition: rawptr,
    IsEndOfStream: rawptr,
    Read:          rawptr,
    BeginRead:     rawptr,
    EndRead:       rawptr,
    Write:         rawptr,
    BeginWrite:    rawptr,
    EndWrite:      rawptr,
    Seek:          rawptr,
    Flush:         rawptr,
    Close: proc "stdcall" (this: ^IMFByteStream) -> windows.HRESULT,
}

IMFByteStream :: struct { using vtbl: ^IMFByteStream_VTable }

// MF_FILE_ACCESSMODE / MF_FILE_OPENMODE / MF_FILE_FLAGS (mfobjects.h ~5334)
MF_ACCESSMODE_READWRITE :: 3
MF_OPENMODE_DELETE_IF_EXIST :: 4
MF_FILEFLAGS_NONE :: 0

MF_E_NOTACCEPTING :: windows.HRESULT(-1072875083) // 0xC00D36B5

// Diagnostics only (recon for the streaming-degrades-on-second-consumer /
// video-track-missing investigation). No behavioural meaning -- purely
// counted and logged at sink stop by src/mp4/sink.odin. Not synchronized:
// safe because exactly one thread (the mp4 sink feeder thread) ever touches
// a given instance.
Sample_Stats :: struct {
    attempted:           u64,
    ok:                  u64,
    not_accepting:       u64,
    other_fail:          u64,
    sample_logged:       int, // rate-limits the first-10-samples debug log
    notaccepting_logged: int, // rate-limits the GetEvent-on-NOTACCEPTING debug log
}

IID_IMFFinalizableMediaSink := windows.GUID{0xeaecb74a, 0x9a50, 0x42ce, {0x95, 0x41, 0x6a, 0x7f, 0x57, 0xaa, 0x4a, 0xd7}}

foreign import mfplat_mp4 "system:mfplat.lib"
// MFCreateMPEG4MediaSink/MFCreatePresentationClock are declared in mfidl.h
// but, empirically (grepping the SDK .lib files for the symbol -- Mfplat.lib
// does NOT contain it, Mf.lib does), exported from Mf.lib, not Mfplat.lib.
foreign import mf_mp4 "system:Mf.lib"

@(default_calling_convention="stdcall")
foreign mfplat_mp4 {
    MFCreateFile :: proc(
        access_mode: u32, // MF_FILE_ACCESSMODE
        open_mode:   u32, // MF_FILE_OPENMODE
        flags:       u32, // MF_FILE_FLAGS
        url:         windows.wstring,
        byte_stream: ^^IMFByteStream,
    ) -> windows.HRESULT ---

    MFCreateSystemTimeSource :: proc(time_source: ^^windows.IUnknown) -> windows.HRESULT ---
}

@(default_calling_convention="stdcall")
foreign mf_mp4 {
    MFCreateMPEG4MediaSink :: proc(
        byte_stream: ^IMFByteStream,
        video_media_type: ^IMFMediaType, // opt
        audio_media_type: ^IMFMediaType, // opt
        media_sink: ^^IMFMediaSink,
    ) -> windows.HRESULT ---

    MFCreatePresentationClock :: proc(clock: ^^IMFPresentationClock) -> windows.HRESULT ---
}

// libs/mf's IMFAttributes_VTable leaves SetBlob as a `rawptr` placeholder
// (mf_interfaces.odin) since nothing else in this package needs it. The MP4
// sink's media types carry the H.264 sequence header and AAC user-data blob
// as attributes, so cast that slot to its real signature locally.
@(private)
IMFAttributes_SetBlob_Proc :: #type proc "stdcall" (this: ^IMFMediaType, key: ^windows.GUID, buf: [^]u8, size: u32) -> windows.HRESULT

@(private)
set_media_type_blob :: proc(mt: ^IMFMediaType, key: ^windows.GUID, data: []u8) -> windows.HRESULT {
    fn := cast(IMFAttributes_SetBlob_Proc)mt.vtbl.SetBlob
    return fn(mt, key, raw_data(data), u32(len(data)))
}

// Rebuilds the Annex-B "SPS+PPS, each with a 4-byte start code" blob that
// MF_MT_MPEG_SEQUENCE_HEADER expects, from the split SPS/PPS NALUs
// encode.Encoder already exposes (begin_h264_encoder split them out of this
// exact blob via h264.split_sequence_header -- this is that operation run in
// reverse).
@(private)
build_annexb_sequence_header :: proc(sps, pps: []u8, allocator := context.allocator) -> []u8 {
    out := make([]u8, 4 + len(sps) + 4 + len(pps), allocator)
    out[0] = 0; out[1] = 0; out[2] = 0; out[3] = 1
    copy(out[4:], sps)
    off := 4 + len(sps)
    out[off] = 0; out[off+1] = 0; out[off+2] = 0; out[off+3] = 1
    copy(out[off+4:], pps)
    return out
}

// Rebuilds the MF_MT_USER_DATA blob (HEAACWAVEINFO header + AudioSpecificConfig)
// that the AAC encoder's negotiated output type carries, from the ASC-only
// tail encode.Encoder exposes as aac_config (it stored asc_blob[12:] -- see
// begin_aac_encoder). The 12-byte header is wPayloadType=0 (RAW AAC, matching
// what this sink is fed), wAudioProfileLevelIndication=0 ("unspecified" per
// mmreg.h), wStructType=0 (ASC follows), wReserved1=0, dwReserved2=0 -- all
// zero, which is exactly what MF's own encoder produces for a raw AAC stream.
@(private)
build_aac_user_data :: proc(aac_config: []u8, allocator := context.allocator) -> []u8 {
    out := make([]u8, 12 + len(aac_config), allocator)
    copy(out[12:], aac_config)
    return out
}

Mp4_Sink_Handles :: struct {
    media_sink:  ^IMFMediaSink,
    video_sink:  ^IMFStreamSink,
    audio_sink:  ^IMFStreamSink,
    byte_stream: ^IMFByteStream,
    clock:       ^IMFPresentationClock,
    time_source: ^windows.IUnknown,
}

// Creates the output file, the compressed H.264/AAC media types (carrying
// the sequence header / AAC user-data blob), the MPEG-4 media sink, resolves
// its two stream sinks, and starts its presentation clock. Does NOT wait for
// MEStreamSinkStarted -- call mp4_sink_wait_started on each stream sink for
// that, after this returns.
begin_mp4_sink :: proc(
    path: string,
    sps, pps, aac_config: []u8,
    width, height, fps, video_bitrate: u32,
    audio_sample_rate, audio_channels, audio_bitrate: u32,
) -> (handles: Mp4_Sink_Handles, ok: bool) {
    path_w := windows.utf8_to_wstring(path)
    byte_stream: ^IMFByteStream
    hr := MFCreateFile(MF_ACCESSMODE_READWRITE, MF_OPENMODE_DELETE_IF_EXIST, MF_FILEFLAGS_NONE, path_w, &byte_stream)
    if hr < 0 {
        log.errorf("MFCreateFile(%v) failed: 0x%08X", path, u32(hr))
        return {}, false
    }

    seq_header := build_annexb_sequence_header(sps, pps, context.temp_allocator)
    aac_user_data := build_aac_user_data(aac_config, context.temp_allocator)

    video_type: ^IMFMediaType
    hr = MFCreateMediaType(&video_type)
    if hr < 0 {
        log.errorf("MFCreateMediaType (mp4 video) failed: 0x%08X", u32(hr))
        byte_stream.Close(byte_stream)
        byte_stream.Release(byte_stream)
        return {}, false
    }
    defer video_type.Release(video_type)
    video_type.SetGUID(video_type, &MF_MT_MAJOR_TYPE, &MFMediaType_Video)
    video_type.SetGUID(video_type, &MF_MT_SUBTYPE, &MFVideoFormat_H264)
    video_type.SetUINT32(video_type, &MF_MT_AVG_BITRATE, video_bitrate)
    video_type.SetUINT32(video_type, &MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive)
    mf_set_size(video_type, &MF_MT_FRAME_SIZE, width, height)
    mf_set_ratio(video_type, &MF_MT_FRAME_RATE, fps, 1)
    mf_set_ratio(video_type, &MF_MT_PIXEL_ASPECT_RATIO, 1, 1)
    if hr = set_media_type_blob(video_type, &MF_MT_MPEG_SEQUENCE_HEADER, seq_header); hr < 0 {
        log.errorf("SetBlob(MF_MT_MPEG_SEQUENCE_HEADER) failed: 0x%08X", u32(hr))
        byte_stream.Close(byte_stream)
        byte_stream.Release(byte_stream)
        return {}, false
    }

    audio_type: ^IMFMediaType
    hr = MFCreateMediaType(&audio_type)
    if hr < 0 {
        log.errorf("MFCreateMediaType (mp4 audio) failed: 0x%08X", u32(hr))
        byte_stream.Close(byte_stream)
        byte_stream.Release(byte_stream)
        return {}, false
    }
    defer audio_type.Release(audio_type)
    audio_type.SetGUID(audio_type, &MF_MT_MAJOR_TYPE, &MFMediaType_Audio)
    audio_type.SetGUID(audio_type, &MF_MT_SUBTYPE, &MFAudioFormat_AAC)
    audio_type.SetUINT32(audio_type, &MF_MT_AAC_PAYLOAD_TYPE, 0)
    audio_type.SetUINT32(audio_type, &MF_MT_AUDIO_NUM_CHANNELS, audio_channels)
    audio_type.SetUINT32(audio_type, &MF_MT_AUDIO_SAMPLES_PER_SECOND, audio_sample_rate)
    audio_type.SetUINT32(audio_type, &MF_MT_AUDIO_BITS_PER_SAMPLE, 16)
    audio_type.SetUINT32(audio_type, &MF_MT_AUDIO_AVG_BYTES_PER_SECOND, audio_bitrate)
    if hr = set_media_type_blob(audio_type, &MF_MT_USER_DATA, aac_user_data); hr < 0 {
        log.errorf("SetBlob(MF_MT_USER_DATA) failed: 0x%08X", u32(hr))
        byte_stream.Close(byte_stream)
        byte_stream.Release(byte_stream)
        return {}, false
    }

    media_sink: ^IMFMediaSink
    hr = MFCreateMPEG4MediaSink(byte_stream, video_type, audio_type, &media_sink)
    if hr < 0 {
        log.errorf("MFCreateMPEG4MediaSink failed: 0x%08X", u32(hr))
        byte_stream.Close(byte_stream)
        byte_stream.Release(byte_stream)
        return {}, false
    }

    ok = false
    defer if !ok {
        media_sink.Shutdown(media_sink)
        media_sink.Release(media_sink)
        byte_stream.Close(byte_stream)
        byte_stream.Release(byte_stream)
    }

    stream_count: u32
    media_sink.GetStreamSinkCount(media_sink, &stream_count)

    video_sink, audio_sink: ^IMFStreamSink
    for i: u32 = 0; i < stream_count; i += 1 {
        s: ^IMFStreamSink
        media_sink.GetStreamSinkByIndex(media_sink, i, &s)
        if s == nil do continue
        handler: ^IMFMediaTypeHandler
        major: windows.GUID
        if s.GetMediaTypeHandler(s, &handler) >= 0 && handler != nil {
            handler.GetMajorType(handler, &major)
            handler.Release(handler)
        }
        if major == MFMediaType_Video {
            video_sink = s
        } else {
            audio_sink = s
        }
    }
    if video_sink == nil || audio_sink == nil {
        log.errorf("MFCreateMPEG4MediaSink did not produce both a video and an audio stream sink")
        if video_sink != nil do video_sink.Release(video_sink)
        if audio_sink != nil do audio_sink.Release(audio_sink)
        return {}, false
    }

    // Explicitly select the current media type on each stream's type handler
    // -- MFCreateMPEG4MediaSink's video/audio params only seed the handler's
    // type LIST, not its CURRENT type (confirmed in the probe: ProcessSample
    // rejected every sample with MF_E_INVALIDREQUEST until this was added).
    {
        vh: ^IMFMediaTypeHandler
        if video_sink.GetMediaTypeHandler(video_sink, &vh) >= 0 && vh != nil {
            if vh_hr := vh.SetCurrentMediaType(vh, video_type); vh_hr < 0 {
                log.errorf("video type handler SetCurrentMediaType failed: 0x%08X", u32(vh_hr))
            }
            vh.Release(vh)
        }
        ah: ^IMFMediaTypeHandler
        if audio_sink.GetMediaTypeHandler(audio_sink, &ah) >= 0 && ah != nil {
            if ah_hr := ah.SetCurrentMediaType(ah, audio_type); ah_hr < 0 {
                log.errorf("audio type handler SetCurrentMediaType failed: 0x%08X", u32(ah_hr))
            }
            ah.Release(ah)
        }
    }

    // MEDIASINK_CLOCK_REQUIRED is set on this sink (confirmed in the probe) --
    // ProcessSample rejects everything, and the first call can crash the
    // process outright, without a running presentation clock attached first.
    clock: ^IMFPresentationClock
    time_source: ^windows.IUnknown
    hr = MFCreatePresentationClock(&clock)
    if hr >= 0 {
        hr = MFCreateSystemTimeSource(&time_source)
    }
    if hr >= 0 {
        hr = clock.SetTimeSource(clock, time_source)
    }
    if hr >= 0 {
        hr = media_sink.SetPresentationClock(media_sink, clock)
    }
    if hr >= 0 {
        hr = clock.Start(clock, 0)
    }
    if hr < 0 {
        log.errorf("presentation clock setup failed: 0x%08X", u32(hr))
        video_sink.Release(video_sink)
        audio_sink.Release(audio_sink)
        if time_source != nil do time_source.Release(time_source)
        if clock != nil do clock.Release(clock)
        return {}, false
    }

    ok = true
    return Mp4_Sink_Handles{
        media_sink  = media_sink,
        video_sink  = video_sink,
        audio_sink  = audio_sink,
        byte_stream = byte_stream,
        clock       = clock,
        time_source = time_source,
    }, true
}

// Blocks on stream_sink's event queue until MEStreamSinkStarted arrives --
// sent once when the presentation clock actually starts, per the ground
// truth in experiments/mp4_sink_probe/ (clock.Start() returning is NOT
// sufficient). IMFMediaEventGenerator::GetEvent(dwFlags=0) has no timeout of
// its own and blocks until an event is queued, so max_events bounds this as
// a count of unrelated events tolerated before giving up, not wall time.
mp4_sink_wait_started :: proc(stream_sink: ^IMFStreamSink, max_events: u32) -> bool {
    for _ in 0 ..< max_events {
        event: ^IMFMediaEvent
        hr := stream_sink.GetEvent(stream_sink, MF_EVENT_FLAG_NONE, &event)
        if hr < 0 || event == nil {
            log.errorf("GetEvent (waiting for MEStreamSinkStarted) failed: 0x%08X", u32(hr))
            return false
        }
        event_type: u32
        event.GetType(event, &event_type)
        event.Release(event)
        if event_type == MEStreamSinkStarted do return true
    }
    log.errorf("gave up waiting for MEStreamSinkStarted after %v event(s)", max_events)
    return false
}

@(private)
process_sample_retrying :: proc(stream_sink: ^IMFStreamSink, sample: ^IMFSample, stats: ^Sample_Stats, stream_name: string) -> windows.HRESULT {
    // MF_E_NOTACCEPTING is expected backpressure (the sink's internal queue
    // is full), not an error -- confirmed in the probe. GetEvent(flags=0)
    // blocks for the sink's next readiness signal, then we retry.
    for {
        hr := stream_sink.ProcessSample(stream_sink, sample)
        if hr != MF_E_NOTACCEPTING do return hr
        stats.not_accepting += 1
        event: ^IMFMediaEvent
        ev_hr := stream_sink.GetEvent(stream_sink, MF_EVENT_FLAG_NONE, &event)
        // Diagnostics only, rate-limited: what GetEvent actually handed back
        // on the NOTACCEPTING retry path.
        if stats.notaccepting_logged < 20 {
            stats.notaccepting_logged += 1
            if ev_hr < 0 {
                log.debugf("mp4 sink %v NOTACCEPTING retry: GetEvent failed: 0x%08X", stream_name, u32(ev_hr))
            } else if event == nil {
                log.debugf("mp4 sink %v NOTACCEPTING retry: GetEvent returned S_OK with no event", stream_name)
            } else {
                event_type: u32
                event.GetType(event, &event_type)
                log.debugf("mp4 sink %v NOTACCEPTING retry: GetEvent returned event type %v", stream_name, event_type)
            }
        }
        if event != nil do event.Release(event)
        if ev_hr < 0 do return hr
    }
}

@(private)
make_media_sample :: proc(data: []u8, pts, dur: i64) -> (^IMFSample, bool) {
    buffer: ^IMFMediaBuffer
    hr := MFCreateMemoryBuffer(u32(len(data)), &buffer)
    if hr < 0 {
        log.errorf("MFCreateMemoryBuffer failed: 0x%08X", u32(hr))
        return nil, false
    }
    dst: [^]u8
    hr = buffer.Lock(buffer, &dst, nil, nil)
    if hr < 0 {
        log.errorf("Buffer Lock failed: 0x%08X", u32(hr))
        buffer.Release(buffer)
        return nil, false
    }
    mem.copy(dst, raw_data(data), len(data))
    buffer.Unlock(buffer)
    buffer.SetCurrentLength(buffer, u32(len(data)))

    sample: ^IMFSample
    hr = MFCreateSample(&sample)
    if hr < 0 {
        log.errorf("MFCreateSample failed: 0x%08X", u32(hr))
        buffer.Release(buffer)
        return nil, false
    }
    sample.AddBuffer(sample, buffer)
    sample.SetSampleTime(sample, pts)
    sample.SetSampleDuration(sample, dur)
    buffer.Release(buffer)
    return sample, true
}

// Reframes 0+ concatenated raw NALU payloads (no start codes, no length
// prefixes -- exactly what encode.Frame_Group.nalus holds, per
// h264.split_annexb) into Annex-B: each NALU gets its own 4-byte start code.
// The MP4 stream sink's ProcessSample wants Annex-B, not AVCC (ground truth
// from the probe) -- feeding the concatenated payloads with no delimiters at
// all, as-is, is neither and the sink's H.264 box builder cannot parse it.
@(private)
reframe_nalus_annexb :: proc(nalus: [][]u8, allocator := context.allocator) -> []u8 {
    total := 0
    for n in nalus do total += 4 + len(n)
    out := make([]u8, total, allocator)
    off := 0
    for n in nalus {
        out[off] = 0; out[off+1] = 0; out[off+2] = 0; out[off+3] = 1
        off += 4
        copy(out[off:], n)
        off += len(n)
    }
    return out
}

// Builds an Annex-B-framed IMFSample from one video access unit's NALUs.
// Copies the NALU bytes into the sample's own buffer, so the caller's source
// (a Frame_Group) can be released as soon as this returns -- it does not
// need to outlive the later, possibly-blocking mp4_sink_send_sample call.
mp4_sink_build_video_sample :: proc(nalus: [][]u8, pts, duration: i64) -> (^IMFSample, int, bool) {
    framed := reframe_nalus_annexb(nalus, context.temp_allocator)
    sample, ok := make_media_sample(framed, pts, duration)
    return sample, len(framed), ok
}

// Builds an IMFSample from one raw AAC access unit (no ADTS/reframing -- the
// sink's audio type was built for payload type RAW). Same copy-then-release
// contract as mp4_sink_build_video_sample.
mp4_sink_build_audio_sample :: proc(data: []u8, pts, duration: i64) -> (^IMFSample, int, bool) {
    sample, ok := make_media_sample(data, pts, duration)
    return sample, len(data), ok
}

// Hands a sample (from either build proc above) to stream_sink, retrying
// through MF_E_NOTACCEPTING, and releases the sample either way. This is the
// call that can block -- callers must release their source Frame_Group
// before this, not after.
//
// pts/duration/payload_len and stats/stream_name are diagnostics-only
// additions (recon instrumentation) -- they do not change the retry or
// release behaviour below.
mp4_sink_send_sample :: proc(stream_sink: ^IMFStreamSink, sample: ^IMFSample, pts, duration: i64, payload_len: int, stats: ^Sample_Stats, stream_name: string) -> bool {
    defer sample.Release(sample)
    stats.attempted += 1
    log_this_sample := stats.sample_logged < 10
    if log_this_sample do stats.sample_logged += 1

    hr := process_sample_retrying(stream_sink, sample, stats, stream_name)

    if log_this_sample {
        log.debugf("mp4 sink %v sample #%v: pts=%v duration=%v bytes=%v hr=0x%08X",
            stream_name, stats.sample_logged, pts, duration, payload_len, u32(hr))
    }
    if hr < 0 {
        stats.other_fail += 1
        log.errorf("ProcessSample failed: 0x%08X", u32(hr))
        return false
    }
    stats.ok += 1
    return true
}

@(private)
finalize_callback_vtbl := IMFAsyncCallback_VTable{
    QueryInterface = finalize_qi,
    AddRef         = finalize_addref,
    Release        = finalize_release,
    GetParameters  = finalize_get_parameters,
    Invoke         = finalize_invoke,
}

@(private)
finalize_qi :: proc "stdcall" (this: ^IMFAsyncCallback, riid: ^windows.GUID, ppv: ^rawptr) -> windows.HRESULT {
    ppv^ = this
    return 0 // S_OK -- good enough for this single-use, stack-lifetime callback
}
@(private) finalize_addref  :: proc "stdcall" (this: ^IMFAsyncCallback) -> u32 { return 1 }
@(private) finalize_release :: proc "stdcall" (this: ^IMFAsyncCallback) -> u32 { return 1 }
@(private)
finalize_get_parameters :: proc "stdcall" (this: ^IMFAsyncCallback, flags: ^u32, queue: ^u32) -> windows.HRESULT {
    return windows.HRESULT(-2147467263) // E_NOTIMPL -- tells MF to use default flags/queue
}
@(private)
finalize_invoke :: proc "stdcall" (this: ^IMFAsyncCallback, result: rawptr) -> windows.HRESULT {
    r := cast(^windows.IUnknown)result
    if r != nil do r.AddRef(r)
    this.async_result = r
    windows.SetEvent(this.done_event)
    return 0 // S_OK
}

// Runs the full finalize sequence: BeginFinalize -> wait -> EndFinalize (with
// the exact IMFAsyncResult* the callback received, per MSDN) -> Shutdown.
// Never touch byte_stream after this returns.
mp4_sink_finalize :: proc(media_sink: ^IMFMediaSink) -> bool {
    finalizable: ^IMFFinalizableMediaSink
    hr := media_sink.QueryInterface(media_sink, &IID_IMFFinalizableMediaSink, cast(^rawptr)&finalizable)
    if hr < 0 {
        log.errorf("QueryInterface(IMFFinalizableMediaSink) failed: 0x%08X", u32(hr))
        media_sink.Shutdown(media_sink)
        return false
    }
    defer finalizable.Release(finalizable)

    done_event := windows.CreateEventW(nil, false, false, nil)
    if done_event == nil {
        log.errorf("CreateEventW (finalize) failed")
        media_sink.Shutdown(media_sink)
        return false
    }
    defer windows.CloseHandle(done_event)

    cb := new(IMFAsyncCallback)
    defer free(cb)
    cb.vtbl = &finalize_callback_vtbl
    cb.done_event = done_event

    hr = finalizable.BeginFinalize(finalizable, cb, nil)
    if hr < 0 {
        log.errorf("BeginFinalize failed: 0x%08X", u32(hr))
        media_sink.Shutdown(media_sink)
        return false
    }

    wait := windows.WaitForSingleObject(done_event, 10000)
    if wait != windows.WAIT_OBJECT_0 {
        log.errorf("BeginFinalize wait failed/timed out: %v", wait)
        media_sink.Shutdown(media_sink)
        return false
    }

    hr = finalizable.EndFinalize(finalizable, cb.async_result)
    if cb.async_result != nil {
        cb.async_result.Release(cb.async_result)
        cb.async_result = nil
    }
    if hr < 0 {
        log.errorf("EndFinalize failed: 0x%08X", u32(hr))
        media_sink.Shutdown(media_sink)
        return false
    }

    hr = media_sink.Shutdown(media_sink)
    if hr < 0 {
        log.errorf("Shutdown failed: 0x%08X", u32(hr))
        return false
    }
    return true
}

mp4_sink_close :: proc(byte_stream: ^IMFByteStream) {
    byte_stream.Close(byte_stream)
}
