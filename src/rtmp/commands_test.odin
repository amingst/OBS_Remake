package rtmp

import "core:log"
import "core:sys/windows"
import "core:testing"
import "core:time"
import "libs:flv"
import "libs:h264"
import "libs:mf"

// Needs an RTMP server on 127.0.0.1:1935:
//
//     ffmpeg -listen 1 -i rtmp://0.0.0.0:1935/live/test -c copy out.flv
//
// -listen 1 accepts exactly one connection and exits, so restart it between
// runs -- and note this test and the handshake test in rtmp_test.odin will
// fight over that single connection if the runner uses more than one thread.
// Run with -define:ODIN_TEST_THREADS=1, or run them individually.

@(test)
publish_sequence :: proc(t: ^testing.T) {
    c, ok := connect("127.0.0.1", 1935)
    if !ok {
        log.info("no RTMP server on 127.0.0.1:1935 -- skipping")
        return
    }
    defer close(&c)

    if !handshake(&c) do testing.fail_now(t, "handshake failed")
    if !send_connect(&c, "live", "rtmp://127.0.0.1:1935/live") {
        testing.fail_now(t, "send_connect failed")
    }

    if !send_set_chunk_size(&c, 4096) {
        testing.fail_now(t, "send_set_chunk_size failed")
    }

    // Drain the connect response -- window ack, peer bandwidth, stream begin,
    // and the _result. createStream's reply can't be read until these are off
    // the wire.
    for _ in 0..<4 {
        msg, msg_ok := read_message(&c)
        if !msg_ok do break
        log.infof("connect reply: type=%v len=%v", msg.type_id, len(msg.payload))
    }

    if !send_create_stream(&c) do testing.fail_now(t, "send_create_stream failed")

    stream_id, id_ok := read_create_stream_result(&c)
    testing.expect(t, id_ok, "createStream did not return a stream id")
    log.infof("stream id: %v", stream_id)

    c.stream_id = stream_id

    testing.expect(t, send_publish(&c, "test"), "send_publish failed")

    // onStatus with NetStream.Publish.Start if it worked.
    msg, msg_ok := read_message(&c)
    testing.expect(t, msg_ok, "no reply to publish")
    if msg_ok {
        log.infof("publish reply: type=%v len=%v", msg.type_id, len(msg.payload))
    }
}

