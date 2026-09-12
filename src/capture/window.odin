package capture

import "base:intrinsics"
import win32 "core:sys/windows"
import "../applog"
import "core:log"
import "vendor:directx/d3d11"
import "vendor:directx/dxgi"
import "libs:wgc"

// width, height, texture, and srv are written by start_window_capture and
// stop_window_capture on the main thread, and read by frame_arrived on the
// WinRT thread pool. That's safe only in this step because start fully
// initialises them before StartCapture is called (so the callback never sees
// a torn state) and stop removes the FrameArrived registration before
// touching anything else. The pending-size flag in a later step is the first
// field genuinely written and read concurrently, and will need to be atomic.
//
// lost IS genuinely concurrent starting this step: written by the Closed
// callback and by frame_arrived (both WinRT thread-pool threads), read by
// the main thread via window_capture_lost. Every access goes through
// intrinsics.atomic_load/store_explicit -- see window_capture_lost,
// closed_arrived, and frame_arrived below.
//
// pending_size/pending_width/pending_height are the same shape, for the
// same reason: frame_arrived (callback thread) detects a resize and can
// only flag it -- Recreate and texture/SRV lifetime are main-thread only
// (the multithread-protected immediate context covers CopySubresourceRegion
// and Draw, not CreateTexture2D/CreateShaderResourceView/Release). The
// callback writes pending_width/pending_height FIRST, then stores
// pending_size with .Release; the main thread loads pending_size with
// .Acquire and only then reads the size fields -- see
// window_capture_service_resize below. That ordering is what makes it safe
// for the callback to skip synchronizing the width/height writes
// themselves.
Window_Capture :: struct {
	item:           ^wgc.IGraphicsCaptureItem,
	pool:           ^wgc.IDirect3D11CaptureFramePool,
	session:        ^wgc.IGraphicsCaptureSession,
	d3d_device:     rawptr, // IDirect3DDevice from the bridge, released via IUnknown
	frame_handler:  wgc.Frame_Handler,
	frame_token:    wgc.EventRegistrationToken,
	closed_handler: wgc.Closed_Handler,
	closed_token:   wgc.EventRegistrationToken,
	texture:        ^d3d11.ITexture2D,
	srv:            ^d3d11.IShaderResourceView,
	width, height:  u32,
	log_context:    applog.Log_Context,
	device_context: ^d3d11.IDeviceContext,
	lost:           bool, // written by WinRT callback threads, read by the main thread -- always accessed atomically, see window_capture_lost
	pending_size:   bool, // atomic; set by callback, cleared by main thread -- see window_capture_service_resize
	pending_width:  u32,  // written by callback before pending_size is set; read by main thread only after observing pending_size true
	pending_height: u32,  //   "
}

// window_capture_lost is the only sanctioned way to read Window_Capture.lost
// -- an atomic load, so the scene can check it without reaching into the
// struct and without racing the callback threads that set it.
window_capture_lost :: proc(wc: ^Window_Capture) -> bool {
	return intrinsics.atomic_load_explicit(&wc.lost, .Acquire)
}

