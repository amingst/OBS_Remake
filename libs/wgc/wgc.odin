package wgc

import "core:log"
import win32 "core:sys/windows"

// ---------------------------------------------------------------------------
// WinRT bootstrap — RuntimeObject.lib provides RoInitialize, activation, and
// HSTRING management.  D3D11.lib provides the DXGI → WinRT device bridge.
// Apartment setup (RoInitialize / RoUninitialize) stays in main.odin.
// ---------------------------------------------------------------------------
HSTRING :: rawptr

foreign import winrt_lib "system:RuntimeObject.lib"
@(default_calling_convention = "stdcall")
foreign winrt_lib {
	RoInitialize           :: proc(initType: u32) -> win32.HRESULT ---
	RoUninitialize         :: proc() ---
	RoGetActivationFactory :: proc(
		activatableClassId: HSTRING,
		iid:               ^win32.GUID,
		factory:           ^rawptr,
	) -> win32.HRESULT ---
	WindowsCreateString :: proc(
		sourceString: [^]u16,
		length:       u32,
		string_out:   ^HSTRING,
	) -> win32.HRESULT ---
	WindowsDeleteString :: proc(string_: HSTRING) -> win32.HRESULT ---
}

foreign import d3d11_lib "system:D3D11.lib"
@(default_calling_convention = "stdcall")
foreign d3d11_lib {
	CreateDirect3D11DeviceFromDXGIDevice :: proc(
		dxgiDevice:     rawptr,  // IDXGIDevice*
		graphicsDevice: ^rawptr, // IInspectable** (WinRT IDirect3DDevice)
	) -> win32.HRESULT ---
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
RO_INIT_SINGLETHREADED :: u32(0)
RPC_E_CHANGED_MODE     :: win32.HRESULT(-2147417850)  // 0x80010106
E_NOINTERFACE          :: win32.HRESULT(-0x7FFFBFFE)  // 0x80004002
E_FAIL                 :: win32.HRESULT(-0x7FFFFFFB)  // 0x80004005
E_POINTER              :: win32.HRESULT(-0x7FFFFFFD)  // 0x80004003
RO_E_CLOSED            :: win32.HRESULT(-0x7FFFFFED)  // 0x80000013 — the WinRT object (e.g. a closed GraphicsCaptureItem) has been closed

// DirectXPixelFormat.B8G8R8A8UIntNormalized — the only value we use.
DXPF_B8G8R8A8_UINT_NORMALIZED :: i32(87)

// ---------------------------------------------------------------------------
// Process-lifetime HSTRINGs for the two WinRT class names passed to
// RoGetActivationFactory.  Created once in wgc_init, released in wgc_shutdown.
// Mirrors the factory pattern in libs/wic/.
// ---------------------------------------------------------------------------
hs_capture_item: HSTRING   // "Windows.Graphics.Capture.GraphicsCaptureItem"
hs_frame_pool:   HSTRING   // "Windows.Graphics.Capture.Direct3D11CaptureFramePool"

wgc_init :: proc() -> bool {
	CLASS_CAPTURE_ITEM :: "Windows.Graphics.Capture.GraphicsCaptureItem"
	CLASS_FRAME_POOL   :: "Windows.Graphics.Capture.Direct3D11CaptureFramePool"

	// len() gives byte length, but WindowsCreateString wants UTF-16 code units.
	// Both class names are pure ASCII so the counts coincide.
	// utf8_to_wstring writes into context.temp_allocator; WindowsCreateString
	// copies the data, so the temp pointer is not kept past this call.
	wide := win32.utf8_to_wstring(CLASS_CAPTURE_ITEM)
	hr := WindowsCreateString(([^]u16)(wide), u32(len(CLASS_CAPTURE_ITEM)), &hs_capture_item)
	if hr < 0 {
		log.errorf("WindowsCreateString(%v) failed: 0x%08X", CLASS_CAPTURE_ITEM, u32(hr))
		return false
	}

	wide = win32.utf8_to_wstring(CLASS_FRAME_POOL)
	hr = WindowsCreateString(([^]u16)(wide), u32(len(CLASS_FRAME_POOL)), &hs_frame_pool)
	if hr < 0 {
		log.errorf("WindowsCreateString(%v) failed: 0x%08X", CLASS_FRAME_POOL, u32(hr))
		WindowsDeleteString(hs_capture_item)
		hs_capture_item = nil
		return false
	}

	return true
}

wgc_shutdown :: proc() {
	if hs_frame_pool != nil {
		WindowsDeleteString(hs_frame_pool)
		hs_frame_pool = nil
	}
	if hs_capture_item != nil {
		WindowsDeleteString(hs_capture_item)
		hs_capture_item = nil
	}
}
