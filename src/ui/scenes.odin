#+feature dynamic-literals // Warning: Please understand that dynamic literals will implicitly allocate using the current 'context.allocator' in that scope
package ui

import im "libs:odin-imgui"

Scene :: struct {
    name: string,
    order: i32,
}

Scenes_State :: struct {
    scenes: [dynamic]Scene,
    selected: i32,
}

init_scenes_state :: proc() -> Scenes_State {
    return Scenes_State{
        scenes = [dynamic]Scene{
            Scene{name = "Scene 1", order = 0},
        },
        selected = -1,
    }
}

draw_scenes :: proc (state: ^Scenes_State) {
    if im.Begin("Scenes") {
        // Render Scene List Here
    }
    im.End()
}