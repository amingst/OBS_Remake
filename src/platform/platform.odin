package platform

import "base:runtime"
import "core:log"
import win32 "core:sys/windows"
import "vendor:directx/d3d11"
import "vendor:directx/dxgi"

@(private) g_window: ^Window
@(private) g_ctx: runtime.Context
@(private) CLASS_NAME := win32.L("StreamSmithWindow")
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
	g_ctx = context // captured so wnd_proc inherits the caller's logger
	hinstance := win32.HINSTANCE(win32.GetModuleHandleW(nil))
	// Icon resource 1 is embedded by assets/icons/streamsmith.rc (see build.bat -resource).
	icon := win32.LoadIconW(hinstance, cstring16(win32.MAKEINTRESOURCEW(1)))
	wc := win32.WNDCLASSEXW{
		cbSize        = size_of(win32.WNDCLASSEXW),
		style         = win32.CS_HREDRAW | win32.CS_VREDRAW | win32.CS_OWNDC,
		lpfnWndProc   = wnd_proc,
		hInstance     = hinstance,
		hIcon         = icon,
		hIconSm       = icon,
		hCursor       = win32.LoadCursorW(nil, nil),
		lpszClassName = win32.L("MyWindowClass"),
	}
	if win32.RegisterClassExW(&wc) == 0 {
		log.errorf("RegisterClassExW failed: GetLastError() = %v", win32.GetLastError())
	}

	win.hwnd = win32.CreateWindowW(
		wc.lpszClassName,
		win32.utf8_to_wstring(title),
		win32.WS_OVERLAPPEDWINDOW,
		win32.CW_USEDEFAULT, win32.CW_USEDEFAULT,
		w, h,
		nil, nil, wc.hInstance, nil,
	)
	if win.hwnd == nil {
		log.fatalf("CreateWindowW failed: GetLastError() = %v", win32.GetLastError())
		return false
	}

	if (!create_device_d3d(win)) {
		log.fatal("D3D init failed, aborting window creation")
		destroy_window(win)
		return false
	}
	log.infof("window created: hwnd=%v, size=%vx%v", win.hwnd, w, h)
	return true
}

destroy_window :: proc(win: ^Window) {
    if win == nil { return }
    log.debug("window teardown started")
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
            log.debug("WM_QUIT received, main loop will exit")
            should_quit = true
        }
    }
    return
}

