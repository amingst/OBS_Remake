package show

import json "core:encoding/json"
import os "core:os"
import log "core:log"
import "core:strings"
import "core:fmt"

// shows/index.json — maps a show's permanent id to its current (renamable) folder name.
Show_Index_Entry_DTO :: struct {
    id:     string,
    folder: string,
}

Show_Index_DTO :: struct {
    version: int,
    entries: []Show_Index_Entry_DTO,
}

@(private)
INDEX_VERSION :: 1

// Saves s to its existing folder, resolved via the index. Unlike create,
// this never touches the folder name -- it's for persisting edits to an
// already-registered show.
save_show :: proc(shows_dir: string, s: ^Show) -> bool {
    idx := load_index(shows_dir)
    folder := ""
    for e in idx.entries {
        if e.id == s.id {
            folder = e.folder
            break
        }
    }
    if folder == "" {
        log.warnf("show registry: no index entry for show %v; cannot save", s.id)
        return false
    }

    path, jerr := os.join_path({shows_dir, folder, "show.json"}, context.temp_allocator)
    if jerr != nil {
        log.warnf("show registry: could not build show.json path for %v: %v", s.id, jerr)
        return false
    }
    return save(s, path)
}

// Creates a new show, picks a collision-safe folder name from `name`, writes
// show.json into it, and records the id -> folder mapping in the index.
create :: proc(shows_dir, name: string) -> (Show, bool) {
    if shows_dir == "" {
        log.warn("show registry: create requested, but no shows directory is available")
        return {}, false
    }

    s := create_default()
    delete(s.name)
    s.name = strings.clone(name)

    base := sanitize_folder_name(name, context.temp_allocator)
    dir, folder, dir_ok := make_unique_dir(shows_dir, base)
    if !dir_ok {
        delete(s.id)
        delete(s.name)
        return {}, false
    }
    defer delete(dir)
    defer delete(folder)

    show_path, jerr := os.join_path({dir, "show.json"}, context.temp_allocator)
    if jerr != nil {
        log.warnf("show registry: could not build show.json path in %v: %v", dir, jerr)
        delete(s.id)
        delete(s.name)
        return {}, false
    }

    if !save(&s, show_path) {
        delete(s.id)
        delete(s.name)
        return {}, false
    }

    idx := load_index(shows_dir)
    entries := make([dynamic]Show_Index_Entry_DTO, 0, len(idx.entries) + 1, context.temp_allocator)
    append(&entries, ..idx.entries)
    append(&entries, Show_Index_Entry_DTO{id = s.id, folder = folder})
    idx.entries = entries[:]
    if !save_index(shows_dir, &idx) {
        // The show file itself saved fine; a stale index is recoverable via
        // the scan-and-relink repair path, not a reason to fail creation.
        log.warnf("show registry: created show %v but failed to update index", s.id)
    }

    log.infof("created show %v (%v) at %v", s.name, s.id, dir)
    return s, true
}

// Looks up id's folder in the index and loads show.json from it. Does not
// scan or repair a stale/missing index entry -- that's a separate,
// user-confirmed operation (see the spec's scan-and-relink flow), never
// silent, so a bad index here is a load failure, not a fallback trigger.
load_by_id :: proc(id: string, shows_dir: string) -> (Show, bool) {
	if shows_dir == "" {
		log.warn("show registry: load requested, but no shows directory is available")
		return {}, false
	}

	idx := load_index(shows_dir)
	folder := ""
	for e in idx.entries {
		if e.id == id {
			folder = e.folder
			break
		}
	}
	if folder == "" {
		log.warnf("show registry: no index entry for show %v", id)
		return {}, false
	}

	show_path, jerr := os.join_path({shows_dir, folder, "show.json"}, context.temp_allocator)
	if jerr != nil {
		log.warnf("show registry: could not build show.json path for %v: %v", id, jerr)
		return {}, false
	}

	s: Show
	if !load(&s, show_path) {
		log.warnf("show registry: index points show %v at folder %q, but show.json there failed to load", id, folder)
		return {}, false
	}

	if s.id != id {
		// The folder exists and parses, but its id doesn't match what the
		// index promised -- someone renamed/moved a folder outside the app.
		log.warnf("show registry: index says %v is at folder %q, but show.json there has id %v — index is stale",
			id, folder, s.id)
		destroy_show(&s)
		return {}, false
	}

	return s, true
}

