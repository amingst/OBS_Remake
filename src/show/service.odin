package show

import "core:log"
import "core:sys/windows"
import "core:time"
import "vendor:directx/d3d11"
import "vendor:directx/dxgi"
import "../audio"
import "../applog"
import "../capture"
import "../render"

find_source :: proc(s: ^Show, id: string) -> ^Show_Source {
	for &src in s.sources {
		if src.id == id {
			return &src
		}
	}
	return nil
}

find_scene :: proc(s: ^Show, id: string) -> ^Show_Scene {
	for &sc in s.scenes {
		if sc.id == id {
			return &sc
		}
	}
	return nil
}

// Services the whole show once per frame. Audio is continuous and
// show-scoped -- every audio source anywhere in the show keeps its stream
// open regardless of which scene is selected, unlike scene.service_sources,
// which only visited the active scene and so silently orphaned streams on
// switch instead of releasing or keeping them (see the show file spec).
// Video/quad servicing (display/window/camera/image capture) stays scoped to
// the active scene's placements, since that's what's actually on screen.
service_show :: proc(
	s: ^Show, selected_scene_id: string,
	device: ^d3d11.IDevice, device_context: ^d3d11.IDeviceContext,
	log_sink: ^applog.Sink,
	quads: ^[dynamic]render.Quad, inputs: ^[dynamic]audio.Mix_Input,
) {
	service_audio(s, selected_scene_id, inputs)

	sel := find_scene(s, selected_scene_id)
	if sel == nil do return

	for &p in sel.sources {
		if !p.visible do continue
		src := find_source(s, p.source_id)
		if src == nil do continue

		#partial switch &d in src.data {
		case Color_Source_Data:
			append(quads, render.Quad{
				x = p.x, y = p.y, w = p.w, h = p.h,
				color = p.color,
			})
		case Image_Source_Data:
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
					x = p.x, y = p.y, w = p.w, h = p.h,
					color = {1, 1, 1, 1},
					texture = d.srv,
				})
			}
		case Display_Source_Data:
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
				x = p.x, y = p.y, w = p.w, h = p.h,
				color = {1, 1, 1, 1},
				texture = d.srv,
			})
		case Window_Source_Data:
			if d.capture != nil && capture.window_capture_lost(d.capture) && !d.lost {
				log.warnf("window source: %q lost", d.title)
				d.lost = true
				d.next_retry = time.time_add(time.now(), 500 * time.Millisecond)
			}
			// Nothing to capture until the picker supplies an identity.
			has_identity := d.title != "" || d.class_name != "" || d.exe_name != ""
			if has_identity && (d.capture == nil || d.lost) && time.now()._nsec >= d.next_retry._nsec {
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
					x = p.x, y = p.y, w = p.w, h = p.h,
					color = {1, 1, 1, 1},
					texture = d.capture.srv,
				})
			}
		case Camera_Source_Data:
			// Lazy start: first visible frame with a device set spawns the reader.
			if d.cam == nil && d.symlink != "" {
				wide := windows.utf8_to_utf16(d.symlink, context.temp_allocator)
				d.cam = capture.camera_start(wide, log_sink, camera_tag_from_id(src.id))
			}
			// Per-frame upload: pull the latest CPU frame onto the dynamic texture.
			if d.cam != nil {
				capture.camera_upload(d.cam, device, &d.texture, &d.srv, &d.width, &d.height)
			}
			if d.srv != nil {
				append(quads, render.Quad{
					x = p.x, y = p.y, w = p.w, h = p.h,
					color = {1, 1, 1, 1},
					texture = d.srv,
				})
			}
		}
	}
}

@(private = "file")
service_audio :: proc(s: ^Show, selected_scene_id: string, inputs: ^[dynamic]audio.Mix_Input) {
	for &src in s.sources {
		#partial switch &d in src.data {
		case Audio_Source_Data:
			if d.stream == nil && d.device_id != "" && time.now()._nsec >= d.next_retry._nsec {
				if strm := audio.acquire_stream(d.device_id, d.is_loopback); strm != nil {
					d.stream = strm
					if strm.sample_rate != 48000 {
						log.warnf("audio stream %v reports %v Hz, expected 48000 — recording may be pitch-shifted", d.device_id, strm.sample_rate)
					}
				} else {
					d.next_retry = time.time_add(time.now(), 2 * time.Second)
				}
			}
			if d.stream == nil do continue

			// Not placed in the active scene at all -- silent by omission,
			// never by tearing the stream down (that's what caused the
			// orphaned-stream bug in the old scene-scoped servicing).
			placed, muted_here := find_placement_mute(s, selected_scene_id, src.id)
			if !placed do continue

			append(inputs, audio.Mix_Input{
				stream = d.stream,
				volume = d.params.volume,
				muted  = d.params.muted || muted_here,
			})
		}
	}
}

@(private = "file")
find_placement_mute :: proc(s: ^Show, scene_id, source_id: string) -> (placed, muted: bool) {
	sc := find_scene(s, scene_id)
	if sc == nil do return false, false
	for p in sc.sources {
		if p.source_id == source_id {
			return true, p.mute_override
		}
	}
	return false, false
}

// next_camera_tag_index wants a u64; show source ids are UUID strings, so
// derive a differentiator tag by summing bytes instead. It's only used to
// vary a debug/thread tag across cameras, not for identity, so collisions
// are harmless.
@(private = "file")
camera_tag_from_id :: proc(id: string) -> u8 {
	sum: u8 = 0
	for b in transmute([]u8)id {
		sum += b
	}
	return capture.next_camera_tag_index(u64(sum))
}
