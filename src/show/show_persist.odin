package show

import json "core:encoding/json"
import os "core:os"
import log "core:log"
import "core:strings"

Show_Source_DTO :: struct {
    id:   string,
    name: string,
    kind: string, // "color" | "display" | "audio" | "image" | "window" | "camera"

    adapter_index: i32,
    output_index:  i32,

    device_id:   string,
    is_loopback: bool,
    volume:      f32,
    muted:       bool,

    path: string,

    title:      string,
    class_name: string,
    exe_name:   string,

    game_capture: bool,
    hide_cursor:  bool,
    hide_border:  bool,

    symlink: string,
}

Show_Placement_DTO :: struct {
    id:            string,
    source_id:     string,
    x, y:          f32,
    w, h:          f32,
    order:         int,
    color:         [4]f32,
    visible:       bool,
    mute_override: bool,
}

Show_Scene_DTO :: struct {
    id:       string,
    name:     string,
    order:    int,
    sources:  []Show_Placement_DTO,
}

Show_Output_DTO :: struct {
    id:           string,
    label:        string,
    enabled:      bool,
    platform:     string,
    bitrate_kbps: int,
    bitrate_mode: Bitrate_Mode,
    kind:         string, // "rtmp"

    url: string,
    key: string,
}

Show_DTO :: struct {
    version:   int,
    id:        string,
    name:      string,
    video:     Show_Video_Settings,
    sources:   []Show_Source_DTO,
    scenes:    []Show_Scene_DTO,
    outputs:   []Show_Output_DTO,
    recording: Show_Stream_Recording_Destination,
}

@(private)
CURRENT_VERSION :: 1

save :: proc(s: ^Show, path: string) -> bool {
    dto := to_dto(s)
    data, merr := json.marshal(dto, {pretty = true}, context.temp_allocator)
    if merr != nil {
        log.errorf("show marshal failed: %v", merr)
        return false
    }

    if werr := os.write_entire_file(path, data); werr != nil {
        log.errorf("show write failed: %v (%v)", path, werr)
        return false
    }

    log.infof("show saved: %v", path)
    return true
}

load :: proc(s: ^Show, path: string) -> bool {
    data, rerr := os.read_entire_file(path, context.temp_allocator)
    if rerr != nil {
        // No file is the normal first-run case and must stay quiet.
        if rerr != os.General_Error.Not_Exist {
            log.warnf("show read failed: %v (%v)", path, rerr)
        }
        return false
    }

    dto: Show_DTO
    if perr := json.unmarshal(data, &dto, allocator = context.temp_allocator); perr != nil {
        log.errorf("show parse failed: %v (%v)", path, perr)
        return false
    }
    if dto.version != CURRENT_VERSION {
        log.warnf("show version %v, expected %v — using defaults: %v",
            dto.version, CURRENT_VERSION, path)
        return false
    }
    if dto.id == "" {
        log.warnf("show rejected (no id) — using defaults: %v", path)
        return false
    }

    // Free whatever s already held before overwriting it -- load can be
    // called on a live Show (e.g. a reload), not just a zero-valued one.
    destroy_show(s)
    s^ = from_dto(&dto)
    return true
}

@(private = "file")
to_dto :: proc(s: ^Show) -> Show_DTO {
    sources := make([]Show_Source_DTO, len(s.sources), context.temp_allocator)
    for src, i in s.sources {
        dto := Show_Source_DTO{
            id   = src.id,
            name = src.name,
        }
        switch d in src.data {
        case Color_Source_Data:
            dto.kind = "color"
        case Display_Source_Data:
            dto.kind          = "display"
            dto.adapter_index = d.adapter_index
            dto.output_index  = d.output_index
        case Audio_Source_Data:
            dto.kind        = "audio"
            dto.device_id   = d.device_id
            dto.is_loopback = d.is_loopback
            dto.volume      = d.params.volume
            dto.muted       = d.params.muted
        case Image_Source_Data:
            dto.kind = "image"
            dto.path = d.path
        case Window_Source_Data:
            dto.kind         = "window"
            dto.title        = d.title
            dto.class_name   = d.class_name
            dto.exe_name     = d.exe_name
            dto.game_capture = d.game_capture
            dto.hide_cursor  = d.hide_cursor
            dto.hide_border  = d.hide_border
        case Camera_Source_Data:
            dto.kind    = "camera"
            dto.symlink = d.symlink
        }
        sources[i] = dto
    }

    scenes := make([]Show_Scene_DTO, len(s.scenes), context.temp_allocator)
    for scene, i in s.scenes {
        placements := make([]Show_Placement_DTO, len(scene.sources), context.temp_allocator)
        for p, j in scene.sources {
            placements[j] = Show_Placement_DTO{
                id            = p.id,
                source_id     = p.source_id,
                x = p.x, y = p.y, w = p.w, h = p.h,
                order         = p.order,
                color         = p.color,
                visible       = p.visible,
                mute_override = p.mute_override,
            }
        }
        scenes[i] = Show_Scene_DTO{
            id      = scene.id,
            name    = scene.name,
            order   = scene.order,
            sources = placements,
        }
    }

    outputs := make([]Show_Output_DTO, len(s.outputs), context.temp_allocator)
    for out, i in s.outputs {
        dto := Show_Output_DTO{
            id           = out.id,
            label        = out.label,
            enabled      = out.enabled,
            platform     = out.platform,
            bitrate_kbps = out.bitrate_kbps,
            bitrate_mode = out.bitrate_mode,
        }
        switch d in out.data {
        case RTMP_Output_Data:
            dto.kind = "rtmp"
            dto.url  = d.url
            dto.key  = d.key
        }
        outputs[i] = dto
    }

    return Show_DTO{
        version   = CURRENT_VERSION,
        id        = s.id,
        name      = s.name,
        video     = s.video,
        sources   = sources,
        scenes    = scenes,
        outputs   = outputs,
        recording = s.recording,
    }
}

