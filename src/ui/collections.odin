package ui

import "core:fmt"
import "core:strings"
import im "libs:odin-imgui"

import "../scene"

Collection_Request :: enum {
    None,
    Switch,
    New,
    Rename,
    Delete,
}

// Requests are raised here and consumed/cleared by main -- same pattern as
// Profile_State.request, and for the same reason: ui has no config path and
// cannot touch the registry itself.
Collection_State :: struct {
    request:      Collection_Request,
    switch_to:    string,  // owned clone of the target collection id; set only for .Switch
    pending_name: string,  // owned clone of the entered name; set only for .New / .Rename
    name_buf:     [128]u8, // shared by the New and Rename popups; only one is open at a time
    denied:       string,  // owned; non-empty shows a dismissible "can't delete" popup until main clears it
    want_new:     bool,    // raised by the menu item, consumed by draw_collection_popups
    want_rename:  bool,    // same
    want_delete:  bool,    // same
}

init_collections_state :: proc() -> Collection_State {
    return Collection_State{}
}

// infos is owned and refreshed by main (a directory scan per frame would be
// wasteful); a collection added, renamed, or removed outside the app isn't
// reflected here until main's next refresh.
draw_collection_menu :: proc(state: ^Collection_State, infos: []scene.Collection_Info, active_id, active_name: string) {
    if im.BeginMenu("Scene Collection") {
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

        // These only raise a flag rather than calling im.OpenPopup directly --
        // see the identical comment in draw_profile_menu for why calling
        // OpenPopup from inside a nested menu doesn't work.
        if im.MenuItem("New Collection...") {
            state.name_buf = {}
            state.want_new = true
        }
        if im.MenuItem("Rename Collection...") {
            state.name_buf = {}
            seed_name_buf(state.name_buf[:], active_name)
            state.want_rename = true
        }
        if im.MenuItem("Delete Collection...") {
            state.want_delete = true
        }

        im.EndMenu()
    }
}

// Called every frame regardless of whether the Scene Collection menu is open
// -- BeginPopupModal has to run every frame for ImGui to keep tracking an
// already-open popup, same reason draw_settings is unconditional. OpenPopup
// is called right here, next to its BeginPopupModal, so both see the same
// (top-level) ID stack.
draw_collection_popups :: proc(state: ^Collection_State, active_name: string) {
    if state.want_new {
        im.OpenPopup("New Collection")
        state.want_new = false
    }
    draw_new_collection_popup(state)

    if state.want_rename {
        im.OpenPopup("Rename Collection")
        state.want_rename = false
    }
    draw_rename_collection_popup(state)

    if state.want_delete {
        im.OpenPopup("Delete Collection")
        state.want_delete = false
    }
    draw_delete_collection_popup(state, active_name)

    draw_delete_collection_denied_popup(state)
}

@(private = "file")
draw_new_collection_popup :: proc(state: ^Collection_State) {
    if im.BeginPopupModal("New Collection") {
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
draw_rename_collection_popup :: proc(state: ^Collection_State) {
    if im.BeginPopupModal("Rename Collection") {
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
draw_delete_collection_popup :: proc(state: ^Collection_State, active_name: string) {
    if im.BeginPopupModal("Delete Collection") {
        im.TextUnformatted(fmt.ctprintf("Delete scene collection \"%s\"? This cannot be undone.", active_name))
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
draw_delete_collection_denied_popup :: proc(state: ^Collection_State) {
    if state.denied != "" && !im.IsPopupOpen("Can't Delete Collection") {
        im.OpenPopup("Can't Delete Collection")
    }
    if im.BeginPopupModal("Can't Delete Collection") {
        im.TextUnformatted(fmt.ctprintf("%s", state.denied))
        if im.Button("OK") {
            delete(state.denied)
            state.denied = ""
            im.CloseCurrentPopup()
        }
        im.EndPopup()
    }
}
