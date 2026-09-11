package mf

import "core:log"
import "core:mem"
import "core:sys/windows"
import "libs:h264"
import "core:slice"

foreign import mfplat "system:mfplat.lib"

@(default_calling_convention="stdcall")
foreign mfplat {
    MFStartup           :: proc(version: u32, flags: u32) -> windows.HRESULT ---
    MFShutdown          :: proc() -> windows.HRESULT ---
    MFCreateMediaType   :: proc(media_type: ^^IMFMediaType) -> windows.HRESULT ---
    MFCreateMemoryBuffer:: proc(max_length: u32, buffer: ^^IMFMediaBuffer) -> windows.HRESULT ---
    MFCreateSample      :: proc(sample: ^^IMFSample) -> windows.HRESULT ---
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

// Declared here (rather than mf_types.odin, alongside CODECAPI_AVEncMPVGOPSize)
// because this fix is scoped to mf.odin only. Values verified against the
// Windows 10.0.26100.0 SDK's codecapi.h.
CODECAPI_AVEncCommonRateControlMode := windows.GUID{0x1c0608e9, 0x370c, 0x4710, {0x8a, 0x58, 0xcb, 0x61, 0x81, 0xc4, 0x24, 0x23}}
CODECAPI_AVEncCommonMeanBitRate     := windows.GUID{0xf7222374, 0x2144, 0x4815, {0xb5, 0x50, 0xa3, 0x7f, 0x8e, 0x12, 0xee, 0x52}}
eAVEncCommonRateControlMode_CBR :: 0

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

    // ---- rate control + GOP size via ICodecAPI, set BEFORE SetOutputType ----
    // The MS software H.264 MFT frequently requires CODECAPI properties to be
    // committed before the output type is negotiated for them to actually
    // take effect; setting them afterward (as set_encoder_gop_size does, from
    // create_mfts) is accepted (S_OK) but silently ignored by this MFT. Also
    // set an explicit rate control mode: with none configured, the encoder
    // can default to a mode that does not honor GOP size at all.
    codec_api: ^ICodecAPI
    qi_hr := encoder.QueryInterface(encoder, &IID_ICodecAPI, cast(^rawptr)&codec_api)
    if qi_hr < 0 {
        log.warnf("QueryInterface(ICodecAPI) failed: 0x%08X", u32(qi_hr))
    } else {
        rc_mode := VARIANT{vt = VT_UI4, val = u64(eAVEncCommonRateControlMode_CBR)}
        rc_hr := codec_api.SetValue(codec_api, &CODECAPI_AVEncCommonRateControlMode, &rc_mode)
        if rc_hr < 0 {
            log.warnf("ICodecAPI::SetValue(AVEncCommonRateControlMode=CBR) failed: 0x%08X", u32(rc_hr))
        }

        mean_bitrate := VARIANT{vt = VT_UI4, val = u64(bitrate)}
        mbr_hr := codec_api.SetValue(codec_api, &CODECAPI_AVEncCommonMeanBitRate, &mean_bitrate)
        if mbr_hr < 0 {
            log.warnf("ICodecAPI::SetValue(AVEncCommonMeanBitRate=%v) failed: 0x%08X", bitrate, u32(mbr_hr))
        }

        gop_size := fps * 2
        gop := VARIANT{vt = VT_UI4, val = u64(gop_size)}
        gop_hr := codec_api.SetValue(codec_api, &CODECAPI_AVEncMPVGOPSize, &gop)
        if gop_hr < 0 {
            log.warnf("ICodecAPI::SetValue(AVEncMPVGOPSize=%v) failed: 0x%08X", gop_size, u32(gop_hr))
        }

        codec_api.Release(codec_api)
    }

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

// Sets the GOP size (keyframe interval in frames) on a live encoder via
// ICodecAPI. Call after begin_h264_encoder; the MS software H.264 MFT
// accepts this property after type negotiation.
set_encoder_gop_size :: proc(encoder: ^IMFTransform, gop_size: u32) -> bool {
    codec_api: ^ICodecAPI
    hr := encoder.QueryInterface(encoder, &IID_ICodecAPI, cast(^rawptr)&codec_api)
    if hr < 0 {
        log.errorf("QueryInterface(ICodecAPI) failed: 0x%08X", u32(hr))
        return false
    }
    defer codec_api.Release(codec_api)

    v := VARIANT{vt = VT_UI4, val = u64(gop_size)}
    hr = codec_api.SetValue(codec_api, &CODECAPI_AVEncMPVGOPSize, &v)
    if hr < 0 {
        log.errorf("ICodecAPI::SetValue(AVEncMPVGOPSize=%v) failed: 0x%08X", gop_size, u32(hr))
        return false
    }
    return true
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
    defer delete(all_nalus)
    for nv12 in nv12_samples {
        frame_nalus, enc_ok := encode_h264_frame(encoder, nv12, sample_time, sample_duration)
        if !enc_ok {
            for n in all_nalus do delete(n)
            return nil, false
        }
        for n in frame_nalus do append(&all_nalus, n)
        delete(frame_nalus)
    }

    out := make([][]u8, len(all_nalus))
    copy(out, all_nalus[:])
    return out, true
}

encode_bgra_frame_into :: proc(
    processor, encoder: ^IMFTransform,
    bgra: []u8,
    sample_time, sample_duration: i64,
    on_nalu: proc(ctx: rawptr, nalu: []u8),
    ctx: rawptr,
) -> (nalu_count: int, ok: bool) {
	assert(len(bgra) > 0, "bgra frame is empty")
    buffer: ^IMFMediaBuffer
    hr := MFCreateMemoryBuffer(u32(len(bgra)), &buffer)
    if hr < 0 {
        log.errorf("MFCreateMemoryBuffer failed: 0x%08X", u32(hr))
        return 0, false
    }

    data: [^]u8
    hr = buffer.Lock(buffer, &data, nil, nil)
    if hr < 0 {
        log.errorf("IMFMediaBuffer_Lock failed: 0x%08X", u32(hr))
        buffer.Release(buffer)
        return 0, false
    }
    mem.copy(data, raw_data(bgra), len(bgra))
    buffer.Unlock(buffer)
    buffer.SetCurrentLength(buffer, u32(len(bgra)))

    sample: ^IMFSample
    hr = MFCreateSample(&sample)
    if hr < 0 {
        log.errorf("MFCreateSample failed: 0x%08X", u32(hr))
        buffer.Release(buffer)
        return 0, false
    }
    sample.AddBuffer(sample, buffer)
    sample.SetSampleTime(sample, sample_time)
    sample.SetSampleDuration(sample, sample_duration)

    hr = processor.ProcessInput(processor, 0, sample, 0)
    sample.Release(sample)
    buffer.Release(buffer)
    if hr < 0 {
        log.errorf("IMFTransform_ProcessInput failed: 0x%08X", u32(hr))
        return 0, false
    }

    nv12_samples, drain_ok := drain_transform_samples(processor, 0, context.temp_allocator)
    if !drain_ok {
        log.errorf("drain_transform_samples failed")
        return 0, false
    }

    for nv12 in nv12_samples {
        n, enc_ok := encode_h264_frame_into(encoder, nv12, sample_time, sample_duration, on_nalu, ctx)
        if !enc_ok {
            log.errorf("encode_h264_frame_into failed")
            return nalu_count, false
        }
        nalu_count += n
    }
    return nalu_count, true
}

@(private)
drain_encoder_output_into :: proc(
	encoder: ^IMFTransform,
	on_nalu: proc(ctx: rawptr, nalu: []u8),
	ctx: rawptr,
) -> (nalu_count: int, ok: bool) {
	raw_samples, drain_ok := drain_transform_samples(encoder, 0, context.temp_allocator)
	if !drain_ok {
		return 0, false
	}

	for sample_bytes in raw_samples {
		for nalu in h264.split_annexb(sample_bytes, context.temp_allocator) {
			on_nalu(ctx, nalu)
			nalu_count += 1
		}
	}

	return nalu_count, true
}

encode_h264_frame_into :: proc(
	encoder: ^IMFTransform,
	nv12: []u8,
	sample_time: i64,
	sample_duration: i64,
	on_nalu: proc(ctx: rawptr, nalu: []u8),
	ctx: rawptr) -> (nalu_count: int, ok: bool) {
	buffer: ^IMFMediaBuffer
	hr := MFCreateMemoryBuffer(u32(len(nv12)), &buffer)
	if hr < 0 {
		log.errorf("MFCreateMemoryBuffer failed: 0x%08X", u32(hr))
		return 0, false
	}

	data: [^]u8
	hr = buffer.Lock(buffer, &data, nil, nil)
	if hr < 0 {
		log.errorf("Lock failed: 0x%08X", u32(hr))
		buffer.Release(buffer)
		return 0, false
	}
	mem.copy(data, raw_data(nv12), len(nv12))
	buffer.Unlock(buffer)
	buffer.SetCurrentLength(buffer, u32(len(nv12)))

	sample: ^IMFSample
	hr = MFCreateSample(&sample)
	if hr < 0 {
		log.errorf("MFCreateSample failed: 0x%08X", u32(hr))
		buffer.Release(buffer)
		return 0, false
	}
	sample.AddBuffer(sample, buffer)
	sample.SetSampleTime(sample, sample_time)
	sample.SetSampleDuration(sample, sample_duration)

	hr = encoder.ProcessInput(encoder, 0, sample, 0)
	sample.Release(sample)
	buffer.Release(buffer)
	if hr < 0 {
		log.errorf("ProcessInput failed: 0x%08X", u32(hr))
		return 0, false
	}

	return drain_encoder_output_into(encoder, on_nalu, ctx)
}

end_video_processor :: proc(processor: ^IMFTransform) {
    processor.ProcessMessage(processor, MFT_MESSAGE_COMMAND_DRAIN, 0)
    leftover, _ := drain_transform_samples(processor, 0, context.temp_allocator)
    if len(leftover) > 0 {
        log.warnf("video processor drain produced %d unexpected frame(s) - it may not be a pure 1:1 converter", len(leftover))
    }
    processor.Release(processor)
}

begin_aac_encoder :: proc(audio_sample_rate, audio_channels, audio_bitrate: u32) -> (encoder: ^IMFTransform, aac_config: []u8, ok: bool) {
    output_filter := MFT_REGISTER_TYPE_INFO{MFMediaType_Audio, MFAudioFormat_AAC}
    activates: [^]^IMFActivate
    count: u32

    hr := MFTEnumEx(MFT_CATEGORY_AUDIO_ENCODER, MFT_ENUM_FLAG_SYNCMFT, nil, &output_filter, &activates, &count)
    if hr < 0 {
        log.errorf("MFTEnumEx failed: 0x%08X", u32(hr))
        return nil, nil, false
    }
    if count == 0 {
        log.errorf("MFTEnumEx found no synchronous AAC encoder")
        windows.CoTaskMemFree(activates)
        return nil, nil, false
    }

    activate := activates[0]
    for i: u32 = 1; i < count; i += 1 {
        activates[i].Release(activates[i])
    }
    windows.CoTaskMemFree(activates)
    defer activate.Release(activate)

    hr = activate.ActivateObject(activate, &IID_IMFTransform, cast(^rawptr)&encoder)
    if hr < 0 {
        log.errorf("ActivateObject failed: 0x%08X", u32(hr))
        return nil, nil, false
    }

    if !valid_aac_bitrate(audio_channels, audio_bitrate) {
        log.errorf("Invalid AAC bitrate for %d channels: %d", audio_channels, audio_bitrate)
        encoder.Release(encoder)
        return nil, nil, false
    }

    // ---- output type: AAC ----
    output_type: ^IMFMediaType
    hr = MFCreateMediaType(&output_type)
    if hr < 0 {
        log.errorf("MFCreateMediaType (encoder output) failed: 0x%08X", u32(hr))
        encoder.Release(encoder)
        return nil, nil, false
    }

    defer output_type.Release(output_type)
    output_type.SetGUID(output_type, &MF_MT_MAJOR_TYPE, &MFMediaType_Audio)
    output_type.SetGUID(output_type, &MF_MT_SUBTYPE, &MFAudioFormat_AAC)
    if hr = output_type.SetUINT32(output_type, &MF_MT_AAC_PAYLOAD_TYPE, 0); hr < 0 {
        log.errorf("SetUINT32(MF_MT_AAC_PAYLOAD_TYPE) failed: 0x%08X", u32(hr))
    }
    if hr = output_type.SetUINT32(output_type, &MF_MT_AUDIO_NUM_CHANNELS, audio_channels); hr < 0 {
        log.errorf("SetUINT32(output MF_MT_AUDIO_NUM_CHANNELS) failed: 0x%08X", u32(hr))
    }
    if hr = output_type.SetUINT32(output_type, &MF_MT_AUDIO_SAMPLES_PER_SECOND, audio_sample_rate); hr < 0 {
        log.errorf("SetUINT32(output MF_MT_AUDIO_SAMPLES_PER_SECOND) failed: 0x%08X", u32(hr))
    }
    if hr = output_type.SetUINT32(output_type, &MF_MT_AUDIO_BITS_PER_SAMPLE, 16); hr < 0 {
        log.errorf("SetUINT32(output MF_MT_AUDIO_BITS_PER_SAMPLE) failed: 0x%08X", u32(hr))
    }
    if hr = output_type.SetUINT32(output_type, &MF_MT_AUDIO_AVG_BYTES_PER_SECOND, audio_bitrate); hr < 0 {
        log.errorf("SetUINT32(output MF_MT_AUDIO_AVG_BYTES_PER_SECOND) failed: 0x%08X", u32(hr))
    }
    hr = encoder.SetOutputType(encoder, 0, output_type, 0)
    if hr < 0 {
        log.errorf("SetOutputType failed: 0x%08X", u32(hr))
        encoder.Release(encoder)
        return nil, nil, false
    }

    // Diagnostic: read back what the MFT actually negotiated for the output
    // type, to determine whether a requested/negotiated mismatch (e.g. a
    // captured stream reporting 44100 Hz when 48000 was requested) originates
    // here, at type negotiation, rather than downstream.
    current_output: ^IMFMediaType
    hr = encoder.GetOutputCurrentType(encoder, 0, &current_output)
    if hr < 0 {
        log.errorf("GetOutputCurrentType failed: 0x%08X", u32(hr))
        encoder.Release(encoder)
        return nil, nil, false
    }
    defer current_output.Release(current_output)

    neg_out_rate, neg_out_channels, neg_out_bytes: u32
    current_output.GetUINT32(current_output, &MF_MT_AUDIO_SAMPLES_PER_SECOND, &neg_out_rate)
    current_output.GetUINT32(current_output, &MF_MT_AUDIO_NUM_CHANNELS, &neg_out_channels)
    current_output.GetUINT32(current_output, &MF_MT_AUDIO_AVG_BYTES_PER_SECOND, &neg_out_bytes)
    log.infof("AAC output type negotiated: sample_rate requested=%v negotiated=%v, channels requested=%v negotiated=%v, avg_bytes_per_sec requested=%v negotiated=%v",
        audio_sample_rate, neg_out_rate, audio_channels, neg_out_channels, audio_bitrate, neg_out_bytes)

    // ---- input type: PCM ----
    input_type: ^IMFMediaType
    hr = MFCreateMediaType(&input_type)
    if hr < 0 {
        log.errorf("MFCreateMediaType (encoder input) failed: 0x%08X", u32(hr))
        encoder.Release(encoder)
        return nil, nil, false
    }

    block_align := audio_channels * 2
    input_avg_bytes := audio_sample_rate * block_align

    defer input_type.Release(input_type)
    input_type.SetGUID(input_type, &MF_MT_MAJOR_TYPE, &MFMediaType_Audio)
    input_type.SetGUID(input_type, &MF_MT_SUBTYPE, &MFAudioFormat_PCM)
    if hr = input_type.SetUINT32(input_type, &MF_MT_AUDIO_NUM_CHANNELS, audio_channels); hr < 0 {
        log.errorf("SetUINT32(input MF_MT_AUDIO_NUM_CHANNELS) failed: 0x%08X", u32(hr))
    }
    if hr = input_type.SetUINT32(input_type, &MF_MT_AUDIO_SAMPLES_PER_SECOND, audio_sample_rate); hr < 0 {
        log.errorf("SetUINT32(input MF_MT_AUDIO_SAMPLES_PER_SECOND) failed: 0x%08X", u32(hr))
    }
    if hr = input_type.SetUINT32(input_type, &MF_MT_AUDIO_BITS_PER_SAMPLE, 16); hr < 0 {
        log.errorf("SetUINT32(input MF_MT_AUDIO_BITS_PER_SAMPLE) failed: 0x%08X", u32(hr))
    }
    if hr = input_type.SetUINT32(input_type, &MF_MT_AUDIO_AVG_BYTES_PER_SECOND, input_avg_bytes); hr < 0 {
        log.errorf("SetUINT32(input MF_MT_AUDIO_AVG_BYTES_PER_SECOND) failed: 0x%08X", u32(hr))
    }
    if hr = input_type.SetUINT32(input_type, &MF_MT_AUDIO_BLOCK_ALIGNMENT, block_align); hr < 0 {
        log.errorf("SetUINT32(input MF_MT_AUDIO_BLOCK_ALIGNMENT) failed: 0x%08X", u32(hr))
    }
    hr = encoder.SetInputType(encoder, 0, input_type, 0)
    if hr < 0 {
        log.errorf("SetInputType failed: 0x%08X", u32(hr))
        encoder.Release(encoder)
        return nil, nil, false
    }

    // Diagnostic: read back the negotiated input type the same way as the
    // output type above. IMFTransform::GetInputCurrentType is not bound in
    // the IMFTransform vtable in mf_interfaces.odin (declared `rawptr`), so
    // it's invoked here via a local cast rather than widening that file.
    get_input_current_type := cast(proc "stdcall" (this: ^IMFTransform, stream_id: u32, media_type: ^^IMFMediaType) -> windows.HRESULT)(encoder.GetInputCurrentType)
    current_input: ^IMFMediaType
    hr = get_input_current_type(encoder, 0, &current_input)
    if hr < 0 {
        log.errorf("GetInputCurrentType failed: 0x%08X", u32(hr))
    } else {
        defer current_input.Release(current_input)
        neg_in_rate, neg_in_channels, neg_in_bytes: u32
        current_input.GetUINT32(current_input, &MF_MT_AUDIO_SAMPLES_PER_SECOND, &neg_in_rate)
        current_input.GetUINT32(current_input, &MF_MT_AUDIO_NUM_CHANNELS, &neg_in_channels)
        current_input.GetUINT32(current_input, &MF_MT_AUDIO_AVG_BYTES_PER_SECOND, &neg_in_bytes)
        log.infof("AAC input type negotiated: sample_rate requested=%v negotiated=%v, channels requested=%v negotiated=%v, avg_bytes_per_sec requested=%v negotiated=%v",
            audio_sample_rate, neg_in_rate, audio_channels, neg_in_channels, input_avg_bytes, neg_in_bytes)
    }

    // TODO: extract aac_config via MF_MT_USER_DATA
    aac_size: u32
    hr = current_output.GetBlobSize(current_output, &MF_MT_USER_DATA, &aac_size)
    if hr < 0 {
        log.errorf("GetBlobSize(AAC) failed: 0x%08X", u32(hr))
        encoder.Release(encoder)
        return nil, nil, false
    }
    asc_blob := make([]u8, aac_size, context.temp_allocator)
    hr = current_output.GetBlob(current_output, &MF_MT_USER_DATA, raw_data(asc_blob), aac_size, nil)
    if hr < 0 {
        log.errorf("GetBlob(AAC) failed: 0x%08X", u32(hr))
        encoder.Release(encoder)
        return nil, nil, false
    }
    aac_config = slice.clone(asc_blob[12:])

    // Diagnostic: decode the ASC's leading fields to determine whether the
    // [12:] slice offset above is correct, independent of what FLV's own
    // audio tag header (capped at 44100 Hz) reports downstream.
    if len(aac_config) >= 2 {
        b0, b1 := aac_config[0], aac_config[1]
        audio_object_type := (b0 >> 3) & 0x1F
        sampling_freq_index := ((b0 & 0x07) << 1) | (b1 >> 7)
        channel_config := (b1 >> 3) & 0x0F
        log.infof("AAC ASC: raw MF_MT_USER_DATA blob (%v bytes)=%x, extracted ASC after [12:] (%v bytes)=%x, audio_object_type=%v sampling_freq_index=%v channel_config=%v",
            aac_size, asc_blob, len(aac_config), aac_config, audio_object_type, sampling_freq_index, channel_config)
    } else {
        log.warnf("AAC ASC: extracted ASC too short to decode (%v bytes), raw MF_MT_USER_DATA blob (%v bytes)=%x", len(aac_config), aac_size, asc_blob)
    }

    hr = encoder.ProcessMessage(encoder, MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0)
    if hr < 0 {
        log.errorf("ProcessMessage(BEGIN_STREAMING) failed: 0x%08X", u32(hr))
        delete(aac_config)
        encoder.Release(encoder)
        return nil, nil, false
    }

    return encoder, aac_config, true
}

encode_aac_frame :: proc(encoder: ^IMFTransform, raw_pcm_samples: []u8, pcm_sample_time, pcm_sample_duration: i64) -> (aac_data: [][]u8, ok: bool) {
	buffer: ^IMFMediaBuffer
	hr := MFCreateMemoryBuffer(u32(len(raw_pcm_samples)), &buffer)
	if hr < 0 {
		log.errorf("MFCreateMemoryBuffer failed: 0x%08X", u32(hr))
		return nil, false
	}

	data: [^]u8
	hr = buffer.Lock(buffer, &data, nil, nil)
	if hr < 0 {
		log.errorf("Lock failed: 0x%08X", u32(hr))
		buffer.Release(buffer)
		return nil, false
	}
	mem.copy(data, raw_data(raw_pcm_samples), len(raw_pcm_samples))
	hr = buffer.Unlock(buffer)
	if hr < 0 {
		log.errorf("Unlock failed: 0x%08X", u32(hr))
		buffer.Release(buffer)
		return nil, false
	}
	buffer.SetCurrentLength(buffer, u32(len(raw_pcm_samples)))

	sample: ^IMFSample
	hr = MFCreateSample(&sample)
	if hr < 0 {
		log.errorf("MFCreateSample failed: 0x%08X", u32(hr))
		buffer.Release(buffer)
		return nil, false
	}

	sample.AddBuffer(sample, buffer)

	sample.SetSampleTime(sample, pcm_sample_time)
	sample.SetSampleDuration(sample, pcm_sample_duration)

	hr = encoder.ProcessInput(encoder, 0, sample, 0)
	sample.Release(sample)
    buffer.Release(buffer)
	if hr < 0 {
		log.errorf("ProcessInput failed: 0x%08X", u32(hr))
		return nil, false
	}

	return drain_transform_samples(encoder, 0)
}

// Non-allocating counterpart to encode_aac_frame: on_frame is invoked once per
// AAC frame the MFT produces from this PCM block (usually one, but the MFT is
// free to emit zero or several), with a byte slice backed by context.temp_allocator
// that is only valid until the caller's next free_all.
encode_aac_frame_into :: proc(
	encoder: ^IMFTransform,
	raw_pcm_samples: []u8,
	pcm_sample_time, pcm_sample_duration: i64,
	on_frame: proc(ctx: rawptr, frame: []u8),
	ctx: rawptr,
) -> (frame_count: int, ok: bool) {
	buffer: ^IMFMediaBuffer
	hr := MFCreateMemoryBuffer(u32(len(raw_pcm_samples)), &buffer)
	if hr < 0 {
		log.errorf("MFCreateMemoryBuffer failed: 0x%08X", u32(hr))
		return 0, false
	}

	data: [^]u8
	hr = buffer.Lock(buffer, &data, nil, nil)
	if hr < 0 {
		log.errorf("Lock failed: 0x%08X", u32(hr))
		buffer.Release(buffer)
		return 0, false
	}
	mem.copy(data, raw_data(raw_pcm_samples), len(raw_pcm_samples))
	hr = buffer.Unlock(buffer)
	if hr < 0 {
		log.errorf("Unlock failed: 0x%08X", u32(hr))
		buffer.Release(buffer)
		return 0, false
	}
	buffer.SetCurrentLength(buffer, u32(len(raw_pcm_samples)))

	sample: ^IMFSample
	hr = MFCreateSample(&sample)
	if hr < 0 {
		log.errorf("MFCreateSample failed: 0x%08X", u32(hr))
		buffer.Release(buffer)
		return 0, false
	}

	sample.AddBuffer(sample, buffer)
	sample.SetSampleTime(sample, pcm_sample_time)
	sample.SetSampleDuration(sample, pcm_sample_duration)

	hr = encoder.ProcessInput(encoder, 0, sample, 0)
	sample.Release(sample)
	buffer.Release(buffer)
	if hr < 0 {
		log.errorf("ProcessInput failed: 0x%08X", u32(hr))
		return 0, false
	}

	raw_frames, drain_ok := drain_transform_samples(encoder, 0, context.temp_allocator)
	if !drain_ok {
		log.errorf("drain_transform_samples failed")
		return 0, false
	}

	for frame_bytes in raw_frames {
		on_frame(ctx, frame_bytes)
		frame_count += 1
	}
	return frame_count, true
}

end_aac_encoder :: proc(encoder: ^IMFTransform) -> [][]u8 {
	encoder.ProcessMessage(encoder, MFT_MESSAGE_COMMAND_DRAIN, 0)
	tail_frames, _ := drain_transform_samples(encoder, 0)
	encoder.Release(encoder)
	return tail_frames
}