// Strips characters Windows filenames can't hold; falls back to a generic
// name if nothing usable is left. Collision handling is make_unique_dir's job.
@(private = "file")
sanitize_folder_name :: proc(name: string, allocator := context.allocator) -> string {
    b: strings.Builder
    strings.builder_init(&b, context.temp_allocator)
    for r in name {
        if strings.index_rune(`<>:"/\|?*`, r) >= 0 || r < 32 {
            strings.write_rune(&b, '_')
        } else {
            strings.write_rune(&b, r)
        }
    }

    trimmed := strings.trim_right(strings.to_string(b), " .")
    if trimmed == "" {
        trimmed = "Show"
    }
    return strings.clone(trimmed, allocator)
}

// Creates shows_dir/base, or shows_dir/base (2), (3), ... on collision.
// Existence is checked by actually attempting the create, not a separate
// exists-check, so this can't race a concurrent creator of the same name.
@(private = "file")
make_unique_dir :: proc(shows_dir, base: string) -> (dir, folder: string, ok: bool) {
    for attempt in 0 ..< 1000 {
        candidate: string
        if attempt == 0 {
            candidate = base
        } else {
            candidate = fmt.tprintf("%s (%d)", base, attempt + 1)
        }

        path, jerr := os.join_path({shows_dir, candidate}, context.allocator)
        if jerr != nil {
            log.warnf("show registry: could not build path for %q: %v", candidate, jerr)
            return "", "", false
        }

        if merr := os.make_directory(path); merr == nil {
            return path, strings.clone(candidate), true
        } else if merr != os.General_Error.Exist {
            log.warnf("show registry: could not create directory %v: %v", path, merr)
            delete(path)
            return "", "", false
        }
        delete(path)
    }

    log.warnf("show registry: could not find a unique folder name for %q after 1000 attempts", base)
    return "", "", false
}

@(private = "file")
index_file_path :: proc(shows_dir: string, allocator := context.allocator) -> string {
    path, _ := os.join_path({shows_dir, "index.json"}, allocator)
    return path
}

@(private = "file")
load_index :: proc(shows_dir: string) -> Show_Index_DTO {
    path := index_file_path(shows_dir, context.temp_allocator)
    data, rerr := os.read_entire_file(path, context.temp_allocator)
    if rerr != nil {
        // Missing index is the normal first-run / first-show case.
        if rerr != os.General_Error.Not_Exist {
            log.warnf("show registry: could not read index %v: %v", path, rerr)
        }
        return Show_Index_DTO{version = INDEX_VERSION}
    }

    idx: Show_Index_DTO
    if perr := json.unmarshal(data, &idx, allocator = context.temp_allocator); perr != nil {
        log.warnf("show registry: could not parse index %v: %v", path, perr)
        return Show_Index_DTO{version = INDEX_VERSION}
    }
    if idx.version != INDEX_VERSION {
        log.warnf("show registry: index version %v, expected %v — treating as empty: %v",
            idx.version, INDEX_VERSION, path)
        return Show_Index_DTO{version = INDEX_VERSION}
    }
    return idx
}

@(private = "file")
save_index :: proc(shows_dir: string, idx: ^Show_Index_DTO) -> bool {
    idx.version = INDEX_VERSION
    path := index_file_path(shows_dir, context.temp_allocator)
    data, merr := json.marshal(idx^, {pretty = true}, context.temp_allocator)
    if merr != nil {
        log.errorf("show registry: index marshal failed: %v", merr)
        return false
    }
    if werr := os.write_entire_file(path, data); werr != nil {
        log.errorf("show registry: index write failed: %v (%v)", path, werr)
        return false
    }
    return true
}

