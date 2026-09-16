package app

import "core:log"
import "core:strings"

import "../config"
import "../show"
import "../ui"

// Dispatches a Show menu request raised by ui; always clears the request.
handle_show_request :: proc(
	req:     ui.Show_Request,
	state:   ^ui.Show_State,
	cfg:     ^show.Show,
	app_cfg: ^config.App_Config,
	paths:   ^config.Paths,
	infos:   ^[]show.Show_Info,
) {
	state.request = .None

	#partial switch req {
	case .Switch:
		id := state.switch_to
		defer {
			delete(id)
			state.switch_to = ""
		}
		switch_show(id, cfg, app_cfg, paths)

	case .New:
		name := state.pending_name
		defer { delete(name); state.pending_name = "" }
		if paths.shows == "" {
			log.warn("new show requested, but no shows directory is available")
			return
		}
		if created, ok := show.create(paths.shows, name); ok {
			// Save the outgoing show so its edits aren't lost.
			show.save_show(paths.shows, cfg)
			show.destroy_show(cfg)
			cfg^ = created
			set_active_show(app_cfg, paths, cfg.id)
			refresh_show_infos(infos, paths)
			log.infof("created and switched to show %v (%v)", cfg.name, cfg.id)
		} else {
			log.warnf("could not create show %q", name)
		}

	case .Rename:
		name := state.pending_name
		defer { delete(name); state.pending_name = "" }
		if paths.shows == "" {
			log.warn("show rename requested, but no shows directory is available")
			return
		}
		// show.rename moves the folder and updates show.json's name itself;
		// just sync the in-memory copy to match.
		if show.rename(paths.shows, cfg.id, name) {
			delete(cfg.name)
			cfg.name = strings.clone(name)
			refresh_show_infos(infos, paths)
		} else {
			log.warnf("could not rename show %v to %q", cfg.id, name)
		}

	case .Delete:
		delete_active_show(cfg, app_cfg, paths, infos, state)
	}
}

@(private = "file")
switch_show :: proc(id: string, cfg: ^show.Show, app_cfg: ^config.App_Config, paths: ^config.Paths) {
	if id == cfg.id do return
	if paths.shows == "" {
		log.warn("show switch requested, but no shows directory is available")
		return
	}

	// Save the outgoing show so unapplied edits aren't lost.
	show.save_show(paths.shows, cfg)

	loaded, ok := show.load_by_id(id, paths.shows)
	if !ok {
		// Don't touch cfg -- a failed load must not leave it half-destroyed.
		log.warnf("could not load show %v; staying on %v", id, cfg.id)
		return
	}

	show.destroy_show(cfg)
	cfg^ = loaded
	set_active_show(app_cfg, paths, cfg.id)

	log.infof("switched to show %v (%v)", cfg.name, cfg.id)
}

@(private = "file")
delete_active_show :: proc(
	cfg:     ^show.Show,
	app_cfg: ^config.App_Config,
	paths:   ^config.Paths,
	infos:   ^[]show.Show_Info,
	state:   ^ui.Show_State,
) {
	if paths.shows == "" {
		log.warn("show delete requested, but no shows directory is available")
		return
	}

	survivor := pick_survivor_show(infos^, cfg.id)
	if survivor == "" {
		state.denied = strings.clone("Can't delete the only remaining show.")
		return
	}

	loaded, ok := show.load_by_id(survivor, paths.shows)
	if !ok {
		log.warnf("could not switch away from %v to delete it; leaving it in place", cfg.id)
		return
	}

	// Move the active show aside before deleting its folder.
	prev_id := strings.clone(cfg.id)
	defer delete(prev_id)

	show.destroy_show(cfg)
	cfg^ = loaded
	set_active_show(app_cfg, paths, cfg.id)

	if !show.remove(paths.shows, prev_id) {
		log.warnf("switched away from show %v but could not delete it", prev_id)
	}

	refresh_show_infos(infos, paths)
	log.infof("deleted show %v, switched to %v (%v)", prev_id, cfg.name, cfg.id)
}

// Picks a replacement show: first by name, tie-broken by id.
@(private = "file")
pick_survivor_show :: proc(infos: []show.Show_Info, exclude_id: string) -> string {
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
set_active_show :: proc(app_cfg: ^config.App_Config, paths: ^config.Paths, id: string) {
	if paths.app_config == "" || app_cfg.active_show_id == id do return
	delete(app_cfg.active_show_id)
	app_cfg.active_show_id = strings.clone(id)
	config.save_app_config(app_cfg, paths.app_config)
}

@(private = "file")
refresh_show_infos :: proc(infos: ^[]show.Show_Info, paths: ^config.Paths) {
	show.destroy_infos(infos^)
	infos^ = paths.shows != "" ? show.enumerate(paths.shows) : nil
}
