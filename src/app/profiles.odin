package app

import "core:log"
import "core:strings"

import "../config"
import "../settings"
import "../ui"

// Dispatches a Profile menu request raised by ui. Always clears the request
// and whatever owned strings ui attached to it (switch_to / pending_name),
// whether or not the action actually went through -- a request is
// one-shot regardless of outcome.
handle_profile_request :: proc(
	req:    ui.Profile_Request,
	state:  ^ui.Profile_State,
	cfg:    ^settings.Profile,
	app_cfg: ^config.App_Config,
	paths:  ^config.Paths,
	infos:  ^[]settings.Profile_Info,
) {
	state.request = .None

	#partial switch req {
	case .Switch:
		id := state.switch_to
		defer { delete(id); state.switch_to = "" }
		switch_profile(id, cfg, app_cfg, paths)

	case .New:
		name := state.pending_name
		defer { delete(name); state.pending_name = "" }
		if paths.profiles == "" {
			log.warn("new profile requested, but no config path is available")
			return
		}
		if created, ok := settings.create(paths.profiles, name); ok {
			// Belt-and-braces, as with Switch: don't lose unsaved edits to
			// the profile being left behind.
			settings.save_profile(cfg, paths.profiles)
			settings.destroy_profile(cfg)
			cfg^ = created
			set_active_profile(app_cfg, paths, cfg.id)
			refresh_profile_infos(infos, paths)
			log.infof("created and switched to profile %v (%v)", cfg.name, cfg.id)
		} else {
			log.warnf("could not create profile %q", name)
		}

	case .Rename:
		name := state.pending_name
		defer { delete(name); state.pending_name = "" }
		delete(cfg.name)
		cfg.name = strings.clone(name)
		if paths.profiles != "" {
			settings.save_profile(cfg, paths.profiles)
			refresh_profile_infos(infos, paths)
		}

	case .Delete:
		delete_active_profile(cfg, app_cfg, paths, infos, state)
	}
}

@(private = "file")
switch_profile :: proc(id: string, cfg: ^settings.Profile, app_cfg: ^config.App_Config, paths: ^config.Paths) {
	if id == cfg.id do return
	if paths.profiles == "" {
		log.warn("profile switch requested, but no config path is available")
		return
	}

	// Apply already persists, but a profile edited and not applied
	// shouldn't silently lose changes just because the user switched away.
	settings.save_profile(cfg, paths.profiles)

	loaded, ok := settings.load_by_id(paths.profiles, id)
	if !ok {
		// Don't touch cfg -- a failed load must not leave it half-destroyed.
		log.warnf("could not load profile %v; staying on %v", id, cfg.id)
		return
	}

	settings.destroy_profile(cfg)
	cfg^ = loaded
	set_active_profile(app_cfg, paths, cfg.id)

	log.infof("switched to profile %v (%v, canvas %vx%v)",
		cfg.name, cfg.id, cfg.video.canvas_width, cfg.video.canvas_height)
}

@(private = "file")
delete_active_profile :: proc(
	cfg:     ^settings.Profile,
	app_cfg: ^config.App_Config,
	paths:   ^config.Paths,
	infos:   ^[]settings.Profile_Info,
	state:   ^ui.Profile_State,
) {
	if paths.profiles == "" {
		log.warn("profile delete requested, but no config path is available")
		return
	}

	survivor := pick_survivor(infos^, cfg.id)
	if survivor == "" {
		// registry.remove would refuse this too, but silently -- surface it.
		state.denied = strings.clone("Can't delete the only remaining profile.")
		return
	}

	loaded, ok := settings.load_by_id(paths.profiles, survivor)
	if !ok {
		log.warnf("could not switch away from %v to delete it; leaving it in place", cfg.id)
		return
	}

	// The active profile has to move aside *before* its file is removed:
	// deleting first would either leave cfg pointing at a file that no
	// longer exists (and resurrect it on the next save) or require running
	// with no valid profile at all, which nothing downstream is built to
	// handle mid-frame.
	prev_id := strings.clone(cfg.id)
	defer delete(prev_id)

	settings.destroy_profile(cfg)
	cfg^ = loaded
	set_active_profile(app_cfg, paths, cfg.id)

	if !settings.remove(paths.profiles, prev_id) {
		log.warnf("switched away from profile %v but could not delete its file", prev_id)
	}

	refresh_profile_infos(infos, paths)
	log.infof("deleted profile %v, switched to %v (%v)", prev_id, cfg.name, cfg.id)
}

// First by name, not enumeration order, so repeated deletes behave
// predictably; tie-broken by id in case two profiles share a name. Mirrors
// the pick made at startup when no active profile is recorded.
@(private = "file")
pick_survivor :: proc(infos: []settings.Profile_Info, exclude_id: string) -> string {
	best := -1
	for info, i in infos {
		if info.id == exclude_id do continue
		if best < 0 ||
		   info.name < infos[best].name ||
		   (info.name == infos[best].name && info.id < infos[best].id) {
			best = i
		}
	}
	if best < 0 do return ""
	return infos[best].id
}

@(private = "file")
set_active_profile :: proc(app_cfg: ^config.App_Config, paths: ^config.Paths, id: string) {
	if paths.app_config == "" || app_cfg.active_profile_id == id do return
	delete(app_cfg.active_profile_id)
	app_cfg.active_profile_id = strings.clone(id)
	config.save_app_config(app_cfg, paths.app_config)
}

@(private = "file")
refresh_profile_infos :: proc(infos: ^[]settings.Profile_Info, paths: ^config.Paths) {
	settings.destroy_infos(infos^)
	infos^ = paths.profiles != "" ? settings.enumerate(paths.profiles) : nil
}
