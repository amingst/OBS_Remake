package obs_remake

import "core:log"
import "vendor:directx/d3d11"

import "render"
import "settings"

// Video settings currently built into live GPU resources.
Applied :: struct {
	video: settings.Video_Settings,
}

// Brings the render target in line with the desired profile's video settings.
reconcile :: proc(applied: ^Applied, desired: ^settings.Profile, device: ^d3d11.IDevice, target: ^render.Target, output_active: bool) {
	// Canvas resolution
	if desired.video.canvas_width  != applied.video.canvas_width ||
	   desired.video.canvas_height != applied.video.canvas_height {
		if output_active {
			// Can't resize the canvas while an output is active.
			log.warnf("ignoring canvas resolution change %vx%v -> %vx%v while output is active, keeping %vx%v",
				applied.video.canvas_width, applied.video.canvas_height,
				desired.video.canvas_width, desired.video.canvas_height,
				applied.video.canvas_width, applied.video.canvas_height)
			desired.video.canvas_width  = applied.video.canvas_width
			desired.video.canvas_height = applied.video.canvas_height
		} else if desired.video.canvas_width <= 0 || desired.video.canvas_height <= 0 {
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
