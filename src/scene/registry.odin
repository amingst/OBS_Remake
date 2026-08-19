package scene

import json "core:encoding/json"
import os "core:os"
import log "core:log"
import "core:strings"

Collection_Info :: struct {
    id:   string, // owned
    name: string, // owned
    path: string, // owned; full path to the json
}

destroy_infos :: proc(infos: []Collection_Info) {
    for info in infos {
        delete(info.id)
        delete(info.name)
        delete(info.path)
    }
    delete(infos)
}

@(private = "file")
collection_path :: proc(dir, id: string, allocator := context.allocator) -> string {
    filename := strings.concatenate({id, ".json"}, context.temp_allocator)
    path, _ := os.join_path({dir, filename}, allocator)
    return path
}

enumerate :: proc(dir: string) -> []Collection_Info {
    infos := make([dynamic]Collection_Info, 0)

    entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
    if err != nil {
        if err != os.General_Error.Not_Exist {
            log.warnf("scene registry: could not read directory %v: %v", dir, err)
        }
        return infos[:]
    }

    for entry in entries {
        if entry.type != .Regular do continue
        if os.ext(entry.name) != ".json" do continue

        data, rerr := os.read_entire_file(entry.fullpath, context.temp_allocator)
        if rerr != nil {
            log.warnf("scene registry: could not read %v: %v", entry.fullpath, rerr)
            continue
        }

        dto: Collection_DTO
        if perr := json.unmarshal(data, &dto, allocator = context.temp_allocator); perr != nil {
            log.warnf("scene registry: could not parse %v: %v", entry.fullpath, perr)
            continue
        }
        if dto.id == "" {
            log.warnf("scene registry: skipping %v (no collection id)", entry.fullpath)
            continue
        }

        // A mismatch between the id inside the file and the filename it was
        // found under means someone hand-copied a file. Trusting the
        // filename means two collections can never claim the same id, at the
        // cost of a possibly-surprising name.
        id := dto.id
        stem := os.stem(entry.name)
        if id != stem {
            log.warnf(
                "scene registry: id %q in %v does not match filename %q — trusting filename",
                dto.id, entry.fullpath, stem)
            id = stem
        }

        name := dto.name
        if name == "" {
            name = "Unnamed"
        }

        append(&infos, Collection_Info{
            id   = strings.clone(id),
            name = strings.clone(name),
            path = strings.clone(entry.fullpath),
        })
    }

    return infos[:]
}

load_by_id :: proc(dir, id: string) -> (Collection, bool) {
    path := collection_path(dir, id, context.temp_allocator)

    c := create_default()
    if !load(&c, path) {
        destroy_all(&c)
        return {}, false
    }
    return c, true
}

save_collection :: proc(c: ^Collection, dir: string) -> bool {
    path := collection_path(dir, c.id, context.temp_allocator)
    return save(c, path)
}

create :: proc(dir, name: string) -> (Collection, bool) {
    c := create_default()
    delete(c.name)
    c.name = strings.clone(name)

    if !save_collection(&c, dir) {
        destroy_all(&c)
        return {}, false
    }
    return c, true
}

remove :: proc(dir, id: string) -> bool {
    infos := enumerate(dir)
    defer destroy_infos(infos)

    if len(infos) <= 1 {
        log.warnf("scene registry: refusing to remove %v — it is the last remaining collection in %v", id, dir)
        return false
    }

    path := collection_path(dir, id, context.temp_allocator)
    if err := os.remove(path); err != nil {
        log.warnf("scene registry: could not remove %v: %v", path, err)
        return false
    }
    return true
}
