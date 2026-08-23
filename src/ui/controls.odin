package ui

import im "libs:odin-imgui"

Controls_Request :: enum {
    None,
    Start_Recording,
    Stop_Recording,
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
}

init_controls_state :: proc() -> Controls_State {
    return Controls_State{}
}

draw_controls :: proc(state: ^Controls_State) {
    if im.Begin("Controls") {
        if state.recording {
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
    }
    im.End()
}
