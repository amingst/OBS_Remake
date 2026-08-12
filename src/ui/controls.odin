package ui

import im "libs:odin-imgui"

Controls_State :: struct {

}

init_controls_state :: proc() -> Controls_State {
    return Controls_State {

    }
}

draw_controls :: proc(state: ^Controls_State) {
    if im.Begin("Controls") {

    }
    im.End()
}