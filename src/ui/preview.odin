package ui

import im "libs:odin-imgui"

Preview_State :: struct {

}

init_preview_state :: proc() -> Preview_State {
    return Preview_State{}
}   

draw_preview :: proc(state: ^Preview_State) {
    if im.Begin("Preview") {
        // Render Preview Here
    }
    im.End()
}