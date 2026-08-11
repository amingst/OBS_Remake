package ui

import im "libs:odin-imgui"

Mixer_State :: struct {

}

init_mixer_state :: proc() -> Mixer_State {
    return Mixer_State{}
}

draw_mixer :: proc(state: ^Mixer_State) {
    if im.Begin("Audio Mixer") {

    }
    im.End();
}