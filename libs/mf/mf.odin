package mf

import "core:log"
import "core:mem"
import "core:sys/windows"
import "libs:h264"
import "core:slice"

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

@(default_calling_convention="stdcall")
foreign mfplat {
    MFTEnumEx :: proc(
        category: windows.GUID,                    // by VALUE, not REFGUID — easy to get wrong by pattern-matching on SetGUID calls elsewhere
        flags: u32,
        input_type: ^MFT_REGISTER_TYPE_INFO,        // nil = match any
        output_type: ^MFT_REGISTER_TYPE_INFO,       // nil = match any
        activates: ^[^]^IMFActivate,                // pointer to a fresh CoTaskMemAlloc'd array of IMFActivate*
        count: ^u32,
    ) -> windows.HRESULT ---
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

begin_h264_encoder :: proc(width, height, fps, bitrate: u32) -> (encoder: ^IMFTransform, sps, pps: []u8, ok: bool) {
    output_filter := MFT_REGISTER_TYPE_INFO{MFMediaType_Video, MFVideoFormat_H264}

    activates: [^]^IMFActivate
    count: u32
    hr := MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER, MFT_ENUM_FLAG_SYNCMFT, nil, &output_filter, &activates, &count)
    if hr < 0 {
        log.errorf("MFTEnumEx failed: 0x%08X", u32(hr))
        return nil, nil, nil, false
    }
    if count == 0 {
        log.errorf("MFTEnumEx found no synchronous H264 encoder")
        windows.CoTaskMemFree(activates)
        return nil, nil, nil, false
    }

    activate := activates[0]
    for i: u32 = 1; i < count; i += 1 {
        activates[i].Release(activates[i]) // only using the first result; release the rest
    }
    windows.CoTaskMemFree(activates)
    defer activate.Release(activate)

    hr = activate.ActivateObject(activate, &IID_IMFTransform, cast(^rawptr)&encoder)
    if hr < 0 {
        log.errorf("ActivateObject failed: 0x%08X", u32(hr))
        return nil, nil, nil, false
    }

    // ---- output type first, per docs ----
    output_type: ^IMFMediaType
    hr = MFCreateMediaType(&output_type)
    if hr < 0 {
        log.errorf("MFCreateMediaType (encoder output) failed: 0x%08X", u32(hr))
        encoder.Release(encoder)
        return nil, nil, nil, false
    }
    defer output_type.Release(output_type)

    output_type.SetGUID(output_type, &MF_MT_MAJOR_TYPE, &MFMediaType_Video)
    output_type.SetGUID(output_type, &MF_MT_SUBTYPE, &MFVideoFormat_H264)
    output_type.SetUINT32(output_type, &MF_MT_AVG_BITRATE, bitrate)
    output_type.SetUINT32(output_type, &MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive)
    mf_set_size(output_type, &MF_MT_FRAME_SIZE, width, height)
    mf_set_ratio(output_type, &MF_MT_FRAME_RATE, fps, 1)

    hr = encoder.SetOutputType(encoder, 0, output_type, 0)
    if hr < 0 {
        log.errorf("SetOutputType failed: 0x%08X", u32(hr))
        encoder.Release(encoder)
        return nil, nil, nil, false
    }

    // ---- input type: NV12, NOT RGB32 ----
    input_type: ^IMFMediaType
    hr = MFCreateMediaType(&input_type)
    if hr < 0 {
        log.errorf("MFCreateMediaType (encoder input) failed: 0x%08X", u32(hr))
        encoder.Release(encoder)
        return nil, nil, nil, false
    }
    defer input_type.Release(input_type)

    input_type.SetGUID(input_type, &MF_MT_MAJOR_TYPE, &MFMediaType_Video)
    input_type.SetGUID(input_type, &MF_MT_SUBTYPE, &MFVideoFormat_NV12)
    input_type.SetUINT32(input_type, &MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive)
    mf_set_size(input_type, &MF_MT_FRAME_SIZE, width, height)
    mf_set_ratio(input_type, &MF_MT_FRAME_RATE, fps, 1)

    hr = encoder.SetInputType(encoder, 0, input_type, 0)
    if hr < 0 {
        log.errorf("SetInputType failed: 0x%08X", u32(hr))
        encoder.Release(encoder)
        return nil, nil, nil, false
    }

    // ---- pull SPS/PPS from the negotiated output type (not the object we passed in) ----
    current_output: ^IMFMediaType
    hr = encoder.GetOutputCurrentType(encoder, 0, &current_output)
    if hr < 0 {
        log.errorf("GetOutputCurrentType failed: 0x%08X", u32(hr))
        encoder.Release(encoder)
        return nil, nil, nil, false
    }
    defer current_output.Release(current_output)

    seq_size: u32
    hr = current_output.GetBlobSize(current_output, &MF_MT_MPEG_SEQUENCE_HEADER, &seq_size)
    if hr < 0 {
        log.errorf("GetBlobSize(sequence header) failed: 0x%08X", u32(hr))
        encoder.Release(encoder)
        return nil, nil, nil, false
    }

    seq_header := make([]u8, seq_size, context.temp_allocator)
    hr = current_output.GetBlob(current_output, &MF_MT_MPEG_SEQUENCE_HEADER, raw_data(seq_header), seq_size, nil)
    if hr < 0 {
        log.errorf("GetBlob(sequence header) failed: 0x%08X", u32(hr))
        encoder.Release(encoder)
        return nil, nil, nil, false
    }

    sps_ref, pps_ref, split_ok := h264.split_sequence_header(seq_header)
    if !split_ok {
        log.errorf("SPS/PPS not found in sequence header blob")
        encoder.Release(encoder)
        return nil, nil, nil, false
    }
    sps = slice.clone(sps_ref)
    pps = slice.clone(pps_ref)

    hr = encoder.ProcessMessage(encoder, MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0)
    if hr < 0 {
        log.errorf("ProcessMessage(BEGIN_STREAMING) failed: 0x%08X", u32(hr))
        delete(sps); delete(pps)
        encoder.Release(encoder)
        return nil, nil, nil, false
    }

    return encoder, sps, pps, true
}

