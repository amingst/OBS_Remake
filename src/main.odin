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

// Import from platform module
import "platform"
import "render"
import "scene"
import "ui"
import "capture"

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
	// create_window because it needs win.device.
	preview_target, target_ok := render.create_target(win.device, 1920, 1080)
	if !target_ok {
		log.fatal("preview target creation failed, exiting (cause logged above)")
		return
	}
	defer render.destroy_target(&preview_target)

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

	// Our state
	doc := scene.init()
	defer scene.destroy_all(&doc)

    ui_state := ui.init_state(&doc)
	clear_color := im.Vec4{0.45, 0.55, 0.60, 1.00}
    defer ui.destroy(&ui_state)

    done := false
	was_occluded := false
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
		render.draw_scene(win.device_context, &preview_target, &pipeline, quads[:], scene_clear)

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
        ui.draw(&ui_state, &doc, &clear_color, preview_tex, outputs,
            f32(preview_target.width), f32(preview_target.height))

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
}