Show_Info :: struct {
    id:   string, // owned
    name: string, // owned
    dir:  string, // owned; full path to the show's folder
}

destroy_infos :: proc(infos: []Show_Info) {
    for info in infos {
        delete(info.id)
        delete(info.name)
        delete(info.dir)
    }
    delete(infos)
}

@(private = "file")
Show_Summary_DTO :: struct {
    id:   string,
    name: string,
}

// Lists shows via the index, cross-checking each folder's show.json id
// against what the index promised. A mismatch is skipped (not trusted
// either way) and logged -- same "surface it, don't silently pick a side"
// stance as load_by_id; the actual repair is a separate, user-confirmed step.
enumerate :: proc(shows_dir: string) -> []Show_Info {
    infos := make([dynamic]Show_Info, 0)
    if shows_dir == "" do return infos[:]

    idx := load_index(shows_dir)
    for e in idx.entries {
        dir, jerr := os.join_path({shows_dir, e.folder}, context.temp_allocator)
        if jerr != nil {
            log.warnf("show registry: could not build path for %q: %v", e.folder, jerr)
            continue
        }
        show_path, jerr2 := os.join_path({dir, "show.json"}, context.temp_allocator)
        if jerr2 != nil {
            log.warnf("show registry: could not build show.json path for %q: %v", e.folder, jerr2)
            continue
        }

        data, rerr := os.read_entire_file(show_path, context.temp_allocator)
        if rerr != nil {
            log.warnf("show registry: could not read %v: %v", show_path, rerr)
            continue
        }

        summary: Show_Summary_DTO
        if perr := json.unmarshal(data, &summary, allocator = context.temp_allocator); perr != nil {
            log.warnf("show registry: could not parse %v: %v", show_path, perr)
            continue
        }
        if summary.id != e.id {
            log.warnf("show registry: index says %v is at folder %q, but show.json there has id %v — skipping (stale index)",
                e.id, e.folder, summary.id)
            continue
        }

        name := summary.name
        if name == "" do name = "Unnamed"

        append(&infos, Show_Info{
            id   = strings.clone(summary.id),
            name = strings.clone(name),
            dir  = strings.clone(dir),
        })
    }

    return infos[:]
}

// Deletes a show's folder (recursively -- assets and all) and its index
// entry. Refuses to remove the last remaining show, same as settings/scene.
remove :: proc(shows_dir, id: string) -> bool {
    infos := enumerate(shows_dir)
    defer destroy_infos(infos)

    if len(infos) <= 1 {
        log.warnf("show registry: refusing to remove %v — it is the last remaining show in %v", id, shows_dir)
        return false
    }

    idx := load_index(shows_dir)
    entry_i := -1
    for e, i in idx.entries {
        if e.id == id {
            entry_i = i
            break
        }
    }
    if entry_i < 0 {
        log.warnf("show registry: no index entry for show %v; nothing to remove", id)
        return false
    }
    folder := idx.entries[entry_i].folder

    dir, jerr := os.join_path({shows_dir, folder}, context.temp_allocator)
    if jerr != nil {
        log.warnf("show registry: could not build path for %v: %v", id, jerr)
        return false
    }

    if !remove_dir_recursive(dir) {
        log.warnf("show registry: could not fully remove %v", dir)
        return false
    }

    remaining := make([dynamic]Show_Index_Entry_DTO, 0, len(idx.entries), context.temp_allocator)
    for e, i in idx.entries {
        if i == entry_i do continue
        append(&remaining, e)
    }
    idx.entries = remaining[:]
    if !save_index(shows_dir, &idx) {
        log.warnf("show registry: removed show %v but failed to update index", id)
    }

    log.infof("removed show %v", id)
    return true
}