@(private)
drain_encoder_output :: proc(encoder: ^IMFTransform, allocator := context.allocator) -> (nalus: [][]u8, ok: bool) {
    raw_samples, drain_ok := drain_transform_samples(encoder, 0, context.temp_allocator)
    if !drain_ok do return nil, false

    collected: [dynamic][]u8
    defer delete(collected)
    for sample_bytes in raw_samples {
        for nalu in h264.split_annexb(sample_bytes, context.temp_allocator) {
            append(&collected, slice.clone(nalu, allocator))
        }
    }

    out := make([][]u8, len(collected), allocator)
    copy(out, collected[:])
    return out, true
}

// nv12 must be width*height*3/2 bytes (Y plane, then interleaved U/V at half resolution).
encode_h264_frame :: proc(encoder: ^IMFTransform, nv12: []u8, sample_time, sample_duration: i64) -> (nalus: [][]u8, ok: bool) {
    buffer: ^IMFMediaBuffer
    hr := MFCreateMemoryBuffer(u32(len(nv12)), &buffer)
    if hr < 0 {
        log.errorf("MFCreateMemoryBuffer failed: 0x%08X", u32(hr))
        return nil, false
    }

    data: [^]u8
    hr = buffer.Lock(buffer, &data, nil, nil)
    if hr < 0 {
        log.errorf("Buffer Lock failed: 0x%08X", u32(hr))
        buffer.Release(buffer)
        return nil, false
    }
    mem.copy(data, raw_data(nv12), len(nv12))
    buffer.Unlock(buffer)
    buffer.SetCurrentLength(buffer, u32(len(nv12)))

    sample: ^IMFSample
    hr = MFCreateSample(&sample)
    if hr < 0 {
        log.errorf("MFCreateSample failed: 0x%08X", u32(hr))
        buffer.Release(buffer)
        return nil, false
    }
    sample.AddBuffer(sample, buffer)
    sample.SetSampleTime(sample, sample_time)
    sample.SetSampleDuration(sample, sample_duration)

    hr = encoder.ProcessInput(encoder, 0, sample, 0)
    sample.Release(sample)
    buffer.Release(buffer)

    if hr < 0 {
        log.errorf("ProcessInput failed: 0x%08X", u32(hr))
        return nil, false
    }

    return drain_encoder_output(encoder)
}

end_h264_encoder :: proc(encoder: ^IMFTransform) -> (tail_nalus: [][]u8) {
    encoder.ProcessMessage(encoder, MFT_MESSAGE_COMMAND_DRAIN, 0)
    tail_nalus, _ = drain_encoder_output(encoder)
    encoder.Release(encoder)
    return tail_nalus
}

