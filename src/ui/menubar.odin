package ui

import "core:fmt"
import "core:strings"
import im "libs:odin-imgui"
import "../capture"
import "../scene"
import "../settings"
import "../show"

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

    // Stream (Output tab) fields, edited via fixed byte buffers and only
    // turned back into owned strings on Apply/OK.
    stream_host_buf:  [128]u8,
    stream_app_buf:   [128]u8,
    stream_tcurl_buf: [256]u8,
    stream_key_buf:   [128]u8,
    stream_port:      i32,
    stream_bitrate:   i32,
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

// Menu entries only -- the caller supplies the menu bar (see draw_top_bar).
draw_menus :: proc(
    state: ^State,
    cfg: ^settings.Profile,
    doc: ^scene.Collection,
    show_cfg: ^show.Show,
    profiles: []settings.Profile_Info,
    collections: []scene.Collection_Info,
    shows: []show.Show_Info,
) {
    draw_file_menu(state, cfg, doc, show_cfg, profiles, collections, shows)
    draw_view_menu(state)
}

// Modals owned by the menus; drawn at top level, after the chrome.
draw_modals :: proc(
    state: ^State,
    cfg: ^settings.Profile,
    doc: ^scene.Collection,
    show_cfg: ^show.Show,
    outputs: []capture.Output_Info,
    streaming: bool,
) {
    if state.show_settings && !im.IsPopupOpen("Settings") {
        im.OpenPopup("Settings")
    }
    draw_settings(state, cfg, outputs, streaming)

    draw_profile_popups(&state.profiles, cfg.name)
    draw_collection_popups(&state.collections, doc.name)
    draw_show_popups(&state.shows, show_cfg.name)
}

@(private="file")
draw_file_menu :: proc(
    state: ^State,
    cfg: ^settings.Profile,
    doc: ^scene.Collection,
    show_cfg: ^show.Show,
    profiles: []settings.Profile_Info,
    collections: []scene.Collection_Info,
    shows: []show.Show_Info,
) {
    if im.BeginMenu("File") {
        if im.MenuItem("Save Settings") {
            state.settings.save_request = .File_Menu
        }

        im.Separator()

        draw_profile_menu(&state.profiles, profiles, cfg.id, cfg.name)
        draw_collection_menu(&state.collections, collections, doc.id, doc.name)
        draw_show_menu(&state.shows, shows, show_cfg.id, show_cfg.name)

        im.Separator()

        if im.MenuItem("Settings") {
            state.show_settings = true
            im.OpenPopup("Settings")
        }

        im.EndMenu()
    }
}

@(private="file")
draw_settings :: proc(state: ^State, cfg: ^settings.Profile, outputs: []capture.Output_Info, streaming: bool) {
    s := &state.settings
    presets := build_presets(outputs)

    if state.show_settings && !s.was_open {
        s.pending = cfg.video
        s.preset_idx = match_preset(presets, s.pending.canvas_width, s.pending.canvas_height)

        seed_name_buf(s.stream_host_buf[:], cfg.stream.host)
        seed_name_buf(s.stream_app_buf[:], cfg.stream.app)
        seed_name_buf(s.stream_tcurl_buf[:], cfg.stream.tc_url)
        seed_name_buf(s.stream_key_buf[:], cfg.stream.stream_key)
        s.stream_port = cfg.stream.port
        s.stream_bitrate = cfg.stream.bitrate
    }
    s.was_open = state.show_settings

    // ###Settings keeps the popup ID stable while the title shows the active profile.
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
                // No live-reconcile for stream settings, so disable editing mid-stream.
                if streaming {
                    im.TextColored({1, 0.7, 0, 1}, "Stop the stream to edit these settings.")
                }
                im.BeginDisabled(streaming)

                im.InputText("Host", cstring(&s.stream_host_buf[0]), len(s.stream_host_buf))
                port := s.stream_port
                if im.InputInt("Port", &port) {
                    s.stream_port = port
                }
                im.InputText("App", cstring(&s.stream_app_buf[0]), len(s.stream_app_buf))
                im.InputText("TC URL", cstring(&s.stream_tcurl_buf[0]), len(s.stream_tcurl_buf))
                im.InputText("Stream Key", cstring(&s.stream_key_buf[0]), len(s.stream_key_buf), {.Password})
                bitrate := s.stream_bitrate
                if im.InputInt("Bitrate (bps)", &bitrate) {
                    s.stream_bitrate = bitrate
                }

                im.EndDisabled()
                im.EndTabItem()
            }
            im.EndTabBar()
        }

        im.Separator()

        if im.Button("OK") {
            cfg.video = s.pending
            apply_stream_settings(s, cfg)
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
            apply_stream_settings(s, cfg)
            s.save_request = .Settings_Apply
        }

        im.EndPopup()
    }
}

// Frees the profile's current stream strings before cloning the edited buffers over them.
@(private="file")
apply_stream_settings :: proc(s: ^Settings_State, cfg: ^settings.Profile) {
    delete(cfg.stream.host)
    delete(cfg.stream.app)
    delete(cfg.stream.tc_url)
    delete(cfg.stream.stream_key)

    cfg.stream = {
        host       = read_stream_field(s.stream_host_buf[:]),
        port       = s.stream_port,
        app        = read_stream_field(s.stream_app_buf[:]),
        tc_url     = read_stream_field(s.stream_tcurl_buf[:]),
        stream_key = read_stream_field(s.stream_key_buf[:]),
        bitrate    = s.stream_bitrate,
    }
}

// Unlike read_name_buf (profiles.odin), an empty stream field is valid.
@(private="file")
read_stream_field :: proc(buf: []u8) -> string {
    n := strings.index_byte(string(buf), 0)
    if n < 0 {
        n = len(buf)
    }
    return strings.clone(string(buf[:n]))
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
