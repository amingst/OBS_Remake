package mf

import "core:fmt"
import "core:log"
import "core:slice"
import "core:sys/windows"
import "core:testing"
import "libs:h264"

// ---------------------------------------------------------------------
// encode_bgra_frame vs encode_bgra_frame_into equivalence tests.
//
// encode_bgra_frame_into is the non-allocating replacement for
// encode_bgra_frame. These tests prove the two produce byte-identical
// NALU streams while both still exist, by driving a fresh
// processor/encoder pair through each and comparing output frame by
// frame. The two pipelines must never share a processor or encoder --
// each needs its own so their internal encoder state (rate control,
// GOP position, reference frames) evolves identically from a clean
// start.
// ---------------------------------------------------------------------

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
collect_nalu :: proc(ctx: rawptr, nalu: []u8) {
    list := cast(^[dynamic][]u8)ctx
    // nalu is temp-allocator-backed and only valid until the caller's next
    // free_all(context.temp_allocator) -- copy it out onto the heap.
    append(list, slice.clone(nalu))
}

@(private="file")
free_nalu_list :: proc(nalus: [][]u8) {
    for n in nalus do delete(n)
    delete(nalus)
}

@(private="file")
free_nalu_dynamic :: proc(nalus: [dynamic][]u8) {
    for n in nalus do delete(n)
    delete(nalus)
}

@(test)
test_encode_bgra_frame_into_single_frame_equivalence :: proc(t: ^testing.T) {
    hr := windows.CoInitializeEx(nil, .MULTITHREADED)
    if !testing.expect(t, hr >= 0, "CoInitializeEx failed") do return
    defer windows.CoUninitialize()

    hr = MFStartup(MF_VERSION, MFSTARTUP_FULL)
    if !testing.expect(t, hr >= 0, "MFStartup failed") do return
    defer MFShutdown()

    width, height, fps, bitrate: u32 = 64, 64, 5, 4_000_000

    pa, pa_ok := setup_encode_pipeline(width, height, fps, bitrate)
    if !testing.expect(t, pa_ok, "setup pipeline A (allocating) failed") do return
    defer teardown_encode_pipeline(pa)

    pb, pb_ok := setup_encode_pipeline(width, height, fps, bitrate)
    if !testing.expect(t, pb_ok, "setup pipeline B (into) failed") do return
    defer teardown_encode_pipeline(pb)

    frame_duration := i64(10_000_000) / i64(fps)
    bgra := make_bgra_test_frame(width, height, 0, context.temp_allocator)

    old_nalus, old_ok := encode_bgra_frame(pa.processor, pa.encoder, bgra, 0, frame_duration)
    if !testing.expect(t, old_ok, "encode_bgra_frame failed") do return
    defer free_nalu_list(old_nalus)
    free_all(context.temp_allocator)

    bgra2 := make_bgra_test_frame(width, height, 0, context.temp_allocator)
    new_collected: [dynamic][]u8
    defer free_nalu_dynamic(new_collected)

    count, new_ok := encode_bgra_frame_into(pb.processor, pb.encoder, bgra2, 0, frame_duration, collect_nalu, &new_collected)
    if !testing.expect(t, new_ok, "encode_bgra_frame_into failed") do return
    free_all(context.temp_allocator)

    testing.expect_value(t, count, len(new_collected))
    testing.expect_value(t, len(old_nalus), len(new_collected))

    n := min(len(old_nalus), len(new_collected))
    for i in 0 ..< n {
        testing.expect_value(t, len(old_nalus[i]), len(new_collected[i]))
        testing.expect(t, slice.equal(old_nalus[i], new_collected[i]), fmt.tprintf("NALU %d bytes differ between pipelines", i))
    }
}