@(private = "file")
from_dto :: proc(dto: ^Show_DTO) -> Show {
    sources := make([dynamic]Show_Source, 0, len(dto.sources))
    for src_dto in dto.sources {
        data: Show_Source_Data
        switch src_dto.kind {
        case "color":
            data = Color_Source_Data{}
        case "display":
            data = Display_Source_Data{
                adapter_index = src_dto.adapter_index,
                output_index  = src_dto.output_index,
            }
        case "audio":
            data = Audio_Source_Data{
                device_id   = strings.clone(src_dto.device_id),
                is_loopback = src_dto.is_loopback,
                params = Audio_Source_Params{
                    volume = src_dto.volume,
                    muted  = src_dto.muted,
                },
            }
        case "image":
            data = Image_Source_Data{
                path = strings.clone(src_dto.path),
            }
        case "window":
            data = Window_Source_Data{
                title        = strings.clone(src_dto.title),
                class_name   = strings.clone(src_dto.class_name),
                exe_name     = strings.clone(src_dto.exe_name),
                game_capture = src_dto.game_capture,
                hide_cursor  = src_dto.hide_cursor,
                hide_border  = src_dto.hide_border,
            }
        case "camera":
            data = Camera_Source_Data{
                symlink = strings.clone(src_dto.symlink),
            }
        case:
            // One bad source must not sink the whole show.
            log.warnf("show: skipping source %q (id %v) — unrecognised kind %q",
                src_dto.name, src_dto.id, src_dto.kind)
            continue
        }

        append(&sources, Show_Source{
            id   = strings.clone(src_dto.id),
            name = strings.clone(src_dto.name),
            data = data,
        })
    }

    scenes := make([]Show_Scene, len(dto.scenes))
    for scene_dto, i in dto.scenes {
        placements := make([]Show_Source_Placement, len(scene_dto.sources))
        for p_dto, j in scene_dto.sources {
            placements[j] = Show_Source_Placement{
                id            = strings.clone(p_dto.id),
                source_id     = strings.clone(p_dto.source_id),
                x = p_dto.x, y = p_dto.y, w = p_dto.w, h = p_dto.h,
                order         = p_dto.order,
                color         = p_dto.color,
                visible       = p_dto.visible,
                mute_override = p_dto.mute_override,
            }
        }
        scenes[i] = Show_Scene{
            id      = strings.clone(scene_dto.id),
            name    = strings.clone(scene_dto.name),
            order   = scene_dto.order,
            sources = placements,
        }
    }

    outputs := make([dynamic]Show_Stream_Output, 0, len(dto.outputs))
    for out_dto in dto.outputs {
        data: Show_Stream_Output_Data
        switch out_dto.kind {
        case "rtmp":
            data = RTMP_Output_Data{
                url = strings.clone(out_dto.url),
                key = strings.clone(out_dto.key),
            }
        case:
            log.warnf("show: skipping output %q (id %v) — unrecognised kind %q",
                out_dto.label, out_dto.id, out_dto.kind)
            continue
        }

        append(&outputs, Show_Stream_Output{
            id           = strings.clone(out_dto.id),
            label        = strings.clone(out_dto.label),
            enabled      = out_dto.enabled,
            platform     = strings.clone(out_dto.platform),
            bitrate_kbps = out_dto.bitrate_kbps,
            bitrate_mode = out_dto.bitrate_mode,
            data         = data,
        })
    }

    return Show{
        id      = strings.clone(dto.id),
        name    = strings.clone(dto.name),
        version = CURRENT_VERSION,
        video   = dto.video,
        sources = sources[:],
        scenes  = scenes,
        outputs = outputs[:],
        recording = Show_Stream_Recording_Destination{
            path = strings.clone(dto.recording.path),
        },
    }
}
