package show

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