@(test)
test_encode_bgra_frame_into_multi_frame_equivalence :: proc(t: ^testing.T) {
    hr := windows.CoInitializeEx(nil, .MULTITHREADED)
    if !testing.expect(t, hr >= 0, "CoInitializeEx failed") do return
    defer windows.CoUninitialize()

    hr = MFStartup(MF_VERSION, MFSTARTUP_FULL)
    if !testing.expect(t, hr >= 0, "MFStartup failed") do return
    defer MFShutdown()

    width, height, fps, bitrate: u32 = 64, 64, 5, 4_000_000
    // The MS software H.264 MFT buffers internally (observed: first output
    // around frame 17 with these settings) before it starts emitting NALUs,
    // so this needs enough frames to actually exercise P-frames and an IDR.
    FRAME_COUNT :: 30

    pa, pa_ok := setup_encode_pipeline(width, height, fps, bitrate)
    if !testing.expect(t, pa_ok, "setup pipeline A (allocating) failed") do return
    defer teardown_encode_pipeline(pa)

    pb, pb_ok := setup_encode_pipeline(width, height, fps, bitrate)
    if !testing.expect(t, pb_ok, "setup pipeline B (into) failed") do return
    defer teardown_encode_pipeline(pb)

    frame_duration := i64(10_000_000) / i64(fps)

    total_nalus := 0
    total_bytes := 0
    found_idr := false

    for i: u32 = 0; i < FRAME_COUNT; i += 1 {
        sample_time := i64(i) * frame_duration

        bgra_old := make_bgra_test_frame(width, height, i, context.temp_allocator)
        old_nalus, old_ok := encode_bgra_frame(pa.processor, pa.encoder, bgra_old, sample_time, frame_duration)
        if !testing.expect(t, old_ok, fmt.tprintf("encode_bgra_frame failed on frame %d", i)) do break
        free_all(context.temp_allocator)

        bgra_new := make_bgra_test_frame(width, height, i, context.temp_allocator)
        new_collected: [dynamic][]u8
        count, new_ok := encode_bgra_frame_into(pb.processor, pb.encoder, bgra_new, sample_time, frame_duration, collect_nalu, &new_collected)
        if !testing.expect(t, new_ok, fmt.tprintf("encode_bgra_frame_into failed on frame %d", i)) {
            free_nalu_list(old_nalus)
            free_nalu_dynamic(new_collected)
            break
        }
        free_all(context.temp_allocator)

        testing.expect_value(t, count, len(new_collected))
        testing.expect(t, len(old_nalus) == len(new_collected),
            fmt.tprintf("frame %d: NALU count mismatch old=%d new=%d", i, len(old_nalus), len(new_collected)))

        n := min(len(old_nalus), len(new_collected))
        for j in 0 ..< n {
            testing.expect(t, len(old_nalus[j]) == len(new_collected[j]),
                fmt.tprintf("frame %d nalu %d: length mismatch old=%d new=%d", i, j, len(old_nalus[j]), len(new_collected[j])))
            testing.expect(t, slice.equal(old_nalus[j], new_collected[j]),
                fmt.tprintf("frame %d nalu %d: byte contents differ", i, j))
            if h264.nal_type(new_collected[j]) == h264.NAL_TYPE_IDR {
                found_idr = true
            }
        }

        total_nalus += len(new_collected)
        for nalu in new_collected do total_bytes += len(nalu)

        free_nalu_list(old_nalus)
        free_nalu_dynamic(new_collected)
    }

    testing.expect(t, found_idr, "no IDR NALU produced across the sequence")
    log.infof("multi-frame equivalence: %d total NALUs, %d total bytes across %d frames", total_nalus, total_bytes, FRAME_COUNT)
}

@(private="file")
Counting_Ctx :: struct {
    count: int,
}

@(private="file")
count_nalu :: proc(ctx: rawptr, nalu: []u8) {
    c := cast(^Counting_Ctx)ctx
    c.count += 1
}

@(test)
test_encode_bgra_frame_into_nalu_count_matches_callback_and_legacy :: proc(t: ^testing.T) {
    hr := windows.CoInitializeEx(nil, .MULTITHREADED)
    if !testing.expect(t, hr >= 0, "CoInitializeEx failed") do return
    defer windows.CoUninitialize()

    hr = MFStartup(MF_VERSION, MFSTARTUP_FULL)
    if !testing.expect(t, hr >= 0, "MFStartup failed") do return
    defer MFShutdown()

    width, height, fps, bitrate: u32 = 64, 64, 5, 4_000_000
    FRAME_COUNT :: 20

    p_legacy, ok1 := setup_encode_pipeline(width, height, fps, bitrate)
    if !testing.expect(t, ok1, "setup legacy pipeline failed") do return
    defer teardown_encode_pipeline(p_legacy)

    p_into, ok2 := setup_encode_pipeline(width, height, fps, bitrate)
    if !testing.expect(t, ok2, "setup into pipeline failed") do return
    defer teardown_encode_pipeline(p_into)

    frame_duration := i64(10_000_000) / i64(fps)

    for i: u32 = 0; i < FRAME_COUNT; i += 1 {
        sample_time := i64(i) * frame_duration

        bgra_legacy := make_bgra_test_frame(width, height, i, context.temp_allocator)
        legacy_nalus, legacy_ok := encode_bgra_frame(p_legacy.processor, p_legacy.encoder, bgra_legacy, sample_time, frame_duration)
        if !testing.expect(t, legacy_ok, fmt.tprintf("encode_bgra_frame failed on frame %d", i)) do break
        free_all(context.temp_allocator)

        bgra_into := make_bgra_test_frame(width, height, i, context.temp_allocator)
        counting: Counting_Ctx
        returned_count, into_ok := encode_bgra_frame_into(p_into.processor, p_into.encoder, bgra_into, sample_time, frame_duration, count_nalu, &counting)
        if !testing.expect(t, into_ok, fmt.tprintf("encode_bgra_frame_into failed on frame %d", i)) {
            free_nalu_list(legacy_nalus)
            break
        }
        free_all(context.temp_allocator)

        testing.expect_value(t, returned_count, counting.count)
        testing.expect_value(t, returned_count, len(legacy_nalus))

        free_nalu_list(legacy_nalus)
    }
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