start_window_capture :: proc (device: ^d3d11.IDevice, device_context: ^d3d11.IDeviceContext, hwnd: win32.HWND, log_sink: ^applog.Sink) -> (^Window_Capture, bool) {
	wc := new(Window_Capture)
	ok := false
	frame_registered := false
	closed_registered := false
	defer if !ok {
		pool    := wc.pool
		item    := wc.item
		session := wc.session
		srv     := wc.srv
		texture := wc.texture
		d3d_dev := wc.d3d_device
		if frame_registered && pool != nil { pool->remove_FrameArrived(wc.frame_token) }
		if closed_registered && item != nil { item->remove_Closed(wc.closed_token) }
		if session != nil { session->Release() }
		if srv != nil { srv->Release() }
		if texture != nil { texture->Release() }
		if pool != nil { pool->Release() }
		if item != nil { item->Release() }
		if d3d_dev != nil { (^wgc.IUnknown)(d3d_dev)->Release() }
		free(wc)
	}
	dxgi_device: ^dxgi.IDevice
	hr := device->QueryInterface(dxgi.IDevice_UUID, (^rawptr)(&dxgi_device))
	if hr < 0 {
	    log.errorf("QueryInterface(IDXGIDevice) failed: 0x%08X", u32(hr))
	    return nil, false
	}

	hr = wgc.CreateDirect3D11DeviceFromDXGIDevice(dxgi_device, &wc.d3d_device)
	dxgi_device->Release()
	if hr < 0 {
	    log.errorf("CreateDirect3D11DeviceFromDXGIDevice failed: 0x%08X", u32(hr))
	    return nil, false
	}

	interop: ^wgc.IGraphicsCaptureItemInterop
	hr = wgc.RoGetActivationFactory(wgc.hs_capture_item, &wgc.IID_IGraphicsCaptureItemInterop, (^rawptr)(&interop))
	if hr < 0 {
	    log.errorf("RoGetActivationFactory failed: 0x%08X", u32(hr))
	    return nil, false
	}

	hr = interop->CreateForWindow(hwnd, &wgc.IID_IGraphicsCaptureItem, (^rawptr)(&wc.item))
	interop->Release()
	if hr < 0 {
	    log.errorf("CreateForWindow failed: 0x%08X", u32(hr))
	    return nil, false
	}

	// The callbacks run on WinRT thread-pool threads, so they must log under
	// the capture source's own tag rather than whichever logger happens to
	// be in the calling thread's context. wc.log_context is stored by value
	// on the struct so it has stable lifetime for the life of the handlers.
	// Built here, right after the item exists, so it's ready for the Closed
	// registration below as well as the frame handler registered later.
	wc.log_context = applog.Log_Context{sink = log_sink, tag = {.Capture, 0}}
	wc_logger := applog.make_logger(&wc.log_context)

	wgc.closed_handler_init(&wc.closed_handler, closed_arrived, wc, wc_logger)
	hr = wc.item->add_Closed(&wc.closed_handler, &wc.closed_token)
	if hr < 0 {
		log.errorf("add_Closed failed: 0x%08X", u32(hr))
		return nil, false
	}
	closed_registered = true

	size: wgc.SizeInt32
	hr = wc.item->get_Size(&size)
	if hr < 0 {
	    log.errorf("get_Size failed: 0x%08X", u32(hr))
	    return nil, false
	}

	if size.Height == 0 || size.Width == 0 {
	    log.errorf("Invalid size: %dx%d", size.Width, size.Height)
	    return nil, false
	}

	wc.width = (u32)(size.Width)
	wc.height = (u32)(size.Height)
	wc.device_context = device_context

	statics: ^wgc.IDirect3D11CaptureFramePoolStatics2
	hr = wgc.RoGetActivationFactory(wgc.hs_frame_pool, &wgc.IID_IDirect3D11CaptureFramePoolStatics2, (^rawptr)(&statics))
	if hr < 0 {
	    log.errorf("RoGetActivationFactory failed: 0x%08X", u32(hr))
	    return nil, false
	}

	hr = statics->CreateFreeThreaded(
		wc.d3d_device,
		wgc.DXPF_B8G8R8A8_UINT_NORMALIZED,
		2,
		size,
		(^rawptr)(&wc.pool),
	)
	statics->Release()
	if hr < 0 {
	    log.errorf("CreateFreeThreaded failed: 0x%08X", u32(hr))
	    return nil, false
	}

	wgc.frame_handler_init(&wc.frame_handler, frame_arrived, wc, wc_logger)

	hr = wc.pool->add_FrameArrived(&wc.frame_handler, &wc.frame_token)
	if hr < 0 {
		log.errorf("add_FrameArrived failed: 0x%08X", u32(hr))
		return nil, false
	}
	frame_registered = true

	desc := d3d11.TEXTURE2D_DESC{
		Width      = wc.width,
		Height     = wc.height,
		MipLevels  = 1,
		ArraySize  = 1,
		Format     = .B8G8R8A8_UNORM,
		SampleDesc = {Count = 1},
		Usage      = .DEFAULT,
		BindFlags  = {.SHADER_RESOURCE},
	}
	hr = device->CreateTexture2D(&desc, nil, &wc.texture)
	if hr < 0 {
		log.errorf("CreateTexture2D failed: 0x%08X", u32(hr))
		return nil, false
	}

	hr = device->CreateShaderResourceView((^d3d11.IResource)(wc.texture), nil, &wc.srv)
	if hr < 0 {
		log.errorf("CreateShaderResourceView failed: 0x%08X", u32(hr))
		return nil, false
	}

	hr = wc.pool->CreateCaptureSession(wc.item, (^rawptr)(&wc.session))
	if hr < 0 {
		log.errorf("CreateCaptureSession failed: 0x%08X", u32(hr))
		return nil, false
	}

	// A source's capture session keeps running even while its scene isn't
	// selected -- there is no pause/resume wired to scene visibility yet.
	// Known, out of scope for this step.
	hr = wc.session->StartCapture()
	if hr < 0 {
		log.errorf("StartCapture failed: 0x%08X", u32(hr))
		return nil, false
	}

	ok = true
	return wc, true
}

