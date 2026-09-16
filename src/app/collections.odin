package app

import "core:log"
import "core:strings"

import "../config"
import "../scene"
import "../ui"

// Dispatches a Scene Collection menu request raised by ui; always clears the request.
handle_collection_request :: proc(
	req:     ui.Collection_Request,
	state:   ^ui.Collection_State,
	doc:     ^scene.Collection,
	app_cfg: ^config.App_Config,
	paths:   ^config.Paths,
	infos:   ^[]scene.Collection_Info,
) {
	state.request = .None

	#partial switch req {
	case .Switch:
		id := state.switch_to
		defer { delete(id); state.switch_to = "" }
		switch_collection(id, doc, app_cfg, paths)

	case .New:
		name := state.pending_name
		defer { delete(name); state.pending_name = "" }
		if paths.collections == "" {
			log.warn("new scene collection requested, but no config path is available")
			return
		}
		if created, ok := scene.create(paths.collections, name); ok {
			// Save the outgoing collection so its edits aren't lost.
			scene.save_collection(doc, paths.collections)
			scene.destroy_all(doc)
			doc^ = created
			set_active_collection(app_cfg, paths, doc.id)
			refresh_collection_infos(infos, paths)
			log.infof("created and switched to scene collection %v (%v)", doc.name, doc.id)
		} else {
			log.warnf("could not create scene collection %q", name)
		}

	case .Rename:
		name := state.pending_name
		defer { delete(name); state.pending_name = "" }
		delete(doc.name)
		doc.name = strings.clone(name)
		if paths.collections != "" {
			scene.save_collection(doc, paths.collections)
			refresh_collection_infos(infos, paths)
		}

	case .Delete:
		delete_active_collection(doc, app_cfg, paths, infos, state)
	}
}

// Saves and switches the active scene collection.
@(private = "file")
switch_collection :: proc(id: string, doc: ^scene.Collection, app_cfg: ^config.App_Config, paths: ^config.Paths) {
	if id == doc.id do return
	if paths.collections == "" {
		log.warn("scene collection switch requested, but no config path is available")
		return
	}

	scene.save_collection(doc, paths.collections)

	loaded, ok := scene.load_by_id(paths.collections, id)
	if !ok {
		// Don't touch doc -- a failed load must not leave it half-destroyed.
		log.warnf("could not load scene collection %v; staying on %v", id, doc.id)
		return
	}

	// Releases the outgoing collection's active captures before the swap.
	scene.destroy_all(doc)
	doc^ = loaded
	set_active_collection(app_cfg, paths, doc.id)

	log.infof("switched to scene collection %v (%v, %v scene(s))", doc.name, doc.id, len(doc.scenes))
}

@(private = "file")
delete_active_collection :: proc(
	doc:     ^scene.Collection,
	app_cfg: ^config.App_Config,
	paths:   ^config.Paths,
	infos:   ^[]scene.Collection_Info,
	state:   ^ui.Collection_State,
) {
	if paths.collections == "" {
		log.warn("scene collection delete requested, but no config path is available")
		return
	}

	survivor := pick_collection_survivor(infos^, doc.id)
	if survivor == "" {
		state.denied = strings.clone("Can't delete the only remaining scene collection.")
		return
	}

	loaded, ok := scene.load_by_id(paths.collections, survivor)
	if !ok {
		log.warnf("could not switch away from %v to delete it; leaving it in place", doc.id)
		return
	}

	// Move the active collection aside (releasing its COM objects) before deleting its file.
	prev_id := strings.clone(doc.id)
	defer delete(prev_id)

	scene.destroy_all(doc)
	doc^ = loaded
	set_active_collection(app_cfg, paths, doc.id)

	if !scene.remove(paths.collections, prev_id) {
		log.warnf("switched away from scene collection %v but could not delete its file", prev_id)
	}

	refresh_collection_infos(infos, paths)
	log.infof("deleted scene collection %v, switched to %v (%v)", prev_id, doc.name, doc.id)
}

// Picks a replacement collection: first by name, tie-broken by id.
@(private = "file")
pick_collection_survivor :: proc(infos: []scene.Collection_Info, exclude_id: string) -> string {
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
set_active_collection :: proc(app_cfg: ^config.App_Config, paths: ^config.Paths, id: string) {
	if paths.app_config == "" || app_cfg.active_collection_id == id do return
	delete(app_cfg.active_collection_id)
	app_cfg.active_collection_id = strings.clone(id)
	config.save_app_config(app_cfg, paths.app_config)
}

@(private = "file")
refresh_collection_infos :: proc(infos: ^[]scene.Collection_Info, paths: ^config.Paths) {
	scene.destroy_infos(infos^)
	infos^ = paths.collections != "" ? scene.enumerate(paths.collections) : nil
}
