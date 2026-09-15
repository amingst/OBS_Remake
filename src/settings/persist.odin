package settings

import json "core:encoding/json"
import os "core:os"
import log "core:log"
import "core:strings"

Video_Settings_DTO :: struct {
    canvas_width, canvas_height: i32,
    output_width, output_height: i32,
    fps: i32,
}

Stream_Settings_DTO :: struct {
    host: string,
    port: i32,
    app: string,
    tc_url: string,
    stream_key: string,
    bitrate: i32,
}

Settings_DTO :: struct {
    version: int,
    id:      string,
    name:    string,
    video:   Video_Settings_DTO,
    stream:  Stream_Settings_DTO,
}

// Version of the settings file (Settings_DTO), independent of app.json's version.
@(private)
CURRENT_VERSION :: 1

save :: proc(cfg: ^Profile, path: string) -> bool {
    dto := to_dto(cfg)
    data, merr := json.marshal(dto, {pretty=true}, context.temp_allocator)
    if merr != nil {
        log.errorf("settings marshal failed: %v", merr)
        return false
    }

    if werr := os.write_entire_file(path, data); werr != nil {
        log.errorf("settings write failed: %v (%v)", path, werr)
        return false
    }

    log.infof("settings saved: %v", path)
    return true
}

load :: proc(cfg: ^Profile, path: string) -> bool {
    data, rerr := os.read_entire_file(path, context.temp_allocator)
    if rerr != nil {
        // Missing file is the normal first-run case; anything else logs a warning.
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

// Rejects a syntactically valid but nonsensical file (e.g. canvas_width: 0);
// a missing id rejects the file, a missing name is repaired in place.
@(private="file")
dto_is_valid :: proc(dto: ^Settings_DTO, path: string) -> bool {
    if dto.id == "" {
        log.warnf("settings rejected (no profile id) — using defaults: %v", path)
        return false
    }
    if dto.name == "" {
        log.warnf("settings has no profile name, using %q: %v", "Unnamed", path)
        dto.name = "Unnamed"
    }

    v := dto.video
    if v.canvas_width <= 0 || v.canvas_height <= 0 ||
       v.output_width <= 0 || v.output_height <= 0 || v.fps <= 0 {
        log.warnf(
            "settings rejected (canvas %vx%v, output %vx%v, %v fps) — using defaults: %v",
            v.canvas_width, v.canvas_height, v.output_width, v.output_height, v.fps, path)
        return false
    }

    // An empty/zero stream config is a legitimate "not set up yet" state.
    return true
}

// Borrows cfg's strings; the DTO doesn't outlive the marshal call in save.
@(private="file")
to_dto :: proc(cfg: ^Profile) -> Settings_DTO {
    return Settings_DTO {
        version = CURRENT_VERSION,
        id = cfg.id,
        name = cfg.name,
        video = {
            canvas_width = cfg.video.canvas_width,
            canvas_height = cfg.video.canvas_height,
            output_width = cfg.video.output_width,
            output_height = cfg.video.output_height,
            fps = cfg.video.fps
        },
        stream = {
            host = cfg.stream.host,
            port = cfg.stream.port,
            app = cfg.stream.app,
            tc_url = cfg.stream.tc_url,
            stream_key = cfg.stream.stream_key,
            bitrate = cfg.stream.bitrate,
        }
    }
}

// Frees cfg's existing strings (already populated by create_default) and
// clones the DTO's (temp-allocated, won't outlive this call).
@(private="file")
from_dto :: proc(dto: ^Settings_DTO, cfg: ^Profile) {
    delete(cfg.id)
    delete(cfg.name)
    delete(cfg.stream.host)
    delete(cfg.stream.app)
    delete(cfg.stream.tc_url)
    delete(cfg.stream.stream_key)
    cfg.id = strings.clone(dto.id)
    cfg.name = strings.clone(dto.name)

    cfg.video = {
        canvas_width  = dto.video.canvas_width,
        canvas_height = dto.video.canvas_height,
        output_width  = dto.video.output_width,
        output_height = dto.video.output_height,
        fps           = dto.video.fps,
    }

    stream_bitrate := dto.stream.bitrate
    if stream_bitrate <= 0 {
        log.warnf("settings: bitrate is %v, substituting default %v", stream_bitrate, DEFAULT_BITRATE)
        stream_bitrate = DEFAULT_BITRATE
    }

    cfg.stream = {
        host       = strings.clone(dto.stream.host),
        port       = dto.stream.port,
        app        = strings.clone(dto.stream.app),
        tc_url     = strings.clone(dto.stream.tc_url),
        stream_key = strings.clone(dto.stream.stream_key),
        bitrate    = stream_bitrate,
    }
}