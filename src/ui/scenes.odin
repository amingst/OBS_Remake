package ui

import "core:log"
import "core:strings"
import im "libs:odin-imgui"

Source :: struct {
    id:      u64,
    name:    string, // owned; cloned on create, deleted on remove
    visible: bool,
}

Scene :: struct {
    id:      u64,
    name:    string, // owned; cloned on create, deleted on remove
    order:   i32,
    color:   [4]f32,
    sources: [dynamic]Source,
}

Scenes_State :: struct {
    scenes:      [dynamic]Scene,
    selected_id: u64, // 0 == nothing selected; ids start at 1
    next_id:     u64,
    name_buf:    [128]u8,
}

init_scenes_state :: proc() -> Scenes_State {
    state := Scenes_State{next_id = 1}
    id := alloc_id(&state)
    append(&state.scenes, Scene{
        id    = id,
        name  = strings.clone("Scene 1"),
        order = 0,
        color = scene_color(id),
    })
    state.selected_id = id
    return state
}

draw_scenes :: proc(state: ^Scenes_State) {
    if im.Begin("Scenes") {
        if im.Button("+") {
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
                    id := alloc_id(state)
                    append(&state.scenes, Scene{
                        id    = id,
                        name  = strings.clone(name),
                        order = i32(len(state.scenes)),
                        color = scene_color(id),
                    })
                    log.debugf("scene created: id=%v name=%q", id, name)
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

        to_delete := -1

        for &scene, i in state.scenes {
            label := strings.clone_to_cstring(scene.name, context.temp_allocator)
            if im.Selectable(label, state.selected_id == scene.id) {
                state.selected_id = scene.id
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
    for &scene in state.scenes {
        destroy_scene(&scene)
    }
    delete(state.scenes)
}

// Returns nil when no scene has this id (including id 0 == no selection).
//
// NOTE: the returned pointer is invalidated by the next append to
// state.scenes, which may reallocate the backing array. Copy what you need out
// of it rather than holding it across a create.
find_scene :: proc(state: ^Scenes_State, id: u64) -> ^Scene {
    for &scene in state.scenes {
        if scene.id == id {
            return &scene
        }
    }
    return nil
}

// Ids are drawn from a single counter shared by scenes and sources, so an id is
// unique across both. Package-private: sources.odin allocates from it too.
@(private)
alloc_id :: proc(state: ^Scenes_State) -> u64 {
    id := state.next_id
    state.next_id += 1
    return id
}

// Private Helpers
// `::` won't work here: a constant isn't addressable, so it can't be indexed by
// a runtime value. @(rodata) gets the same immutability via read-only storage.
@(private="file", rodata)
SCENE_PALETTE := [?][4]f32{
    {0.16, 0.22, 0.30, 1.0},
    {0.28, 0.18, 0.24, 1.0},
    {0.18, 0.28, 0.22, 1.0},
    {0.30, 0.26, 0.16, 1.0},
    {0.22, 0.18, 0.30, 1.0},
}

@(private="file")
scene_color :: proc(id: u64) -> [4]f32 {
    return SCENE_PALETTE[id % len(SCENE_PALETTE)]
}

// Frees everything the scene owns, but does not remove it from the array.
@(private="file")
destroy_scene :: proc(scene: ^Scene) {
    for source in scene.sources {
        delete(source.name)
    }
    delete(scene.sources)
    delete(scene.name)
}

@(private="file")
remove_scene :: proc(state: ^Scenes_State, index: int) {
    log.debugf("scene deleted: id=%v name=%q sources=%v",
        state.scenes[index].id, state.scenes[index].name, len(state.scenes[index].sources))
    removed_id := state.scenes[index].id
    destroy_scene(&state.scenes[index])
    ordered_remove(&state.scenes, index)

    // Selection is by id, so it only needs repair when the removed scene was
    // the selected one. Prefer whatever slid into the vacated slot, else the
    // new last scene, else nothing.
    if state.selected_id == removed_id {
        state.selected_id = 0
        if len(state.scenes) > 0 {
            state.selected_id = state.scenes[min(index, len(state.scenes) - 1)].id
        }
    }

    // Keep `order` dense and matching position.
    for &scene, i in state.scenes {
        scene.order = i32(i)
    }
}
