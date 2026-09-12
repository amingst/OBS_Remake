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
    kind:    string, // "color" | "display" | "audio" | "image" | "window"

    adapter_index: i32,
    output_index:  i32,

    device_id: string,
    is_loopback: bool,
    volume: f32,
    muted: bool,

    path: string,

    // Window identity: title alone is the backward-compatible case (a
    // collection saved before class_name/exe_name existed has them absent
    // from the JSON, which json.unmarshal leaves at "" -- resolve_window
    // treats class_name == "" as "no class recorded" and falls back to
    // title-only FindWindowW, exactly the old behaviour). With class_name
    // present, resolution prefers class+exe over title -- see
    // capture.resolve_window.
    title:      string,
    class_name: string,
    exe_name:   string,

    // Session toggles, stored inverted (false = WGC default) for the same
    // backward-compatibility reason: absent from an older file, they
    // unmarshal to false, which means "no opinion" here, not "explicitly
    // disabled".
    game_capture: bool,
    hide_cursor:  bool,
    hide_border:  bool,
    symlink:      string,
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
                case Audio_Data:
                    dto.kind = "audio"
                    dto.device_id = d.device_id
                    dto.volume = d.params.volume
                    dto.muted = d.params.muted
                    dto.is_loopback = d.is_loopback
                case Image_Data:
                    dto.kind = "image"
                    dto.path = d.path
                case Window_Data:
                    dto.kind         = "window"
                    dto.title        = d.title
                    dto.class_name   = d.class_name
                    dto.exe_name     = d.exe_name
                    dto.game_capture = d.game_capture
                    dto.hide_cursor  = d.hide_cursor
                    dto.hide_border  = d.hide_border
                case Camera_Data:
                    dto.kind = "camera"
                    dto.symlink = d.symlink
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
            case "audio":
                data = Audio_Data{
                    device_id = strings.clone(src_dto.device_id),
                    is_loopback = src_dto.is_loopback,
                    params = Audio_Params{
                        volume = src_dto.volume,
                        muted = src_dto.muted
                    }
                }
            case "image":
                data = Image_Data{
                    path = strings.clone(src_dto.path),
                }
            case "window":
                data = Window_Data{
                    title        = strings.clone(src_dto.title),
                    class_name   = strings.clone(src_dto.class_name),
                    exe_name     = strings.clone(src_dto.exe_name),
                    game_capture = src_dto.game_capture,
                    hide_cursor  = src_dto.hide_cursor,
                    hide_border  = src_dto.hide_border,
                }
            case "camera":
            data = Camera_Data{
                symlink = strings.clone(src_dto.symlink),
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
