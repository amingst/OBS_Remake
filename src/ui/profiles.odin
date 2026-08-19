package ui

import "core:fmt"
import "core:log"
import "core:strings"
import im "libs:odin-imgui"

import "../settings"

Profile_Request :: enum {
    None,
    Switch,
    New,
    Rename,
    Delete,
}

// Requests are raised here and consumed/cleared by main -- same pattern as
// Settings_State.save_request, and for the same reason: ui has no config
// path and cannot touch the registry itself.
Profile_State :: struct {
    request:      Profile_Request,
    switch_to:    string,  // owned clone of the target profile id; set only for .Switch
    pending_name: string,  // owned clone of the entered name; set only for .New / .Rename
    name_buf:     [128]u8, // shared by the New and Rename popups; only one is open at a time
    denied:       string,  // owned; non-empty shows a dismissible "can't delete" popup until main clears it
    want_new:     bool,    // raised by the menu item, consumed by draw_profile_popups
    want_rename:  bool,    // same
    want_delete:  bool,    // same
}

init_profiles_state :: proc() -> Profile_State {
    return Profile_State{}
}

// infos is owned and refreshed by main (a directory scan per frame would be
// wasteful); a profile added, renamed, or removed outside the app isn't
// reflected here until main's next refresh.
draw_profile_menu :: proc(state: ^Profile_State, infos: []settings.Profile_Info, active_id, active_name: string) {
    if im.BeginMenu("Profile") {
        for info in infos {
            label := strings.clone_to_cstring(info.name, context.temp_allocator)
            if im.MenuItem(label, nil, info.id == active_id) {
                if info.id != active_id && state.request == .None {
                    state.switch_to = strings.clone(info.id)
                    state.request = .Switch
                }
            }
        }

        im.Separator()

        // These only raise a flag rather than calling im.OpenPopup directly:
        // popup IDs are relative to the ID stack at the point OpenPopup is
        // called, and this is nested two menus deep (File > Profile) while
        // the matching BeginPopupModal in draw_profile_popups is called at
        // the top level. Calling OpenPopup here would compute a different ID
        // than BeginPopupModal expects, and the popup would never open.
        if im.MenuItem("New Profile...") {
            state.name_buf = {}
            state.want_new = true
        }
        if im.MenuItem("Rename Profile...") {
            state.name_buf = {}
            seed_name_buf(state.name_buf[:], active_name)
            state.want_rename = true
        }
        if im.MenuItem("Delete Profile...") {
            state.want_delete = true
        }

        im.EndMenu()
    }
}

// Called every frame regardless of whether the Profile menu is open --
// BeginPopupModal has to run every frame for ImGui to keep tracking an
// already-open popup, same reason draw_settings is unconditional. OpenPopup
// is called right here, next to its BeginPopupModal, so both see the same
// (top-level) ID stack -- see the comment in draw_profile_menu.
draw_profile_popups :: proc(state: ^Profile_State, active_name: string) {
    if state.want_new {
        im.OpenPopup("New Profile")
        state.want_new = false
    }
    draw_new_profile_popup(state)

    if state.want_rename {
        im.OpenPopup("Rename Profile")
        state.want_rename = false
    }
    draw_rename_profile_popup(state)

    if state.want_delete {
        im.OpenPopup("Delete Profile")
        state.want_delete = false
    }
    draw_delete_profile_popup(state, active_name)

    draw_delete_denied_popup(state)
}

// Shared with collections.odin: both New/Rename popups (profiles and
// collections alike) use the same InputText-into-fixed-buffer shape.
@(private)
seed_name_buf :: proc(buf: []u8, name: string) {
    n := min(len(name), len(buf) - 1)
    copy(buf[:n], name[:n])
}

@(private)
read_name_buf :: proc(buf: []u8) -> (name: string, ok: bool) {
    n := strings.index_byte(string(buf), 0)
    if n < 0 {
        log.warn("name truncated at 128 bytes (no NUL found)")
        n = len(buf)
    }
    name = string(buf[:n])
    if len(name) == 0 {
        log.debug("empty name rejected")
        return "", false
    }
    return name, true
}

@(private = "file")
draw_new_profile_popup :: proc(state: ^Profile_State) {
    if im.BeginPopupModal("New Profile") {
        im.InputText("Name", cstring(&state.name_buf[0]), len(state.name_buf))
        if im.Button("Create") {
            if name, ok := read_name_buf(state.name_buf[:]); ok {
                state.pending_name = strings.clone(name)
                state.request = .New
                state.name_buf = {}
                im.CloseCurrentPopup()
            }
        }
        im.SameLine()
        if im.Button("Cancel") {
            state.name_buf = {}
            im.CloseCurrentPopup()
        }
        im.EndPopup()
    }
}

@(private = "file")
draw_rename_profile_popup :: proc(state: ^Profile_State) {
    if im.BeginPopupModal("Rename Profile") {
        im.InputText("Name", cstring(&state.name_buf[0]), len(state.name_buf))
        if im.Button("Rename") {
            if name, ok := read_name_buf(state.name_buf[:]); ok {
                state.pending_name = strings.clone(name)
                state.request = .Rename
                state.name_buf = {}
                im.CloseCurrentPopup()
            }
        }
        im.SameLine()
        if im.Button("Cancel") {
            state.name_buf = {}
            im.CloseCurrentPopup()
        }
        im.EndPopup()
    }
}

@(private = "file")
draw_delete_profile_popup :: proc(state: ^Profile_State, active_name: string) {
    if im.BeginPopupModal("Delete Profile") {
        im.TextUnformatted(fmt.ctprintf("Delete profile \"%s\"? This cannot be undone.", active_name))
        if im.Button("Delete") {
            state.request = .Delete
            im.CloseCurrentPopup()
        }
        im.SameLine()
        if im.Button("Cancel") {
            im.CloseCurrentPopup()
        }
        im.EndPopup()
    }
}

@(private = "file")
draw_delete_denied_popup :: proc(state: ^Profile_State) {
    if state.denied != "" && !im.IsPopupOpen("Can't Delete Profile") {
        im.OpenPopup("Can't Delete Profile")
    }
    if im.BeginPopupModal("Can't Delete Profile") {
        im.TextUnformatted(fmt.ctprintf("%s", state.denied))
        if im.Button("OK") {
            delete(state.denied)
            state.denied = ""
            im.CloseCurrentPopup()
        }
        im.EndPopup()
    }
}
