package obs_remake

import "core:log"
import "vendor:directx/d3d11"

import "render"
import "settings"

// Deliberately a Video_Settings and not a Profile: this mirrors what has
// actually been built on the device, and nothing in a Profile outside `video`
// drives a resource -- id and name have no live counterpart to reconcile
// against, so holding them here would only be a second copy to keep in sync.
Applied :: struct {
	video: settings.Video_Settings,
}

reconcile :: proc(applied: ^Applied, desired: ^settings.Profile, device: ^d3d11.IDevice, target: ^render.Target, recording: bool) {
	// Canvas resolution
	if desired.video.canvas_width  != applied.video.canvas_width ||
	   desired.video.canvas_height != applied.video.canvas_height {
		if recording {
			// The encoder was configured with the applied dimensions; resizing
			// the target out from under it mid-stream would break the
			// recording. Revert desired rather than just skipping the block,
			// so this check doesn't re-fire every frame for as long as
			// recording continues -- same shape as the invalid-resolution
			// case below.
			log.warnf("ignoring canvas resolution change %vx%v -> %vx%v while recording, keeping %vx%v",
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
