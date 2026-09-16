package app

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "../applog"
import "../config"
import "../scene"
import "../settings"
import "../show"

// Opens one log file per run under paths.root, named with the start timestamp.
open_log_file :: proc(sink: ^applog.Sink, paths: ^config.Paths) {
	if paths.root == "" do return

	year, month, day := time.date(time.now())
	hour, min, sec := time.clock(time.now())
	log_file_name := fmt.tprintf("log-%4d-%02d-%02d_%02d-%02d-%02d.txt",
		year, int(month), day, hour, min, sec)
	if log_path, jerr := filepath.join({paths.root, log_file_name}, context.temp_allocator); jerr == nil {
		if !applog.sink_open_file(sink, log_path) {
			fmt.eprintfln("applog: could not open log file %v -- continuing with ring buffer and console only", log_path)
		}
	}
}

// One-shot migration of the pre-profile settings.json into profiles/<id>.json.
@(private = "file")
migrate_legacy_settings :: proc(paths: ^config.Paths) -> (id: string, migrated: bool) {
	if paths.settings == "" || paths.profiles == "" do return
	if !os.exists(paths.settings) do return

	legacy := settings.create_default()
	defer settings.destroy_profile(&legacy)
	if !settings.load(&legacy, paths.settings) {
		log.warnf("legacy settings %v did not load cleanly; leaving it in place for inspection", paths.settings)
		return
	}

	if existing, already := settings.load_by_id(paths.profiles, legacy.id); already {
		settings.destroy_profile(&existing)
		return
	}

	if !settings.save_profile(&legacy, paths.profiles) {
		log.warnf("could not migrate legacy settings %v into %v; will retry next launch", paths.settings, paths.profiles)
		return
	}

	if rerr := os.remove(paths.settings); rerr != nil {
		log.warnf("migrated %v but could not delete it: %v", paths.settings, rerr)
	}

	log.infof("migrated legacy settings %v -> %v/%v.json", paths.settings, paths.profiles, legacy.id)
	return strings.clone(legacy.id), true
}

// Loads app.json, migrates legacy settings if needed, and selects the active
// profile (load-active / pick-first-by-name / create-Default).
load_app_config_and_profile :: proc(paths: ^config.Paths) -> (app_cfg: config.App_Config, cfg: settings.Profile, profile_infos: []settings.Profile_Info) {
	if paths.app_config != "" {
		config.load_app_config(&app_cfg, paths.app_config)
	}

	if migrated_id, migrated := migrate_legacy_settings(paths); migrated {
		delete(app_cfg.active_profile_id)
		app_cfg.active_profile_id = migrated_id
	}

	cfg = settings.create_default()
	selected := false

	if paths.profiles != "" {
		infos := settings.enumerate(paths.profiles)
		defer settings.destroy_infos(infos)

		if app_cfg.active_profile_id != "" {
			found := false
			for info in infos {
				if info.id == app_cfg.active_profile_id {
					found = true
					break
				}
			}
			if found {
				if loaded, ok := settings.load_by_id(paths.profiles, app_cfg.active_profile_id); ok {
					settings.destroy_profile(&cfg)
					cfg = loaded
					selected = true
				}
			} else {
				log.warnf("active profile %v not found among %v profile(s) in %v; picking another",
					app_cfg.active_profile_id, len(infos), paths.profiles)
			}
		}

		if !selected && len(infos) > 0 {
			// First by name (stable across runs), tie-broken by id.
			best := 0
			for info, i in infos {
				if info.name < infos[best].name ||
				   (info.name == infos[best].name && info.id < infos[best].id) {
					best = i
				}
			}
			if loaded, ok := settings.load_by_id(paths.profiles, infos[best].id); ok {
				settings.destroy_profile(&cfg)
				cfg = loaded
				selected = true
			}
		}

		if !selected {
			if created, ok := settings.create(paths.profiles, "Default"); ok {
				settings.destroy_profile(&cfg)
				cfg = created
				selected = true
			}
		}
	}

	// Keep app.json in sync with whichever profile ended up active.
	if selected && paths.app_config != "" && app_cfg.active_profile_id != cfg.id {
		delete(app_cfg.active_profile_id)
		app_cfg.active_profile_id = strings.clone(cfg.id)
		config.save_app_config(&app_cfg, paths.app_config)
	}

	log.infof("profile %v (%v) active (canvas %vx%v)",
		cfg.name, cfg.id, cfg.video.canvas_width, cfg.video.canvas_height)

	// Cached listing for the Profile menu; refreshed on create/rename/delete.
	if paths.profiles != "" {
		profile_infos = settings.enumerate(paths.profiles)
	}

	return
}

