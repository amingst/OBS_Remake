package ui

import "core:fmt"
import "core:log"
import "core:strings"
import im "libs:odin-imgui"
import "../capture"
import "../scene"
import "../audio"

// Audio input and output are separate choices here but construct the same
// Audio_Data variant -- they differ only in the loopback flag.
Source_Kind_Choice :: enum i32 {
    Color,
    Display,
    Audio_Input,
    Audio_Output,
}

Sources_State :: struct {
    selected_id:   u64, // 0 == nothing selected; ids start at 1
    name_buf:      [128]u8,
    kind_choice:   Source_Kind_Choice,
    output_choice: int, // index into the enumerated outputs, for the Add popup
    audio_choice:  int, // index into the *filtered* device list, for the Add popup
}

init_sources_state :: proc() -> Sources_State {
    return Sources_State{}
}

// "\\.\DISPLAY1 (2560x1600)". Temp-allocated, so it lives until the end of the
// frame -- long enough for ImGui to copy it.
@(private="file")
output_label :: proc(o: capture.Output_Info) -> cstring {
    return fmt.ctprintf("%v (%vx%v)", o.device_name, o.width, o.height)
}

@(private="file")
audio_label :: proc(d: audio.Device_Info) -> cstring {
    return fmt.ctprintf("%v", d.name)
}

// Index of the output a display source is currently pointed at, or -1 if the
// indices don't match anything we enumerated (e.g. a monitor was unplugged).
@(private="file")
find_output :: proc(outputs: []capture.Output_Info, adapter_index, output_index: i32) -> int {
    for o, i in outputs {
        if i32(o.adapter_index) == adapter_index && i32(o.output_index) == output_index {
            return i
        }
    }
    return -1
}

// The devices matching a source's direction. Temp-allocated and rebuilt each
// frame; the Device_Info strings are borrowed from the caller's slice, so the
// result must not outlive the frame.
@(private="file")
audio_devices_for :: proc(devices: []audio.Device_Info, is_loopback: bool) -> []audio.Device_Info {
    out := make([dynamic]audio.Device_Info, 0, len(devices), context.temp_allocator)
    for d in devices {
        if d.is_loopback == is_loopback do append(&out, d)
    }
    return out[:]
}

// Sizes a source to fill the canvas while preserving its native aspect ratio,
// centred -- letterboxed or pillarboxed depending on which axis binds. Same
// width-first-then-correct shape as the preview panel fit in preview.odin.
// Colour sources have no native aspect, so they just take the canvas'.
@(private="file")
fit_to_canvas :: proc(src: ^scene.Source, outputs: []capture.Output_Info, canvas_w, canvas_h: f32) {
    aspect := canvas_w / canvas_h
    if d, is_display := src.data.(scene.Display_Data); is_display {
        if i := find_output(outputs, d.adapter_index, d.output_index); i >= 0 && outputs[i].height > 0 {
            aspect = f32(outputs[i].width) / f32(outputs[i].height)
        }
    }

    size := [2]f32{canvas_w, canvas_w / aspect}
    if size.y > canvas_h {
        size = {canvas_h * aspect, canvas_h}
    }

    src.w, src.h = size.x, size.y
    src.x = (canvas_w - size.x) * 0.5
    src.y = (canvas_h - size.y) * 0.5
}

// Combo listing every enumerated output. Picking a different one rewrites the
// source's indices and tears the capture down, so the frame loop restarts it.
@(private="file")
draw_output_picker :: proc(d: ^scene.Display_Data, outputs: []capture.Output_Info) {
    if len(outputs) == 0 {
        im.TextDisabled("No outputs available")
        return
    }

    current := find_output(outputs, d.adapter_index, d.output_index)
    preview: cstring = current >= 0 ? output_label(outputs[current]) : "<unavailable>"

    if im.BeginCombo("Output", preview) {
        for o, i in outputs {
            if im.Selectable(output_label(o), i == current) && i != current {
                log.infof("display source output %v/%v -> %v/%v (%v), restarting capture",
                    d.adapter_index, d.output_index, o.adapter_index, o.output_index, o.device_name)
                d.adapter_index = i32(o.adapter_index)
                d.output_index  = i32(o.output_index)
                scene.reset_display_capture(d)
            }
        }
        im.EndCombo()
    }
}

