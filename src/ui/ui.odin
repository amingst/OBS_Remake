package ui

import "core:log"
import im "libs:odin-imgui"

import "../capture"
import "../scene"
import "../settings"

State :: struct {
    show_demo: bool,
    show_settings: bool,
    scenes: Scenes_State,
    preview: Preview_State,
    controls: Controls_State,
    mixer: Mixer_State,
    sources: Sources_State,
    settings: Settings_State
}

draw :: proc(
    state: ^State,
    cfg: ^settings.Settings,
    doc: ^scene.Collection,
    clear_color: ^im.Vec4,
    preview_tex: im.TextureRef,
    outputs: []capture.Output_Info,
    canvas_w, canvas_h: f32,
) {
    im.DockSpaceOverViewport(0, im.GetMainViewport(), {.PassthruCentralNode}, nil)

    draw_menubar(state, cfg, outputs);

    draw_preview(&state.preview, preview_tex)
    draw_scenes(&state.scenes, doc)
    draw_sources(&state.sources, &state.scenes, doc, outputs, canvas_w, canvas_h)
    draw_mixer(&state.mixer)
    draw_controls(&state.controls)
}

init_state :: proc(doc: ^scene.Collection) -> State {
    state := State{
        show_demo = false,
        show_settings = false,
        scenes = init_scenes_state(),
        preview = init_preview_state(),
        sources = init_sources_state(),
        mixer = init_mixer_state(),
        controls = init_controls_state(),
        settings = init_settings_state()
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
