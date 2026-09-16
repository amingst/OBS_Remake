package ui

import "core:fmt"
import "core:log"
import "core:strings"
import im "libs:odin-imgui"

import "../show"

Show_Request :: enum {
 	None,
    Switch,
    New,
    Rename,
    Delete,
}

Show_State :: struct {
    request:      Show_Request,
    switch_to:    string,  // owned clone of the target show id; set only for .Switch
    pending_name: string,  // owned clone of the entered name; set only for .New / .Rename
    name_buf:     [128]u8, // shared by the New and Rename popups; only one is open at a time
    denied:       string,  // owned; non-empty shows a dismissible "can't delete" popup until main clears it
    want_new:     bool,    // raised by the menu item, consumed by draw_collection_popups
    want_rename:  bool,    // same
    want_delete:  bool,    // same
}

init_show_state :: proc() -> Show_State {
	return Show_State{}
}

// Shared with menubar.odin's Settings Output tab: both use the same
// InputText-into-fixed-buffer shape.
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

// infos is owned and refreshed by main, not rescanned every frame.
draw_show_menu :: proc(state: ^Show_State, infos: []show.Show_Info, active_id, active_name: string) {
	if im.BeginMenu("Show") {
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

		// Raise a flag rather than calling im.OpenPopup directly -- this is
		// nested inside File > Show, but the matching BeginPopupModal is
		// at the top level, so OpenPopup must be called from there instead.
		if im.MenuItem("New Show...") {
			state.name_buf = {}
			state.want_new = true
		}
		if im.MenuItem("Rename Show...") {
			state.name_buf = {}
			seed_name_buf(state.name_buf[:], active_name)
			state.want_rename = true
		}
		if im.MenuItem("Delete Show...") {
			state.want_delete = true
		}

		im.EndMenu()
	}
}

// Called every frame regardless of menu state -- ImGui needs BeginPopupModal
// to run every frame to keep tracking an already-open popup.
draw_show_popups :: proc(state: ^Show_State, active_name: string) {
	if state.want_new {
		im.OpenPopup("New Show")
		state.want_new = false
	}
	draw_new_show_popup(state)

	if state.want_rename {
		im.OpenPopup("Rename Show")
		state.want_rename = false
	}
	draw_rename_show_popup(state)

	if state.want_delete {
		im.OpenPopup("Delete Show")
		state.want_delete = false
	}
	draw_delete_show_popup(state, active_name)

	draw_delete_show_denied_popup(state)
}

@(private = "file")
draw_new_show_popup :: proc(state: ^Show_State) {
	if im.BeginPopupModal("New Show") {
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
draw_rename_show_popup :: proc(state: ^Show_State) {
	if im.BeginPopupModal("Rename Show") {
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
draw_delete_show_popup :: proc(state: ^Show_State, active_name: string) {
	if im.BeginPopupModal("Delete Show") {
		im.TextUnformatted(fmt.ctprintf("Delete show \"%s\"? This cannot be undone.", active_name))
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
draw_delete_show_denied_popup :: proc(state: ^Show_State) {
	if state.denied != "" && !im.IsPopupOpen("Can't Delete Show") {
		im.OpenPopup("Can't Delete Show")
	}
	if im.BeginPopupModal("Can't Delete Show") {
		im.TextUnformatted(fmt.ctprintf("%s", state.denied))
		if im.Button("OK") {
			delete(state.denied)
			state.denied = ""
			im.CloseCurrentPopup()
		}
		im.EndPopup()
	}
}
