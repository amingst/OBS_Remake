package encode

import mf "libs:mf"
import "core:log"

@(private)
State :: struct {
    sink_writer:        ^mf.IMFSinkWriter,
    video_stream_index: u32,
    audio_stream_index: u32,
    has_audio:          bool,
    width, height:      u32,
    frame_duration:     i64,
    frame_index:        u32,
    recording:          bool,
}

@(private)
g_state: State

start :: proc(
    output_path: string,
    width, height, fps: u32,
    video_bitrate: u32 = 4_000_000,
    audio_sample_rate: u32 = 0,  // 0 = no audio stream
    audio_channels: u32 = 0,
    audio_bitrate: u32 = 16_000, // bytes/sec - must be 12000/16000/20000/24000 for mono/stereo
) -> bool {
    if g_state.recording {
        log.errorf("encode.start called with an already active recording")
        return false
    }

    ok := mf.begin_recording(
        output_path, width, height, fps, video_bitrate,
        audio_sample_rate, audio_channels, audio_bitrate,
        &g_state.sink_writer,
        &g_state.video_stream_index,
        &g_state.audio_stream_index,
    )
    if !ok do return false

    g_state.width = width
    g_state.height = height
    g_state.frame_duration = i64(10_000_000) / i64(fps)
    g_state.frame_index = 0
    g_state.has_audio = audio_channels > 0
    g_state.recording = true
    return true
}

push_video :: proc(pixels: []u8) -> bool {
    if !g_state.recording {
        log.errorf("encode.push_video called with no active recording")
        return false
    }

    expected := int(g_state.width) * int(g_state.height) * 4
    if len(pixels) != expected {
        log.errorf("encode.push_video: expected %d bytes, got %d", expected, len(pixels))
        return false
    }

    sample_time := i64(g_state.frame_index) * g_state.frame_duration
    ok := mf.write_video_frame(g_state.sink_writer, g_state.video_stream_index, pixels, sample_time, g_state.frame_duration)
    if !ok do return false

    g_state.frame_index += 1
    return true
}

// Caller supplies the timestamp explicitly, in 100ns units - the video/audio
// clock strategy isn't decided yet, so this package isn't computing one for
// audio internally either. samples is already-converted interleaved 16-bit
// PCM matching whatever audio_channels was passed to start.
push_audio :: proc(samples: []u8, pts_100ns, duration_100ns: i64) -> bool {
    if !g_state.recording {
        log.errorf("encode.push_audio called with no active recording")
        return false
    }
    if !g_state.has_audio {
        log.errorf("encode.push_audio called but recording was started without an audio stream")
        return false
    }
    if duration_100ns <= 0 {
        log.errorf("encode.push_audio: duration_100ns must be > 0 (zero duration causes a divide-by-zero inside the AAC encoder's ProcessOutput)")
        return false
    }

    return mf.write_audio_frame(g_state.sink_writer, g_state.audio_stream_index, samples, pts_100ns, duration_100ns)
}

stop :: proc() -> bool {
    if !g_state.recording {
        log.errorf("encode.stop called with no active recording")
        return false
    }

    // NOTE: Look to see if I should be handling !ok
    ok := mf.end_recording(g_state.sink_writer)
    g_state.sink_writer = nil
    g_state.recording = false
    return ok;
}
