package ui

import "core:time"

Controls_Request :: enum {
    None,
    Start_Recording,
    Stop_Recording,
    Start_Streaming,
    Stop_Streaming,
}

// Requests are raised here and consumed/cleared by main, which owns the encoder.
// Drawn by the sidebar -- see frame.odin.
Controls_State :: struct {
    request:   Controls_Request,
    recording: bool, // mirrored from main each frame; ui can't query the encoder directly
    streaming: bool, // mirrored from main each frame
    finalizing: bool, // previous recording's MP4 sink still draining/finalizing

    // Stamped by the UI on the off->on edge, for the elapsed timers. Zero when idle.
    rec_started:    time.Time,
    stream_started: time.Time,
}

init_controls_state :: proc() -> Controls_State {
    return Controls_State{}
}
