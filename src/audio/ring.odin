package audio

import "base:intrinsics"

Ring :: struct {
    data: []f32,
    write: u32,
    read: u32
}

ring_init :: proc(r: ^Ring, capacity: int) {
    assert(capacity > 0 && capacity & (capacity - 1) == 0)
    r.data = make([]f32, capacity)
    r.write = 0
    r.read = 0
}

ring_destroy :: proc(r: ^Ring) {
    delete(r.data)
    r^ = {}
}

ring_write :: proc(r: ^Ring, src: []f32) -> (written: int) {
    cap_ := u32(len(r.data))
    mask := cap_ - 1
    rd := intrinsics.atomic_load_explicit(&r.read, .Acquire)
    wr := r.write

    space := cap_ - (wr - rd)
    n := u32(len(src))
    if n > space do n = space
    if n == 0 do return 0

    start := wr & mask
    first := min(n, cap_ - start)
    copy(r.data[start:start+first], src[:first])

    if n > first {
        copy(r.data[:n-first], src[first:n])
    }

    intrinsics.atomic_store_explicit(&r.write, wr + n, .Release)
    return int(n)
}

ring_read :: proc(r: ^Ring, dst: []f32) -> (read: int) {
    cap_ := u32(len(r.data))
    mask := cap_ - 1
    wr := intrinsics.atomic_load_explicit(&r.write, .Acquire)
    rd := r.read

    avail := wr - rd
    n := u32(len(dst))
    if n > avail do n = avail
    if n == 0 do return 0

    start := rd & mask
    first := min(n, cap_ - start)
    copy(dst[:first], r.data[start:start+first])
    if n > first {
        copy(dst[first:n], r.data[:n-first])
    }

    intrinsics.atomic_store_explicit(&r.read, rd + n, .Release)

    return int(n)
}

ring_available :: proc(r: ^Ring) -> int {
    wr := intrinsics.atomic_load_explicit(&r.write, .Acquire)
    return int(wr - r.read)
}