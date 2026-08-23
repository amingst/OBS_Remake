package encode

import mf "libs:mf"
import "core:log"

@(private)
State :: struct {
    sink_writer: ^mf.IMFSinkWriter,
    stream_index: u32,
    width, height: u32,
    frame_duration: i64,
    frame_index: u32,
    recording: bool
}

@(private)
g_state: State

start :: proc(
    output_path: string,
    width, height, fps: u32,
    bitrate: u32 = 4_000_000
) -> bool {
    if g_state.recording {
        log.errorf("encode.start called with an already active recording")
        return false
    }

    ok := mf.begin_recording(
        output_path,
        width,
        height,
        fps,
        bitrate,
        &g_state.sink_writer,
        &g_state.stream_index
    )
    if !ok do return false

    g_state.width = width
    g_state.height = height
    g_state.frame_duration = i64(10_000_000) / i64(fps)
    g_state.frame_index = 0
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
    ok := mf.write_video_frame(g_state.sink_writer, g_state.stream_index, pixels, sample_time, g_state.frame_duration)
    if !ok do return false

    g_state.frame_index += 1
    return true
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