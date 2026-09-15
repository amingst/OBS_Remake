package scene

import "core:log"
import "core:sys/windows"
import "core:time"
import "vendor:directx/d3d11"
import "vendor:directx/dxgi"
import "../audio"
import "../applog"
import "../capture"
import "../render"

// Walks the scene's sources once per frame, lazily acquiring/retrying each
// one's capture, and appends a render.Quad / audio.Mix_Input for each.
service_sources :: proc(
	c: ^Collection, selected_scene_id: u64,
	device: ^d3d11.IDevice, device_context: ^d3d11.IDeviceContext,
	log_sink: ^applog.Sink,
	quads: ^[dynamic]render.Quad, inputs: ^[dynamic]audio.Mix_Input,
) {
	sel := find(c, selected_scene_id)
	if sel == nil do return

	for &src in sel.sources {
		if !src.visible do continue
		switch &d in src.data {
			case Audio_Data:
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
					append(inputs, audio.Mix_Input{
						stream = d.stream,
						volume = d.volume,
						muted  = d.muted,
					})
				}
			case Color_Data:
				append(quads, render.Quad{
					x = src.x, y = src.y, w = src.w, h = src.h,
					color = src.color,
				})
			case Image_Data:
				if d.texture == nil && !d.lost {
					tex, srv, w, h, img_ok := capture.load_image(device, d.path)
					if img_ok {
						d.texture = tex
						d.srv = srv
						d.width = w
						d.height = h
						log.infof("image loaded: %v (%vx%v)", d.path, w, h)
					} else {
						d.lost = true
						log.errorf("image decode failed, will not retry: %v", d.path)
					}
				}
				if d.srv != nil {
					append(quads, render.Quad{
						x = src.x, y = src.y, w = src.w, h = src.h,
						color = {1, 1, 1, 1},
						texture = d.srv,
					})
				}
			case Display_Data:
				if d.dupl == nil && time.now()._nsec >= d.next_retry._nsec {
					if dupl, ok := capture.start_duplication(device, u32(d.adapter_index), u32(d.output_index)); ok {
						d.dupl = dupl
					} else {
						d.next_retry = time.time_add(time.now(), 2 * time.Second)
					}
				}

				if d.dupl != nil {
					desc: dxgi.OUTDUPL_DESC
					d.dupl->GetDesc(&desc)

					// Recreate the texture if the output's mode changed size.
					if d.texture != nil {
						tex_desc: d3d11.TEXTURE2D_DESC
						d.texture->GetDesc(&tex_desc)
						if tex_desc.Width != desc.ModeDesc.Width || tex_desc.Height != desc.ModeDesc.Height {
							log.infof("display source: output %v/%v resized %vx%v -> %vx%v, recreating texture",
								d.adapter_index, d.output_index, tex_desc.Width, tex_desc.Height,
								desc.ModeDesc.Width, desc.ModeDesc.Height)
							if d.srv != nil     { d.srv->Release();     d.srv = nil }
							if d.texture != nil { d.texture->Release(); d.texture = nil }
						}
					}

					if d.texture == nil {
						tex, srv, ok := capture.create_capture_texture(
							device, desc.ModeDesc.Width, desc.ModeDesc.Height)
						if ok {
							d.texture = tex
							d.srv = srv
						}
					}
				}
				if d.dupl != nil && d.texture != nil {
					ok, lost, got_frame := capture.acquire_frame(device_context, d.dupl, d.texture)
					if lost {
						log.warn("duplication access lost, will restart")
						capture.stop_duplication(d.dupl)
						d.dupl = nil
						d.next_retry = time.time_add(time.now(), 500 * time.Millisecond)
					}
					_ = ok

					// Log when the desktop stops/resumes producing new frames.
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

				append(quads, render.Quad{
					x = src.x, y = src.y, w = src.w, h = src.h,
					color = {1, 1, 1, 1},
					texture = d.srv,
				})
			case Window_Data:
				if d.capture != nil && capture.window_capture_lost(d.capture) && !d.lost {
					log.warnf("window source: %q lost", d.title)
					d.lost = true
					d.next_retry = time.time_add(time.now(), 500 * time.Millisecond)
				}
				if (d.capture == nil || d.lost) && time.now()._nsec >= d.next_retry._nsec {
					hwnd, resolved := capture.resolve_window(d.title, d.class_name, d.exe_name)
					if !resolved {
						if !d.lost {
							log.warnf("window source: window %q not found", d.title)
							d.lost = true
						} else {
							log.debugf("window source: retry: %q still not found", d.title)
						}
						d.next_retry = time.time_add(time.now(), 2 * time.Second)
					} else {
						if wc, wc_ok := capture.start_window_capture(device, device_context, hwnd, log_sink); wc_ok {
							// game_capture forces cursor capture off regardless of hide_cursor.
							capture.window_capture_set_cursor_capture(wc, !d.hide_cursor && !d.game_capture)
							capture.window_capture_set_border_required(wc, !d.hide_border)

							// Release the old capture only after the new one is in place.
							old := d.capture
							d.capture = wc
							if old != nil {
								capture.stop_window_capture(old)
							}
							if d.lost {
								log.infof("window source: %q recovered (%vx%v)", d.title, wc.width, wc.height)
							} else {
								log.infof("window source: capture started for %q (%vx%v)", d.title, wc.width, wc.height)
							}
							d.lost = false
						} else {
							if !d.lost {
								log.errorf("window source: start_window_capture failed for %q", d.title)
								d.lost = true
							} else {
								log.debugf("window source: retry: start_window_capture failed again for %q", d.title)
							}
							d.next_retry = time.time_add(time.now(), 2 * time.Second)
						}
					}
				}
				if d.capture != nil && !d.lost {
					if !capture.window_capture_service_resize(d.capture, device) {
						log.errorf("window source: %q resize failed, treating as lost", d.title)
						capture.stop_window_capture(d.capture)
						d.capture = nil
						d.lost = true
						d.next_retry = time.time_add(time.now(), 500 * time.Millisecond)
					}
				}


				if d.capture != nil && d.capture.srv != nil {
					append(quads, render.Quad{
						x = src.x, y = src.y, w = src.w, h = src.h,
						color = {1, 1, 1, 1},
						texture = d.capture.srv,
					})
				}
			case Camera_Data:
				// Lazy start: first visible frame with a device set spawns the reader.
				if d.cam == nil && d.symlink != "" {
					wide := windows.utf8_to_utf16(d.symlink, context.temp_allocator)
					d.cam = capture.camera_start(wide, log_sink, capture.next_camera_tag_index(src.id))
				}
				// Per-frame upload: pull the latest CPU frame onto the dynamic texture.
				if d.cam != nil {
					capture.camera_upload(d.cam, device, &d.texture, &d.srv, &d.width, &d.height)
				}
				if d.srv != nil {
					append(quads, render.Quad{
						x = src.x, y = src.y, w = src.w, h = src.h,
						color = {1, 1, 1, 1},
						texture = d.srv,
					})
				}
			}

	}
}
