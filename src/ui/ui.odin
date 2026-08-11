package ui

import im "libs:odin-imgui"

State :: struct {
    show_demo: bool,
    scenes: Scenes_State,
    preview: Preview_State,
    controls: Controls_State,
    mixer: Mixer_State,
    sources: Sources_State
}

draw :: proc(state: ^State, clear_color: ^im.Vec4) {
    im.DockSpaceOverViewport(0, im.GetMainViewport(), {.PassthruCentralNode}, nil)

    // TODO: Refactor this to a menubar.odin
    if im.BeginMainMenuBar() {
        if im.BeginMenu("View") {
            if im.MenuItem("ImGui Demo", "", state.show_demo) {
                state.show_demo = !state.show_demo
            }
            im.EndMenu()
        }
        im.EndMainMenuBar()
    }

    if state.show_demo do im.ShowDemoWindow(&state.show_demo)

    draw_preview(&state.preview)
    draw_scenes(&state.scenes)
    draw_sources(&state.sources)
    draw_mixer(&state.mixer)
    draw_controls(&state.controls)
}

init :: proc() -> State {
    return State{
        show_demo = false,
        scenes = init_scenes_state(),
        preview = init_preview_state(),
        sources = init_sources_state(),
        mixer = init_mixer_state(),
        controls = init_controls_state()
    }
}