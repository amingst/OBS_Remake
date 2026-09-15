package ui

import "core:log"
import "core:strings"
import im "libs:odin-imgui"

import "../scene"

Scenes_State :: struct {
    selected_id: u64, // 0 == nothing selected; ids start at 1
    name_buf:    [128]u8,
}

init_scenes_state :: proc() -> Scenes_State {
    return Scenes_State{}
}

draw_scenes :: proc(state: ^Scenes_State, doc: ^scene.Collection) {
    p := panel_begin("Scenes", "SCENES")
    if p.visible {
        add_scene := panel_header_button("+", "Add scene")
        panel_header_end()

        if add_scene {
            im.OpenPopup("Create Scene")
        }

        if im.BeginPopupModal("Create Scene") {
            im.InputText("Name", cstring(&state.name_buf[0]), len(state.name_buf))
            if im.Button("Create") {
                n := strings.index_byte(string(state.name_buf[:]), 0)
                if n < 0 {
                    log.warn("scene name truncated at 128 bytes (no NUL found)")
                    n = len(state.name_buf)
                }
                name := string(state.name_buf[:n])

                if len(name) == 0 {
                    log.debug("empty scene name rejected")
                } else {
                    state.selected_id = scene.create_scene(doc, name)
                    state.name_buf = {}
                    im.CloseCurrentPopup()
                }
            }
            im.SameLine()
            if im.Button("Cancel") {
                state.name_buf = {}
                im.CloseCurrentPopup()
            }
            im.EndPopup()
        }

        to_delete := -1

        for &sc, i in doc.scenes {
            label := strings.clone_to_cstring(sc.name, context.temp_allocator)
            if im.Selectable(label, state.selected_id == sc.id) {
                state.selected_id = sc.id
            }

            if im.BeginPopupContextItem() {
                if im.MenuItem("Delete") {
                    to_delete = i
                }
                im.EndPopup()
            }
        }

        if to_delete >= 0 {
            removed_id := scene.remove_scene(doc, to_delete)

            // Selection is by id, so it only needs repair when the removed scene
            // was the selected one. Prefer whatever slid into the vacated slot,
            // else the new last scene, else nothing.
            if state.selected_id == removed_id {
                state.selected_id = 0
                if len(doc.scenes) > 0 {
                    state.selected_id = doc.scenes[min(to_delete, len(doc.scenes) - 1)].id
                }
            }
        }
    }

    panel_end(p)
}