// Same load-active / pick-first / create-Default shape for scene collections.
load_scene_collection :: proc(paths: ^config.Paths, app_cfg: ^config.App_Config) -> (doc: scene.Collection, collection_infos: []scene.Collection_Info) {
	doc = scene.create_default()
	collection_selected := false

	if paths.collections != "" {
		infos := scene.enumerate(paths.collections)
		defer scene.destroy_infos(infos)

		if app_cfg.active_collection_id != "" {
			found := false
			for info in infos {
				if info.id == app_cfg.active_collection_id {
					found = true
					break
				}
			}
			if found {
				if loaded, ok := scene.load_by_id(paths.collections, app_cfg.active_collection_id); ok {
					scene.destroy_all(&doc)
					doc = loaded
					collection_selected = true
				}
			} else {
				log.warnf("active scene collection %v not found among %v collection(s) in %v; picking another",
					app_cfg.active_collection_id, len(infos), paths.collections)
			}
		}

		if !collection_selected && len(infos) > 0 {
			best := 0
			for info, i in infos {
				if info.name < infos[best].name ||
				   (info.name == infos[best].name && info.id < infos[best].id) {
					best = i
				}
			}
			if loaded, ok := scene.load_by_id(paths.collections, infos[best].id); ok {
				scene.destroy_all(&doc)
				doc = loaded
				collection_selected = true
			}
		}

		if !collection_selected {
			if created, ok := scene.create(paths.collections, "Default"); ok {
				scene.destroy_all(&doc)
				doc = created
				collection_selected = true
			}
		}
	}

	if collection_selected && paths.app_config != "" && app_cfg.active_collection_id != doc.id {
		delete(app_cfg.active_collection_id)
		app_cfg.active_collection_id = strings.clone(doc.id)
		config.save_app_config(app_cfg, paths.app_config)
	}

	log.infof("scene collection %v (%v) active (%v scene(s))", doc.name, doc.id, len(doc.scenes))

	// Cached listing for the Scene Collection menu.
	if paths.collections != "" {
		collection_infos = scene.enumerate(paths.collections)
	}

	return
}

// Same load-active / pick-first / create-Default shape as profiles and scene
// collections. Deliberately no migration step -- a show starts empty, it is
// never derived from an existing profile or scene collection.
load_show :: proc(paths: ^config.Paths, app_cfg: ^config.App_Config) -> (s: show.Show, show_infos: []show.Show_Info) {
	s = show.create_default()
	selected := false

	if paths.shows != "" {
		infos := show.enumerate(paths.shows)
		defer show.destroy_infos(infos)

		if app_cfg.active_show_id != "" {
			found := false
			for info in infos {
				if info.id == app_cfg.active_show_id {
					found = true
					break
				}
			}
			if found {
				if loaded, ok := show.load_by_id(app_cfg.active_show_id, paths.shows); ok {
					show.destroy_show(&s)
					s = loaded
					selected = true
				}
			} else {
				log.warnf("active show %v not found among %v show(s) in %v; picking another",
					app_cfg.active_show_id, len(infos), paths.shows)
			}
		}

		if !selected && len(infos) > 0 {
			// First by name (stable across runs), tie-broken by id.
			best := 0
			for info, i in infos {
				if info.name < infos[best].name ||
				   (info.name == infos[best].name && info.id < infos[best].id) {
					best = i
				}
			}
			if loaded, ok := show.load_by_id(infos[best].id, paths.shows); ok {
				show.destroy_show(&s)
				s = loaded
				selected = true
			}
		}

		if !selected {
			if created, ok := show.create(paths.shows, "Default"); ok {
				show.destroy_show(&s)
				s = created
				selected = true
			}
		}
	}

	// Keep app.json in sync with whichever show ended up active.
	if selected && paths.app_config != "" && app_cfg.active_show_id != s.id {
		delete(app_cfg.active_show_id)
		app_cfg.active_show_id = strings.clone(s.id)
		config.save_app_config(app_cfg, paths.app_config)
	}

	log.infof("show %v (%v) active (%v scene(s))", s.name, s.id, len(s.scenes))

	// Cached listing for the Show menu; refreshed on create/rename/delete.
	if paths.shows != "" {
		show_infos = show.enumerate(paths.shows)
	}

	return
}
