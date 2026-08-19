package scene

import json "core:encoding/json"
import os "core:os"
import log "core:log"
import "core:strings"

Source_DTO :: struct {
    id:      u64,
    name:    string,
    visible: bool,
    x, y:    f32,
    w, h:    f32,
    color:   [4]f32,
    kind:    string, // "color" | "display"

    adapter_index: i32,
    output_index:  i32,
}

Scene_DTO :: struct {
    id:      u64,
    name:    string,
    order:   i32,
    color:   [4]f32,
    sources: []Source_DTO,
}

Collection_DTO :: struct {
    version: int,
    id:      string,
    name:    string,
    next_id: u64,
    scenes:  []Scene_DTO,
}

@(private)
CURRENT_VERSION :: 1

save :: proc(c: ^Collection, path: string) -> bool {
    dto := to_dto(c)
    data, merr := json.marshal(dto, {pretty = true}, context.temp_allocator)
    if merr != nil {
        log.errorf("scene collection marshal failed: %v", merr)
        return false
    }

    if werr := os.write_entire_file(path, data); werr != nil {
        log.errorf("scene collection write failed: %v (%v)", path, werr)
        return false
    }

    log.infof("scene collection saved: %v", path)
    return true
}

load :: proc(c: ^Collection, path: string) -> bool {
    data, rerr := os.read_entire_file(path, context.temp_allocator)
    if rerr != nil {
        // No file is the normal first-run case and must stay quiet.
        if rerr != os.General_Error.Not_Exist {
            log.warnf("scene collection read failed: %v (%v)", path, rerr)
        }
        return false
    }

    dto: Collection_DTO
    if perr := json.unmarshal(data, &dto, allocator = context.temp_allocator); perr != nil {
        log.errorf("scene collection parse failed: %v (%v)", path, perr)
        return false
    }
    if dto.version != CURRENT_VERSION {
        log.warnf("scene collection version %v, expected %v — using defaults: %v",
            dto.version, CURRENT_VERSION, path)
        return false
    }
    if dto.id == "" {
        log.warnf("scene collection rejected (no id) — using defaults: %v", path)
        return false
    }

    from_dto(&dto, c)
    return true
}

@(private = "file")
to_dto :: proc(c: ^Collection) -> Collection_DTO {
    scenes := make([]Scene_DTO, len(c.scenes), context.temp_allocator)
    for s, i in c.scenes {
        sources := make([]Source_DTO, len(s.sources), context.temp_allocator)
        for src, j in s.sources {
            dto := Source_DTO{
                id      = src.id,
                name    = src.name,
                visible = src.visible,
                x = src.x, y = src.y, w = src.w, h = src.h,
                color   = src.color,
            }
            switch d in src.data {
            case Color_Data:
                dto.kind = "color"
            case Display_Data:
                dto.kind          = "display"
                dto.adapter_index = d.adapter_index
                dto.output_index  = d.output_index
            }
            sources[j] = dto
        }

        scenes[i] = Scene_DTO{
            id      = s.id,
            name    = s.name,
            order   = s.order,
            color   = s.color,
            sources = sources,
        }
    }

    return Collection_DTO{
        version = CURRENT_VERSION,
        id      = c.id,
        name    = c.name,
        next_id = c.next_id,
        scenes  = scenes,
    }
}

@(private = "file")
from_dto :: proc(dto: ^Collection_DTO, c: ^Collection) {
    for &s in c.scenes {
        destroy_scene(&s)
    }
    clear(&c.scenes)
    delete(c.id)
    delete(c.name)

    c.id   = strings.clone(dto.id)
    c.name = strings.clone(dto.name)

    highest: u64
    for scene_dto in dto.scenes {
        sources := make([dynamic]Source, 0, len(scene_dto.sources))
        for src_dto in scene_dto.sources {
            data: Source_Data
            switch src_dto.kind {
            case "color":
                data = Color_Data{}
            case "display":
                data = Display_Data{
                    adapter_index = src_dto.adapter_index,
                    output_index  = src_dto.output_index,
                }
            case:
                // One bad source must not sink the whole collection.
                log.warnf("scene collection: skipping source %q (id %v) — unrecognised kind %q",
                    src_dto.name, src_dto.id, src_dto.kind)
                continue
            }

            append(&sources, Source{
                id      = src_dto.id,
                name    = strings.clone(src_dto.name),
                visible = src_dto.visible,
                x = src_dto.x, y = src_dto.y, w = src_dto.w, h = src_dto.h,
                color   = src_dto.color,
                data    = data,
            })
            highest = max(highest, src_dto.id)
        }

        append(&c.scenes, Scene{
            id      = scene_dto.id,
            name    = strings.clone(scene_dto.name),
            order   = scene_dto.order,
            color   = scene_dto.color,
            sources = sources,
        })
        highest = max(highest, scene_dto.id)
    }

    c.next_id = max(dto.next_id, highest + 1)
}