@(private = "file")
remove_dir_recursive :: proc(dir: string) -> bool {
    entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
    if err != nil {
        if err == os.General_Error.Not_Exist do return true
        log.warnf("show registry: could not read directory %v: %v", dir, err)
        return false
    }

    for entry in entries {
        if entry.type == .Directory {
            if !remove_dir_recursive(entry.fullpath) do return false
        } else {
            if rerr := os.remove(entry.fullpath); rerr != nil {
                log.warnf("show registry: could not remove %v: %v", entry.fullpath, rerr)
                return false
            }
        }
    }

    if rerr := os.remove(dir); rerr != nil {
        log.warnf("show registry: could not remove directory %v: %v", dir, rerr)
        return false
    }
    return true
}

// Renames a show: moves its folder to a collision-safe name derived from
// new_name, updates the index, and updates the display name inside show.json.
rename :: proc(shows_dir, id, new_name: string) -> bool {
    if shows_dir == "" {
        log.warn("show registry: rename requested, but no shows directory is available")
        return false
    }

    idx := load_index(shows_dir)
    entry_i := -1
    for e, i in idx.entries {
        if e.id == id {
            entry_i = i
            break
        }
    }
    if entry_i < 0 {
        log.warnf("show registry: no index entry for show %v", id)
        return false
    }
    old_folder := idx.entries[entry_i].folder

    old_dir, jerr := os.join_path({shows_dir, old_folder}, context.temp_allocator)
    if jerr != nil {
        log.warnf("show registry: could not build path for %v: %v", id, jerr)
        return false
    }

    base := sanitize_folder_name(new_name, context.temp_allocator)
    new_dir, new_folder, ok := rename_to_unique(shows_dir, old_dir, base)
    if !ok {
        return false
    }
    defer delete(new_dir)
    defer delete(new_folder)

    show_path, jerr2 := os.join_path({new_dir, "show.json"}, context.temp_allocator)
    if jerr2 != nil {
        log.warnf("show registry: could not build show.json path for %v: %v", id, jerr2)
        return false
    }

    s: Show
    if !load(&s, show_path) {
        log.warnf("show registry: renamed folder for %v but could not load show.json to update its name", id)
        return false
    }
    defer destroy_show(&s)

    delete(s.name)
    s.name = strings.clone(new_name)
    if !save(&s, show_path) {
        log.warnf("show registry: could not save renamed show %v", id)
        return false
    }

    idx.entries[entry_i].folder = new_folder
    if !save_index(shows_dir, &idx) {
        log.warnf("show registry: renamed show %v but failed to update index", id)
    }

    log.infof("renamed show %v to %q (folder %q -> %q)", id, new_name, old_folder, new_folder)
    return true
}

// Moves old_dir to shows_dir/base, or shows_dir/base (2), (3), ... on
// collision. A no-op rename (new name sanitizes to the same folder) is
// treated as success without touching the filesystem.
@(private = "file")
rename_to_unique :: proc(shows_dir, old_dir, base: string) -> (dir, folder: string, ok: bool) {
    for attempt in 0 ..< 1000 {
        candidate: string
        if attempt == 0 {
            candidate = base
        } else {
            candidate = fmt.tprintf("%s (%d)", base, attempt + 1)
        }

        path, jerr := os.join_path({shows_dir, candidate}, context.allocator)
        if jerr != nil {
            log.warnf("show registry: could not build path for %q: %v", candidate, jerr)
            return "", "", false
        }

        if path == old_dir {
            return path, strings.clone(candidate), true
        }

        if os.exists(path) {
            delete(path)
            continue
        }

        if rerr := os.rename(old_dir, path); rerr != nil {
            log.warnf("show registry: could not rename %v to %v: %v", old_dir, path, rerr)
            delete(path)
            return "", "", false
        }

        return path, strings.clone(candidate), true
    }

    log.warnf("show registry: could not find a unique folder name for %q after 1000 attempts", base)
    return "", "", false
}