// Device combo plus the mixer params. A device that's been unplugged since the
// source was saved won't be in the list -- shown as unavailable rather than
// silently repointed at something else.
@(private="file")
draw_audio_picker :: proc(d: ^scene.Audio_Data, devices: []audio.Device_Info) {
    matching := audio_devices_for(devices, d.is_loopback)
    if len(matching) == 0 {
        im.TextDisabled("No matching audio devices")
    } else {
        current := -1
        for m, i in matching {
            if m.id == d.device_id {
                current = i
                break
            }
        }
        preview: cstring = current >= 0 ? audio_label(matching[current]) : "<unavailable>"

        if im.BeginCombo("Device", preview) {
            for m, i in matching {
                if im.Selectable(audio_label(m), i == current) && i != current {
                    log.infof("audio source device -> %q", m.name)
                    if d.stream != nil {
                        audio.release_stream(d.device_id)
                        d.stream = nil
                    }
                    delete(d.device_id)
                    d.device_id = strings.clone(m.id)
                    d.next_retry = {}
                }
            }
            im.EndCombo()
        }
    }

    // volume/muted come from the embedded Audio_Params, so they're reachable
    // without going through d.params.
    im.SliderFloat("Volume", &d.volume, 0, 1)
    im.Checkbox("Muted", &d.muted)
}

