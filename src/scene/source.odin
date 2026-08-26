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

Display_Data :: struct {
    output_index:    i32,
    adapter_index:   i32,
    dupl:            ^dxgi.IOutputDuplication,
    texture:         ^d3d11.ITexture2D,
    srv:             ^d3d11.IShaderResourceView,
    lost:            bool,
    next_retry:      time.Time,
    last_frame_time: time.Time, // wall-clock time of last new desktop frame
    stalled:         bool,      // true once we've logged a stall (>5s with no new frame)
}

Source_Data :: union {
    Color_Data,
    Display_Data,
    Audio_Data,
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

    d.lost = false
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
    }

    delete(src.name)
}