// ID3D11Multithread — not in vendor bindings; hand-written from d3d11_4.h
ID3D11Multithread_VTable :: struct {
	// IUnknown
	QueryInterface:          proc "stdcall" (this: ^ID3D11Multithread, riid: ^win32.GUID, ppv: ^rawptr) -> win32.HRESULT,
	AddRef:                  proc "stdcall" (this: ^ID3D11Multithread) -> u32,
	Release:                 proc "stdcall" (this: ^ID3D11Multithread) -> u32,
	// ID3D11Multithread
	Enter:                   proc "stdcall" (this: ^ID3D11Multithread),
	Leave:                   proc "stdcall" (this: ^ID3D11Multithread),
	SetMultithreadProtected: proc "stdcall" (this: ^ID3D11Multithread, bMTProtect: win32.BOOL) -> win32.BOOL,
	GetMultithreadProtected: proc "stdcall" (this: ^ID3D11Multithread) -> win32.BOOL,
}
ID3D11Multithread :: struct { using vtbl: ^ID3D11Multithread_VTable }
IID_ID3D11Multithread := win32.GUID{0x9B7E4E00, 0x342C, 0x4106, {0xA1, 0x9F, 0x4F, 0x27, 0x04, 0xF6, 0x89, 0xF0}}

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

	create_device_flags := d3d11.CREATE_DEVICE_FLAGS{.BGRA_SUPPORT, .VIDEO_SUPPORT}
	when ODIN_DEBUG do create_device_flags += {.DEBUG}
	feature_level: d3d11.FEATURE_LEVEL
	feature_level_array := [2]d3d11.FEATURE_LEVEL{._11_0, ._10_0}

	res := d3d11.CreateDeviceAndSwapChain(
		nil, .HARDWARE, nil, create_device_flags,
		&feature_level_array[0], 2, d3d11.SDK_VERSION,
		&sd, &win.swap_chain, &win.device, &feature_level, &win.device_context)
	if res == dxgi.ERROR_UNSUPPORTED { // Try WARP software driver if hardware is not available.
		log.warn("no hardware D3D11 device, falling back to WARP (software)")
		res = d3d11.CreateDeviceAndSwapChain(
			nil, .WARP, nil, create_device_flags,
			&feature_level_array[0], 2, d3d11.SDK_VERSION,
			&sd, &win.swap_chain, &win.device, &feature_level, &win.device_context)
	}
	when ODIN_DEBUG {
		if res != 0 && .DEBUG in create_device_flags {
			log.warn("D3D11 debug layer unavailable (install the Windows 'Graphics Tools' optional feature); retrying without it")
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
		log.fatalf("D3D11 device/swap chain creation failed: HRESULT 0x%08X", u32(res))
		return false
	}

	pSwapChainFactory: ^dxgi.IFactory
	if id := win.swap_chain->GetParent(dxgi.IFactory_UUID, (^rawptr)(&pSwapChainFactory)); id >= 0 {
		pSwapChainFactory->MakeWindowAssociation(dxgi.HWND(win.hwnd), {.NO_ALT_ENTER})
		pSwapChainFactory->Release()
	} else {
		log.warn("GetParent on swap chain failed, Alt+Enter remains enabled")
	}

	// Enable D3D11 multithread protection so the immediate context is safe
	// to use from the WGC frame-arrived callback thread.
	mt: ^ID3D11Multithread
	if hr := win.device_context->QueryInterface(&IID_ID3D11Multithread, (^rawptr)(&mt)); hr >= 0 {
		mt->SetMultithreadProtected(win32.TRUE) // returns previous state, not HRESULT
		log.info("ID3D11Multithread: protection enabled on immediate context")
		mt->Release()
	} else {
		log.warnf("ID3D11Multithread QI failed: HRESULT 0x%08X", u32(hr))
	}

	create_render_target(win)
	log.infof("D3D11 device created: feature_level=%v", feature_level)
	return true
}

cleanup_device_d3d :: proc(win: ^Window) {
	log.debug("releasing swapchain/context/device")
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

create_render_target :: proc(win: ^Window) {
	pBackBuffer: ^d3d11.ITexture2D
	if hr := win.swap_chain->GetBuffer(0, d3d11.ITexture2D_UUID, (^rawptr)(&pBackBuffer)); hr < 0 {
		log.errorf("swap chain GetBuffer failed: HRESULT 0x%08X", u32(hr))
		return
	}
	if hr := win.device->CreateRenderTargetView(
		(^d3d11.IResource)(pBackBuffer), nil, &win.render_target_view); hr < 0 {
		log.errorf("CreateRenderTargetView failed: HRESULT 0x%08X", u32(hr))
	}
	pBackBuffer->Release()
}

cleanup_render_target :: proc(win: ^Window) {
	if win.render_target_view != nil {
		log.debug("releasing render target view")
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
	if g_window != nil && g_window.msg_hook != nil {
		if result := g_window.msg_hook(hwnd, msg, wparam, lparam); result != 0 {
			return result
		}
	}

	switch msg {
	case win32.WM_SIZE:
		if wparam == win32.SIZE_MINIMIZED {
			log.debug("window minimized")
			return 0
		}
		g_window.resize_width = u32(win32.LOWORD(u32(lparam))) // Queue resize
		g_window.resize_height = u32(win32.HIWORD(u32(lparam)))
		return 0
	case win32.WM_EXITSIZEMOVE:
		if g_window.resize_width != 0 && g_window.resize_height != 0 {
			log.debugf("resize settled: %vx%v", g_window.resize_width, g_window.resize_height)
		}
		return 0
	case win32.WM_SYSCOMMAND:
		if (wparam & 0xfff0) == win32.SC_KEYMENU { // Disable ALT application menu
			return 0
		}
	case win32.WM_DESTROY:
		log.debug("WM_DESTROY, posting quit")
		win32.PostQuitMessage(0)
		return 0
	}
	return win32.DefWindowProcW(hwnd, msg, wparam, lparam)
}