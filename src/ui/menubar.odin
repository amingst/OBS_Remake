package ui

import "core:fmt"
import im "libs:odin-imgui"
import "../capture"
import "../scene"
import "../settings"

Save_Trigger :: enum {
    None,
    File_Menu,
    Settings_Apply,
    Settings_OK,
}

Settings_State :: struct {
    pending:      settings.Video_Settings,
    preset_idx:   int,          // index into the preset list; == len(presets) means Custom
    was_open:     bool,         // last frame's show_settings, so we can seed on the opening edge
    save_request: Save_Trigger, // raised here, consumed and cleared by main
}

init_settings_state :: proc() -> Settings_State {
    return Settings_State{}
}

@(private="file")
Canvas_Preset :: struct {
    label:  cstring,
    width:  i32,
    height: i32,
}


@(private="file")
build_presets :: proc(outputs: []capture.Output_Info) -> []Canvas_Preset {
    presets := make([dynamic]Canvas_Preset, 0, 3 + len(outputs), context.temp_allocator)
    append(&presets,
        Canvas_Preset{"1920 x 1080", 1920, 1080},
        Canvas_Preset{"2560 x 1440", 2560, 1440},
        Canvas_Preset{"3840 x 2160", 3840, 2160},
    )
    for o in outputs {
        append(&presets, Canvas_Preset{
            label  = fmt.ctprintf("%v (%v x %v)", o.device_name, o.width, o.height),
            width  = o.width,
            height = o.height,
        })
    }
    return presets[:]
}

@(private="file")
match_preset :: proc(presets: []Canvas_Preset, w, h: i32) -> int {
    for p, i in presets {
        if p.width == w && p.height == h {
            return i
        }
    }
    return len(presets)
}

draw_menubar :: proc(
    state: ^State,
    cfg: ^settings.Profile,
    doc: ^scene.Collection,
    outputs: []capture.Output_Info,
    profiles: []settings.Profile_Info,
    collections: []scene.Collection_Info,
) {
    if im.BeginMainMenuBar() {
        draw_file_menu(state, cfg, doc, profiles, collections)
        draw_view_menu(state)
        im.EndMainMenuBar()
    }

    if state.show_settings && !im.IsPopupOpen("Settings") {
        im.OpenPopup("Settings")
    }
    draw_settings(state, cfg, outputs)

    draw_profile_popups(&state.profiles, cfg.name)
    draw_collection_popups(&state.collections, doc.name)
}

@(private="file")
draw_file_menu :: proc(
    state: ^State,
    cfg: ^settings.Profile,
    doc: ^scene.Collection,
    profiles: []settings.Profile_Info,
    collections: []scene.Collection_Info,
) {
    if im.BeginMenu("File") {
        if im.MenuItem("Save Settings") {
            state.settings.save_request = .File_Menu
        }

        im.Separator()

        draw_profile_menu(&state.profiles, profiles, cfg.id, cfg.name)
        draw_collection_menu(&state.collections, collections, doc.id, doc.name)

        im.Separator()

        if im.MenuItem("Settings") {
            state.show_settings = true
            im.OpenPopup("Settings")
        }

        im.EndMenu()
    }
}

@(private="file")
draw_settings :: proc(state: ^State, cfg: ^settings.Profile, outputs: []capture.Output_Info) {
    s := &state.settings
    presets := build_presets(outputs)

    if state.show_settings && !s.was_open {
        s.pending = cfg.video
        s.preset_idx = match_preset(presets, s.pending.canvas_width, s.pending.canvas_height)
    }
    s.was_open = state.show_settings

    // The trailing ###Settings keeps the popup's ID stable (matching the bare
    // "Settings" passed to OpenPopup above -- ImGui hashes only the part
    // after ### when it's present) while the visible title tracks whichever
    // profile is currently active.
    title := fmt.ctprintf("Settings — %s###Settings", cfg.name)
    if im.BeginPopupModal(title, &state.show_settings) {
        if im.BeginTabBar("SettingsTabs") {
            if im.BeginTabItem("Video") {
                preview: cstring = s.preset_idx < len(presets) ? presets[s.preset_idx].label : "Custom"
                if im.BeginCombo("Canvas Resolution", preview) {
                    for p, i in presets {
                        if im.Selectable(p.label, i == s.preset_idx) {
                            s.preset_idx = i
                            s.pending.canvas_width  = p.width
                            s.pending.canvas_height = p.height
                        }
                    }
                    if im.Selectable("Custom", s.preset_idx == len(presets)) {
                        s.preset_idx = len(presets)
                    }
                    im.EndCombo()
                }
                dims := [2]i32{s.pending.canvas_width, s.pending.canvas_height}
                if im.InputInt2("Custom Canvas", &dims) {
                    s.pending.canvas_width, s.pending.canvas_height = dims.x, dims.y
                    s.preset_idx = match_preset(presets, dims.x, dims.y)
                }

                im.InputInt("FPS", &s.pending.fps)

                im.EndTabItem()
            }
            if im.BeginTabItem("Audio") {
                im.EndTabItem()
            }
            if im.BeginTabItem("Output") {
                im.EndTabItem()
            }
            im.EndTabBar()
        }

        im.Separator()

        if im.Button("OK") {
            cfg.video = s.pending
            s.save_request = .Settings_OK
            state.show_settings = false
            im.CloseCurrentPopup()
        }
        im.SameLine()
        if im.Button("Cancel") {
            state.show_settings = false
            im.CloseCurrentPopup()
        }
        im.SameLine()
        if im.Button("Apply") {
            cfg.video = s.pending
            s.save_request = .Settings_Apply
        }

        im.EndPopup()
    }
}

@(private="file")
draw_view_menu :: proc(state: ^State) {
    if im.BeginMenu("View") {
        if im.MenuItem("ImGui Demo", "", state.show_demo) {
            state.show_demo = !state.show_demo
        }
        im.EndMenu()
    }
}
