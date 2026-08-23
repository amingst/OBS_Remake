package mf

import "core:log"
import "core:mem"
import "core:sys/windows"

foreign import mfplat "system:mfplat.lib"
foreign import mfreadwrite "system:mfreadwrite.lib"

@(default_calling_convention="stdcall")
foreign mfplat {
    MFStartup           :: proc(version: u32, flags: u32) -> windows.HRESULT ---
    MFShutdown          :: proc() -> windows.HRESULT ---
    MFCreateMediaType   :: proc(media_type: ^^IMFMediaType) -> windows.HRESULT ---
    MFCreateMemoryBuffer:: proc(max_length: u32, buffer: ^^IMFMediaBuffer) -> windows.HRESULT ---
    MFCreateSample      :: proc(sample: ^^IMFSample) -> windows.HRESULT ---
}

@(default_calling_convention="stdcall")
foreign mfreadwrite {
    MFCreateSinkWriterFromURL :: proc(output_url: cstring16, byte_stream: rawptr, attributes: rawptr, sink_writer: ^^IMFSinkWriter) -> windows.HRESULT ---
}

@(private)
mf_succeeded :: #force_inline proc(hr: windows.HRESULT) -> bool { return hr >= 0 }

@(private)
mf_set_size :: proc(mt: ^IMFMediaType, key: ^windows.GUID, w, h: u32) -> windows.HRESULT {
    return mt.SetUINT64(mt, key, (u64(w) << 32) | u64(h))
}

@(private)
mf_set_ratio :: proc(mt: ^IMFMediaType, key: ^windows.GUID, num, den: u32) -> windows.HRESULT {
    return mt.SetUINT64(mt, key, (u64(num) << 32) | u64(den))
}

// TODO: Turn this into a test
// Writes `seconds` of a solid BGRA color to `output_path` as H264/MP4.
// Assumes COM is already initialized on this thread (same as your DXGI/WASAPI setup).
test_write_solid_clip :: proc(output_path: string, width, height, fps, seconds: u32, b, g, r: u8) -> bool {
    hr := MFStartup(MF_VERSION, MFSTARTUP_FULL)
    if !mf_succeeded(hr) {
        log.errorf("MFStartup failed: 0x%08X", u32(hr))
        return false
    }
    defer MFShutdown()

    path_w := windows.utf8_to_wstring(output_path)
    // (heap allocation from context.allocator; free if your convention requires it explicitly)

    sink_writer: ^IMFSinkWriter
    hr = MFCreateSinkWriterFromURL(path_w, nil, nil, &sink_writer)
    if !mf_succeeded(hr) {
        log.errorf("MFCreateSinkWriterFromURL failed: 0x%08X", u32(hr))
        return false
    }
    defer sink_writer.Release(sink_writer)

    // ---- output type: H264 ----
    output_type: ^IMFMediaType
    hr = MFCreateMediaType(&output_type)
    if !mf_succeeded(hr) {
        log.errorf("MFCreateMediaType (output) failed: 0x%08X", u32(hr))
        return false
    }
    defer output_type.Release(output_type)

    output_type.SetGUID(output_type, &MF_MT_MAJOR_TYPE, &MFMediaType_Video)
    output_type.SetGUID(output_type, &MF_MT_SUBTYPE, &MFVideoFormat_H264)
    output_type.SetUINT32(output_type, &MF_MT_AVG_BITRATE, 4_000_000)
    output_type.SetUINT32(output_type, &MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive)
    mf_set_size(output_type, &MF_MT_FRAME_SIZE, width, height)
    mf_set_ratio(output_type, &MF_MT_FRAME_RATE, fps, 1)
    mf_set_ratio(output_type, &MF_MT_PIXEL_ASPECT_RATIO, 1, 1)

    stream_index: u32
    hr = sink_writer.AddStream(sink_writer, output_type, &stream_index)
    if !mf_succeeded(hr) {
        log.errorf("AddStream failed: 0x%08X", u32(hr))
        return false
    }

    // ---- input type: RGB32, MF's own converter goes RGB32 -> NV12 ----
    input_type: ^IMFMediaType
    hr = MFCreateMediaType(&input_type)
    if !mf_succeeded(hr) {
        log.errorf("MFCreateMediaType (input) failed: 0x%08X", u32(hr))
        return false
    }
    defer input_type.Release(input_type)

    input_type.SetGUID(input_type, &MF_MT_MAJOR_TYPE, &MFMediaType_Video)
    input_type.SetGUID(input_type, &MF_MT_SUBTYPE, &MFVideoFormat_RGB32)
    input_type.SetUINT32(input_type, &MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive)
    input_type.SetUINT32(input_type, &MF_MT_ALL_SAMPLES_INDEPENDENT, 1)
    mf_set_size(input_type, &MF_MT_FRAME_SIZE, width, height)          // must match output's frame size
    mf_set_ratio(input_type, &MF_MT_FRAME_RATE, fps, 1)
    mf_set_ratio(input_type, &MF_MT_PIXEL_ASPECT_RATIO, 1, 1)

    hr = sink_writer.SetInputMediaType(sink_writer, stream_index, input_type, nil)
    if !mf_succeeded(hr) {
        log.errorf("SetInputMediaType failed: 0x%08X", u32(hr))
        return false
    }

    hr = sink_writer.BeginWriting(sink_writer)
    if !mf_succeeded(hr) {
        log.errorf("BeginWriting failed: 0x%08X", u32(hr))
        return false
    }

    // build one row of solid color, reused for every frame
    frame_size := width * height * 4
    pixel := [4]u8{b, g, r, 0} // X8R8G8B8 little-endian byte order: B,G,R,X
    src := make([]u8, frame_size)
    defer delete(src)
    for i: u32 = 0; i < frame_size; i += 4 {
        copy(src[i:i+4], pixel[:])
    }

    frame_duration := i64(10_000_000) / i64(fps) // 100-ns units
    frame_count := fps * seconds

    for i: u32 = 0; i < frame_count; i += 1 {
        buffer: ^IMFMediaBuffer
        hr = MFCreateMemoryBuffer(frame_size, &buffer)
        if !mf_succeeded(hr) {
            log.errorf("MFCreateMemoryBuffer failed on frame %d: 0x%08X", i, u32(hr))
            return false
        }

        data: [^]u8
        hr = buffer.Lock(buffer, &data, nil, nil)
        if !mf_succeeded(hr) {
            log.errorf("Buffer Lock failed on frame %d: 0x%08X", i, u32(hr))
            buffer.Release(buffer)
            return false
        }
        mem.copy(data, raw_data(src), int(frame_size))
        buffer.Unlock(buffer)
        buffer.SetCurrentLength(buffer, frame_size)

        sample: ^IMFSample
        hr = MFCreateSample(&sample)
        if !mf_succeeded(hr) {
            log.errorf("MFCreateSample failed on frame %d: 0x%08X", i, u32(hr))
            buffer.Release(buffer)
            return false
        }

        sample.AddBuffer(sample, buffer)
        sample.SetSampleTime(sample, i64(i) * frame_duration)
        sample.SetSampleDuration(sample, frame_duration)

        hr = sink_writer.WriteSample(sink_writer, stream_index, sample)

        sample.Release(sample)
        buffer.Release(buffer)

        if !mf_succeeded(hr) {
            log.errorf("WriteSample failed on frame %d: 0x%08X", i, u32(hr))
            return false
        }
    }

    hr = sink_writer.Finalize(sink_writer)
    if !mf_succeeded(hr) {
        log.errorf("Finalize failed: 0x%08X", u32(hr))
        return false
    }

    return true
}

