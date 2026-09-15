package encode

import "core:testing"

@(test)
audio_queue_round_trip :: proc(t: ^testing.T) {
    STRIDE   :: 8
    CAPACITY :: 4

    q := audio_queue_init(CAPACITY, STRIDE)
    defer audio_queue_destroy(q)

    written := [STRIDE]u8{1, 2, 3, 4, 5, 6, 7, 8}
    ok := audio_queue_put(q, written[:], 1234)
    testing.expect(t, ok, "put should succeed on an empty queue")
    testing.expect(t, q.count == 1, "count should be 1 after one put")

    dst: [STRIDE]u8
    pts, take_ok := audio_queue_take(q, dst[:])
    testing.expect(t, take_ok, "take should succeed when a block is queued")
    testing.expect(t, pts == 1234, "pts should round-trip unchanged")
    testing.expect(t, q.count == 0, "count should be 0 after draining the only block")
    testing.expect(t, dst == written, "bytes should round-trip unchanged")
}

@(test)
audio_queue_empty_take_fails :: proc(t: ^testing.T) {
    STRIDE   :: 8
    CAPACITY :: 4

    q := audio_queue_init(CAPACITY, STRIDE)
    defer audio_queue_destroy(q)

    dst: [STRIDE]u8
    _, ok := audio_queue_take(q, dst[:])
    testing.expect(t, !ok, "take on an empty queue should fail")
}

@(test)
audio_queue_full_put_fails :: proc(t: ^testing.T) {
    STRIDE   :: 8
    CAPACITY :: 4

    q := audio_queue_init(CAPACITY, STRIDE)
    defer audio_queue_destroy(q)

    block: [STRIDE]u8
    for i in 0 ..< CAPACITY {
        ok := audio_queue_put(q, block[:], i64(i))
        testing.expect(t, ok, "put should succeed while the queue has room")
    }
    testing.expect(t, q.count == CAPACITY, "count should equal capacity once full")

    ok := audio_queue_put(q, block[:], 999)
    testing.expect(t, !ok, "put should fail once the queue is full")
    testing.expect(t, q.count == CAPACITY, "count should be unchanged after a rejected put")
}

@(test)
audio_queue_size_mismatch_rejected :: proc(t: ^testing.T) {
    STRIDE   :: 8
    CAPACITY :: 4

    q := audio_queue_init(CAPACITY, STRIDE)
    defer audio_queue_destroy(q)

    too_small: [STRIDE - 1]u8
    ok := audio_queue_put(q, too_small[:], 1)
    testing.expect(t, !ok, "put should reject a block shorter than stride")
    testing.expect(t, q.count == 0, "a rejected put should not change count")

    dst: [STRIDE - 1]u8
    _, take_ok := audio_queue_take(q, dst[:])
    testing.expect(t, !take_ok, "take should reject a dst shorter than stride")
}

@(test)
audio_queue_wraparound :: proc(t: ^testing.T) {
    STRIDE   :: 4
    CAPACITY :: 3

    q := audio_queue_init(CAPACITY, STRIDE)
    defer audio_queue_destroy(q)

    dst: [STRIDE]u8

    // Fill completely, then drain completely, then fill again -- forces
    // write_slot and read_slot each around the ring more than once and
    // confirms slot 0's storage is safe to reuse after being read.
    for cycle in 0 ..< 3 {
        for i in 0 ..< CAPACITY {
            block := [STRIDE]u8{u8(cycle), u8(i), 0xAA, 0xBB}
            ok := audio_queue_put(q, block[:], i64(cycle * CAPACITY + i))
            testing.expect(t, ok, "put should succeed while draining keeps the queue from filling")
        }
        testing.expect(t, q.count == CAPACITY, "queue should be full after filling one full cycle")

        for i in 0 ..< CAPACITY {
            pts, ok := audio_queue_take(q, dst[:])
            testing.expect(t, ok, "take should succeed for each block just written")
            expected := [STRIDE]u8{u8(cycle), u8(i), 0xAA, 0xBB}
            testing.expect(t, dst == expected, "bytes read back should match what was written, in order")
            testing.expect(t, pts == i64(cycle * CAPACITY + i), "pts read back should match write order")
        }
        testing.expect(t, q.count == 0, "queue should be empty after draining a full cycle")
    }
}
