package mf

import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:sys/windows"
import "core:testing"

@(private="file") RPC_E_CHANGED_MODE :: windows.HRESULT(-2147417850) // 0x80010106

// Writes `seconds` of a solid BGRA color to `output_path` as H264/MP4.
// Assumes COM is already initialized on this thread (same as your DXGI/WASAPI setup).
@(private)
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
write_annexb :: proc(file: ^os.File, nalu: []u8) {
    os.write(file, []u8{0, 0, 0, 1})
    os.write(file, nalu)
}

@(private)
test_encode_solid_nv12 :: proc(output_path: string, width, height, fps, seconds: u32) -> bool {
    hr := MFStartup(MF_VERSION, MFSTARTUP_FULL)
    if hr < 0 {
        log.errorf("MFStartup failed: 0x%08X", u32(hr))
        return false
    }
    defer MFShutdown()

    encoder, sps, pps, ok := begin_h264_encoder(width, height, fps, 4_000_000)
    if !ok do return false
    defer { delete(sps); delete(pps) }

    y_size := int(width) * int(height)
    uv_size := y_size / 2
    nv12 := make([]u8, y_size + uv_size, context.temp_allocator)
    for i in 0 ..< y_size do nv12[i] = 96          // mid-gray luma
    for i in y_size ..< y_size + uv_size do nv12[i] = 128 // neutral chroma

    frame_duration := i64(10_000_000) / i64(fps)
    frame_count := fps * seconds

    file, ferr := os.open(output_path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
    if ferr != nil {
        log.errorf("failed to open %s: %v", output_path, ferr)
        encoder.Release(encoder)
        return false
    }
    defer os.close(file)

    write_annexb(file, sps)
    write_annexb(file, pps)

    for i: u32 = 0; i < frame_count; i += 1 {
        nalus, enc_ok := encode_h264_frame(encoder, nv12, i64(i) * frame_duration, frame_duration)
        if !enc_ok {
            encoder.Release(encoder)
            return false
        }
        for nalu in nalus do write_annexb(file, nalu)
        for nalu in nalus do delete(nalu)
        delete(nalus)
    }

    tail := end_h264_encoder(encoder)
    for nalu in tail do write_annexb(file, nalu)
    for nalu in tail do delete(nalu)
    delete(tail)

    return true
}

@(private="file")
with_com :: proc() -> (uninit: bool) {
    hr := windows.CoInitializeEx(nil, .APARTMENTTHREADED)
    if windows.FAILED(hr) && hr != RPC_E_CHANGED_MODE {
        log.errorf("CoInitializeEx failed: 0x%08X", u32(hr))
        return false
    }
    return true
}

// Output lands in build/test-output/ and is intentionally left on disk
// (both on success and failure) so the encoded clip can be opened in
// VLC/ffplay to confirm it's actually decodable, not just API-successful.
@(private)
test_output_dir :: "build/test-output"

@(private)
ensure_test_output_dir :: proc() -> bool {
    // Same "already-there is the steady state" pattern as config.odin's make_dir.
    if err := os.make_directory("build"); err != nil && err != os.General_Error.Exist {
        log.warnf("could not create build directory: %v", err)
        return false
    }
    if err := os.make_directory(test_output_dir); err != nil && err != os.General_Error.Exist {
        log.warnf("could not create %s directory: %v", test_output_dir, err)
        return false
    }
    return true
}

@(private)
log_test_output_path :: proc(path: string) {
    abs_path, aerr := filepath.abs(path)
    if aerr != nil {
        log.infof("wrote test clip to %s", path)
        return
    }
    defer delete(abs_path)
    log.infof("wrote test clip to %s", abs_path)
}

@(test)
test_sink_writer_solid_clip :: proc(t: ^testing.T) {
    if !with_com() do return
    defer windows.CoUninitialize()

    if !testing.expect(t, ensure_test_output_dir(), "could not create test output directory") do return

    path, jerr := filepath.join({test_output_dir, "sink_writer_solid_clip.mp4"})
    if !testing.expect(t, jerr == nil, "could not build test output path") do return
    defer delete(path)

    // MFCreateSinkWriterFromURL doesn't guarantee overwrite semantics for an
    // existing file; remove any stale clip from a previous run up front so
    // re-running the test is never blocked by leftover output.
    os.remove(path)

    ok := test_write_solid_clip(path, 64, 64, 5, 1, 0, 0, 255)
    if ok do log_test_output_path(path)
    testing.expect(t, ok, "test_write_solid_clip failed")
}

@(test)
test_h264_transform_solid_nv12 :: proc(t: ^testing.T) {
    if !with_com() do return
    defer windows.CoUninitialize()

    if !testing.expect(t, ensure_test_output_dir(), "could not create test output directory") do return

    path, jerr := filepath.join({test_output_dir, "h264_transform_solid_nv12.h264"})
    if !testing.expect(t, jerr == nil, "could not build test output path") do return
    defer delete(path)

    ok := test_encode_solid_nv12(path, 64, 64, 5, 1)
    if ok do log_test_output_path(path)
    testing.expect(t, ok, "test_encode_solid_nv12 failed")
}

@(test)
test_h264_transform_solid_bgra :: proc(t: ^testing.T) {
    hr := windows.CoInitializeEx(nil, .MULTITHREADED)
    testing.expect(t, hr >= 0)
    defer windows.CoUninitialize()

    hr = MFStartup(MF_VERSION, MFSTARTUP_FULL)
    testing.expect(t, hr >= 0)
    defer MFShutdown()

    width, height, fps, seconds: u32 = 64, 64, 5, 1

    processor, proc_ok := begin_video_processor(width, height)
    testing.expect(t, proc_ok)
    if !proc_ok do return
    defer end_video_processor(processor)

    encoder, sps, pps, enc_ok := begin_h264_encoder(width, height, fps, 4_000_000)
    testing.expect(t, enc_ok)
    if !enc_ok do return
    defer { delete(sps); delete(pps) }

    // Solid BGRA color - B8G8R8A8_UNORM byte order, matching the real render target.
    bgra := make([]u8, int(width) * int(height) * 4, context.temp_allocator)
    for i := 0; i < len(bgra); i += 4 {
        bgra[i+0] = 200 // B
        bgra[i+1] = 60  // G
        bgra[i+2] = 40  // R
        bgra[i+3] = 255 // X
    }

    path :: "build/test-output/h264_transform_solid_bgra.h264"
    file, ferr := os.open(path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
    testing.expect(t, ferr == nil)
    if ferr != nil {
        encoder.Release(encoder)
        return
    }
    defer os.close(file)

    write_annexb(file, sps)
    write_annexb(file, pps)

    frame_duration := i64(10_000_000) / i64(fps)
    frame_count := fps * seconds

    all_ok := true
    for i: u32 = 0; i < frame_count; i += 1 {
        nalus, frame_ok := encode_bgra_frame(processor, encoder, bgra, i64(i) * frame_duration, frame_duration)
        if !frame_ok {
            all_ok = false
            break
        }
        for nalu in nalus {
            write_annexb(file, nalu)
            delete(nalu)
        }
        delete(nalus)
    }
    testing.expect(t, all_ok)

    tail := end_h264_encoder(encoder)
    for nalu in tail {
        write_annexb(file, nalu)
        delete(nalu)
    }
    delete(tail)

    log.infof("wrote test clip to %s", path)
}
