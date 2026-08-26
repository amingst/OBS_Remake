package audio

import "core:strings"
import "core:log"

@(private)
Stream_Entry :: struct {
    key: string,
    stream: ^Stream,
    refcount: int
}

@(private) g_streams: map[string]Stream_Entry

acquire_stream :: proc(device_id: string, is_loopback: bool) -> ^Stream {
    if device_id == "" do return nil

    if entry, found := &g_streams[device_id]; found {
        entry.refcount += 1
        log.debugf("audio stream %v refcount -> %v", device_id, entry.refcount)
        return entry.stream
    }

    s := new(Stream)
    if !open_stream(s, device_id, is_loopback) {
        free(s)
        return nil
    }

    key := strings.clone(device_id)
    g_streams[key] = Stream_Entry{key = key, stream = s, refcount = 1}
    return s
}

release_stream :: proc(device_id: string) {
    entry, found := &g_streams[device_id]
    if !found {
        log.warnf("release_stream: no stream for %v", device_id)
        return
    }

    entry.refcount -= 1
    if entry.refcount > 0 do return

    key := entry.key
    close_stream(entry.stream)
    free(entry.stream)
    delete_key(&g_streams, device_id)
    delete(key)
}
