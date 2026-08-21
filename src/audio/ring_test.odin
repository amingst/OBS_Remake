package audio

import "core:testing"

@(test)
ring_roundtrip :: proc(t: ^testing.T) {
    r: Ring
    ring_init(&r, 64)
    defer ring_destroy(&r)

    src := [10]f32{1, 2, 3, 4, 5, 6, 7, 8, 9, 10}
    n := ring_write(&r, src[:])
    testing.expect_value(t, n, 10)

    dst: [10]f32
    m := ring_read(&r, dst[:])
    testing.expect_value(t, m, 10)
    testing.expect_value(t, dst, src)
}

@(test)
ring_wraps :: proc(t: ^testing.T) {
    r: Ring
    ring_init(&r, 64)
    defer ring_destroy(&r)

    src, dst: [8]f32
    for i in 0..<1000 {
        for j in 0..<8 do src[j] = f32(i*8 + j)
        testing.expect_value(t, ring_write(&r, src[:]), 8)
        testing.expect_value(t, ring_read(&r, dst[:]), 8)
        testing.expect_value(t, dst, src)
    }
}