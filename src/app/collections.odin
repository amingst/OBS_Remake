package app

import "core:log"
import "core:strings"

import "../config"
import "../scene"
import "../ui"

// Dispatches a Scene Collection menu request raised by ui. Same one-shot
// contract as handle_profile_request: the request and whatever owned strings
// ui attached to it are always cleared, whether or not the action went
// through.
handle_collection_request :: proc(
	req:     ui.Collection_Request,
	state:   ^ui.Collection_State,
	scenes:  ^ui.Scenes_State,
	sources: ^ui.Sources_State,
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
		if switch_collection(id, doc, app_cfg, paths) {
			reset_collection_selection(scenes, sources, doc)
		}

	case .New:
		name := state.pending_name
		defer { delete(name); state.pending_name = "" }
		if paths.collections == "" {
			log.warn("new scene collection requested, but no config path is available")
			return
		}
		if created, ok := scene.create(paths.collections, name); ok {
			// Belt-and-braces, as with profiles: don't lose unsaved edits to
			// the collection being left behind.
			scene.save_collection(doc, paths.collections)
			scene.destroy_all(doc)
			doc^ = created
			set_active_collection(app_cfg, paths, doc.id)
			refresh_collection_infos(infos, paths)
			reset_collection_selection(scenes, sources, doc)
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
		delete_active_collection(doc, app_cfg, paths, infos, state, scenes, sources)
	}
}

// Scenes and sources have no Apply button -- edits are immediate -- so
// saving on every mutation would mean a disk write on every frame of a
// DragFloat drag. Switch and exit are the two natural save points instead,
// same trade-off profiles make around their own Apply button: anything
// since the last switch or exit is lost on a crash.
@(private = "file")
switch_collection :: proc(id: string, doc: ^scene.Collection, app_cfg: ^config.App_Config, paths: ^config.Paths) -> bool {
	if id == doc.id do return false
	if paths.collections == "" {
		log.warn("scene collection switch requested, but no config path is available")
		return false
	}

	scene.save_collection(doc, paths.collections)

	loaded, ok := scene.load_by_id(paths.collections, id)
	if !ok {
		// Don't touch doc -- a failed load must not leave it half-destroyed.
		log.warnf("could not load scene collection %v; staying on %v", id, doc.id)
		return false
	}

	// destroy_all releases any active display-capture COM objects for the
	// outgoing collection. This has to run here, at the same point in the
	// loop as the profile switch, and not from inside ui.draw or a frame
	// later: the quads-building block later in the frame reads doc's sources
	// and lazily (re)starts captures for whichever collection is current, so
	// the swap must be complete before it runs.
	scene.destroy_all(doc)
	doc^ = loaded
	set_active_collection(app_cfg, paths, doc.id)

	log.infof("switched to scene collection %v (%v, %v scene(s))", doc.name, doc.id, len(doc.scenes))
	return true
}

@(private = "file")
delete_active_collection :: proc(
	doc:     ^scene.Collection,
	app_cfg: ^config.App_Config,
	paths:   ^config.Paths,
	infos:   ^[]scene.Collection_Info,
	state:   ^ui.Collection_State,
	scenes:  ^ui.Scenes_State,
	sources: ^ui.Sources_State,
) {
	if paths.collections == "" {
		log.warn("scene collection delete requested, but no config path is available")
		return
	}

	survivor := pick_collection_survivor(infos^, doc.id)
	if survivor == "" {
		// registry.remove would refuse this too, but silently -- surface it.
		state.denied = strings.clone("Can't delete the only remaining scene collection.")
		return
	}

	loaded, ok := scene.load_by_id(paths.collections, survivor)
	if !ok {
		log.warnf("could not switch away from %v to delete it; leaving it in place", doc.id)
		return
	}

	// Same ordering as delete_active_profile and for the same reason: doc
	// has to move aside, releasing its COM objects, before its file is
	// removed -- deleting first would leave doc pointing at a vanished file
	// (which a later save would just recreate) with nothing downstream built
	// to run a frame against no collection at all.
	prev_id := strings.clone(doc.id)
	defer delete(prev_id)

	scene.destroy_all(doc)
	doc^ = loaded
	set_active_collection(app_cfg, paths, doc.id)
	reset_collection_selection(scenes, sources, doc)

	if !scene.remove(paths.collections, prev_id) {
		log.warnf("switched away from scene collection %v but could not delete its file", prev_id)
	}

	refresh_collection_infos(infos, paths)
	log.infof("deleted scene collection %v, switched to %v (%v)", prev_id, doc.name, doc.id)
}

// First by name, not enumeration order, tie-broken by id -- mirrors
// pick_survivor for the same reasons.
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

// selected_id on both scenes and sources refers to ids owned by whichever
// collection was active before a switch/create/delete; the new collection
// doesn't have those ids, so both must be repointed. Mirrors what
// ui.init_state seeds on first load: the new collection's first scene, or
// nothing if it's empty.
@(private = "file")
reset_collection_selection :: proc(scenes: ^ui.Scenes_State, sources: ^ui.Sources_State, doc: ^scene.Collection) {
	sources.selected_id = 0
	scenes.selected_id = 0
	if len(doc.scenes) > 0 {
		scenes.selected_id = doc.scenes[0].id
	}
}
