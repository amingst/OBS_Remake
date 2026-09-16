package show

import "core:log"
import "core:strings"
import time "core:time"
import "vendor:directx/d3d11"
import "vendor:directx/dxgi"

import "../audio"
import "../capture"

Audio_Source_Params :: struct {
    volume: f32,
    muted: bool
}

Audio_Source_Data :: struct {
    using params: Audio_Source_Params,
    device_id: string,
    is_loopback: bool,
    stream: ^audio.Stream,
    next_retry: time.Time,
}

Camera_Source_Data :: struct {
    symlink:       string,
    friendly_name: string,
    cam:           ^capture.Camera, // nil = not started; loss/reconnect is owned by the
                                    // reader thread (cam.lost, atomic), not encoded here
    texture:       ^d3d11.ITexture2D,
    srv:           ^d3d11.IShaderResourceView,
    width, height: u32,
}

Color_Source_Data :: struct {
}

Display_Source_Data :: struct {
    output_index:    i32,
    adapter_index:   i32,
    dupl:            ^dxgi.IOutputDuplication,
    texture:         ^d3d11.ITexture2D,
    srv:             ^d3d11.IShaderResourceView,
    next_retry:      time.Time,
    last_frame_time: time.Time, // wall-clock time of last new desktop frame
    stalled:         bool,      // true once we've logged a stall (>5s with no new frame)
}

Image_Source_Data :: struct {
    path:    string,
    texture: ^d3d11.ITexture2D,
    srv:     ^d3d11.IShaderResourceView,
    width:   u32,
    height:  u32,
    lost:    bool,
}

Window_Source_Data :: struct {
    title:        string,
    class_name:   string,
    exe_name:     string,
    capture:      ^capture.Window_Capture,
    lost:         bool,
    next_retry:   time.Time,
    game_capture: bool, // prefers likely-game windows in the picker's default filter; also forces cursor capture off regardless of hide_cursor -- see main.odin
    hide_cursor:  bool,
    hide_border:  bool,
}

Show_Source_Data :: union {
    Audio_Source_Data,
    Camera_Source_Data,
    Color_Source_Data,
    Display_Source_Data,
    Image_Source_Data,
    Window_Source_Data,
}

Show_Source :: struct {
	id: string,	// UUID v4
	name: string, // display name
	data: Show_Source_Data,
}

// Adds a source to the show's inventory only -- it isn't visible anywhere
// until placed into a scene with place_source.
create_source :: proc(s: ^Show, name: string, data: Show_Source_Data) -> string {
	id := new_id()
	append(&s.sources, Show_Source{
		id   = id,
		name = strings.clone(name),
		data = data,
	})
	log.debugf("show source created: id=%v name=%q", id, name)
	return id
}

// Tears down a display source's capture state (e.g. when its output picker
// changes) without touching the rest of the source. Mirrors scene.reset_display_capture.
reset_display_capture :: proc(d: ^Display_Source_Data) {
	if d.srv != nil {
		d.srv->Release()
		d.srv = nil
	}
	if d.texture != nil {
		d.texture->Release()
		d.texture = nil
	}
	capture.stop_duplication(d.dupl)
	d.dupl = nil

	d.next_retry = {}
	d.last_frame_time = {}
	d.stalled = false
}

// Releases live capture/audio resources in addition to owned strings --
// mirrors scene.destroy_source, since Show_Source_Data carries the same
// runtime handles (D3D views, camera/window capture, audio streams).
destroy_source :: proc(src: ^Show_Source) {
	if src == nil do return

	switch &d in src.data {
	case Color_Source_Data:
		// Nothing to release
	case Display_Source_Data:
		if d.srv != nil {
			d.srv->Release()
			d.srv = nil
		}
		if d.texture != nil {
			d.texture->Release()
			d.texture = nil
		}
		capture.stop_duplication(d.dupl)
		d.dupl = nil
	case Audio_Source_Data:
		if d.stream != nil {
			audio.release_stream(d.device_id)
			d.stream = nil
		}
		delete(d.device_id)
	case Image_Source_Data:
		if d.srv != nil do d.srv->Release()
		if d.texture != nil do d.texture->Release()
		if d.path != "" do delete(d.path)
	case Window_Source_Data:
		if d.capture != nil do capture.stop_window_capture(d.capture)
		if d.title != "" do delete(d.title)
		if d.class_name != "" do delete(d.class_name)
		if d.exe_name != "" do delete(d.exe_name)
	case Camera_Source_Data:
		if d.cam != nil do capture.camera_stop(d.cam)
		if d.texture != nil do d.texture->Release()
		if d.srv != nil do d.srv->Release()
		if d.symlink != "" do delete(d.symlink)
		if d.friendly_name != "" do delete(d.friendly_name)
	}

	delete(src.id)
	delete(src.name)
}
