package ui

import "core:log"
import "core:strings"
import im "libs:odin-imgui"

Sources_State :: struct {
    selected_id: u64, // 0 == nothing selected; ids start at 1
    name_buf:    [128]u8,
}

init_sources_state :: proc() -> Sources_State {
    return Sources_State{}
}

draw_sources :: proc(state: ^Sources_State, scenes: ^Scenes_State) {
    if im.Begin("Sources") {
        scene := find_scene(scenes, scenes.selected_id)
        if scene == nil {
            im.TextDisabled("No scene selected")
        } else {
            if im.Button("+") {
                im.OpenPopup("Add Source")
            }

            if im.BeginPopupModal("Add Source") {
                im.InputText("Name", cstring(&state.name_buf[0]), len(state.name_buf))
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
                        id := alloc_id(scenes)
                        append(&scene.sources, Source{
                            id      = id,
                            name    = strings.clone(name), // owned by the Source
                            visible = true,
                        })
                        log.debugf("source added: id=%v name=%q scene=%v", id, name, scene.id)
                        state.selected_id = id
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

            if len(scene.sources) == 0 {
                im.TextDisabled("No sources in this scene")
            }

            to_delete := -1

            for &src, i in scene.sources {
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

            if to_delete >= 0 {
                remove_source(state, scene, to_delete)
            }
        }
    }

    im.End()
}

// Private Helpers
@(private="file")
remove_source :: proc(state: ^Sources_State, scene: ^Scene, index: int) {
    log.debugf("source deleted: id=%v name=%q", scene.sources[index].id, scene.sources[index].name)
    removed_id := scene.sources[index].id
    delete(scene.sources[index].name)
    ordered_remove(&scene.sources, index)

    if state.selected_id == removed_id {
        state.selected_id = 0
        if len(scene.sources) > 0 {
            state.selected_id = scene.sources[min(index, len(scene.sources) - 1)].id
        }
    }
}
