package obs_remake

import "core:log"
import "vendor:directx/d3d11"

import "render"
import "settings"

Applied :: struct {
	video: settings.Video_Settings,
}

reconcile :: proc(applied: ^Applied, desired: ^settings.Settings, device: ^d3d11.IDevice, target: ^render.Target) {
	// Canvas resolution
	if desired.video.canvas_width  != applied.video.canvas_width ||
	   desired.video.canvas_height != applied.video.canvas_height {
		if desired.video.canvas_width <= 0 || desired.video.canvas_height <= 0 {
			log.warnf("ignoring invalid canvas resolution %vx%v, keeping %vx%v",
				desired.video.canvas_width, desired.video.canvas_height,
				applied.video.canvas_width, applied.video.canvas_height)
			desired.video.canvas_width  = applied.video.canvas_width
			desired.video.canvas_height = applied.video.canvas_height
		} else if new_target, new_ok := render.create_target(
			device, u32(desired.video.canvas_width), u32(desired.video.canvas_height)); new_ok {
			log.infof("canvas resolution %vx%v -> %vx%v",
				target.width, target.height, new_target.width, new_target.height)
			render.destroy_target(target)
			target^ = new_target
			applied.video.canvas_width  = desired.video.canvas_width
			applied.video.canvas_height = desired.video.canvas_height
		} else {
			log.errorf("canvas resize to %vx%v failed, staying at %vx%v (cause logged above)",
				desired.video.canvas_width, desired.video.canvas_height,
				applied.video.canvas_width, applied.video.canvas_height)
			desired.video.canvas_width  = applied.video.canvas_width
			desired.video.canvas_height = applied.video.canvas_height
		}
	}

	if desired.video.fps != applied.video.fps {
		applied.video.fps = desired.video.fps
	}
}
