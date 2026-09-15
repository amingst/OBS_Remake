package capture

import "base:intrinsics"
import win32 "core:sys/windows"
import "../applog"
import "core:log"
import "vendor:directx/d3d11"
import "vendor:directx/dxgi"
import "libs:wgc"

// A single window's WinRT capture session, texture, and its callback state.
// lost and pending_size/width/height are written from WinRT callback threads
// and must only be accessed atomically -- see window_capture_lost and
// window_capture_service_resize.
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
	lost:           bool, // atomic; set by WinRT callback threads, read via window_capture_lost
	pending_size:   bool, // atomic; set by callback, cleared by main thread
	pending_width:  u32,  // valid once pending_size observed true
	pending_height: u32,  //   "
}

// Atomic read of Window_Capture.lost -- safe to call from the main thread.
window_capture_lost :: proc(wc: ^Window_Capture) -> bool {
	return intrinsics.atomic_load_explicit(&wc.lost, .Acquire)
}

// Starts WinRT window capture for hwnd: creates the capture item, frame pool,
// session, and backing texture/SRV, and begins receiving frames.
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

	// Callbacks run on WinRT thread-pool threads, so they log via their own
	// stored context rather than the calling thread's.
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

	// Note: a capture session keeps running even while its scene isn't selected.
	hr = wc.session->StartCapture()
	if hr < 0 {
		log.errorf("StartCapture failed: 0x%08X", u32(hr))
		return nil, false
	}

	ok = true
	return wc, true
}

// Main-thread-only toggles, applied by the caller after start/retry. QI's the
// session for the optional interface each time rather than holding it.
@(private = "file")
cursor_toggle_warned := false
@(private = "file")
border_toggle_warned := false

// Enables/disables cursor capture; returns false if unsupported on this build.
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

// Enables/disables the capture border; returns false if unsupported on this build.
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

// Only sanctioned writer of Window_Capture.lost -- atomic store, callback threads only.
@(private="file")
mark_lost :: proc(wc: ^Window_Capture) {
	intrinsics.atomic_store_explicit(&wc.lost, true, .Release)
}

// WinRT callback: fires when the captured window closes.
@(private="file")
closed_arrived :: proc(user_data: rawptr, sender: rawptr, args: rawptr) -> win32.HRESULT {
	if user_data == nil {
		log.errorf("closed_arrived: user_data is nil")
		return win32.S_OK
	}
	wc := (^Window_Capture)(user_data)
	// Flag only -- releasing WinRT objects here would race the main thread's reads.
	if !window_capture_lost(wc) {
		log.warn("window closed")
	}
	mark_lost(wc)
	return win32.S_OK
}

// WinRT callback: fires when a new captured frame is ready; copies it into wc.texture.
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
    	// S_OK with no frame means a static window -- not loss.
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

	// Resize detection against wc's own size; arms pending_size for the main
	// thread to service in window_capture_service_resize.
	if u32(content_size.Width) != wc.width || u32(content_size.Height) != wc.height {
		if !intrinsics.atomic_load_explicit(&wc.pending_size, .Acquire) {
			log.infof("wgc: window resized %vx%v -> %vx%v, resize pending",
				wc.width, wc.height, content_size.Width, content_size.Height)
		}
		wc.pending_width  = u32(content_size.Width)
		wc.pending_height = u32(content_size.Height)
		intrinsics.atomic_store_explicit(&wc.pending_size, true, .Release)
		return win32.S_OK
	}

	// Gate the copy on pending_size -- the main thread may be mid-recreate of
	// wc.texture/wc.srv right now.
	if intrinsics.atomic_load_explicit(&wc.pending_size, .Acquire) {
		return win32.S_OK
	}

	// Rounding check: compares against the pool's own per-frame texture desc.
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

// Main-thread-only: applies a resize flagged by frame_arrived, recreating the
// pool and the owned texture/SRV at the new size. False means unrecoverable;
// caller treats it like any other loss.
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

	// Cleared last -- only once the new texture/SRV are fully built.
	intrinsics.atomic_store_explicit(&wc.pending_size, false, .Release)

	log.infof("window capture resized %vx%v -> %vx%v", old_width, old_height, new_width, new_height)

	return true
}

// Tears down a window capture session and releases all its COM/WinRT objects.
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

// QI's obj for IClosable and calls Close through it (not a reinterpret-cast,
// since IClosable is a distinct vtable from the caller's interface).
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