begin_video_processor :: proc(width, height: u32) -> (processor: ^IMFTransform, ok: bool) {
	input_filter := MFT_REGISTER_TYPE_INFO{MFMediaType_Video, MFVideoFormat_RGB32}
	output_filter := MFT_REGISTER_TYPE_INFO{MFMediaType_Video, MFVideoFormat_NV12}

	activates: [^]^IMFActivate
	count: u32
	hr := MFTEnumEx(MFT_CATEGORY_VIDEO_PROCESSOR, MFT_ENUM_FLAG_SYNCMFT, &input_filter, &output_filter, &activates, &count)
	if hr < 0 {
		log.errorf("MFTEnumEx (video processor) failed: 0x%08X", u32(hr))
	}

	if count == 0 {
		log.errorf("MFTEnumEx found no synchronous Video Processor MFT for RGB32->NV12")
        windows.CoTaskMemFree(activates)
        return nil, false
	}

	activate := activates[0]
	for i: u32 = 1; i < count; i += 1 {
		activates[i].Release(activates[i])
	}
	windows.CoTaskMemFree(activates)
	defer activate.Release(activate)

	hr = activate.ActivateObject(activate, &IID_IMFTransform, cast(^rawptr)&processor)
 	if hr < 0 {
        log.errorf("ActivateObject (video processor) failed: 0x%08X", u32(hr))
        return nil, false
    }

    // set input type first
    // TODO: Refactor
    input_type: ^IMFMediaType
    hr = MFCreateMediaType(&input_type)
    if hr < 0 {
        log.errorf("MFCreateMediaType (processor input) failed: 0x%08X", u32(hr))
        processor.Release(processor)
        return nil, false
    }
    defer input_type.Release(input_type)

    input_type.SetGUID(input_type, &MF_MT_MAJOR_TYPE, &MFMediaType_Video)
    input_type.SetGUID(input_type, &MF_MT_SUBTYPE, &MFVideoFormat_RGB32)
    input_type.SetUINT32(input_type, &MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive)
    mf_set_size(input_type, &MF_MT_FRAME_SIZE, width, height)

    hr = processor.SetInputType(processor, 0, input_type, 0)
    if hr < 0 {
        log.errorf("SetInputType (processor) failed: 0x%08X", u32(hr))
        processor.Release(processor)
        return nil, false
    }

    // set output type second
    // TODO: Refactor
    output_type: ^IMFMediaType
    hr = MFCreateMediaType(&output_type)
    if hr < 0 {
        log.errorf("MFCreateMediaType (processor output) failed: 0x%08X", u32(hr))
        processor.Release(processor)
        return nil, false
    }
    defer output_type.Release(output_type)

    output_type.SetGUID(output_type, &MF_MT_MAJOR_TYPE, &MFMediaType_Video)
    output_type.SetGUID(output_type, &MF_MT_SUBTYPE, &MFVideoFormat_NV12)
    output_type.SetUINT32(output_type, &MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive)
    mf_set_size(output_type, &MF_MT_FRAME_SIZE, width, height)

    hr = processor.SetOutputType(processor, 0, output_type, 0)
    if hr < 0 {
        log.errorf("SetOutputType (processor) failed: 0x%08X", u32(hr))
        processor.Release(processor)
        return nil, false
    }

    hr = processor.ProcessMessage(processor, MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0)
    if hr < 0 {
        log.errorf("ProcessMessage(BEGIN_STREAMING) on processor failed: 0x%08X", u32(hr))
        processor.Release(processor)
        return nil, false
    }

    return processor, true
}

