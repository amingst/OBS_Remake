package wgc

import win32 "core:sys/windows"

// ---------------------------------------------------------------------------
// Struct types
// ---------------------------------------------------------------------------
SizeInt32 :: struct {
	Width:  i32,
	Height: i32,
}

EventRegistrationToken :: struct {
	Value: i64,
}

// ---------------------------------------------------------------------------
// IIDs — all verified against SDK 10.0.26100.0 headers.
// GUIDs use := (not ::) so their address can be taken for COM calls.
// ---------------------------------------------------------------------------

// windows.graphics.capture.interop.h
IID_IGraphicsCaptureItemInterop := win32.GUID{0x3628e81b, 0x3cac, 0x4c60, {0xb7, 0xf4, 0x23, 0xce, 0x0e, 0x0c, 0x33, 0x56}}

// windows.graphics.capture.h
IID_IGraphicsCaptureItem                 := win32.GUID{0x79c3f95b, 0x31f7, 0x4ec2, {0xa4, 0x64, 0x63, 0x2e, 0xf5, 0xd3, 0x07, 0x60}}
IID_IDirect3D11CaptureFramePool         := win32.GUID{0x24eb6d22, 0x1975, 0x422e, {0x82, 0xe7, 0x78, 0x0d, 0xbd, 0x8d, 0xdf, 0x24}}
IID_IDirect3D11CaptureFramePoolStatics2 := win32.GUID{0x589b103f, 0x6bbc, 0x5df5, {0xa9, 0x91, 0x02, 0xe2, 0x8b, 0x3b, 0x66, 0xd5}}
IID_IDirect3D11CaptureFrame             := win32.GUID{0xfa50c623, 0x38da, 0x4b32, {0xac, 0xf3, 0xfa, 0x97, 0x34, 0xad, 0x80, 0x0e}}
IID_IGraphicsCaptureSession             := win32.GUID{0x814e42a9, 0xf70f, 0x4ad7, {0x93, 0x9b, 0xfd, 0xdc, 0xc6, 0xeb, 0x88, 0x0d}}
IID_IGraphicsCaptureSession2            := win32.GUID{0x2c39ae40, 0x7d2e, 0x5044, {0x80, 0x4e, 0x8b, 0x67, 0x99, 0xd4, 0xcf, 0x9e}}
IID_IGraphicsCaptureSession3            := win32.GUID{0xf2cdd966, 0x22ae, 0x5ea1, {0x95, 0x96, 0x3a, 0x28, 0x93, 0x44, 0xc3, 0xbe}}

// windows.graphics.directx.direct3d11.h
IID_IDirect3DDevice  := win32.GUID{0xa37624ab, 0x8d5f, 0x4650, {0x9d, 0x3e, 0x9e, 0xae, 0x3d, 0x9b, 0xc6, 0x70}}
IID_IDirect3DSurface := win32.GUID{0x0bf4a146, 0x13c1, 0x4694, {0xbe, 0xe3, 0x7a, 0xbf, 0x15, 0xea, 0xf5, 0x86}}

// windows.graphics.directx.direct3d11.interop.h
IID_IDirect3DDxgiInterfaceAccess := win32.GUID{0xa9b3d012, 0x3df2, 0x4ee3, {0xb8, 0xd1, 0x86, 0x95, 0xf4, 0x57, 0xd3, 0xc1}}

// windows.foundation.h
IID_IClosable := win32.GUID{0x30d5a829, 0x7fa4, 0x4026, {0x83, 0xbb, 0xd7, 0x5b, 0xae, 0x4e, 0xa9, 0x9e}}

// Standard COM
IID_IUnknown     := win32.GUID{0x00000000, 0x0000, 0x0000, {0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}}
IID_IAgileObject := win32.GUID{0x94ea2b94, 0xe9cc, 0x49e0, {0xc0, 0xff, 0xee, 0x64, 0xca, 0x8f, 0x5b, 0x90}}
IID_IInspectable := win32.GUID{0xaf86e2e0, 0xb12d, 0x4c6a, {0x9c, 0x5a, 0xd7, 0xaa, 0x65, 0x10, 0x1e, 0x90}}

