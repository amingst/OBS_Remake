package ui

import "core:fmt"
import "core:log"
import "core:strings"
import im "libs:odin-imgui"
import "../capture"
import "../scene"

Source_Kind_Choice :: enum i32 {
    Color,
    Display,
}

Sources_State :: struct {
    selected_id:   u64, // 0 == nothing selected; ids start at 1
    name_buf:      [128]u8,
    kind_choice:   Source_Kind_Choice,
    output_choice: int, // index into the enumerated outputs, for the Add popup
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

draw_sources :: proc(
    state: ^Sources_State,
    scenes: ^Scenes_State,
    doc: ^scene.Collection,
    outputs: []capture.Output_Info,
    canvas_w, canvas_h: f32,
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
                        }

                        state.selected_id = scene.create_source(doc, sc, name, data)
                        // A display capture at the default 400x300 is badly
                        // squashed, so start it at its native aspect instead.
                        if state.kind_choice == .Display {
                            if src := scene.find_source(sc, state.selected_id); src != nil {
                                fit_to_canvas(src, outputs, canvas_w, canvas_h)
                            }
                        }
                        state.name_buf = {}
                        state.kind_choice = .Color
                        im.CloseCurrentPopup()
                    }
                }
                im.SameLine()
                if im.Button("Cancel") {
                    state.name_buf = {}
                    state.kind_choice = .Color
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
                im.DragFloat("X", &src.x)
                im.DragFloat("Y", &src.y)
                im.DragFloat("W", &src.w)
                im.DragFloat("H", &src.h)

                // src.color is only read for colour quads -- the display quad
                // hardcodes white -- so the swatch is only shown where it does
                // something, and the output picker takes its place otherwise.
                switch &d in src.data {
                case scene.Color_Data:
                    im.ColorEdit4("Color", &src.color)
                case scene.Display_Data:
                    draw_output_picker(&d, outputs)
                }

                if im.Button("Fit to canvas") {
                    fit_to_canvas(src, outputs, canvas_w, canvas_h)
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