@(private)
drain_transform_samples :: proc(transform: ^IMFTransform, stream_id: u32, allocator := context.allocator) -> (frames: [][]u8, ok: bool) {
	collected: [dynamic][]u8
	defer delete(collected)

	for {
		stream_info: MFT_OUTPUT_STREAM_INFO
		hr := transform.GetOutputStreamInfo(transform, stream_id, &stream_info)
  		if hr < 0 {
            log.errorf("GetOutputStreamInfo failed: 0x%08X", u32(hr))
            return nil, false
        }

		sample: ^IMFSample
		provides_own := stream_info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES != 0
		if !provides_own {
			hr = MFCreateSample(&sample)
			if hr < 0 {
				log.errorf("MFCreateSample (output) failed: 0x%08X", u32(hr))
                return nil, false
			}

			out_buffer: ^IMFMediaBuffer
			hr = MFCreateMemoryBuffer(stream_info.cbSize, &out_buffer)
			if hr < 0 {
				log.errorf("MFCreateMemoryBuffer (output) failed: 0x%08X", u32(hr))
                sample.Release(sample)
                return nil, false
			}

			sample.AddBuffer(sample, out_buffer)
			out_buffer.Release(out_buffer)
		}

		output_buf := MFT_OUTPUT_DATA_BUFFER{dwStreamID = stream_id, pSample = sample}
		status: u32
		hr = transform.ProcessOutput(transform, 0, 1, &output_buf, &status)

		if u32(hr) == MF_E_TRANSFORM_NEED_MORE_INPUT {
			if sample != nil do sample.Release(sample)
			break
		}
		if hr < 0 {
			log.errorf("ProcessOutput failed: 0x%08X", u32(hr))
            if sample != nil do sample.Release(sample)
            return nil, false
		}

		result := output_buf.pSample
		contiguous: ^IMFMediaBuffer
		hr = result.ConvertToContiguousBuffer(result, &contiguous)
  		if hr < 0 {
            log.errorf("ConvertToContiguousBuffer failed: 0x%08X", u32(hr))
            result.Release(result)
            return nil, false
        }

        data: [^]u8
        hr = contiguous.Lock(contiguous, &data, nil, nil)
        if hr < 0 {
            log.errorf("Buffer Lock (output) failed: 0x%08X", u32(hr))
            contiguous.Release(contiguous)
            result.Release(result)
            return nil, false
        }

        length: u32
        contiguous.GetCurrentLength(contiguous, &length)
        raw_bytes := make([]u8, length, allocator)
        mem.copy(raw_data(raw_bytes), data, int(length))
        contiguous.Unlock(contiguous)
        contiguous.Release(contiguous)
        result.Release(result)

        append(&collected, raw_bytes)
	}

 	out := make([][]u8, len(collected), allocator)
    copy(out, collected[:])
    return out, true
}



// bgra must be width*height*4 bytes (B8G8R8A8_UNORM, matching your render target).
encode_bgra_frame :: proc(processor: ^IMFTransform, encoder: ^IMFTransform, bgra: []u8, sample_time, sample_duration: i64) -> (nalus: [][]u8, ok: bool) {
    buffer: ^IMFMediaBuffer
    hr := MFCreateMemoryBuffer(u32(len(bgra)), &buffer)
    if hr < 0 {
        log.errorf("MFCreateMemoryBuffer (processor input) failed: 0x%08X", u32(hr))
        return nil, false
    }

    data: [^]u8
    hr = buffer.Lock(buffer, &data, nil, nil)
    if hr < 0 {
        log.errorf("Buffer Lock (processor input) failed: 0x%08X", u32(hr))
        buffer.Release(buffer)
        return nil, false
    }
    mem.copy(data, raw_data(bgra), len(bgra))
    buffer.Unlock(buffer)
    buffer.SetCurrentLength(buffer, u32(len(bgra)))

    sample: ^IMFSample
    hr = MFCreateSample(&sample)
    if hr < 0 {
        log.errorf("MFCreateSample (processor input) failed: 0x%08X", u32(hr))
        buffer.Release(buffer)
        return nil, false
    }
    sample.AddBuffer(sample, buffer)
    sample.SetSampleTime(sample, sample_time)
    sample.SetSampleDuration(sample, sample_duration)

    hr = processor.ProcessInput(processor, 0, sample, 0)
    sample.Release(sample)
    buffer.Release(buffer)
    if hr < 0 {
        log.errorf("ProcessInput (processor) failed: 0x%08X", u32(hr))
        return nil, false
    }

    nv12_samples, drain_ok := drain_transform_samples(processor, 0, context.temp_allocator)
    if !drain_ok do return nil, false

    all_nalus: [dynamic][]u8
    for nv12 in nv12_samples {
        frame_nalus, enc_ok := encode_h264_frame(encoder, nv12, sample_time, sample_duration)
        if !enc_ok do return nil, false
        for n in frame_nalus do append(&all_nalus, n)
    }

    out := make([][]u8, len(all_nalus))
    copy(out, all_nalus[:])
    return out, true
}

end_video_processor :: proc(processor: ^IMFTransform) {
    processor.ProcessMessage(processor, MFT_MESSAGE_COMMAND_DRAIN, 0)
    leftover, _ := drain_transform_samples(processor, 0, context.temp_allocator)
    if len(leftover) > 0 {
        log.warnf("video processor drain produced %d unexpected frame(s) - it may not be a pure 1:1 converter", len(leftover))
    }
    processor.Release(processor)
}
