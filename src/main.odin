package obs_remake

// @(require) keeps these imports legal under -vet in non-debug builds, where the
// `when ODIN_DEBUG` block below compiles away and nothing references them.
@(require) import "core:fmt"
import "core:log"
@(require) import "core:mem"
import win32 "core:sys/windows"
import "vendor:directx/dxgi"
import im      "libs:odin-imgui"
import imwin32 "libs:odin-imgui/backends/win32"
import imdx11  "libs:odin-imgui/backends/dx11"
import time "core:time"
import "core:os"
import "core:strings"

// Import from platform module
import "config"
import "settings"
import "platform"
import "render"
import "scene"
import "ui"
import "capture"
import "audio"

main :: proc() {
	// Wrap the heap allocator so we get a leak/bad-free report at exit.
	// Registered first, so its `defer` runs last -- after every other `defer`
	// below has had its chance to free.
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
		defer {
			if len(track.allocation_map) > 0 {
				fmt.eprintfln("=== %v allocation(s) not freed: ===", len(track.allocation_map))
				for _, entry in track.allocation_map {
					fmt.eprintfln("  %v bytes @ %v", entry.size, entry.location)
				}
			}
			if len(track.bad_free_array) > 0 {
				fmt.eprintfln("=== %v bad free(s): ===", len(track.bad_free_array))
				for entry in track.bad_free_array {
					fmt.eprintfln("  %p @ %v", entry.memory, entry.location)
				}
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

	// Set up logging -- console logger to stderr, debug level in debug builds.
	when ODIN_DEBUG {
		context.logger = log.create_console_logger(.Debug)
	} else {
		context.logger = log.create_console_logger(.Info)
	}
	defer log.destroy_console_logger(context.logger)

	// Config locations and persisted state. Done up here, before any device
	// objects exist, because the loaded canvas resolution decides how big the
	// preview target is created below -- see the create_target call.
	//
	// resolve_paths failing is non-fatal and already logged at .Warning: the app
	// runs fine without a writable config directory, it just cannot persist. A
	// zeroed Paths leaves every field "", which is the "no persistence" signal
	// used below, and destroy_paths tolerates it.
	paths, _ := config.resolve_paths()
	defer config.destroy_paths(&paths)

	// app.json: which profile is active. Loaded before any profile is, since
	// deciding which profile to load depends on it. A missing or unreadable
	// file just means a zero-valued config -- non-fatal, same contract as
	// resolve_paths above.
	app_cfg: config.App_Config
	defer config.destroy_app_config(&app_cfg)
	if paths.app_config != "" {
		config.load_app_config(&app_cfg, paths.app_config)
	}

	// One-shot migration of the pre-profile settings file (root/settings.json)
	// into profiles/<id>.json. If it fires, the migrated profile becomes the
	// active one.
	if migrated_id, migrated := migrate_legacy_settings(&paths); migrated {
		delete(app_cfg.active_profile_id)
		app_cfg.active_profile_id = migrated_id
	}

	// Profile owns two heap strings (id, name), so unlike the old plain-data
	// Settings it needs a matching destroy. Whichever branch below ends up
	// filling cfg, destroy_profile is called exactly once on whatever it
	// replaces first, so nothing leaks.
	cfg := settings.create_default()
	defer settings.destroy_profile(&cfg)
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
	// refreshed after a create/rename/delete goes through below -- a profile
	// added, renamed, or removed outside the app isn't noticed until then.
	profile_infos: []settings.Profile_Info
	if paths.profiles != "" {
		profile_infos = settings.enumerate(paths.profiles)
	}
	defer settings.destroy_infos(profile_infos)

	// Make process DPI aware and obtain main monitor scale
	imwin32.EnableDpiAwareness()
	main_scale := imwin32.GetDpiScaleForMonitor(
		win32.MonitorFromPoint(win32.POINT{0, 0}, .MONITOR_DEFAULTTOPRIMARY))

    win: platform.Window
    if (!platform.create_window(&win, "OBS Remake", 1280, 800)) {
        log.fatal("window/device creation failed, exiting")
        return
    }
    defer platform.destroy_window(&win)
    win.msg_hook = imwin32.WndProcHandler

	// Offscreen target the scene is composited into. Created after
	// create_window because it needs win.device, and sized from cfg rather than
	// a constant so a saved canvas resolution is honoured on the very first
	// frame. The reconciliation step in the loop below would eventually catch a
	// divergence, but only after rendering one frame at the wrong size and then
	// tearing the target down again -- pointless when the size is already known.
	preview_target, target_ok := render.create_target(
		win.device, u32(cfg.video.canvas_width), u32(cfg.video.canvas_height))
	if !target_ok {
		log.fatal("preview target creation failed, exiting (cause logged above)")
		return
	}
	defer render.destroy_target(&preview_target)

	// The target that was just built *is* the applied state, so seed from the
	// same cfg it was sized from. Any later divergence is a real request.
	applied := Applied{video = cfg.video}

	pipeline, pok := render.create_pipeline(win.device)
	if !pok do return
	defer render.destroy_pipeline(&pipeline)

	// Show the window
	win32.ShowWindow(win.hwnd, win32.SW_SHOWDEFAULT)
	win32.UpdateWindow(win.hwnd)

	// Setup Dear ImGui context
	im.CHECKVERSION()
	im.CreateContext()
	log.debug("ImGui context created")
	defer {
		im.DestroyContext()
		log.debug("ImGui context destroyed")
	}

	io := im.GetIO()
	io.ConfigFlags |= {
		.NavEnableKeyboard, // Enable Keyboard Controls
		.NavEnableGamepad,  // Enable Gamepad Controls
		.DockingEnable,     // Enable Docking
		.ViewportsEnable,   // Enable Multi-Viewport / Platform Windows
	}
	// io.ConfigViewportsNoAutoMerge = true
	// io.ConfigViewportsNoTaskBarIcon = true
	// io.ConfigDockingAlwaysTabBar = true
	// io.ConfigDockingTransparentPayload = true

	// Setup Dear ImGui style
	im.StyleColorsDark()
	// im.StyleColorsLight()

	// Setup scaling
	style := im.GetStyle()
	// Bake a fixed style scale. (until we have a solution for dynamic style
	// scaling, changing this requires resetting Style + calling this again)
	im.Style_ScaleAllSizes(style, main_scale)
	// Set initial font scale. (in docking branch: using
	// io.ConfigDpiScaleFonts=true automatically overrides this for every window
	// depending on the current monitor)
	style.FontScaleDpi = main_scale
	io.ConfigDpiScaleFonts = true     // [Experimental]
	io.ConfigDpiScaleViewports = true // [Experimental]

	// When viewports are enabled we tweak WindowRounding/WindowBg so platform
	// windows can look identical to regular ones.
	if .ViewportsEnable in io.ConfigFlags {
		style.WindowRounding = 0.0
		style.Colors[im.Col.WindowBg].w = 1.0
	}

	// Setup Platform/Renderer backends
	if !imwin32.Init(win.hwnd) {
		log.fatal("ImGui Win32 backend initialization failed")
		return
	}
	defer imwin32.Shutdown()
	if !imdx11.Init(win.device, win.device_context) {
		log.fatal("ImGui DirectX11 backend initialization failed")
		return
	}
	defer imdx11.Shutdown()
	log.info("ImGui backends initialised")

	// Load Fonts
	// - If fonts are not explicitly loaded, Dear ImGui will select an embedded
	//   font: either AddFontDefaultVector() or AddFontDefaultBitmap().
	// - You can load multiple fonts and use im.PushFont()/PopFont() to select them.
	// - Read 'docs/FONTS.md' for more instructions and details.
	//style.FontSizeBase = 20.0
	//io.Fonts->AddFontDefaultVector()
	//io.Fonts->AddFontFromFileTTF("c:\\Windows\\Fonts\\segoeui.ttf")

	outputs := capture.enumerate_outputs(win.device)
	defer capture.destroy_outputs(outputs)
	capture.log_device_adapter(win.device)

	audio_devices := audio.enumerate_devices()
	defer audio.destroy_devices(audio_devices)
	defer audio.shutdown()
	for dev in audio_devices {
		audio.log_device_format(dev)
	}
	
	// TODO: Remove after testing
	audio_stream: audio.Stream
	defer audio.close_stream(&audio_stream)
	// for dev in audio_devices {
	// 	if dev.is_loopback {
	// 		audio.open_stream(&audio_stream, dev.id, dev.is_default)
	// 		break
	// 	}
	// }

	// The active scene collection. Same load-active/pick-first/create-Default
	// shape as the profile selection above; unlike profiles there's no
	// migration branch, since collections have never been persisted before.
	doc := scene.create_default()
	defer scene.destroy_all(&doc)
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
		config.save_app_config(&app_cfg, paths.app_config)
	}

	log.infof("scene collection %v (%v) active (%v scene(s))", doc.name, doc.id, len(doc.scenes))

	// The Scene Collection menu's list, cached and refreshed the same way as
	// profile_infos above.
	collection_infos: []scene.Collection_Info
	if paths.collections != "" {
		collection_infos = scene.enumerate(paths.collections)
	}
	defer scene.destroy_infos(collection_infos)

    ui_state := ui.init_state(&doc)
	clear_color := im.Vec4{0.45, 0.55, 0.60, 1.00}
    defer ui.destroy(&ui_state)

    done := false
	was_occluded := false
	last_peak_log := time.now()
	// Main loop
	for !done {
		// Poll and handle messages (inputs, window resize, etc.)
        if platform.pump_messages(&win) {
            break
        }

		audio.poll_stream(&audio_stream)

		// Handle window being minimized or screen locked
		if win.swap_chain_occluded && win.swap_chain->Present(0, {.TEST}) == dxgi.STATUS_OCCLUDED {
			if !was_occluded {
				log.debug("swap chain occluded, throttling to 10ms poll")
				was_occluded = true
			}
			win32.Sleep(10)
			continue
		}
		if was_occluded {
			log.debug("occlusion cleared, resuming rendering")
			was_occluded = false
		}
		win.swap_chain_occluded = false

		// Handle window resize (we don't resize directly in the WM_SIZE handler)
		if win.resize_width != 0 && win.resize_height != 0 {
			log.debugf("swapchain resize %vx%v", win.resize_width, win.resize_height)
			platform.cleanup_render_target(&win)
			if hr := win.swap_chain->ResizeBuffers(0, win.resize_width, win.resize_height, .UNKNOWN, {}); hr < 0 {
				log.errorf("ResizeBuffers failed: HRESULT 0x%08X", u32(hr))
			}
			win.resize_width, win.resize_height = 0, 0
			platform.create_render_target(&win)
		}

		// Bring the live objects in line with what the settings modal published.
		// Ordering constraints and the reasoning live in reconcile.odin; the
		// only thing that matters here is that this runs well before
		// im.NewFrame().
		reconcile(&applied, &cfg, win.device, &preview_target)

		// Service a pending save. Deliberately placed *after* the reconciliation
		// above rather than next to the ui.draw call that raises the request: the
		// block above is the only place canvas dimensions are validated, and it
		// may well have overwritten cfg.video with the live target's size. Writing
		// first would put a rejected resolution on disk and then revert it in
		// memory, leaving the file disagreeing with the running app until the next
		// save. So a request raised during frame N is consumed here at the top of
		// frame N+1, once cfg is settled -- one frame of latency, and what gets
		// written is exactly what the app is actually running.
		//
		// The write itself lives here rather than in ui because ui has no idea
		// where the config file is, and shouldn't.
		if trigger := ui_state.settings.save_request; trigger != .None {
			ui_state.settings.save_request = .None
			if paths.profiles != "" {
				log.infof("save requested (%v)", trigger)
				settings.save_profile(&cfg, paths.profiles)
			} else {
				log.warnf("save requested (%v), but no config path is available", trigger)
			}
		}

		// Service a pending profile request, same latency contract as the
		// save request just above. handle_profile_request owns everything it
		// touches on ui_state.profiles (switch_to / pending_name), and clears
		// the request whether or not it succeeded.
		if req := ui_state.profiles.request; req != .None {
			handle_profile_request(req, &ui_state.profiles, &cfg, &app_cfg, &paths, &profile_infos)
		}

		// Service a pending scene collection request. This has to happen here
		// and not, say, folded into ui.draw or deferred a frame: a switch
		// tears down doc (releasing any active display-capture COM objects)
		// and replaces it outright, and that must land before the
		// quads-building block below touches doc's sources -- the same "not
		// mid-frame" requirement that puts the profile switch here too.
		if req := ui_state.collections.request; req != .None {
			handle_collection_request(req, &ui_state.collections, &ui_state.scenes, &ui_state.sources,
				&doc, &app_cfg, &paths, &collection_infos)
		}

		// Neutral fallback for "no scene selected" -- selected_id 0, or the
		// selected scene was deleted. scene.find's pointer is invalidated by
		// the next append to doc.scenes, so copy the colour straight out instead
		// of holding the pointer. Reads last frame's selection, since this runs
		// before ui.draw; one frame of latency is invisible here.
		scene_clear := [4]f32{0.10, 0.10, 0.12, 1.0}
		if sel := scene.find(&doc, ui_state.scenes.selected_id); sel != nil {
			scene_clear = sel.color
		}

		// Composite the scene into the offscreen target before ImGui's frame
		// starts. Render targets are global context state, and the code below
		// rebinds the swap chain's RTV before RenderDrawData -- so doing this
		// first means our binding here is harmlessly replaced rather than
		// clobbering ImGui's.quads := make([dynamic]render.Quad, context.temp_allocator)
		quads := make([dynamic]render.Quad, context.temp_allocator)
		if sel := scene.find(&doc, ui_state.scenes.selected_id); sel != nil {
			for &src in sel.sources {
				if !src.visible do continue
				switch &d in src.data {
					case scene.Audio_Data:
						if d.stream == nil && d.device_id != "" && time.now()._nsec >= d.next_retry._nsec {
							if s := audio.acquire_stream(d.device_id, d.is_loopback); s != nil {
								d.stream = s
							} else {
								d.next_retry = time.time_add(time.now(),2 * time.Second)
							}
						}
					case scene.Color_Data:
						append(&quads, render.Quad{
							x = src.x, y = src.y, w = src.w, h = src.h,
							color = src.color,
						})
					case scene.Display_Data:
						if d.dupl == nil && time.now()._nsec >= d.next_retry._nsec {
							if dupl, ok := capture.start_duplication(win.device, u32(d.adapter_index), u32(d.output_index)); ok {
								d.dupl = dupl
							} else {
								d.next_retry = time.time_add(time.now(), 2 * time.Second)
							}
						}

						if d.dupl != nil && d.texture == nil {
							desc: dxgi.OUTDUPL_DESC
							d.dupl->GetDesc(&desc)
							tex, srv, ok := capture.create_capture_texture(
								win.device, desc.ModeDesc.Width, desc.ModeDesc.Height)
							if ok {
								d.texture = tex
								d.srv = srv
							}
						}
						if d.dupl != nil && d.texture != nil {
							ok, lost := capture.acquire_frame(win.device_context, d.dupl, d.texture)
							if lost {
								log.warn("duplication access lost, will restart")
								capture.stop_duplication(d.dupl)
								d.dupl = nil
								d.next_retry = time.time_add(time.now(), 500 * time.Millisecond)
							}
							_ = ok
						}

						append(&quads, render.Quad{
							x = src.x, y = src.y, w = src.w, h = src.h,
							color = {1, 1, 1, 1},
							texture = d.srv,
						})
				}
			}
		}
		if time.diff(last_peak_log, time.now()) > time.Second {
			log.debugf("audio peak: %.4f", audio_stream.peak)
			audio_stream.peak = 0
			last_peak_log = time.now()
		}
		render.draw_scene(win.device_context, &preview_target, &pipeline, quads[:], scene_clear)
		audio.update_levels()
		// Start the Dear ImGui frame
		imdx11.NewFrame()
		imwin32.NewFrame()
		im.NewFrame()

        // This ImGui version identifies textures by ImTextureRef, not a raw
        // pointer. im.TextureID is a u64, so the SRV goes pointer -> uintptr ->
        // u64; wrapping it in a TextureRef with _TexData left nil means "this
        // is an already-uploaded backend texture, use _TexID directly".
        // Rebuilt each frame so it stays correct if the target is recreated.
        preview_tex := im.TextureRef{_TexID = im.TextureID(uintptr(preview_target.srv))}
        ui.draw(&ui_state, &cfg, &doc, &clear_color, preview_tex, outputs, profile_infos, collection_infos,
            f32(preview_target.width), f32(preview_target.height), audio_devices)

		// Rendering
		im.Render()
		clear_color_with_alpha := [4]f32{
			clear_color.x * clear_color.w,
			clear_color.y * clear_color.w,
			clear_color.z * clear_color.w,
			clear_color.w,
		}
		win.device_context->OMSetRenderTargets(1, &win.render_target_view, nil)
		win.device_context->ClearRenderTargetView(win.render_target_view, &clear_color_with_alpha)
		imdx11.RenderDrawData(im.GetDrawData())

		// Update and Render additional Platform Windows
		if .ViewportsEnable in io.ConfigFlags {
			im.UpdatePlatformWindows()
			im.RenderPlatformWindowsDefault()
		}

		// Present
		hr := win.swap_chain->Present(1, {}) // Present with vsync
		//hr := win.swap_chain->Present(0, {}) // Present without vsync
        free_all(context.temp_allocator)
		if hr < 0 && hr != dxgi.STATUS_OCCLUDED {
			log.errorf("Present failed: HRESULT 0x%08X", u32(hr))
		}
		win.swap_chain_occluded = (hr == dxgi.STATUS_OCCLUDED)
	}

	// Persist on a clean shutdown. Everything that reaches here left the loop
	// normally; the early `return`s above (device/backend init failure) skip it
	// deliberately, since that state isn't worth writing out.
	if paths.profiles != "" {
		log.info("save on exit")
		settings.save_profile(&cfg, paths.profiles)
	}
	if paths.collections != "" {
		scene.save_collection(&doc, paths.collections)
	}
}

// One-shot migration of the pre-profile settings file (root/settings.json)
// into profiles/<id>.json. A successful migration is detected by the *new*
// file existing, not by the old one being gone -- so a run that migrates but
// fails to delete settings.json does not fabricate a second profile from the
// same content on the next launch. Safe to delete this proc, its call site in
// main, and Paths.settings once existing installs have all been through it --
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

// Dispatches a Profile menu request raised by ui. Always clears the request
// and whatever owned strings ui attached to it (switch_to / pending_name),
// whether or not the action actually went through -- a request is
// one-shot regardless of outcome.
@(private = "file")
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

// Dispatches a Scene Collection menu request raised by ui. Same one-shot
// contract as handle_profile_request: the request and whatever owned strings
// ui attached to it are always cleared, whether or not the action went
// through.
@(private = "file")
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
	// later: the quads-building block further down this same frame reads
	// doc's sources and lazily (re)starts captures for whichever collection
	// is current, so the swap must be complete before it runs.
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

