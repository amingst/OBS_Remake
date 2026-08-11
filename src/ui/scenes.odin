package ui

import "core:strings"
import "core:bytes"
import im "libs:odin-imgui"

Scene :: struct {
    name: string,
    order: i32,
}

Scenes_State :: struct {
    scenes: [dynamic]Scene,
    selected: i32,
    name_buf: [128]u8,
    creating: bool
}

init_scenes_state :: proc() -> Scenes_State {
    state := Scenes_State{
        selected = -1,
    }
    append(&state.scenes, Scene{name = strings.clone("Scene 1"), order = 0})
    return state
}

draw_scenes :: proc (state: ^Scenes_State) {
    if im.Begin("Scenes") {
        if im.Button("+") {
            im.OpenPopup("Create Scene")
        }

        if im.BeginPopupModal("Create Scene") {
            im.InputText("Name", cstring(&state.name_buf[0]), len(state.name_buf))
            if im.Button("Create") {
                n := strings.index_byte(string(state.name_buf[:]), 0)
                if n < 0 do n = len(state.name_buf)
                name := string(state.name_buf[:n])

                append(&state.scenes, Scene{ name = strings.clone(name) })
                state.name_buf = {}
                state.name_buf = {}
                im.CloseCurrentPopup()
            }
            im.SameLine()
            if im.Button("Cancel") {
                im.CloseCurrentPopup()
            }
            im.EndPopup()
        }

        to_delete := -1

        for scene, i in state.scenes {
            label := strings.clone_to_cstring(scene.name, context.temp_allocator)
            if im.Selectable(label, state.selected == i32(i)) {
                state.selected = i32(i)
            }

            if im.BeginPopupContextItem() {
                if im.MenuItem("Delete") {
                    to_delete = i
                }
                im.EndPopup()
            }
        }

        if to_delete >= 0 {
            remove_scene(state, to_delete)
        }
    }

    im.End()
}

destroy_scenes :: proc(state: ^Scenes_State) {
    for scene in state.scenes {
        delete(scene.name)
    }
    delete(state.scenes)
}

// Private Helpers
@(private="file")
remove_scene :: proc(state: ^Scenes_State, index: int) {
    delete(state.scenes[index].name)
    ordered_remove(&state.scenes, index)
}