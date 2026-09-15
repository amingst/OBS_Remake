package ui

import im "libs:odin-imgui"

Controls_Request :: enum {
    None,
    Start_Recording,
    Stop_Recording,
    Start_Streaming,
    Stop_Streaming,
}

// Requests are raised here and consumed/cleared by main, which owns the encoder.
Controls_State :: struct {
    request:   Controls_Request,
    recording: bool, // mirrored from main each frame; ui can't query the encoder directly
    streaming: bool, // mirrored from main each frame
    finalizing: bool, // previous recording's MP4 sink still draining/finalizing
}

init_controls_state :: proc() -> Controls_State {
    return Controls_State{}
}

draw_controls :: proc(state: ^Controls_State) {
    if im.Begin("Controls") {
        if state.finalizing {
            im.TextColored({1, 1, 0, 1}, "Finalizing...")
        } else if state.recording {
            if im.Button("Stop") {
                state.request = .Stop_Recording
            }
            im.SameLine()
            im.TextColored({1, 0, 0, 1}, "● REC")
        } else {
            if im.Button("Start") {
                state.request = .Start_Recording
            }
        }

        if state.streaming {
            if im.Button("Stop Stream") {
                state.request = .Stop_Streaming
            }
            im.SameLine()
            im.TextColored({1, 0, 0, 1}, "● LIVE")
        } else {
            if im.Button("Start Stream") {
                state.request = .Start_Streaming
            }
        }
    }
    im.End()
}
