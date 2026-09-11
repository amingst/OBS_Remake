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
import mf      "libs:mf"
import time "core:time"
import "core:os"
import "core:strings"
import "core:path/filepath"

// Import from platform module
import "config"
import "settings"
import "platform"
import "render"
import "scene"
import "ui"
import "capture"
import "audio"
import "encode"
import "rtmp"
import "mp4"
import "applog"

Output_State :: struct {
	recording:		bool,
	streaming:		bool,
	rtmp_stream:	^rtmp.Rtmp_Stream,
	mp4_sink:		^mp4.Mp4_Sink,
}

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
	log_sink := applog.sink_init(8192)
	defer applog.sink_destroy(log_sink)

	main_log_ctx := applog.Log_Context{sink = log_sink, tag = {.Main, 0}}
	context.logger = applog.make_logger(&main_log_ctx)

	// The audio capture thread logs through this same sink -- set once here,
	// before any stream is opened (streams are only acquired later, from the
	// scene-source handling in the main loop below).
	audio.set_log_sink(log_sink)

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

	// One log file per run, named with the start timestamp, under the same
	// config root as everything else in Paths. Not fatal if it can't be
	// opened (no root, or the open itself fails) -- the app already has the
	// ring buffer and console, so it just says so once and moves on.
	if paths.root != "" {
		year, month, day := time.date(time.now())
		hour, min, sec := time.clock(time.now())
		log_file_name := fmt.tprintf("log-%4d-%02d-%02d_%02d-%02d-%02d.txt",
			year, int(month), day, hour, min, sec)
		if log_path, jerr := filepath.join({paths.root, log_file_name}, context.temp_allocator); jerr == nil {
			if !applog.sink_open_file(log_sink, log_path) {
				fmt.eprintfln("applog: could not open log file %v -- continuing with ring buffer and console only", log_path)
			}
		}
	}

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

	if hr := mf.MFStartup(mf.MF_VERSION, mf.MFSTARTUP_FULL); hr < 0 {
		log.errorf("MFStartup failed: 0x%08X", u32(hr))
		return
	}
	defer mf.MFShutdown()

	// Diagnostic wiring: prove the encoder thread's acquire/release lifecycle
	// works end to end before any real work is routed through it. Held for
	// the whole app lifetime -- no consumers registered, no frames pushed.
	// Registered after MFStartup/audio init so its LIFO release runs before
	// mf.MFShutdown and audio.shutdown, while the encoder thread's COM/MF
	// calls are still valid.
	encoder_cfg := encode.Encoder_Config{
		width              = preview_target.width,
		height             = preview_target.height,
		fps                = u32(cfg.video.fps),
		bitrate            = u32(cfg.stream.bitrate),
		audio_sample_rate  = 48000,
		audio_channels     = 2,
		audio_bitrate      = 16000,
		frame_duration     = i64(10_000_000) / i64(cfg.video.fps),
		log_sink           = log_sink,
	}
	enc, encoder_ok := encode.encoder_acquire(encoder_cfg)
	if !encoder_ok {
		log.error("encoder_acquire failed; continuing without encoder thread")
	}
	defer if encoder_ok do encode.encoder_release()

	// Mixer state — allocated once, freed at exit.
	CHANNELS :: 2
	mix_buf := make([]f32, audio.BLOCK_SAMPLES * CHANNELS)
	defer delete(mix_buf)
	blocks_emitted: u64
	mixer_started := false

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

	output: Output_State

	video_frame_count: u64
	using_audio_clock := false // tracks which PTS mode is active, for logging transitions

	frame_bytes := make([]u8, int(preview_target.width) * int(preview_target.height) * 4)

	// Main loop
	for !done {
		// Poll and handle messages (inputs, window resize, etc.)
        if platform.pump_messages(&win) {
            break
        }

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
		reconcile(&applied, &cfg, win.device, &preview_target, output.recording)

		// Check each frame for resize after each reconcile call
		needed := int(preview_target.width) * int(preview_target.height) * 4
		if len(frame_bytes) != needed {
			delete(frame_bytes)
			frame_bytes = make([]u8, needed)
		}

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

		// Service a pending recording request. Deliberately after reconcile,
		// same as the requests above: a canvas resize landing between the
		// output starting and the first pushed frame would hand the encoder
		// a resolution that doesn't match what it was configured with.
		if req := ui_state.controls.request; req != .None {
			// blocks_emitted/video_frame_count/using_audio_clock feed the one
			// PTS timeline shared by every consumer of enc (RTMP, MP4 sink,
			// ...) -- they must track the encoder's lifetime, never a single
			// output's. This used to reset them here on a recording start so
			// that output's first sample would land at PTS 0, but that
			// rebased every other active consumer's timestamps out from under
			// it too (see the mp4 sink recon report). Per-output "first
			// sample at 0" is now handled downstream, per consumer, by
			// rebasing at the sink (see mp4_sink.odin's feeder thread).
			handle_controls_request(req, &ui_state.controls, &output,
				&paths, &preview_target, cfg.video.fps, cfg.stream, log_sink, enc)
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
		inputs := make([dynamic]audio.Mix_Input, context.temp_allocator)
		if sel := scene.find(&doc, ui_state.scenes.selected_id); sel != nil {
			for &src in sel.sources {
				if !src.visible do continue
				switch &d in src.data {
					case scene.Audio_Data:
						if d.stream == nil && d.device_id != "" && time.now()._nsec >= d.next_retry._nsec {
							if s := audio.acquire_stream(d.device_id, d.is_loopback); s != nil {
								d.stream = s
								if s.sample_rate != 48000 {
									log.warnf("audio stream %v reports %v Hz, expected 48000 — recording may be pitch-shifted", d.device_id, s.sample_rate)
								}
							} else {
								d.next_retry = time.time_add(time.now(),2 * time.Second)
							}
						}
						if d.stream != nil {
							append(&inputs, audio.Mix_Input{
								stream = d.stream,
								volume = d.volume,
								muted  = d.muted,
							})
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
							ok, lost, got_frame := capture.acquire_frame(win.device_context, d.dupl, d.texture)
							if lost {
								log.warn("duplication access lost, will restart")
								capture.stop_duplication(d.dupl)
								d.dupl = nil
								d.next_retry = time.time_add(time.now(), 500 * time.Millisecond)
							}
							_ = ok

							// Stall tracking: detect when the desktop stops
							// producing new frames (e.g. display sleep) and log
							// the transition. A static desktop is normal — the
							// app correctly re-encodes the last frame — but the
							// log should say so, since a frozen recording is
							// otherwise indistinguishable from a bug.
							STALL_THRESHOLD :: 5 * time.Second
							now := time.now()
							if got_frame {
								if d.stalled {
									elapsed := time.diff(d.last_frame_time, now)
									log.infof("display capture resumed after %v with no new desktop frames (adapter %v output %v)",
										elapsed, d.adapter_index, d.output_index)
								}
								d.last_frame_time = now
								d.stalled = false
							} else if d.last_frame_time._nsec != 0 && !d.stalled {
								if time.diff(d.last_frame_time, now) > STALL_THRESHOLD {
									log.infof("display capture: no new desktop frames for >5s — desktop is likely static or display is asleep (adapter %v output %v); encoding last frame",
										d.adapter_index, d.output_index)
									d.stalled = true
								}
							}
						}

						append(&quads, render.Quad{
							x = src.x, y = src.y, w = src.w, h = src.h,
							color = {1, 1, 1, 1},
							texture = d.srv,
						})
				}
			}
		}
		render.draw_scene(win.device_context, &preview_target, &pipeline, quads[:], scene_clear)

		// -- Audio mixer --------------------------------------------------
		// Reset the startup gate when all audio sources disappear so that a
		// newly added source after a gap starts buffered.
		if len(inputs) == 0 {
			mixer_started = false
		}

		if !mixer_started && audio.mixer_ready(inputs[:], CHANNELS) {
			mixer_started = true
			log.debug("mixer_started -> true")
		}

		if mixer_started {
			for audio.mix_block(inputs[:], mix_buf, CHANNELS) {
				pts_100ns := i64(blocks_emitted) * audio.BLOCK_SAMPLES * 10_000_000 / 48000
				pcm_buf := f32_to_pcm16(mix_buf)

				if encoder_ok {
					if encode.audio_queue_put(enc.pcm_queue, pcm_buf, pts_100ns) {
						win32.SetEvent(enc.audio_event)
					}
				}

				blocks_emitted += 1
			}
		}

		// -- Video push ---------------------------------------------------
		// Shared on recording || streaming: both consumers need the same GPU
		// readback and PTS clock.
		if output.recording || output.streaming {
			// flip_vertical: MFVideoFormat_RGB32 is bottom-up by convention and
			// MF ignores the MF_MT_DEFAULT_STRIDE hint that's supposed to
			// override that, so the rows are flipped here instead. This is a
			// workaround for that one encoder, not the default -- every other
			// read_target caller wants top-down rows. The RTMP path was already
			// fed these flipped rows whenever recording+streaming were both
			// active, so extending this block to run for streaming-only
			// doesn't change that.
			video_pts: i64
			// mixer_started gates this, not just len(inputs) > 0: audio sources
			// can exist but still be warming up (ring buffers below
			// audio.mixer_ready's threshold), during which blocks_emitted never
			// advances. Previously that warm-up window fell into the "audio
			// clock" branch anyway and produced video_pts == 0 for every frame
			// until mixer_started flipped true -- FLV/RTMP require strictly
			// increasing timestamps per stream, so ffmpeg silently dropped
			// every repeated pts=0 frame, producing no output for the whole
			// warm-up window (up to ~53s observed, bounded by the slowest
			// input's ring fill time). Falling back to the frame counter during
			// warm-up keeps video_pts valid and monotonic from frame one.
			want_audio_clock := len(inputs) > 0 && mixer_started
			if want_audio_clock {
				video_pts = i64(blocks_emitted) * audio.BLOCK_SAMPLES * 10_000_000 / 48000
			} else {
				video_pts = i64(video_frame_count) * (i64(10_000_000) / i64(cfg.video.fps))
			}
			if want_audio_clock != using_audio_clock {
				if want_audio_clock {
					log.info("video PTS: switching to audio-master clock")
				} else {
					log.info("video PTS: switching to frame-counter fallback (no audio sources, or audio sources still warming up)")
				}
				using_audio_clock = want_audio_clock
			}
			read_ok := render.read_target(win.device_context, &preview_target, frame_bytes, flip_vertical = true)

			if !read_ok {
				log.warnf("read_target failed (recording=%v streaming=%v); frame_bytes left stale from the last successful read", output.recording, output.streaming)
			}

			if read_ok {
				if encoder_ok {
					encode.mailbox_put(enc.raw_mailbox, frame_bytes, preview_target.width, preview_target.height, video_pts)
					win32.SetEvent(enc.video_event)
				}
				video_frame_count += 1
			}
		}
		@static dumped := false
		if !dumped {
			buf := make([]u8, int(preview_target.width) * int(preview_target.height) * 4)
			defer delete(buf)
			if render.read_target(win.device_context, &preview_target, buf) {
				log.infof("readback: first pixel BGRA = %v %v %v %v", buf[0], buf[1], buf[2], buf[3])
			}
			dumped = true
		}

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

        // ui can't query the encoder directly -- its state is a private
        // package singleton, and a UI panel reaching into a subsystem would
        // be backwards -- so main writes down its own recording state here,
        // every frame, for the Controls panel to read.
        ui_state.controls.recording = output.recording
        ui_state.controls.streaming = output.streaming

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

	delete(frame_bytes)

	// Finalize any still-active recording/stream before persisting. Previously
	// there was no such call here, so closing the window mid-recording left
	// the MP4's sink writer never finalized -- this closes that gap.
	if output.recording {
		log.info("finalizing recording on exit")
		mp4.mp4_sink_stop(output.mp4_sink)
		output.mp4_sink = nil
	}
	if output.streaming {
		log.info("closing stream on exit")
		rtmp.rtmp_stream_close(output.rtmp_stream)
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

// Dispatches a Controls panel request raised by ui. Same one-shot contract as
// handle_profile_request: the request is always cleared, whether or not the
// action actually went through. Starting while already recording, or
// stopping while not, is a no-op rather than a double call into encode.
@(private = "file")
handle_controls_request :: proc(
	req:         ui.Controls_Request,
	state:       ^ui.Controls_State,
	output:		 ^Output_State,
	paths:       ^config.Paths,
	target:      ^render.Target,
	fps:         i32,
	stream_cfg:  settings.Stream_Settings,
	log_sink:    ^applog.Sink,
	enc:         ^encode.Encoder,
) {
	state.request = .None

	#partial switch req {
	case .Start_Recording:
		if output.recording do return
		if paths.videos == "" {
			log.warn("recording requested, but no videos directory is available")
			return
		}
		if enc == nil {
			log.warn("recording requested, but no encoder is available")
			return
		}

		year, month, day := time.date(time.now())
		hour, min, sec := time.clock(time.now())
		filename := fmt.aprintf("recording_%4d-%02d-%02d_%02d-%02d-%02d.mp4",
			year, int(month), day, hour, min, sec)
		defer delete(filename)

		out_path, jerr := filepath.join({paths.videos, filename})
		if jerr != nil {
			log.warnf("could not build recording output path: %v", jerr)
			return
		}
		// mp4_sink_start (via mf.begin_mp4_sink -> MFCreateFile) converts this
		// to a wide string synchronously and doesn't retain the Odin string,
		// so it's safe to free right after the call returns.
		defer delete(out_path)

		sink, ok := mp4.mp4_sink_start(enc, out_path)
		if ok {
			output.mp4_sink = sink
			output.recording = true
			log.infof("recording started (video+audio) -> %v", out_path)
		} else {
			log.warn("failed to start recording (cause logged above)")
		}

	case .Stop_Recording:
		if !output.recording do return
		mp4.mp4_sink_stop(output.mp4_sink)
		output.mp4_sink = nil
		output.recording = false
		log.info("recording stopped")

	case .Start_Streaming:
		if output.streaming do return
		if stream_cfg.host == "" || stream_cfg.stream_key == "" {
			log.warn("streaming requested, but no stream destination is configured")
			return
		}

		if enc == nil {
			log.warn("streaming requested, but no encoder is available")
			return
		}

		STREAM_AUDIO_CHANNELS :: 2

		// stream_index 0: a single stream is all this build supports today.
		// A real id generator/registry belongs with fan-out, not here.
		stream, ok := rtmp.rtmp_stream_start(
			enc, stream_cfg.app, stream_cfg.host, int(stream_cfg.port), stream_cfg.tc_url,
			stream_cfg.stream_key, STREAM_AUDIO_CHANNELS,
			log_sink, 0)
		if ok {
			output.rtmp_stream = stream
			output.streaming = true
			log.infof("streaming started -> %v:%v/%v", stream_cfg.host, stream_cfg.port, stream_cfg.app)
		} else {
			log.warn("failed to start streaming (cause logged above)")
		}

	case .Stop_Streaming:
		if !output.streaming do return
		rtmp.rtmp_stream_close(output.rtmp_stream)
		output.rtmp_stream = nil
		output.streaming = false
		log.info("streaming stopped")
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

// Convert interleaved f32 samples (range [-1,1]) to interleaved 16-bit PCM
// packed as a byte slice. Uses the temp allocator — freed at end of frame.
@(private = "file")
f32_to_pcm16 :: proc(src: []f32) -> []u8 {
	out := make([]u8, len(src) * 2, context.temp_allocator)
	for s, i in src {
		clamped := clamp(s, -1, 1)
		sample := i16(clamped * 32767)
		out[i * 2 + 0] = u8(sample & 0xFF)
		out[i * 2 + 1] = u8((sample >> 8) & 0xFF)
	}
	return out
}