// TypedEventHandler<Direct3D11CaptureFramePool, IInspectable>
// Signature: pinterface({9de1c534-6ae1-11e0-84e1-18a905bcc53f};
//   rc(Windows.Graphics.Capture.Direct3D11CaptureFramePool;
//   {24eb6d22-1975-422e-82e7-780dbd8ddf24});cinterface(IInspectable))
// uuid5(11f47ad5-7b73-42c0-abae-878b1e16adee, signature)
IID_TypedEventHandler_FramePool := win32.GUID{0x51a947f7, 0x79cf, 0x5a3e, {0xa3, 0xa5, 0x12, 0x89, 0xcf, 0xa6, 0xdf, 0xe8}}

// ---------------------------------------------------------------------------
// Interface vtables and wrapper structs
// Slot order read from SDK 10.0.26100.0 CINTERFACE typedefs.
// All WinRT interfaces inherit IInspectable: QueryInterface, AddRef, Release,
// GetIids, GetRuntimeClassName, GetTrustLevel (slots 0-5).
// IUnknown-derived interfaces have only the first three.
// Uncalled methods are rawptr placeholders occupying their slot.
// ---------------------------------------------------------------------------

// IUnknown : 3 slots
// Minimal vtable for releasing opaque WinRT pointers (IDirect3DSurface,
// IDirect3DDevice) that have no typed interface of their own here.
IUnknown_VTable :: struct {
	QueryInterface: proc "stdcall" (this: rawptr, riid: ^win32.GUID, ppv: ^rawptr) -> win32.HRESULT,
	AddRef:         proc "stdcall" (this: rawptr) -> u32,
	Release:        proc "stdcall" (this: rawptr) -> u32,
}
IUnknown :: struct { using vtbl: ^IUnknown_VTable }

// IGraphicsCaptureItemInterop : IUnknown (3) + 2 own = 5 slots
// Source: windows.graphics.capture.interop.h
IGraphicsCaptureItemInterop_VTable :: struct {
	QueryInterface:   proc "stdcall" (this: rawptr, riid: ^win32.GUID, ppv: ^rawptr) -> win32.HRESULT,
	AddRef:           proc "stdcall" (this: rawptr) -> u32,
	Release:          proc "stdcall" (this: rawptr) -> u32,
	CreateForWindow:  proc "stdcall" (this: rawptr, window: win32.HWND, riid: ^win32.GUID, result: ^rawptr) -> win32.HRESULT,
	CreateForMonitor: rawptr,
}
IGraphicsCaptureItemInterop :: struct { using vtbl: ^IGraphicsCaptureItemInterop_VTable }

// IGraphicsCaptureItem : IInspectable (6) + 4 own = 10 slots
// Source: windows.graphics.capture.h  __x_ABI_..._CIGraphicsCaptureItemVtbl
IGraphicsCaptureItem_VTable :: struct {
	QueryInterface:      proc "stdcall" (this: rawptr, riid: ^win32.GUID, ppv: ^rawptr) -> win32.HRESULT,
	AddRef:              proc "stdcall" (this: rawptr) -> u32,
	Release:             proc "stdcall" (this: rawptr) -> u32,
	GetIids:             rawptr,
	GetRuntimeClassName: rawptr,
	GetTrustLevel:       rawptr,
	get_DisplayName:     rawptr,
	get_Size:            proc "stdcall" (this: rawptr, value: ^SizeInt32) -> win32.HRESULT,
	add_Closed:          proc "stdcall" (this: rawptr, handler: rawptr, token: ^EventRegistrationToken) -> win32.HRESULT,
	remove_Closed:       proc "stdcall" (this: rawptr, token: EventRegistrationToken) -> win32.HRESULT,
}
IGraphicsCaptureItem :: struct { using vtbl: ^IGraphicsCaptureItem_VTable }