@(test)
stream_synthetic_video :: proc(t: ^testing.T) {
    WIDTH      :: 320
    HEIGHT     :: 240
    FPS        :: 30
    BITRATE    :: 2_000_000
    SECONDS    :: 8     // ~4 keyframe intervals at GOP=60
    GOP_FRAMES :: 60    // ~2 s at 30 fps — same rationale as OBS default

    // ---- RTMP session setup (same sequence as publish_sequence) ----

    c, ok := connect("127.0.0.1", 1935)
    if !ok {
        log.info("no RTMP server on 127.0.0.1:1935 -- skipping")
        return
    }
    defer close(&c)

    if !handshake(&c) do testing.fail_now(t, "handshake failed")
    if !send_connect(&c, "live", "rtmp://127.0.0.1:1935/live") {
        testing.fail_now(t, "send_connect failed")
    }
    if !send_set_chunk_size(&c, 4096) {
        testing.fail_now(t, "send_set_chunk_size failed")
    }

    for _ in 0 ..< 4 {
        msg, msg_ok := read_message(&c)
        if !msg_ok do break
        log.infof("connect reply: type=%v len=%v", msg.type_id, len(msg.payload))
    }

    if !send_create_stream(&c) do testing.fail_now(t, "send_create_stream failed")

    stream_id, id_ok := read_create_stream_result(&c)
    if !id_ok do testing.fail_now(t, "createStream did not return a stream id")
    log.infof("stream id: %v", stream_id)
    c.stream_id = stream_id

    if !send_publish(&c, "test") do testing.fail_now(t, "send_publish failed")

    {
        msg, msg_ok := read_message(&c)
        if !msg_ok do testing.fail_now(t, "no reply to publish")
        log.infof("publish reply: type=%v len=%v", msg.type_id, len(msg.payload))
    }

    // ---- encoder init ----

    hr := windows.CoInitializeEx(nil, .MULTITHREADED)
    if windows.FAILED(hr) {
        log.errorf("CoInitializeEx failed: 0x%08X", u32(hr))
        testing.fail_now(t, "CoInitializeEx failed")
    }
    defer windows.CoUninitialize()

    hr = mf.MFStartup(mf.MF_VERSION, mf.MFSTARTUP_FULL)
    if hr < 0 {
        log.errorf("MFStartup failed: 0x%08X", u32(hr))
        testing.fail_now(t, "MFStartup failed")
    }
    defer mf.MFShutdown()

    processor, proc_ok := mf.begin_video_processor(WIDTH, HEIGHT)
    if !proc_ok do testing.fail_now(t, "begin_video_processor failed")

    encoder, sps, pps, enc_ok := mf.begin_h264_encoder(WIDTH, HEIGHT, FPS, BITRATE)
    if !enc_ok {
        mf.end_video_processor(processor)
        testing.fail_now(t, "begin_h264_encoder failed")
    }

    if !mf.set_encoder_gop_size(encoder, GOP_FRAMES) {
        log.warnf("set_encoder_gop_size failed -- encoder will use its default keyframe interval")
    }

    // ---- send AVC sequence header (once, at timestamp 0) ----

    avc_config := h264.build_avc_decoder_config(sps, pps)
    defer delete(avc_config)
    seq_header := flv.build_avc_sequence_header(avc_config)
    defer delete(seq_header)

    if !send_media(&c, 9, seq_header, 0, CSID_VIDEO) {
        delete(sps); delete(pps)
        mf.end_video_processor(processor)
        encoder.Release(encoder)
        testing.fail_now(t, "send_media (sequence header) failed")
    }

    // ---- frame loop ----
    //
    // Timestamps are a monotonic counter in 100 ns units — disposable
    // placeholder, NOT a real audio-master clock.  Sleep paces data at
    // roughly real-time so a live ingest server sees realistic arrival
    // cadence.

    frame_duration := i64(10_000_000) / i64(FPS)   // 100-ns units per frame
    frame_count    := u32(FPS * SECONDS)
    sleep_interval := time.Duration(frame_duration * 100) // 100-ns → nanoseconds

    // Palette that cycles every 30 frames so encoded output stays visually
    // alive (a static solid color produces near-zero P-frame deltas,
    // making liveness invisible).
    palette := [6][3]u8{
        {220, 40,  30},   // B, G, R
        {30,  200, 40},
        {40,  50,  220},
        {200, 200, 30},
        {30,  200, 200},
        {200, 30,  200},
    }

    bgra := make([]u8, int(WIDTH) * int(HEIGHT) * 4)
    defer delete(bgra)

    sent_frames: u32 = 0

    for i: u32 = 0; i < frame_count; i += 1 {
        // Fill BGRA buffer with the current palette entry.
        color := palette[i / 30 % len(palette)]
        for px := 0; px < len(bgra); px += 4 {
            bgra[px + 0] = color[0] // B
            bgra[px + 1] = color[1] // G
            bgra[px + 2] = color[2] // R
            bgra[px + 3] = 255      // X
        }

        sample_time := i64(i) * frame_duration

        nalus, nalus_ok := mf.encode_bgra_frame(processor, encoder, bgra, sample_time, frame_duration)
        if !nalus_ok {
            log.errorf("encode_bgra_frame failed on frame %v", i)
            break
        }

        if len(nalus) > 0 {
            payload, _ := flv.build_avc_frame(nalus)
            if !send_media(&c, 9, payload, sample_time, CSID_VIDEO) {
                log.errorf("send_media failed on frame %v", i)
                delete(payload)
                for n in nalus do delete(n)
                delete(nalus)
                break
            }
            delete(payload)
            sent_frames += 1
        }

        for n in nalus do delete(n)
        delete(nalus)

        time.sleep(sleep_interval)
    }

    // ---- drain tail frames from the encoder ----

    tail := mf.end_h264_encoder(encoder)
    if len(tail) > 0 {
        payload, _ := flv.build_avc_frame(tail)
        pts := i64(sent_frames) * frame_duration
        send_media(&c, 9, payload, pts, CSID_VIDEO)
        delete(payload)
        sent_frames += 1
    }
    for n in tail do delete(n)
    delete(tail)

    mf.end_video_processor(processor)
    delete(sps)
    delete(pps)

    log.infof("stream_synthetic_video: sent %v frames over %v seconds", sent_frames, SECONDS)
    testing.expect(t, sent_frames > 0, "no frames were sent")
}