// window_capture_set_cursor_capture and window_capture_set_border_required
// are both main-thread-only, applied by the caller (see item 6's note in
// main.odin) after start_window_capture returns and again after a retry
// rebuilds the session -- Window_Data owns the toggle values, not the
// session, precisely so a source recovering from loss comes back with them
// intact. Each QI's the session for the interface that carries the property,
// sets it, and releases the interface -- never held past this call. Where
// the QI fails (older Windows build), the "warned" flag logs it once for the
// process rather than once per source per call, and the return value tells
// the caller (and from there, the UI) to grey the control out rather than
// fail the source over a missing optional interface.
@(private = "file")
cursor_toggle_warned := false
@(private = "file")
border_toggle_warned := false

window_capture_set_cursor_capture :: proc(wc: ^Window_Capture, enabled: bool) -> (available: bool) {
	session2: ^wgc.IGraphicsCaptureSession2
	unk := (^wgc.IUnknown)(wc.session)
	hr := unk->QueryInterface(&wgc.IID_IGraphicsCaptureSession2, (^rawptr)(&session2))
	if hr < 0 {
		if !cursor_toggle_warned {
			log.warnf("IGraphicsCaptureSession2 QI failed: 0x%08X -- cursor capture toggle unavailable on this build", u32(hr))
			cursor_toggle_warned = true
		}
		return false
	}
	defer session2->Release()

	hr = session2->put_IsCursorCaptureEnabled(b8(enabled))
	if hr < 0 {
		log.errorf("put_IsCursorCaptureEnabled failed: 0x%08X", u32(hr))
		return false
	}
	return true
}

window_capture_set_border_required :: proc(wc: ^Window_Capture, required: bool) -> (available: bool) {
	session3: ^wgc.IGraphicsCaptureSession3
	unk := (^wgc.IUnknown)(wc.session)
	hr := unk->QueryInterface(&wgc.IID_IGraphicsCaptureSession3, (^rawptr)(&session3))
	if hr < 0 {
		if !border_toggle_warned {
			log.warnf("IGraphicsCaptureSession3 QI failed: 0x%08X -- capture border toggle unavailable on this build", u32(hr))
			border_toggle_warned = true
		}
		return false
	}
	defer session3->Release()

	hr = session3->put_IsBorderRequired(b8(required))
	if hr < 0 {
		log.errorf("put_IsBorderRequired failed: 0x%08X", u32(hr))
		return false
	}
	return true
}

// mark_lost is the only sanctioned writer of Window_Capture.lost -- an
// atomic store, called only from the WinRT callback threads (closed_arrived,
// frame_arrived). The main thread never writes it; it only reads it via
// window_capture_lost and reacts (teardown, retry) on its own thread.
@(private="file")
mark_lost :: proc(wc: ^Window_Capture) {
	intrinsics.atomic_store_explicit(&wc.lost, true, .Release)
}

