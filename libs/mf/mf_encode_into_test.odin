package mf

import "core:fmt"
import "core:sys/windows"
import "core:testing"

@(private="file")
Encode_Pipeline :: struct {
    processor: ^IMFTransform,
    encoder:   ^IMFTransform,
    sps, pps:  []u8,
}

@(private="file")
setup_encode_pipeline :: proc(width, height, fps, bitrate: u32) -> (p: Encode_Pipeline, ok: bool) {
    processor, proc_ok := begin_video_processor(width, height)
    if !proc_ok do return {}, false

    encoder, sps, pps, enc_ok := begin_h264_encoder(width, height, fps, bitrate)
    if !enc_ok {
        end_video_processor(processor)
        return {}, false
    }

    return Encode_Pipeline{processor, encoder, sps, pps}, true
}

@(private="file")
teardown_encode_pipeline :: proc(p: Encode_Pipeline) {
    end_video_processor(p.processor)
    tail := end_h264_encoder(p.encoder)
    for n in tail do delete(n)
    delete(tail)
    delete(p.sps)
    delete(p.pps)
}

// Deterministic, per-frame-varying BGRA pattern so that inter-frame
// prediction actually has something to predict against.
@(private="file")
make_bgra_test_frame :: proc(width, height, frame_index: u32, allocator := context.allocator) -> []u8 {
    bgra := make([]u8, int(width) * int(height) * 4, allocator)
    for y: u32 = 0; y < height; y += 1 {
        for x: u32 = 0; x < width; x += 1 {
            i := (y * width + x) * 4
            bgra[i+0] = u8((x + frame_index * 7) % 256)       // B
            bgra[i+1] = u8((y + frame_index * 13) % 256)      // G
            bgra[i+2] = u8((x + y + frame_index * 29) % 256)  // R
            bgra[i+3] = 255                                    // X
        }
    }
    return bgra
}

@(private="file")
Marker_Ctx :: struct {
    touched: bool,
    calls:   int,
}

@(private="file")
mark_ctx :: proc(ctx: rawptr, nalu: []u8) {
    m := cast(^Marker_Ctx)ctx
    m.touched = true
    m.calls += 1
}

// Verifies the ctx pointer survives the round trip through
// encode_bgra_frame_into's callback intact.
@(test)
test_encode_bgra_frame_into_context_threading :: proc(t: ^testing.T) {
    hr := windows.CoInitializeEx(nil, .MULTITHREADED)
    if !testing.expect(t, hr >= 0, "CoInitializeEx failed") do return
    defer windows.CoUninitialize()

    hr = MFStartup(MF_VERSION, MFSTARTUP_FULL)
    if !testing.expect(t, hr >= 0, "MFStartup failed") do return
    defer MFShutdown()

    width, height, fps, bitrate: u32 = 64, 64, 5, 4_000_000

    p, ok := setup_encode_pipeline(width, height, fps, bitrate)
    if !testing.expect(t, ok, "setup pipeline failed") do return
    defer teardown_encode_pipeline(p)

    frame_duration := i64(10_000_000) / i64(fps)

    marker: Marker_Ctx
    found := false
    // Push frames until the callback actually fires. Early frames may
    // legitimately produce zero NALUs while the encoder primes; this loop
    // only proves the ctx pointer survives the round trip once output
    // exists, not that it fires on frame 0.
    for i: u32 = 0; i < 30; i += 1 {
        bgra := make_bgra_test_frame(width, height, i, context.temp_allocator)
        _, enc_ok := encode_bgra_frame_into(p.processor, p.encoder, bgra, i64(i) * frame_duration, frame_duration, mark_ctx, &marker)
        if !testing.expect(t, enc_ok, fmt.tprintf("encode_bgra_frame_into failed on frame %d", i)) do break
        free_all(context.temp_allocator)
        if marker.touched {
            found = true
            break
        }
    }

    testing.expect(t, found, "callback never fired; ctx pointer may not have reached the callback intact")
    testing.expect(t, marker.calls > 0, "marker.calls should be > 0 once touched")
}
