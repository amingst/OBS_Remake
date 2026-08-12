package platform

import "base:runtime"
import "core:fmt"
import win32 "core:sys/windows"
import "vendor:directx/d3d11"
import "vendor:directx/dxgi"

@(private) g_window: ^Window
@(private) g_ctx: runtime.Context
@(private) CLASS_NAME := win32.L("OBSRemakeWindow")
Window :: struct {
    hwnd: win32.HWND,
    device: ^d3d11.IDevice,
    device_context: ^d3d11.IDeviceContext,
    swap_chain: ^dxgi.ISwapChain,
	swap_chain_occluded: bool,
    render_target_view: ^d3d11.IRenderTargetView,
    resize_width: u32,
    resize_height: u32,
    should_close: bool,
	msg_hook: proc "cdecl" (win32.HWND, win32.UINT, win32.WPARAM, win32.LPARAM) -> win32.LRESULT,
}

create_window :: proc(win: ^Window, title: string, w, h: i32) -> bool {
	g_window = win
	g_ctx = context
	// TODO(log): capture `context` into a package global here -- wnd_proc has no logger without it.
	wc := win32.WNDCLASSEXW{
		cbSize        = size_of(win32.WNDCLASSEXW),
		style         = win32.CS_HREDRAW | win32.CS_VREDRAW | win32.CS_OWNDC,
		lpfnWndProc   = wnd_proc,
		hInstance     = win32.HINSTANCE(win32.GetModuleHandleW(nil)),
		hCursor       = win32.LoadCursorW(nil, nil),
		lpszClassName = win32.L("MyWindowClass"),
	}
	// TODO(log): .Error if RegisterClassExW returns 0 -- ATOM result is discarded; include GetLastError().
	win32.RegisterClassExW(&wc)

	win.hwnd = win32.CreateWindowW(
		wc.lpszClassName,
		win32.utf8_to_wstring(title),
		win32.WS_OVERLAPPEDWINDOW,
		win32.CW_USEDEFAULT, win32.CW_USEDEFAULT,
		w, h,
		nil, nil, wc.hInstance, nil,
	)
	// TODO(log): .Fatal if win.hwnd == nil -- CreateWindowW failure is never checked; GetLastError() has the reason.
	
	if (!create_device_d3d(win)) {
		// TODO(log): .Fatal D3D init failed, aborting window creation (cause already logged below).
		destroy_window(win)
		return false
	}
	// TODO(log): .Info window created: hwnd, requested w/h, DPI scale.
	return true
}

destroy_window :: proc(win: ^Window) {
    if win == nil { return }
    // TODO(log): .Debug window teardown started.
    cleanup_device_d3d(win)
    if win.hwnd != nil { win32.DestroyWindow(win.hwnd) }
	win32.UnregisterClassW(cstring16(CLASS_NAME), win32.HINSTANCE(win32.GetModuleHandleW(nil)))
    g_window = nil
}

pump_messages :: proc(win: ^Window) -> (should_quit: bool) {
    msg: win32.MSG
    for win32.PeekMessageW(&msg, nil, 0, 0, win32.PM_REMOVE) {
        win32.TranslateMessage(&msg)
        win32.DispatchMessageW(&msg)
        if msg.message == win32.WM_QUIT {
            // TODO(log): .Debug WM_QUIT received, main loop will exit.
            should_quit = true
        }
    }
    return
}

begin_frame :: proc(win: ^Window, clear: [4]f32) {

}

present :: proc(win: ^Window) {

}