@(private="file")
closed_arrived :: proc(user_data: rawptr, sender: rawptr, args: rawptr) -> win32.HRESULT {
	if user_data == nil {
		log.errorf("closed_arrived: user_data is nil")
		return win32.S_OK
	}
	wc := (^Window_Capture)(user_data)
	// Flag only -- do not touch any WinRT object here. Releasing them from
	// this thread while the main thread may be reading them (e.g. the SRV,
	// for the last-good-frame draw) is exactly the race this design avoids.
	// The main loop reaps: sees lost, tears down, retries.
	if !window_capture_lost(wc) {
		log.warn("window closed")
	}
	mark_lost(wc)
	return win32.S_OK
}

@(private="file")
frame_arrived :: proc(user_data: rawptr, sender: rawptr, args: rawptr) -> win32.HRESULT {
	if user_data == nil {
		log.errorf("frame_arrived: user_data is nil")
		return win32.S_OK
	}
	wc := (^Window_Capture)(user_data)
	if window_capture_lost(wc) {
		return win32.S_OK
	}
	frame:   ^wgc.IDirect3D11CaptureFrame
	surface: rawptr
	access:  ^wgc.IDirect3DDxgiInterfaceAccess
	src_tex: ^d3d11.ITexture2D
	defer {
		if src_tex != nil { src_tex->Release() }
		if access  != nil { access->Release() }
		if surface != nil { (^wgc.IUnknown)(surface)->Release() }
		if frame   != nil { frame->Release() }
	}

	hr := wc.pool->TryGetNextFrame((^rawptr)(&frame))
	if hr < 0 {
    	log.errorf("TryGetNextFrame failed: 0x%08X", u32(hr))
    	mark_lost(wc)
    	return win32.S_OK
	}
	if frame == nil {
    	// S_OK with no frame is a static window producing nothing new --
    	// correct WGC behaviour, not loss. No counter, no timeout: an idle
    	// window must not false-positive into lost.
    	return win32.S_OK
	}

	hr = frame->get_Surface(&surface)
	if hr < 0 {
    	log.errorf("get_Surface failed: 0x%08X", u32(hr))
    	if hr == wgc.RO_E_CLOSED { mark_lost(wc) }
    	return win32.S_OK
	}

	unk := (^wgc.IUnknown)(surface)
	hr = unk->QueryInterface(
		&wgc.IID_IDirect3DDxgiInterfaceAccess,
		(^rawptr)(&access)
	)
	if hr < 0 {
    	log.errorf("QueryInterface(IDirect3DDxgiInterfaceAccess) failed: 0x%08X", u32(hr))
    	if hr == wgc.RO_E_CLOSED { mark_lost(wc) }
    	return win32.S_OK
	}

	hr = access->GetInterface(d3d11.ITexture2D_UUID, (^rawptr)(&src_tex))
	if hr < 0 {
    	log.errorf("GetInterface(ID3D11Texture2D) failed: 0x%08X", u32(hr))
    	if hr == wgc.RO_E_CLOSED { mark_lost(wc) }
    	return win32.S_OK
	}

	content_size: wgc.SizeInt32
	hr = frame->get_ContentSize(&content_size)
	if hr < 0 {
		log.errorf("get_ContentSize failed: 0x%08X", u32(hr))
		if hr == wgc.RO_E_CLOSED { mark_lost(wc) }
		return win32.S_OK
	}

	desc: d3d11.TEXTURE2D_DESC
	src_tex->GetDesc(&desc)
	if desc.Width == 0 || desc.Height == 0 {
		log.errorf("Texture desc: width=%d height=%d", desc.Width, desc.Height)
		return win32.S_OK
	}

	// Resize detection: the frame against what WE own (wc.width/height), not
	// the pool -- see the rounding check below for the other comparison.
	// Deliberately unsynchronized: while the main thread is mid-service
	// (window_capture_service_resize), wc.width/wc.height still hold their
	// PRE-resize values right up until it updates them (step 5 of that
	// proc), which happens before it clears pending_size (step 6, last) --
	// so this still reads "differs" on a frame landing mid-service, and we
	// bail below before touching wc.texture regardless. The width/height
	// read here only ever decides whether to (re)arm the flag; it is never
	// what gates the copy.
	if u32(content_size.Width) != wc.width || u32(content_size.Height) != wc.height {
		// Log once per transition, not once per frame -- an unserviced
		// resize would otherwise fire this at 60 Hz. pending_width/height
		// keep updating on every differing frame even after the first,
		// deliberately: a fast drag-resize produces many of these before
		// the main thread gets a turn, and the LAST values written before
		// service_resize actually runs are what determine the size it
		// recreates at -- that's how the final resting size wins (test 3),
		// not the first one detected.
		if !intrinsics.atomic_load_explicit(&wc.pending_size, .Acquire) {
			log.infof("wgc: window resized %vx%v -> %vx%v, resize pending",
				wc.width, wc.height, content_size.Width, content_size.Height)
		}
		wc.pending_width  = u32(content_size.Width)
		wc.pending_height = u32(content_size.Height)
		intrinsics.atomic_store_explicit(&wc.pending_size, true, .Release)
		return win32.S_OK
	}

	// Single atomic read gates the copy -- not a check followed by a
	// separate use. The main thread may be releasing wc.texture/wc.srv (or
	// have just nilled them, mid-recreate) at this exact instant; this is
	// the only thing standing between this read and a use-after-free. Do
	// not add a second guard, and do not replace this with the width/height
	// comparison above -- that one only decides whether to arm the flag.
	if intrinsics.atomic_load_explicit(&wc.pending_size, .Acquire) {
		return win32.S_OK
	}

	// Rounding check: WGC's own frame can differ slightly from ContentSize
	// even with no resize in flight and wc already at the right size. This
	// compares the frame against the POOL's per-frame texture (desc, from
	// src_tex above) -- separate from the resize check above, which
	// compares the frame against what we own.
	if u32(content_size.Width) != desc.Width || u32(content_size.Height) != desc.Height {
    	log.infof("wgc: pool texture %vx%v != ContentSize %vx%v — skipping copy this frame (rounding)",
        	desc.Width, desc.Height, content_size.Width, content_size.Height)
	} else {
		box := d3d11.BOX{
		    left   = 0,
		    top    = 0,
		    front  = 0,
		    right  = min(u32(content_size.Width),  desc.Width),
		    bottom = min(u32(content_size.Height), desc.Height),
		    back   = 1,
		}

		wc.device_context->CopySubresourceRegion(
		    wc.texture,   // destination
		    0,            // dest subresource (mip 0)
		    0, 0, 0,      // dest x, y, z
		    src_tex,      // source
		    0,            // source subresource
		    &box,
		)
	}

	log.debugf("frame arrived: content size %vx%v", content_size.Width, content_size.Height)

	return win32.S_OK
}

