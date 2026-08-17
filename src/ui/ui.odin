package ui

import "core:log"
import im "libs:odin-imgui"

import "../capture"
import "../scene"

State :: struct {
    show_demo: bool,
    scenes: Scenes_State,
    preview: Preview_State,
    controls: Controls_State,
    mixer: Mixer_State,
    sources: Sources_State
}

// canvas_w/canvas_h are the render target's dimensions -- the coordinate space
// source x/y/w/h live in. Passed in rather than assumed so the two stay in step.
draw :: proc(
    state: ^State,
    doc: ^scene.Collection,
    clear_color: ^im.Vec4,
    preview_tex: im.TextureRef,
    outputs: []capture.Output_Info,
    canvas_w, canvas_h: f32,
) {
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

    draw_preview(&state.preview, preview_tex)
    draw_scenes(&state.scenes, doc)
    draw_sources(&state.sources, &state.scenes, doc, outputs, canvas_w, canvas_h)
    draw_mixer(&state.mixer)
    draw_controls(&state.controls)
}

init_state :: proc(doc: ^scene.Collection) -> State {
    state := State{
        show_demo = false,
        scenes = init_scenes_state(),
        preview = init_preview_state(),
        sources = init_sources_state(),
        mixer = init_mixer_state(),
        controls = init_controls_state()
    }
    if len(doc.scenes) > 0 {
        state.scenes.selected_id = doc.scenes[0].id
    }
    return state
}

destroy :: proc(state: ^State) {
    log.debug("UI state torn down")
    // future panels' destroyers go here
}