// Helper functions
create_device_d3d :: proc(win: ^Window) -> bool {
	sd := dxgi.SWAP_CHAIN_DESC{
		BufferCount = 2,
		BufferDesc = {
			Width  = 0,
			Height = 0,
			Format = .R8G8B8A8_UNORM,
			RefreshRate = {Numerator = 60, Denominator = 1},
		},
		Flags       = {.ALLOW_MODE_SWITCH},
		BufferUsage = {.RENDER_TARGET_OUTPUT},
		OutputWindow = dxgi.HWND(win.hwnd),
		SampleDesc  = {Count = 1, Quality = 0},
		Windowed    = true,
		SwapEffect  = .DISCARD,
	}

	create_device_flags: d3d11.CREATE_DEVICE_FLAGS
	when ODIN_DEBUG do create_device_flags += {.DEBUG}
	feature_level: d3d11.FEATURE_LEVEL
	feature_level_array := [2]d3d11.FEATURE_LEVEL{._11_0, ._10_0}

	res := d3d11.CreateDeviceAndSwapChain(
		nil, .HARDWARE, nil, create_device_flags,
		&feature_level_array[0], 2, d3d11.SDK_VERSION,
		&sd, &win.swap_chain, &win.device, &feature_level, &win.device_context)
	if res == dxgi.ERROR_UNSUPPORTED { // Try WARP software driver if hardware is not available.
		// TODO(log): .Warning no hardware D3D11 device, falling back to WARP (software) -- top signal for slow capture on other machines.
		res = d3d11.CreateDeviceAndSwapChain(
			nil, .WARP, nil, create_device_flags,
			&feature_level_array[0], 2, d3d11.SDK_VERSION,
			&sd, &win.swap_chain, &win.device, &feature_level, &win.device_context)
	}
	when ODIN_DEBUG {
		if res != 0 && .DEBUG in create_device_flags {
			// TODO(log): .Warning replace this eprintln -- debug layer unavailable, retrying without it.
			fmt.eprintln("D3D11 debug layer unavailable (install the Windows 'Graphics Tools' optional feature); retrying without it")
			create_device_flags -= {.DEBUG}
			res = d3d11.CreateDeviceAndSwapChain(
				nil, .HARDWARE, nil, create_device_flags,
				&feature_level_array[0], 2, d3d11.SDK_VERSION,
				&sd, &win.swap_chain, &win.device, &feature_level, &win.device_context)
			if res == dxgi.ERROR_UNSUPPORTED {
				res = d3d11.CreateDeviceAndSwapChain(
					nil, .WARP, nil, create_device_flags,
					&feature_level_array[0], 2, d3d11.SDK_VERSION,
					&sd, &win.swap_chain, &win.device, &feature_level, &win.device_context)
			}
		}
	}
	if res != 0 {
		// TODO(log): .Fatal replace this eprintfln -- record HRESULT and which driver path (HARDWARE/WARP) was last tried.
		fmt.eprintfln("D3D11 device/swap chain creation failed: HRESULT 0x%08X", u32(res))
		return false
	}

	pSwapChainFactory: ^dxgi.IFactory
	if id := win.swap_chain->GetParent(dxgi.IFactory_UUID, (^rawptr)(&pSwapChainFactory)); id >= 0 {
		pSwapChainFactory->MakeWindowAssociation(dxgi.HWND(win.hwnd), {.NO_ALT_ENTER})
		pSwapChainFactory->Release()
	}
	// TODO(log): .Warning when GetParent fails (no else branch) -- Alt+Enter stays enabled, misbehaves with multi-viewport.

	create_render_target(win)
	// TODO(log): .Info device created: feature_level, driver path, swapchain format/buffer count.
	return true
}

cleanup_device_d3d :: proc(win: ^Window) {
	// TODO(log): .Debug releasing swapchain/context/device.
	cleanup_render_target(win)
	if win.swap_chain != nil {
		win.swap_chain->Release()
		win.swap_chain = nil
	}
	if win.device_context != nil {
		win.device_context->Release()
		win.device_context = nil
	}
	if win.device != nil {
		win.device->Release()
		win.device = nil
	}
}

// TODO(log): SIGNATURE -- returns nothing, so resize-path failures below can't reach the caller; needs -> bool to be actionable.
create_render_target :: proc(win: ^Window) {
	pBackBuffer: ^d3d11.ITexture2D
	// TODO(log): .Error GetBuffer HRESULT discarded -- on failure pBackBuffer stays nil and the next two calls deref it.
	win.swap_chain->GetBuffer(0, d3d11.ITexture2D_UUID, (^rawptr)(&pBackBuffer))
	// TODO(log): .Error CreateRenderTargetView HRESULT discarded -- failure leaves render_target_view nil, window renders blank.
	win.device->CreateRenderTargetView(
		(^d3d11.IResource)(pBackBuffer), nil, &win.render_target_view)
	pBackBuffer->Release()
}

cleanup_render_target :: proc(win: ^Window) {
	// TODO(log): .Debug RATE-LIMITED -- runs on every resize step; log once per resize sequence, not per WM_SIZE.
	if win.render_target_view != nil {
		win.render_target_view->Release()
		win.render_target_view = nil
	}
}

wnd_proc :: proc "system" (
	hwnd: win32.HWND,
	msg: win32.UINT,
	wparam: win32.WPARAM,
	lparam: win32.LPARAM,
) -> win32.LRESULT {
	context = g_ctx
	// TODO(log): BLOCKER -- default_context() has no logger; assign the context captured in create_window instead.
	context = runtime.default_context()
	if g_window != nil && g_window.msg_hook != nil {
		if result := g_window.msg_hook(hwnd, msg, wparam, lparam); result != 0 {
			return result
		}
	}

	switch msg {
	case win32.WM_SIZE:
		if wparam == win32.SIZE_MINIMIZED {
			// TODO(log): .Debug window minimized -- state transition, fires once per minimize.
			return 0
		}
		// TODO(log): .Debug RATE-LIMITED -- WM_SIZE fires continuously while dragging; log the settled size on WM_EXITSIZEMOVE instead.
		g_window.resize_width = u32(win32.LOWORD(u32(lparam))) // Queue resize
		g_window.resize_height = u32(win32.HIWORD(u32(lparam)))
		return 0
	case win32.WM_SYSCOMMAND:
		if (wparam & 0xfff0) == win32.SC_KEYMENU { // Disable ALT application menu
			return 0
		}
	case win32.WM_DESTROY:
		// TODO(log): .Debug WM_DESTROY, posting quit.
		win32.PostQuitMessage(0)
		return 0
	}
	return win32.DefWindowProcW(hwnd, msg, wparam, lparam)
}