@(private)
valid_aac_bitrate :: proc(channels, bytes_per_sec: u32) -> bool {
    base := [4]u32{12000, 16000, 20000, 24000}
    mult: u32 = channels == 6 ? 6 : 1
    for b in base {
        if bytes_per_sec == b * mult do return true
    }
    return false
}

begin_recording :: proc(
    output_path: string,
    width, height, fps, video_bitrate: u32,
    audio_sample_rate, audio_channels, audio_bitrate: u32, // audio_channels == 0 -> no audio stream
    out_writer: ^^IMFSinkWriter,
    out_video_stream_index: ^u32,
    out_audio_stream_index: ^u32,
) -> bool {
    hr := MFStartup(MF_VERSION, MFSTARTUP_FULL)
    if !mf_succeeded(hr) {
        log.errorf("MFStartup failed: 0x%08X", u32(hr))
        return false
    }

    path_w := windows.utf8_to_wstring(output_path)
    sink_writer: ^IMFSinkWriter
    hr = MFCreateSinkWriterFromURL(path_w, nil, nil, &sink_writer)
    if !mf_succeeded(hr) {
        log.errorf("MFCreateSinkWriterFromURL failed: 0x%08X", u32(hr))
        MFShutdown()
        return false
    }

    // ---- video output type: H264 ----
    video_output_type: ^IMFMediaType
    hr = MFCreateMediaType(&video_output_type)
    if !mf_succeeded(hr) {
        log.errorf("MFCreateMediaType (video output) failed: 0x%08X", u32(hr))
        sink_writer.Release(sink_writer)
        MFShutdown()
        return false
    }
    defer video_output_type.Release(video_output_type)

    video_output_type.SetGUID(video_output_type, &MF_MT_MAJOR_TYPE, &MFMediaType_Video)
    video_output_type.SetGUID(video_output_type, &MF_MT_SUBTYPE, &MFVideoFormat_H264)
    video_output_type.SetUINT32(video_output_type, &MF_MT_AVG_BITRATE, video_bitrate)
    video_output_type.SetUINT32(video_output_type, &MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive)
    mf_set_size(video_output_type, &MF_MT_FRAME_SIZE, width, height)
    mf_set_ratio(video_output_type, &MF_MT_FRAME_RATE, fps, 1)
    mf_set_ratio(video_output_type, &MF_MT_PIXEL_ASPECT_RATIO, 1, 1)

    video_stream_index: u32
    hr = sink_writer.AddStream(sink_writer, video_output_type, &video_stream_index)
    if !mf_succeeded(hr) {
        log.errorf("AddStream (video) failed: 0x%08X", u32(hr))
        sink_writer.Release(sink_writer)
        MFShutdown()
        return false
    }

    // ---- video input type: RGB32, MF's own converter goes RGB32 -> NV12 ----
    video_input_type: ^IMFMediaType
    hr = MFCreateMediaType(&video_input_type)
    if !mf_succeeded(hr) {
        log.errorf("MFCreateMediaType (video input) failed: 0x%08X", u32(hr))
        sink_writer.Release(sink_writer)
        MFShutdown()
        return false
    }
    defer video_input_type.Release(video_input_type)

    video_input_type.SetGUID(video_input_type, &MF_MT_MAJOR_TYPE, &MFMediaType_Video)
    video_input_type.SetGUID(video_input_type, &MF_MT_SUBTYPE, &MFVideoFormat_RGB32)
    video_input_type.SetUINT32(video_input_type, &MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive)
    video_input_type.SetUINT32(video_input_type, &MF_MT_ALL_SAMPLES_INDEPENDENT, 1)
    mf_set_size(video_input_type, &MF_MT_FRAME_SIZE, width, height)
    mf_set_ratio(video_input_type, &MF_MT_FRAME_RATE, fps, 1)
    mf_set_ratio(video_input_type, &MF_MT_PIXEL_ASPECT_RATIO, 1, 1)

    hr = sink_writer.SetInputMediaType(sink_writer, video_stream_index, video_input_type, nil)
    if !mf_succeeded(hr) {
        log.errorf("SetInputMediaType (video) failed: 0x%08X", u32(hr))
        sink_writer.Release(sink_writer)
        MFShutdown()
        return false
    }

    audio_stream_index: u32 = max(u32) // sentinel: no audio stream configured

    if audio_channels > 0 {
        if !valid_aac_bitrate(audio_channels, audio_bitrate) {
            log.errorf("audio_bitrate %d bytes/sec is not a value the AAC encoder accepts for %d channel(s) (valid: 12000/16000/20000/24000, x6 for 5.1)", audio_bitrate, audio_channels)
            sink_writer.Release(sink_writer)
            MFShutdown()
            return false
        }

        // ---- audio output type: AAC ----
        audio_output_type: ^IMFMediaType
        hr = MFCreateMediaType(&audio_output_type)
        if !mf_succeeded(hr) {
            log.errorf("MFCreateMediaType (audio output) failed: 0x%08X", u32(hr))
            sink_writer.Release(sink_writer)
            MFShutdown()
            return false
        }
        defer audio_output_type.Release(audio_output_type)

        audio_output_type.SetGUID(audio_output_type, &MF_MT_MAJOR_TYPE, &MFMediaType_Audio)
        audio_output_type.SetGUID(audio_output_type, &MF_MT_SUBTYPE, &MFAudioFormat_AAC)
        audio_output_type.SetUINT32(audio_output_type, &MF_MT_AUDIO_BITS_PER_SAMPLE, 16)
        audio_output_type.SetUINT32(audio_output_type, &MF_MT_AUDIO_SAMPLES_PER_SECOND, audio_sample_rate)
        audio_output_type.SetUINT32(audio_output_type, &MF_MT_AUDIO_NUM_CHANNELS, audio_channels)
        audio_output_type.SetUINT32(audio_output_type, &MF_MT_AUDIO_AVG_BYTES_PER_SECOND, audio_bitrate)

        hr = sink_writer.AddStream(sink_writer, audio_output_type, &audio_stream_index)
        if !mf_succeeded(hr) {
            log.errorf("AddStream (audio) failed: 0x%08X", u32(hr))
            sink_writer.Release(sink_writer)
            MFShutdown()
            return false
        }

        // ---- audio input type: 16-bit PCM ----
        // The AAC encoder requires MFAudioFormat_PCM / 16-bit input - it does not
        // accept MFAudioFormat_Float, unlike the video path's implicit RGB32->NV12
        // conversion. Convert float32 -> int16 upstream, in the mixer.
        audio_input_type: ^IMFMediaType
        hr = MFCreateMediaType(&audio_input_type)
        if !mf_succeeded(hr) {
            log.errorf("MFCreateMediaType (audio input) failed: 0x%08X", u32(hr))
            sink_writer.Release(sink_writer)
            MFShutdown()
            return false
        }
        defer audio_input_type.Release(audio_input_type)

        block_align := audio_channels * 2 // 16-bit samples
        audio_input_type.SetGUID(audio_input_type, &MF_MT_MAJOR_TYPE, &MFMediaType_Audio)
        audio_input_type.SetGUID(audio_input_type, &MF_MT_SUBTYPE, &MFAudioFormat_PCM)
        audio_input_type.SetUINT32(audio_input_type, &MF_MT_AUDIO_BITS_PER_SAMPLE, 16)
        audio_input_type.SetUINT32(audio_input_type, &MF_MT_AUDIO_SAMPLES_PER_SECOND, audio_sample_rate)
        audio_input_type.SetUINT32(audio_input_type, &MF_MT_AUDIO_NUM_CHANNELS, audio_channels)
        audio_input_type.SetUINT32(audio_input_type, &MF_MT_AUDIO_BLOCK_ALIGNMENT, block_align)
        audio_input_type.SetUINT32(audio_input_type, &MF_MT_AUDIO_AVG_BYTES_PER_SECOND, audio_sample_rate * block_align)

        hr = sink_writer.SetInputMediaType(sink_writer, audio_stream_index, audio_input_type, nil)
        if !mf_succeeded(hr) {
            log.errorf("SetInputMediaType (audio) failed: 0x%08X", u32(hr))
            sink_writer.Release(sink_writer)
            MFShutdown()
            return false
        }
    }

    hr = sink_writer.BeginWriting(sink_writer)
    if !mf_succeeded(hr) {
        log.errorf("BeginWriting failed: 0x%08X", u32(hr))
        sink_writer.Release(sink_writer)
        MFShutdown()
        return false
    }

    out_writer^ = sink_writer
    out_video_stream_index^ = video_stream_index
    out_audio_stream_index^ = audio_stream_index
    return true
}