// window_capture_service_resize is main-thread-only. It's the other half of
// the split described at the top of this file: frame_arrived (callback
// thread) only ever flags a resize; this is what actually acts on it --
// Recreate on the pool, then release and recreate the owned texture/SRV at
// the new size. Called once per frame per window source, unconditionally;
// the no-op path (no resize pending) is a single atomic load and nothing
// else, since that's the common case on every frame this runs.
//
// wc.texture/wc.srv are nil for the duration of this proc, between the
// Release calls and the CreateTexture2D/CreateShaderResourceView calls.
// frame_arrived is gated on pending_size and will not touch them during
// that window -- see the single-read gate there. Do not add a second guard
// here; pending_size, cleared last, is the only handshake.
//
// A false return means the capture is unrecoverable -- the caller (main.odin)
// treats it exactly like any other loss: stop_window_capture, nil the
// pointer, arm the retry. This proc never tears anything down itself on
// failure; it only reports.
window_capture_service_resize :: proc(wc: ^Window_Capture, device: ^d3d11.IDevice) -> bool {
	if !intrinsics.atomic_load_explicit(&wc.pending_size, .Acquire) {
		return true
	}

	new_width := wc.pending_width
	new_height := wc.pending_height

	size := wgc.SizeInt32{Width = i32(new_width), Height = i32(new_height)}
	hr := wc.pool->Recreate(wc.d3d_device, wgc.DXPF_B8G8R8A8_UINT_NORMALIZED, 2, size)
	if hr < 0 {
		log.errorf("Recreate failed: 0x%08X", u32(hr))
		return false
	}

	if wc.srv != nil { wc.srv->Release(); wc.srv = nil }
	if wc.texture != nil { wc.texture->Release(); wc.texture = nil }

	desc := d3d11.TEXTURE2D_DESC{
		Width      = new_width,
		Height     = new_height,
		MipLevels  = 1,
		ArraySize  = 1,
		Format     = .B8G8R8A8_UNORM,
		SampleDesc = {Count = 1},
		Usage      = .DEFAULT,
		BindFlags  = {.SHADER_RESOURCE},
	}
	hr = device->CreateTexture2D(&desc, nil, &wc.texture)
	if hr < 0 {
		log.errorf("CreateTexture2D failed: 0x%08X", u32(hr))
		return false
	}

	hr = device->CreateShaderResourceView((^d3d11.IResource)(wc.texture), nil, &wc.srv)
	if hr < 0 {
		log.errorf("CreateShaderResourceView failed: 0x%08X", u32(hr))
		return false
	}

	old_width, old_height := wc.width, wc.height
	wc.width  = new_width
	wc.height = new_height

	// Cleared last, with release semantics, after everything above has
	// succeeded -- if it were cleared earlier the callback could see it
	// clear and copy into a half-built (or still-nil) texture.
	intrinsics.atomic_store_explicit(&wc.pending_size, false, .Release)

	log.infof("window capture resized %vx%v -> %vx%v", old_width, old_height, new_width, new_height)

	return true
}

