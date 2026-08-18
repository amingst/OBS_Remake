package settings

import json "core:encoding/json"
import os "core:os"
import log "core:log"

Video_Settings_DTO :: struct {
    canvas_width, canvas_height: i32,
    output_width, output_height: i32,
    fps: i32,
}

Settings_DTO :: struct {
    version: int,
    video:   Video_Settings_DTO,
}

@(private)
CURRENT_VERSION :: 1

save :: proc(cfg: ^Settings, path: string) -> bool {
    dto := to_dto(cfg)
    data, merr := json.marshal(dto, {pretty=true}, context.temp_allocator)
    if merr != nil {
        log.errorf("settings marshal failed: %v", merr)
        return false
    }

    // write_entire_file creates the file if it is missing, so a config file
    // deleted mid-session is simply recreated. A missing *directory* is not
    // recovered here -- that is main's job at startup.
    if werr := os.write_entire_file(path, data); werr != nil {
        log.errorf("settings write failed: %v (%v)", path, werr)
        return false
    }

    log.infof("settings saved: %v", path)
    return true
}

load :: proc(cfg: ^Settings, path: string) -> bool {
    data, rerr := os.read_entire_file(path, context.temp_allocator)
    if rerr != nil {
        // No file is the normal first-run case and must stay quiet. Anything
        // else (permissions, a directory where the file should be, a bad path)
        // is worth a line, but is still non-fatal -- the caller keeps defaults.
        if rerr != os.General_Error.Not_Exist {
            log.warnf("settings read failed: %v (%v)", path, rerr)
        }
        return false
    }

    dto: Settings_DTO
    if perr := json.unmarshal(data, &dto, allocator = context.temp_allocator); perr != nil {
        log.errorf("settings parse failed: %v (%v)", path, perr)
        return false
    }
    if dto.version != CURRENT_VERSION {
        log.warnf("settings version %v, expected %v — using defaults: %v",
            dto.version, CURRENT_VERSION, path)
        return false
    }
    if !dto_is_valid(&dto, path) do return false

    from_dto(&dto, cfg)
    return true
}

// A syntactically valid file can still hold nonsense -- a hand-edited
// "canvas_width": 0, or a field omitted entirely, which unmarshals to zero.
// Rejecting the whole file here means main never gets a chance to call
// create_target with a degenerate size; the defaults init established stand.
@(private="file")
dto_is_valid :: proc(dto: ^Settings_DTO, path: string) -> bool {
    v := dto.video
    if v.canvas_width <= 0 || v.canvas_height <= 0 ||
       v.output_width <= 0 || v.output_height <= 0 || v.fps <= 0 {
        log.warnf(
            "settings rejected (canvas %vx%v, output %vx%v, %v fps) — using defaults: %v",
            v.canvas_width, v.canvas_height, v.output_width, v.output_height, v.fps, path)
        return false
    }
    return true
}

@(private="file")
to_dto :: proc(cfg: ^Settings) -> Settings_DTO {
    return Settings_DTO {
        version = CURRENT_VERSION,
        video = {
            canvas_width = cfg.video.canvas_width,
            canvas_height = cfg.video.canvas_height,
            output_width = cfg.video.output_width,
            output_height = cfg.video.output_height,
            fps = cfg.video.fps
        }
    }
}

@(private="file")
from_dto :: proc(dto: ^Settings_DTO, cfg: ^Settings) {
    cfg.video = {
        canvas_width  = dto.video.canvas_width,
        canvas_height = dto.video.canvas_height,
        output_width  = dto.video.output_width,
        output_height = dto.video.output_height,
        fps           = dto.video.fps,
    }
}