// IDirect3D11CaptureFramePoolStatics2 : IInspectable (6) + 1 own = 7 slots
// Source: windows.graphics.capture.h  __x_ABI_..._CIDirect3D11CaptureFramePoolStatics2Vtbl
IDirect3D11CaptureFramePoolStatics2_VTable :: struct {
	QueryInterface:      proc "stdcall" (this: rawptr, riid: ^win32.GUID, ppv: ^rawptr) -> win32.HRESULT,
	AddRef:              proc "stdcall" (this: rawptr) -> u32,
	Release:             proc "stdcall" (this: rawptr) -> u32,
	GetIids:             rawptr,
	GetRuntimeClassName: rawptr,
	GetTrustLevel:       rawptr,
	CreateFreeThreaded:  proc "stdcall" (
		this:            rawptr,
		device:          rawptr, // IDirect3DDevice*
		pixelFormat:     i32,    // DirectXPixelFormat enum
		numberOfBuffers: i32,
		size:            SizeInt32,
		result:          ^rawptr, // IDirect3D11CaptureFramePool**
	) -> win32.HRESULT,
}
IDirect3D11CaptureFramePoolStatics2 :: struct { using vtbl: ^IDirect3D11CaptureFramePoolStatics2_VTable }

// IDirect3D11CaptureFramePool : IInspectable (6) + 6 own = 12 slots
// Source: windows.graphics.capture.h  __x_ABI_..._CIDirect3D11CaptureFramePoolVtbl
IDirect3D11CaptureFramePool_VTable :: struct {
	QueryInterface:       proc "stdcall" (this: rawptr, riid: ^win32.GUID, ppv: ^rawptr) -> win32.HRESULT,
	AddRef:               proc "stdcall" (this: rawptr) -> u32,
	Release:              proc "stdcall" (this: rawptr) -> u32,
	GetIids:              rawptr,
	GetRuntimeClassName:  rawptr,
	GetTrustLevel:        rawptr,
	Recreate:             proc "stdcall" (
		this:            rawptr,
		device:          rawptr, // IDirect3DDevice*
		pixelFormat:     i32,    // DirectXPixelFormat enum
		numberOfBuffers: i32,
		size:            SizeInt32,
	) -> win32.HRESULT,
	TryGetNextFrame:      proc "stdcall" (this: rawptr, result: ^rawptr) -> win32.HRESULT,
	add_FrameArrived:     proc "stdcall" (this: rawptr, handler: rawptr, token: ^EventRegistrationToken) -> win32.HRESULT,
	remove_FrameArrived:  proc "stdcall" (this: rawptr, token: EventRegistrationToken) -> win32.HRESULT,
	CreateCaptureSession: proc "stdcall" (this: rawptr, item: rawptr, result: ^rawptr) -> win32.HRESULT,
	get_DispatcherQueue:  rawptr,
}
IDirect3D11CaptureFramePool :: struct { using vtbl: ^IDirect3D11CaptureFramePool_VTable }

// IDirect3D11CaptureFrame : IInspectable (6) + 3 own = 9 slots
// Source: windows.graphics.capture.h  __x_ABI_..._CIDirect3D11CaptureFrameVtbl
IDirect3D11CaptureFrame_VTable :: struct {
	QueryInterface:         proc "stdcall" (this: rawptr, riid: ^win32.GUID, ppv: ^rawptr) -> win32.HRESULT,
	AddRef:                 proc "stdcall" (this: rawptr) -> u32,
	Release:                proc "stdcall" (this: rawptr) -> u32,
	GetIids:                rawptr,
	GetRuntimeClassName:    rawptr,
	GetTrustLevel:          rawptr,
	get_Surface:            proc "stdcall" (this: rawptr, value: ^rawptr) -> win32.HRESULT,
	get_SystemRelativeTime: rawptr,
	get_ContentSize:        proc "stdcall" (this: rawptr, value: ^SizeInt32) -> win32.HRESULT,
}
IDirect3D11CaptureFrame :: struct { using vtbl: ^IDirect3D11CaptureFrame_VTable }

// IGraphicsCaptureSession : IInspectable (6) + 1 own = 7 slots
// Source: windows.graphics.capture.h  __x_ABI_..._CIGraphicsCaptureSessionVtbl
IGraphicsCaptureSession_VTable :: struct {
	QueryInterface:      proc "stdcall" (this: rawptr, riid: ^win32.GUID, ppv: ^rawptr) -> win32.HRESULT,
	AddRef:              proc "stdcall" (this: rawptr) -> u32,
	Release:             proc "stdcall" (this: rawptr) -> u32,
	GetIids:             rawptr,
	GetRuntimeClassName: rawptr,
	GetTrustLevel:       rawptr,
	StartCapture:        proc "stdcall" (this: rawptr) -> win32.HRESULT,
}
IGraphicsCaptureSession :: struct { using vtbl: ^IGraphicsCaptureSession_VTable }

