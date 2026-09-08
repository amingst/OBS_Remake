package rtmp

import "core:log"
import "core:math"
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
            payload := flv.build_avc_frame(nalus, h264.contains_idr(nalus))
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
        payload := flv.build_avc_frame(tail, h264.contains_idr(tail))
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

// stream_synthetic_audio_video mirrors stream_synthetic_video's setup/loop/
// teardown shape exactly, but also drives an AAC encoder alongside the H264
// one, interleaving audio and video against the same 100-ns clock -- the
// same relationship Rtmp_Stream's real send loop maintains between
// Frame_Mailbox and Audio_Queue, just single-threaded here since this test
// drives both encoders directly with no queue/thread hand-off involved.
//
// A real player (ffplay/VLC) on the receiving ffmpeg -listen 1 dump is the
// actual verification step: confirms an external decoder accepts both
// streams together and stays in sync, not just that the API calls succeeded.
@(test)
stream_synthetic_audio_video :: proc(t: ^testing.T) {
    WIDTH      :: 320
    HEIGHT     :: 240
    FPS        :: 30
    BITRATE    :: 2_000_000
    SECONDS    :: 8
    GOP_FRAMES :: 60

    AUDIO_SAMPLE_RATE   :: 48000
    AUDIO_CHANNELS      :: 2
    AUDIO_BITRATE       :: 16000 // one of valid_aac_bitrate's fixed accepted values for non-5.1 channel counts
    AUDIO_BLOCK_SAMPLES :: 1024  // matches audio.BLOCK_SAMPLES and one AAC frame's sample count
    TONE_FREQ           :: 440.0
    TONE_AMPLITUDE      :: 8000.0

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

    // ---- MF / encoder init ----

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

    audio_encoder, aac_config, audio_enc_ok := mf.begin_aac_encoder(AUDIO_SAMPLE_RATE, AUDIO_CHANNELS, AUDIO_BITRATE)
    if !audio_enc_ok {
        mf.end_video_processor(processor)
        encoder.Release(encoder)
        delete(sps)
        delete(pps)
        testing.fail_now(t, "begin_aac_encoder failed")
    }
    is_stereo :: AUDIO_CHANNELS == 2

    // ---- send AVC sequence header (once, at timestamp 0) ----

    avc_config := h264.build_avc_decoder_config(sps, pps)
    defer delete(avc_config)
    seq_header := flv.build_avc_sequence_header(avc_config)
    defer delete(seq_header)

    if !send_media(&c, 9, seq_header, 0, CSID_VIDEO) {
        mf.end_video_processor(processor)
        encoder.Release(encoder)
        delete(sps)
        delete(pps)
        audio_encoder.Release(audio_encoder)
        delete(aac_config)
        testing.fail_now(t, "send_media (AVC sequence header) failed")
    }

    // ---- send AAC sequence header (once, at timestamp 0) ----

    aac_seq_header := flv.build_aac_sequence_header(aac_config, true, is_stereo)
    defer delete(aac_seq_header)

    if !send_media(&c, 8, aac_seq_header, 0, CSID_AUDIO) {
        mf.end_video_processor(processor)
        encoder.Release(encoder)
        delete(sps)
        delete(pps)
        audio_encoder.Release(audio_encoder)
        delete(aac_config)
        testing.fail_now(t, "send_media (AAC sequence header) failed")
    }

    // ---- interleaved frame loop ----
    //
    // Video paces the loop via time.sleep, one iteration per video frame.
    // Audio has a different, non-integer-dividing cadence (21.33ms/block at
    // 48kHz vs 33.3ms/frame at 30fps), so each iteration emits however many
    // whole audio blocks are due against the *same* 100-ns clock video's
    // sample_time already uses -- 0, 1, or occasionally 2 blocks per video
    // frame, mirroring the "drain everything due, then handle video" order
    // Rtmp_Stream's real send loop uses.

    frame_duration := i64(10_000_000) / i64(FPS)
    audio_block_duration := i64(AUDIO_BLOCK_SAMPLES) * 10_000_000 / i64(AUDIO_SAMPLE_RATE)
    frame_count := u32(FPS * SECONDS)
    sleep_interval := time.Duration(frame_duration * 100)

    palette := [6][3]u8{
        {220, 40,  30},
        {30,  200, 40},
        {40,  50,  220},
        {200, 200, 30},
        {30,  200, 200},
        {200, 30,  200},
    }

    bgra := make([]u8, int(WIDTH) * int(HEIGHT) * 4)
    defer delete(bgra)

    pcm := make([]u8, AUDIO_BLOCK_SAMPLES * AUDIO_CHANNELS * 2)
    defer delete(pcm)

    sent_frames: u32 = 0
    sent_audio_blocks: u32 = 0
    audio_blocks_emitted: i64 = 0
    last_audio_pts: i64 = 0

    for i: u32 = 0; i < frame_count; i += 1 {
        color := palette[i / 30 % len(palette)]
        for px := 0; px < len(bgra); px += 4 {
            bgra[px + 0] = color[0]
            bgra[px + 1] = color[1]
            bgra[px + 2] = color[2]
            bgra[px + 3] = 255
        }

        video_pts := i64(i) * frame_duration

        // ---- emit every audio block due by this point in the shared clock ----
        for audio_blocks_emitted * audio_block_duration <= video_pts {
            for s := 0; s < AUDIO_BLOCK_SAMPLES; s += 1 {
                sample_index := int(audio_blocks_emitted) * AUDIO_BLOCK_SAMPLES + s
                angle := 2.0 * math.PI * TONE_FREQ * f64(sample_index) / f64(AUDIO_SAMPLE_RATE)
                v := i16(TONE_AMPLITUDE * math.sin(angle))
                for ch := 0; ch < AUDIO_CHANNELS; ch += 1 {
                    byte_offset := (s * AUDIO_CHANNELS + ch) * 2
                    pcm[byte_offset+0] = u8(v & 0xFF)
                    pcm[byte_offset+1] = u8((v >> 8) & 0xFF)
                }
            }

            audio_pts := audio_blocks_emitted * audio_block_duration

            aac_data, aac_ok := mf.encode_aac_frame(audio_encoder, pcm, audio_pts, audio_block_duration)
            if !aac_ok {
                log.errorf("encode_aac_frame failed on block %v", audio_blocks_emitted)
                break
            }
            for data in aac_data {
                aac_frame := flv.build_aac_frame(data, true, is_stereo)
                if !send_media(&c, 8, aac_frame, audio_pts, CSID_AUDIO) {
                    log.errorf("send_media (audio) failed on block %v", audio_blocks_emitted)
                }
                delete(aac_frame)
                sent_audio_blocks += 1
            }
            for data in aac_data do delete(data)
            delete(aac_data)

            last_audio_pts = audio_pts
            audio_blocks_emitted += 1
        }

        nalus, nalus_ok := mf.encode_bgra_frame(processor, encoder, bgra, video_pts, frame_duration)
        if !nalus_ok {
            log.errorf("encode_bgra_frame failed on frame %v", i)
            break
        }

        if len(nalus) > 0 {
            payload := flv.build_avc_frame(nalus, h264.contains_idr(nalus))
            if !send_media(&c, 9, payload, video_pts, CSID_VIDEO) {
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

    // ---- drain tail frames from both encoders ----

    tail := mf.end_h264_encoder(encoder)
    if len(tail) > 0 {
        payload := flv.build_avc_frame(tail, h264.contains_idr(tail))
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

    audio_tail := mf.end_aac_encoder(audio_encoder)
    for data in audio_tail {
        aac_frame := flv.build_aac_frame(data, true, is_stereo)
        if !send_media(&c, 8, aac_frame, last_audio_pts, CSID_AUDIO) {
            log.errorf("send_media (audio tail) failed")
        }
        delete(aac_frame)
        sent_audio_blocks += 1
    }
    for data in audio_tail do delete(data)
    delete(audio_tail)
    delete(aac_config)

    log.infof("stream_synthetic_audio_video: sent %v video frame(s), %v audio block(s) over %v seconds",
        sent_frames, sent_audio_blocks, SECONDS)
    testing.expect(t, sent_frames > 0, "no video frames were sent")
    testing.expect(t, sent_audio_blocks > 0, "no audio blocks were sent")
}
