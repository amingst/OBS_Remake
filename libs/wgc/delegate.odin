package wgc

import "base:intrinsics"
import "base:runtime"
import win32 "core:sys/windows"

// ---------------------------------------------------------------------------
// TypedEventHandler<Direct3D11CaptureFramePool, IInspectable> delegate
//
// A hand-written COM object implementing the WinRT delegate interface.
// QI answers IUnknown, IAgileObject, and the derived delegate IID.
//
// Ownership: the caller allocates the Frame_Handler (stack, arena, or
// embedding struct) and must keep it alive until after remove_FrameArrived
// returns.  add_FrameArrived calls AddRef; remove_FrameArrived calls Release.
// The caller's own reference is the initial refcount of 1 set by
// frame_handler_init.  Do not free the handler while the pool holds it.
// ---------------------------------------------------------------------------

Frame_Arrived_Callback :: proc(user_data: rawptr, sender: rawptr, args: rawptr) -> win32.HRESULT

Frame_Handler :: struct {
	vtbl:      ^Frame_Handler_VTable,
	refcount:  i32,
	callback:  Frame_Arrived_Callback,
	user_data: rawptr,
	logger:    runtime.Logger, // restored in Invoke — NOT a full Context (see below)
}

Frame_Handler_VTable :: struct {
	QueryInterface: proc "stdcall" (this: ^Frame_Handler, riid: ^win32.GUID, out: ^rawptr) -> win32.HRESULT,
	AddRef:         proc "stdcall" (this: ^Frame_Handler) -> u32,
	Release:        proc "stdcall" (this: ^Frame_Handler) -> u32,
	Invoke:         proc "stdcall" (this: ^Frame_Handler, sender: rawptr, args: rawptr) -> win32.HRESULT,
}

handler_vtbl := Frame_Handler_VTable{
	QueryInterface = handler_qi,
	AddRef         = handler_addref,
	Release        = handler_release,
	Invoke         = handler_invoke,
}

// Initialise a caller-owned Frame_Handler.  Sets vtbl, refcount = 1 (for the
// caller's own reference — add_FrameArrived takes another), callback, user_data,
// and the logger that Invoke will install on the pool thread.  The logger's
// backing Log_Context must outlive the handler (put it in the Window_Capture
// struct, not on any thread's stack).
frame_handler_init :: proc(h: ^Frame_Handler, cb: Frame_Arrived_Callback, user_data: rawptr, logger: runtime.Logger) {
	h.vtbl      = &handler_vtbl
	h.refcount  = 1
	h.callback  = cb
	h.user_data = user_data
	h.logger    = logger
}

@(private = "file")
handler_qi :: proc "stdcall" (this: ^Frame_Handler, riid: ^win32.GUID, out: ^rawptr) -> win32.HRESULT {
	if out == nil do return E_POINTER
	if guid_eq(riid, &IID_IUnknown) ||
	   guid_eq(riid, &IID_IAgileObject) ||
	   guid_eq(riid, &IID_TypedEventHandler_FramePool) {
		out^ = this
		intrinsics.atomic_add(&this.refcount, 1)
		return win32.S_OK
	}
	out^ = nil
	return E_NOINTERFACE
}

@(private = "file")
handler_addref :: proc "stdcall" (this: ^Frame_Handler) -> u32 {
	return u32(intrinsics.atomic_add(&this.refcount, 1) + 1)
}

@(private = "file")
handler_release :: proc "stdcall" (this: ^Frame_Handler) -> u32 {
	new_count := intrinsics.atomic_add(&this.refcount, -1) - 1
	// Caller owns the memory — see frame_handler_init doc.
	return u32(new_count)
}

@(private = "file")
handler_invoke :: proc "stdcall" (this: ^Frame_Handler, sender: rawptr, args: rawptr) -> win32.HRESULT {
	// Start from the pool thread's own default context so we get its private
	// temp arena — NOT the main thread's.  Only the logger is carried across.
	context = runtime.default_context()
	context.logger = this.logger
	if this.callback != nil {
		result := this.callback(this.user_data, sender, args)
		// Pool threads are recycled; free temp allocations so the arena
		// doesn't grow unboundedly across callbacks.
		free_all(context.temp_allocator)
		return result
	}
	return win32.S_OK
}

// Byte-by-byte GUID comparison, contextless — safe to call from stdcall QI.
@(private = "file")
guid_eq :: proc "contextless" (a, b: ^win32.GUID) -> bool {
	a_bytes := ([^]u8)(a)
	b_bytes := ([^]u8)(b)
	for i in 0..<size_of(win32.GUID) {
		if a_bytes[i] != b_bytes[i] do return false
	}
	return true
}

