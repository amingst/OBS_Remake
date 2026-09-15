package ui

import "core:os"
import "core:log"
import im "libs:odin-imgui"

import "../capture"
import "../scene"
import "../settings"
import "../audio"

DEFAULT_LAYOUT :: #load("default_layout.ini", string)

State :: struct {
    version: string, // shown in the status bar; supplied by main
    show_demo: bool,
    show_settings: bool,
    scenes: Scenes_State,
    preview: Preview_State,
    controls: Controls_State,
    mixer: Mixer_State,
    sources: Sources_State,
    settings: Settings_State,
    profiles: Profile_State,
    collections: Collection_State,
}

draw :: proc(
    state: ^State,
    cfg: ^settings.Profile,
    doc: ^scene.Collection,
    clear_color: ^im.Vec4,
    preview_tex: im.TextureRef,
    outputs: []capture.Output_Info,
    profiles: []settings.Profile_Info,
    collections: []scene.Collection_Info,
    canvas_w, canvas_h: f32,
    audio_devices: []audio.Device_Info
) {
    // Chrome first: it shrinks the viewport work area the dockspace then fills.
    draw_chrome(state, cfg, doc, profiles, collections)
    im.DockSpaceOverViewport(0, im.GetMainViewport(), {.PassthruCentralNode}, nil)

    draw_preview(&state.preview, &state.sources, &state.scenes, doc, preview_tex, canvas_w, canvas_h)
    draw_scenes(&state.scenes, doc)
    draw_sources(&state.sources, &state.scenes, doc, outputs, canvas_w, canvas_h, audio_devices)
    draw_mixer(&state.mixer, &state.scenes, doc)

    draw_modals(state, cfg, doc, outputs, state.controls.streaming)
}

init_state :: proc(doc: ^scene.Collection, version: string) -> State {
    state := State{
        version = version,
        show_demo = false,
        show_settings = false,
        scenes = init_scenes_state(),
        preview = init_preview_state(),
        sources = init_sources_state(),
        mixer = init_mixer_state(),
        controls = init_controls_state(),
        settings = init_settings_state(),
        profiles = init_profiles_state(),
        collections = init_collections_state(),
    }
    if len(doc.scenes) > 0 {
        state.scenes.selected_id = doc.scenes[0].id
    }
    return state
}

load_layout :: proc() {
// Load Default IMGUI Layout from default_layout.ini
		io := im.GetIO()
		io.IniFilename = "imgui.ini"

		if !os.exists(string(io.IniFilename)) {
			im.LoadIniSettingsFromMemory(
				cstring(raw_data(DEFAULT_LAYOUT)),
				uint(len(DEFAULT_LAYOUT))
			)
		}
}

destroy :: proc(state: ^State) {
    log.debug("UI state torn down")
    destroy_sources_state(&state.sources)
    // future panels' destroyers go here
}
