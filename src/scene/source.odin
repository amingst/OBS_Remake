package scene

import "core:log"
import "core:strings"
import "vendor:directx/d3d11"
import "vendor:directx/dxgi"
import time "core:time"
import "../audio"
import "../capture"

Audio_Params :: struct {
    volume: f32,
    muted: bool
}

Audio_Data :: struct {
    using params: Audio_Params,
    device_id: string,
    is_loopback: bool,
    stream: ^audio.Stream,
    next_retry: time.Time,
}

Color_Data :: struct {
}

// Loss is fully represented by dupl == nil plus next_retry -- there is no
// separate lost bool. A handle whose nil-ness already means "not currently
// acquired" doesn't need a second encoding of the same state; Image_Data and
// Window_Data need their own bool because their capture handles don't carry
// that meaning without one.
Display_Data :: struct {
    output_index:    i32,
    adapter_index:   i32,
    dupl:            ^dxgi.IOutputDuplication,
    texture:         ^d3d11.ITexture2D,
    srv:             ^d3d11.IShaderResourceView,
    next_retry:      time.Time,
    last_frame_time: time.Time, // wall-clock time of last new desktop frame
    stalled:         bool,      // true once we've logged a stall (>5s with no new frame)
}

Image_Data :: struct {
    path:    string,
    texture: ^d3d11.ITexture2D,
    srv:     ^d3d11.IShaderResourceView,
    width:   u32,
    height:  u32,
    lost:    bool,
}

Window_Data :: struct {
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

Camera_Data :: struct {
    symlink:       string,
    friendly_name: string,
    cam:           ^capture.Camera, // nil = not started; loss/reconnect is owned by the
                                    // reader thread (cam.lost, atomic), not encoded here
    texture:       ^d3d11.ITexture2D,
    srv:           ^d3d11.IShaderResourceView,
    width, height: u32,
}

Source_Data :: union {
    Color_Data,
    Display_Data,
    Audio_Data,
    Image_Data,
    Window_Data,
    Camera_Data
}

Source :: struct {
    id:      u64,
    name:    string,
    visible: bool,
    x, y:    f32,
    w, h:    f32,
    color:   [4]f32,
    data: Source_Data
}

create_source :: proc(c: ^Collection, s: ^Scene, name: string, kind: Source_Data) -> u64 {
    id := alloc_id(c)
    append(&s.sources, Source{
        id      = id,
        name    = strings.clone(name),
        visible = true,
        x       = 100,
        y       = 100,
        w       = 400,
        h       = 300,
        color   = {0.9, 0.3, 0.2, 1.0},
        data    = kind,
    })
    log.debugf("source added: id=%v name=%q scene=%v", id, name, s.id)
    return id
}

remove_source :: proc(s: ^Scene, index: int) -> u64 {
    log.debugf("source deleted: id=%v name=%q", s.sources[index].id, s.sources[index].name)
    removed_id := s.sources[index].id
    destroy_source(&s.sources[index])
    ordered_remove(&s.sources, index)
    return removed_id
}

find_source :: proc(s: ^Scene, id: u64) -> ^Source {
    for &src in s.sources {
        if src.id == id {
            return &src
        }
    }

    return nil
}

reset_display_capture :: proc(d: ^Display_Data) {
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

destroy_source :: proc(src: ^Source) {
    if src == nil { return }
    switch &d in src.data {
        case Color_Data:
            // Nothing to release
        case Display_Data:
            reset_display_capture(&d)
        case Audio_Data:
            if d.stream != nil {
                audio.release_stream(d.device_id)
                d.stream = nil
            }
            delete(d.device_id)
        case Image_Data:
            if d.srv != nil do d.srv->Release()
            if d.texture != nil do d.texture->Release()
            if d.path != "" do delete(d.path)
        case Window_Data:
            if d.capture != nil do capture.stop_window_capture(d.capture)
            if d.title != "" do delete(d.title)
            if d.class_name != "" do delete(d.class_name)
            if d.exe_name != "" do delete(d.exe_name)
        case Camera_Data:
            if d.cam != nil do capture.camera_stop(d.cam)
            if d.texture != nil do d.texture->Release()
            if d.srv != nil do d.srv->Release()
            if d.symlink != "" do delete(d.symlink)
            if d.friendly_name != "" do delete(d.friendly_name)
    }

    delete(src.name)
}
