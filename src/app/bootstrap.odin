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

// One log file per run, named with the start timestamp, under the same
// config root as everything else in Paths. Not fatal if it can't be opened
// (no root, or the open itself fails) -- the app already has the ring buffer
// and console, so it just says so once and moves on.
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

// One-shot migration of the pre-profile settings file (root/settings.json)
// into profiles/<id>.json. A successful migration is detected by the *new*
// file existing, not by the old one being gone -- so a run that migrates but
// fails to delete settings.json does not fabricate a second profile from the
// same content on the next launch. Safe to delete this proc, its call site,
// and Paths.settings once existing installs have all been through it --
// say, mid-2027.
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

// Loads app.json, applies the one-shot legacy migration, and selects the
// active profile: load-active / pick-first-by-name / create-Default. Whichever
// branch fills cfg, app.json is written back if the resulting active profile
// id doesn't already match it. Returns the selected profile and the Profile
// menu's cached listing.
load_app_config_and_profile :: proc(paths: ^config.Paths) -> (app_cfg: config.App_Config, cfg: settings.Profile, profile_infos: []settings.Profile_Info) {
	if paths.app_config != "" {
		config.load_app_config(&app_cfg, paths.app_config)
	}

	if migrated_id, migrated := migrate_legacy_settings(paths); migrated {
		delete(app_cfg.active_profile_id)
		app_cfg.active_profile_id = migrated_id
	}

	// Profile owns two heap strings (id, name), so unlike the old plain-data
	// Settings it needs a matching destroy. Whichever branch below ends up
	// filling cfg, destroy_profile is called exactly once on whatever it
	// replaces first, so nothing leaks.
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
				// Deleted outside the app. Fall through to the deterministic
				// pick below rather than treating this as fatal.
				log.warnf("active profile %v not found among %v profile(s) in %v; picking another",
					app_cfg.active_profile_id, len(infos), paths.profiles)
			}
		}

		if !selected && len(infos) > 0 {
			// First by name, not directory order, so the pick is stable
			// across runs. Tie-break on id in case two profiles share a name.
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

	// Whichever profile ended up active, keep app.json in sync with it.
	if selected && paths.app_config != "" && app_cfg.active_profile_id != cfg.id {
		delete(app_cfg.active_profile_id)
		app_cfg.active_profile_id = strings.clone(cfg.id)
		config.save_app_config(&app_cfg, paths.app_config)
	}

	log.infof("profile %v (%v) active (canvas %vx%v)",
		cfg.name, cfg.id, cfg.video.canvas_width, cfg.video.canvas_height)

	// The Profile menu's list. A directory scan plus one parse per profile
	// isn't something to redo every frame, so it's cached here and only
	// refreshed after a create/rename/delete goes through -- a profile added,
	// renamed, or removed outside the app isn't noticed until then.
	if paths.profiles != "" {
		profile_infos = settings.enumerate(paths.profiles)
	}

	return
}

// Same load-active / pick-first / create-Default shape as
// load_app_config_and_profile, for scene collections. Unlike profiles there's
// no migration branch, since collections have never been persisted before.
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

	// The Scene Collection menu's list, cached and refreshed the same way as
	// profile_infos in load_app_config_and_profile.
	if paths.collections != "" {
		collection_infos = scene.enumerate(paths.collections)
	}

	return
}