// ---------------------------------------------------------------------------
// TypedEventHandler<GraphicsCaptureItem, IInspectable> delegate
//
// Same hand-written-COM-object shape as Frame_Handler above, for
// GraphicsCaptureItem.Closed. QI answers IUnknown, IAgileObject, and its own
// IID; E_NOINTERFACE for everything else including IMarshal.
//
// Ownership: identical contract to Frame_Handler -- the caller allocates the
// Closed_Handler and keeps it alive until after remove_Closed returns.
// add_Closed calls AddRef; remove_Closed calls Release. Release does not free
// the memory; the caller's embedding struct owns that.
// ---------------------------------------------------------------------------

// uuid5(11f47ad5-7b73-42c0-abae-878b1e16adee, "pinterface({9de1c534-6ae1-11e0-84e1-18a905bcc53f};
//   rc(Windows.Graphics.Capture.GraphicsCaptureItem;{79c3f95b-31f7-4ec2-a464-632ef5d30760});
//   cinterface(IInspectable))") -- computed and validated by the C1S spike; do
// not re-derive.
IID_TypedEventHandler_Closed := win32.GUID{0xe9c610c0, 0xa68c, 0x5bd9, {0x80, 0x21, 0x85, 0x89, 0x34, 0x6e, 0xee, 0xe2}}

Closed_Callback :: proc(user_data: rawptr, sender: rawptr, args: rawptr) -> win32.HRESULT

Closed_Handler :: struct {
	vtbl:      ^Closed_Handler_VTable,
	refcount:  i32,
	callback:  Closed_Callback,
	user_data: rawptr,
	logger:    runtime.Logger, // restored in Invoke — NOT a full Context (see below)
}

Closed_Handler_VTable :: struct {
	QueryInterface: proc "stdcall" (this: ^Closed_Handler, riid: ^win32.GUID, out: ^rawptr) -> win32.HRESULT,
	AddRef:         proc "stdcall" (this: ^Closed_Handler) -> u32,
	Release:        proc "stdcall" (this: ^Closed_Handler) -> u32,
	Invoke:         proc "stdcall" (this: ^Closed_Handler, sender: rawptr, args: rawptr) -> win32.HRESULT,
}

closed_handler_vtbl := Closed_Handler_VTable{
	QueryInterface = closed_handler_qi,
	AddRef         = closed_handler_addref,
	Release        = closed_handler_release,
	Invoke         = closed_handler_invoke,
}

// Initialise a caller-owned Closed_Handler. Sets vtbl, refcount = 1 (for the
// caller's own reference — add_Closed takes another), callback, user_data,
// and the logger that Invoke will install on the pool thread. The logger's
// backing Log_Context must outlive the handler (put it in the Window_Capture
// struct, not on any thread's stack) -- same contract as frame_handler_init.
closed_handler_init :: proc(h: ^Closed_Handler, cb: Closed_Callback, user_data: rawptr, logger: runtime.Logger) {
	h.vtbl      = &closed_handler_vtbl
	h.refcount  = 1
	h.callback  = cb
	h.user_data = user_data
	h.logger    = logger
}

@(private = "file")
closed_handler_qi :: proc "stdcall" (this: ^Closed_Handler, riid: ^win32.GUID, out: ^rawptr) -> win32.HRESULT {
	if out == nil do return E_POINTER
	if guid_eq(riid, &IID_IUnknown) ||
	   guid_eq(riid, &IID_IAgileObject) ||
	   guid_eq(riid, &IID_TypedEventHandler_Closed) {
		out^ = this
		intrinsics.atomic_add(&this.refcount, 1)
		return win32.S_OK
	}
	out^ = nil
	return E_NOINTERFACE
}

@(private = "file")
closed_handler_addref :: proc "stdcall" (this: ^Closed_Handler) -> u32 {
	return u32(intrinsics.atomic_add(&this.refcount, 1) + 1)
}

@(private = "file")
closed_handler_release :: proc "stdcall" (this: ^Closed_Handler) -> u32 {
	new_count := intrinsics.atomic_add(&this.refcount, -1) - 1
	// Caller owns the memory — see closed_handler_init doc.
	return u32(new_count)
}

@(private = "file")
closed_handler_invoke :: proc "stdcall" (this: ^Closed_Handler, sender: rawptr, args: rawptr) -> win32.HRESULT {
	// Start from the pool thread's own default context so we get its private
	// temp arena — NOT the main thread's. Only the logger is carried across.
	context = runtime.default_context()
	context.logger = this.logger
	if this.callback != nil {
		result := this.callback(this.user_data, sender, args)
		// Pool threads are recycled; free temp allocations so the arena
		// doesn't grow unboundedly across callbacks.
		free_all(context.temp_allocator)
		return result
	}
	return win32.S_OK
}