// IGraphicsCaptureSession2 : IInspectable (6) + 2 own = 8 slots
// Source: windows.graphics.capture.h  __x_ABI_..._CIGraphicsCaptureSession2Vtbl
// WinRT boolean is unsigned char (1 byte) per rpcndr.h — b8, not Win32 BOOL.
IGraphicsCaptureSession2_VTable :: struct {
	QueryInterface:             proc "stdcall" (this: rawptr, riid: ^win32.GUID, ppv: ^rawptr) -> win32.HRESULT,
	AddRef:                     proc "stdcall" (this: rawptr) -> u32,
	Release:                    proc "stdcall" (this: rawptr) -> u32,
	GetIids:                    rawptr,
	GetRuntimeClassName:        rawptr,
	GetTrustLevel:              rawptr,
	get_IsCursorCaptureEnabled: proc "stdcall" (this: rawptr, value: ^b8) -> win32.HRESULT,
	put_IsCursorCaptureEnabled: proc "stdcall" (this: rawptr, value: b8) -> win32.HRESULT,
}
IGraphicsCaptureSession2 :: struct { using vtbl: ^IGraphicsCaptureSession2_VTable }

// IGraphicsCaptureSession3 : IInspectable (6) + 2 own = 8 slots
// Source: windows.graphics.capture.h  __x_ABI_..._CIGraphicsCaptureSession3Vtbl
// WinRT boolean is unsigned char (1 byte) per rpcndr.h — b8, not Win32 BOOL.
IGraphicsCaptureSession3_VTable :: struct {
	QueryInterface:       proc "stdcall" (this: rawptr, riid: ^win32.GUID, ppv: ^rawptr) -> win32.HRESULT,
	AddRef:               proc "stdcall" (this: rawptr) -> u32,
	Release:              proc "stdcall" (this: rawptr) -> u32,
	GetIids:              rawptr,
	GetRuntimeClassName:  rawptr,
	GetTrustLevel:        rawptr,
	get_IsBorderRequired: proc "stdcall" (this: rawptr, value: ^b8) -> win32.HRESULT,
	put_IsBorderRequired: proc "stdcall" (this: rawptr, value: b8) -> win32.HRESULT,
}
IGraphicsCaptureSession3 :: struct { using vtbl: ^IGraphicsCaptureSession3_VTable }

// IClosable : IInspectable (6) + 1 own = 7 slots
// Source: windows.foundation.h
IClosable_VTable :: struct {
	QueryInterface:      proc "stdcall" (this: rawptr, riid: ^win32.GUID, ppv: ^rawptr) -> win32.HRESULT,
	AddRef:              proc "stdcall" (this: rawptr) -> u32,
	Release:             proc "stdcall" (this: rawptr) -> u32,
	GetIids:             rawptr,
	GetRuntimeClassName: rawptr,
	GetTrustLevel:       rawptr,
	Close:               proc "stdcall" (this: rawptr) -> win32.HRESULT,
}
IClosable :: struct { using vtbl: ^IClosable_VTable }

// IDirect3DDxgiInterfaceAccess : IUnknown (3) + 1 own = 4 slots
// Source: windows.graphics.directx.direct3d11.interop.h
IDirect3DDxgiInterfaceAccess_VTable :: struct {
	QueryInterface: proc "stdcall" (this: rawptr, riid: ^win32.GUID, ppv: ^rawptr) -> win32.HRESULT,
	AddRef:         proc "stdcall" (this: rawptr) -> u32,
	Release:        proc "stdcall" (this: rawptr) -> u32,
	GetInterface:   proc "stdcall" (this: rawptr, iid: ^win32.GUID, p: ^rawptr) -> win32.HRESULT,
}
IDirect3DDxgiInterfaceAccess :: struct { using vtbl: ^IDirect3DDxgiInterfaceAccess_VTable }
