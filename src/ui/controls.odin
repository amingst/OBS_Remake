package ui

import im "libs:odin-imgui"

Controls_Request :: enum {
    None,
    Start_Recording,
    Stop_Recording,
    Start_Streaming,
    Stop_Streaming,
}

// Requests are raised here and consumed/cleared by main -- same pattern as
// Profile_State.request: ui has no access to the encoder and shouldn't call
// into it directly.
Controls_State :: struct {
    request:   Controls_Request,

    // Mirrors main's actual encode.State.recording. ui can't query it
    // directly -- the encoder's state is a private package singleton, and a
    // UI panel reaching into a subsystem would invert the direction requests
    // are supposed to flow -- so main writes this down each frame before
    // ui.draw, and draw_controls only ever reads it back.
    recording: bool,

    // Mirrors main's rtmp streaming state, same reasoning as recording above.
    streaming: bool,

    // True while a previous recording's MP4 sink is draining and finalizing.
    // Neither recording nor idle — the button shows "Finalizing..." and
    // refuses a new recording start until the sink has been reaped.
    finalizing: bool,
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