stop_window_capture :: proc (wc: ^Window_Capture) {
	if wc == nil do return

	if wc.pool != nil {
		hr := wc.pool->remove_FrameArrived(wc.frame_token)
		if hr < 0 {
			log.errorf("remove_FrameArrived failed: 0x%08X", u32(hr))
		}
	}

	if wc.item != nil {
		hr := wc.item->remove_Closed(wc.closed_token)
		if hr < 0 {
			log.errorf("remove_Closed failed: 0x%08X", u32(hr))
		}
	}

	if wc.session != nil {
		if hr := com_close(wc.session); hr < 0 {
			log.errorf("Close (session) failed: 0x%08X", u32(hr))
		}
	}

	if wc.pool != nil {
		if hr := com_close(wc.pool); hr < 0 {
			log.errorf("Close (pool) failed: 0x%08X", u32(hr))
		}
	}

	if wc.session != nil { wc.session->Release() }
	if wc.pool != nil { wc.pool->Release() }
	if wc.item != nil { wc.item->Release() }
	if wc.d3d_device != nil { (^wgc.IUnknown)(wc.d3d_device)->Release() }

	if wc.srv != nil { wc.srv->Release() }
	if wc.texture != nil { wc.texture->Release() }

	free(wc)
}

// com_close QueryInterface's obj for IClosable and calls Close through the
// returned interface -- IClosable is a distinct vtable from
// IGraphicsCaptureSession/IDirect3D11CaptureFramePool, so a reinterpret-cast
// to IClosable would call whatever those types happen to have in IClosable's
// Close slot instead.
@(private="file")
com_close :: proc(obj: rawptr) -> win32.HRESULT {
	closable: ^wgc.IClosable
	unk := (^wgc.IUnknown)(obj)
	hr := unk->QueryInterface(&wgc.IID_IClosable, (^rawptr)(&closable))
	if hr < 0 {
		return hr
	}
	hr = closable->Close()
	closable->Release()
	return hr
}
