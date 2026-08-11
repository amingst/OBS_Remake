package ui

import im "libs:odin-imgui"

Sources_State :: struct {

}

init_sources_state :: proc() -> Sources_State {
    return Sources_State {}
}

draw_sources :: proc(state: ^Sources_State) {
    if im.Begin("Sources") {

    }
    im.End();
}