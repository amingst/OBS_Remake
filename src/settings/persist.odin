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

// Version of the settings file, root/settings.json (Settings_DTO above).
// Independent of config.CURRENT_VERSION, which versions app.json -- the two
// files have separate schemas and separate migration histories, so bumping one
// says nothing about the other.
//
// Stays at 1 across the id/name addition: a version bump exists to tell a
// reader what an *existing* file on disk means, and nothing has shipped, so no
// file with the old fieldless shape exists anywhere to be distinguished. Such a
// file would in any case be caught by dto_is_valid's empty-id check and fall
// back to defaults, which is the same outcome a version mismatch would produce.
@(private)
CURRENT_VERSION :: 1

save :: proc(cfg: ^Profile, path: string) -> bool {
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

load :: proc(cfg: ^Profile, path: string) -> bool {
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
// create_target with a degenerate size; the defaults create_default
// established stand.
//
// Not every bad field is fatal, and the split is by what the field is *for*:
// an id is how a profile is addressed and saved back, so a file without one
// describes a profile that cannot be referred to -- there is nothing sensible
// to invent. A name is a human label; a missing one costs nothing to
// substitute, so it is repaired in place rather than throwing away an
// otherwise good file.
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

    // Unlike video, an empty/zero stream config is a legitimate "streaming
    // not set up yet" state -- Start_Streaming is what rejects a blank host
    // or stream_key, the same way paths.videos == "" is checked at
    // recording-start rather than at settings-load. Nothing here to reject.
    return true
}

@(private="file")
to_dto :: proc(cfg: ^Profile) -> Settings_DTO {
    // id and name are borrowed, not cloned: the DTO lives only until the
    // json.marshal call in save returns, well inside the profile's lifetime.
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

// The first from_dto that does more than copy scalars. Two things follow from
// that: the DTO's strings point into the temp allocator json.unmarshal was
// given and are gone at the end of the frame, so they must be cloned; and cfg
// arrives already populated by create_default, so the strings being replaced
// have to be freed first or every successful load leaks an id and a name.
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

    cfg.stream = {
        host       = strings.clone(dto.stream.host),
        port       = dto.stream.port,
        app        = strings.clone(dto.stream.app),
        tc_url     = strings.clone(dto.stream.tc_url),
        stream_key = strings.clone(dto.stream.stream_key),
        bitrate    = dto.stream.bitrate,
    }
}