draw_sources :: proc(
    state: ^Sources_State,
    scenes: ^Scenes_State,
    doc: ^scene.Collection,
    outputs: []capture.Output_Info,
    canvas_w, canvas_h: f32,
    devices: []audio.Device_Info,
) {
    if im.Begin("Sources") {
        sc := scene.find(doc, scenes.selected_id)
        if sc == nil {
            im.TextDisabled("No scene selected")
        } else {
            if im.Button("+") {
                im.OpenPopup("Add Source")
            }

            if im.BeginPopupModal("Add Source") {
                im.InputText("Name", cstring(&state.name_buf[0]), len(state.name_buf))

                im.RadioButtonIntPtr("Colour", (^i32)(&state.kind_choice), i32(Source_Kind_Choice.Color))
                im.SameLine()
                im.RadioButtonIntPtr("Display Capture", (^i32)(&state.kind_choice), i32(Source_Kind_Choice.Display))
                im.RadioButtonIntPtr("Audio Input", (^i32)(&state.kind_choice), i32(Source_Kind_Choice.Audio_Input))
                im.SameLine()
                im.RadioButtonIntPtr("Audio Output", (^i32)(&state.kind_choice), i32(Source_Kind_Choice.Audio_Output))

                if state.kind_choice == .Display {
                    if len(outputs) == 0 {
                        im.TextDisabled("No outputs available")
                    } else {
                        if state.output_choice >= len(outputs) do state.output_choice = 0
                        if im.BeginCombo("Output", output_label(outputs[state.output_choice])) {
                            for o, i in outputs {
                                if im.Selectable(output_label(o), i == state.output_choice) {
                                    state.output_choice = i
                                }
                            }
                            im.EndCombo()
                        }
                    }
                }

                if state.kind_choice == .Audio_Input || state.kind_choice == .Audio_Output {
                    matching := audio_devices_for(devices, state.kind_choice == .Audio_Output)
                    if len(matching) == 0 {
                        im.TextDisabled("No matching audio devices")
                    } else {
                        if state.audio_choice >= len(matching) do state.audio_choice = 0
                        if im.BeginCombo("Device", audio_label(matching[state.audio_choice])) {
                            for m, i in matching {
                                if im.Selectable(audio_label(m), i == state.audio_choice) {
                                    state.audio_choice = i
                                }
                            }
                            im.EndCombo()
                        }
                    }
                }

                if im.Button("Add") {
                    n := strings.index_byte(string(state.name_buf[:]), 0)
                    if n < 0 {
                        log.warn("source name truncated at 128 bytes (no NUL found)")
                        n = len(state.name_buf)
                    }
                    name := string(state.name_buf[:n])

                    if len(name) == 0 {
                        log.debug("empty source name rejected")
                    } else {
                        data: scene.Source_Data
                        switch state.kind_choice {
                        case .Color:
                            data = scene.Color_Data{}
                        case .Display:
                            d := scene.Display_Data{}
                            if len(outputs) > 0 {
                                o := outputs[state.output_choice]
                                d.adapter_index = i32(o.adapter_index)
                                d.output_index  = i32(o.output_index)
                            }
                            data = d
                        case .Audio_Input, .Audio_Output:
                            // volume defaults to 1.0 explicitly -- the zero
                            // value would make a new source silent.
                            a := scene.Audio_Data{
                                is_loopback = state.kind_choice == .Audio_Output,
                                params      = {volume = 1.0},
                            }
                            matching := audio_devices_for(devices, a.is_loopback)
                            if len(matching) > 0 {
                                a.device_id = strings.clone(matching[state.audio_choice].id)
                            }
                            data = a
                        }

                        state.selected_id = scene.create_source(doc, sc, name, data)

                        // A display capture at the default 400x300 is badly
                        // squashed, so start it at its native aspect instead.
                        if state.kind_choice == .Display {
                            if src := scene.find_source(sc, state.selected_id); src != nil {
                                fit_to_canvas(src, outputs, canvas_w, canvas_h)
                            }
                        }

                        state.name_buf      = {}
                        state.kind_choice   = .Color
                        state.audio_choice  = 0
                        state.output_choice = 0
                        im.CloseCurrentPopup()
                    }
                }
                im.SameLine()
                if im.Button("Cancel") {
                    state.name_buf      = {}
                    state.kind_choice   = .Color
                    state.audio_choice  = 0
                    state.output_choice = 0
                    im.CloseCurrentPopup()
                }
                im.EndPopup()
            }

            if len(sc.sources) == 0 {
                im.TextDisabled("No sources in this scene")
            }

            to_delete := -1

            for &src, i in sc.sources {
                im.PushIDInt(i32(src.id))

                im.Checkbox("##visible", &src.visible)
                im.SameLine()

                label := strings.clone_to_cstring(src.name, context.temp_allocator)
                if im.Selectable(label, state.selected_id == src.id) {
                    state.selected_id = src.id
                }

                if im.BeginPopupContextItem() {
                    if im.MenuItem("Delete") {
                        to_delete = i
                    }
                    im.EndPopup()
                }

                im.PopID()
            }

            if src := scene.find_source(sc, state.selected_id); src != nil {
                im.Separator()

                // Geometry is meaningless for audio -- it has no position on
                // the canvas -- so those controls are visual-sources-only.
                _, is_audio := src.data.(scene.Audio_Data)

                if !is_audio {
                    im.DragFloat("X", &src.x)
                    im.DragFloat("Y", &src.y)
                    im.DragFloat("W", &src.w)
                    im.DragFloat("H", &src.h)
                }

                // src.color is only read for colour quads -- the display quad
                // hardcodes white -- so the swatch is only shown where it does
                // something, and the pickers take its place otherwise.
                switch &d in src.data {
                case scene.Color_Data:
                    im.ColorEdit4("Color", &src.color)
                case scene.Display_Data:
                    draw_output_picker(&d, outputs)
                case scene.Audio_Data:
                    draw_audio_picker(&d, devices)
                }

                if !is_audio {
                    if im.Button("Fit to canvas") {
                        fit_to_canvas(src, outputs, canvas_w, canvas_h)
                    }
                }
            }

            if to_delete >= 0 {
                removed_id := scene.remove_source(sc, to_delete)

                if state.selected_id == removed_id {
                    state.selected_id = 0
                    if len(sc.sources) > 0 {
                        state.selected_id = sc.sources[min(to_delete, len(sc.sources) - 1)].id
                    }
                }
            }
        }
    }

    im.End()
}