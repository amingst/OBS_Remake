package ui

import im "libs:odin-imgui"

State :: struct {
    show_demo: bool,
}

draw :: proc(state: ^State, clear_color: ^im.Vec4) {
    if state.show_demo do im.ShowDemoWindow(&state.show_demo)
}

init :: proc() -> State {
    return State{
        show_demo = true,
    }
}