@(private)
write_stream_sample :: proc(
    sink_writer: ^IMFSinkWriter,
    stream_index: u32,
    data: []u8,
    sample_time, sample_duration: i64,
) -> bool {
    size := u32(len(data))

    buffer: ^IMFMediaBuffer
    hr := MFCreateMemoryBuffer(size, &buffer)
    if !mf_succeeded(hr) {
        log.errorf("MFCreateMemoryBuffer failed: 0x%08X", u32(hr))
        return false
    }

    dst: [^]u8
    hr = buffer.Lock(buffer, &dst, nil, nil)
    if !mf_succeeded(hr) {
        log.errorf("Buffer Lock failed: 0x%08X", u32(hr))
        buffer.Release(buffer)
        return false
    }

    mem.copy(dst, raw_data(data), int(size))
    buffer.Unlock(buffer)
    buffer.SetCurrentLength(buffer, size)

    sample: ^IMFSample
    hr = MFCreateSample(&sample)
    if !mf_succeeded(hr) {
        log.errorf("MFCreateSample failed: 0x%08X", u32(hr))
        buffer.Release(buffer)
        return false
    }

    sample.AddBuffer(sample, buffer)
    sample.SetSampleTime(sample, sample_time)
    sample.SetSampleDuration(sample, sample_duration)

    hr = sink_writer.WriteSample(sink_writer, stream_index, sample)

    sample.Release(sample)
    buffer.Release(buffer)

    if !mf_succeeded(hr) {
        log.errorf("WriteSample failed: 0x%08X", u32(hr))
        return false
    }
    return true
}

write_video_frame :: proc(sink_writer: ^IMFSinkWriter, stream_index: u32, pixels: []u8, sample_time, sample_duration: i64) -> bool {
    return write_stream_sample(sink_writer, stream_index, pixels, sample_time, sample_duration)
}

write_audio_frame :: proc(sink_writer: ^IMFSinkWriter, stream_index: u32, samples: []u8, sample_time, sample_duration: i64) -> bool {
    return write_stream_sample(sink_writer, stream_index, samples, sample_time, sample_duration)
}

end_recording :: proc(sink_writer: ^IMFSinkWriter) -> bool {
    hr := sink_writer.Finalize(sink_writer)
    sink_writer.Release(sink_writer)
    MFShutdown()

    if !mf_succeeded(hr) {
        log.errorf("Finalize failed: 0x%08X", u32(hr))
        return false
    }
    return true
}