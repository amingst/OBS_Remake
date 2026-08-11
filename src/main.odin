package obs_remake

import win32 "core:sys/windows"
import "vendor:directx/dxgi"
import im      "libs:odin-imgui"
import imwin32 "libs:odin-imgui/backends/win32"
import imdx11  "libs:odin-imgui/backends/dx11"

// Import from platform module
import "platform"


main :: proc() {
	// Make process DPI aware and obtain main monitor scale
	imwin32.EnableDpiAwareness()
	main_scale := imwin32.GetDpiScaleForMonitor(
		win32.MonitorFromPoint(win32.POINT{0, 0}, .MONITOR_DEFAULTTOPRIMARY))

    win: platform.Window
    if (!platform.create_window(&win, "OBS Remake", 1280, 800)) {
        return
    }
    defer platform.destroy_window(&win)
    win.msg_hook = imwin32.WndProcHandler

	// Show the window
	win32.ShowWindow(win.hwnd, win32.SW_SHOWDEFAULT)
	win32.UpdateWindow(win.hwnd)

	// Setup Dear ImGui context
	im.CHECKVERSION()
	im.CreateContext()
	defer im.DestroyContext()

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
	imwin32.Init(win.hwnd)
	defer imwin32.Shutdown()
	imdx11.Init(win.device, win.device_context)
	defer imdx11.Shutdown()

	// Load Fonts
	// - If fonts are not explicitly loaded, Dear ImGui will select an embedded
	//   font: either AddFontDefaultVector() or AddFontDefaultBitmap().
	// - You can load multiple fonts and use im.PushFont()/PopFont() to select them.
	// - Read 'docs/FONTS.md' for more instructions and details.
	//style.FontSizeBase = 20.0
	//io.Fonts->AddFontDefaultVector()
	//io.Fonts->AddFontFromFileTTF("c:\\Windows\\Fonts\\segoeui.ttf")

	// Our state
	show_demo_window := true
	show_another_window := false
	clear_color := im.Vec4{0.45, 0.55, 0.60, 1.00}

    done := false
	// Main loop
	for !done {
		// Poll and handle messages (inputs, window resize, etc.)
        if platform.pump_messages(&win) {
            break
        }

		// Handle window being minimized or screen locked
		if win.swap_chain_occluded && win.swap_chain->Present(0, {.TEST}) == dxgi.STATUS_OCCLUDED {
			win32.Sleep(10)
			continue
		}
		win.swap_chain_occluded = false

		// Handle window resize (we don't resize directly in the WM_SIZE handler)
		if win.resize_width != 0 && win.resize_height != 0 {
			platform.cleanup_render_target(&win)
			win.swap_chain->ResizeBuffers(0, win.resize_width, win.resize_height, .UNKNOWN, {})
			win.resize_width, win.resize_height = 0, 0
			platform.create_render_target(&win)
		}

		// Start the Dear ImGui frame
		imdx11.NewFrame()
		imwin32.NewFrame()
		im.NewFrame()

		// 1. Show the big demo window
		if show_demo_window {
			im.ShowDemoWindow(&show_demo_window)
		}

		// 2. Show a simple window that we create ourselves.
		{
			@static f: f32
			@static counter: i32

			im.Begin("Hello, world!")

			im.Text("This is some useful text.")
			im.Checkbox("Demo Window", &show_demo_window)
			im.Checkbox("Another Window", &show_another_window)

			im.SliderFloat("float", &f, 0.0, 1.0)
			im.ColorEdit3("clear color", cast(^[3]f32)&clear_color)

			if im.Button("Button") {
				counter += 1
			}
			im.SameLine()
			im.Text("counter = %d", counter)

			im.Text("Application average %.3f ms/frame (%.1f FPS)",
				1000.0 / io.Framerate, io.Framerate)
			im.End()
		}

		// 3. Show another simple window.
		if show_another_window {
			im.Begin("Another Window", &show_another_window)
			im.Text("Hello from another window!")
			if im.Button("Close Me") {
				show_another_window = false
			}
			im.End()
		}

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
		win.swap_chain_occluded = (hr == dxgi.STATUS_OCCLUDED)
	}
}

