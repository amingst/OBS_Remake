package scene

import "core:encoding/uuid"
import "core:log"
import "core:strings"

Scene :: struct {
    id:      u64,
    name:    string, // owned; cloned on create, deleted on remove
    order:   i32,
    color:   [4]f32,
    sources: [dynamic]Source,
}

Collection :: struct {
    id:      string, // owned
    name:    string, // owned
    scenes:  [dynamic]Scene,
    next_id: u64,
}

create_default :: proc() -> Collection {
    c := Collection{
        id      = new_id(),
        name    = strings.clone("Default"),
        next_id = 1,
    }
    create_scene(&c, "Scene 1")
    return c
}

create_scene :: proc(c: ^Collection, name: string) -> u64 {
    id := alloc_id(c)
    append(&c.scenes, Scene{
        id    = id,
        name  = strings.clone(name),
        order = i32(len(c.scenes)),
        color = scene_color(id),
    })
    log.debugf("scene created: id=%v name=%q", id, name)
    return id
}

remove_scene :: proc(c: ^Collection, index: int) -> u64 {
    log.debugf("scene deleted: id=%v name=%q sources=%v",
        c.scenes[index].id, c.scenes[index].name, len(c.scenes[index].sources))
    removed_id := c.scenes[index].id
    destroy_scene(&c.scenes[index])
    ordered_remove(&c.scenes, index)

    // Keep `order` dense and matching position.
    for &s, i in c.scenes {
        s.order = i32(i)
    }

    return removed_id
}

find :: proc(c: ^Collection, id: u64) -> ^Scene {
    for &s in c.scenes {
        if s.id == id {
            return &s
        }
    }
    return nil
}

destroy_all :: proc(c: ^Collection) {
    log.debugf("scene collection %q (%v) torn down (%v scenes)", c.name, c.id, len(c.scenes))
    for &s in c.scenes {
        destroy_scene(&s)
    }
    delete(c.scenes)
    delete(c.id)
    delete(c.name)
}

@(private)
alloc_id :: proc(c: ^Collection) -> u64 {
    id := c.next_id
    c.next_id += 1
    return id
}

@(private = "file")
new_id :: proc() -> string {
    return uuid.to_string(
        uuid.generate_v4(),
        context.allocator
    )
}

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

@(private)
destroy_scene :: proc(s: ^Scene) {
    for &source in s.sources {
        destroy_source(&source)
    }
    delete(s.sources)
    delete(s.name)
}
