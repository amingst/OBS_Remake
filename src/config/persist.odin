package config

import json "core:encoding/json"
import os "core:os"
import log "core:log"
import "core:strings"

// app.json's on-disk shape.
App_Config_DTO :: struct {
    version:        int,
    active_show_id: string,
}

destroy_app_config :: proc(cfg: ^App_Config) {
    delete(cfg.active_show_id)
    cfg^ = {}
}

save_app_config :: proc(cfg: ^App_Config, path: string) -> bool {
    dto := App_Config_DTO{
        version        = CURRENT_VERSION,
        active_show_id = cfg.active_show_id,
    }
    data, merr := json.marshal(dto, {pretty = true}, context.temp_allocator)
    if merr != nil {
        log.errorf("app config marshal failed: %v", merr)
        return false
    }

    if werr := os.write_entire_file(path, data); werr != nil {
        log.errorf("app config write failed: %v (%v)", path, werr)
        return false
    }

    log.infof("app config saved: %v", path)
    return true
}

load_app_config :: proc(cfg: ^App_Config, path: string) -> bool {
    data, rerr := os.read_entire_file(path, context.temp_allocator)
    if rerr != nil {
        // Missing file is the normal first-run case; anything else logs a warning.
        if rerr != os.General_Error.Not_Exist {
            log.warnf("app config read failed: %v (%v)", path, rerr)
        }
        return false
    }

    dto: App_Config_DTO
    if perr := json.unmarshal(data, &dto, allocator = context.temp_allocator); perr != nil {
        log.errorf("app config parse failed: %v (%v)", path, perr)
        return false
    }
    if dto.version != CURRENT_VERSION {
        log.warnf("app config version %v, expected %v — using defaults: %v",
            dto.version, CURRENT_VERSION, path)
        return false
    }

    delete(cfg.active_show_id)
    cfg.active_show_id = strings.clone(dto.active_show_id)
    return true
}
