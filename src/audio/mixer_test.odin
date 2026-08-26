// src/audio/mixer_test.odin
package audio

import "core:testing"

// A Stream with nothing but a ring -- mix_block only touches inp.stream.ring,
// so no COM objects or threads are needed to exercise the arithmetic.
@(private="file")
fake_stream :: proc(capacity: int) -> ^Stream {
    s := new(Stream)
    ring_init(&s.ring, capacity)
    return s
}

@(private="file")
destroy_fake :: proc(s: ^Stream) {
    ring_destroy(&s.ring)
    free(s)
}

// Fills a stream's ring with `count` interleaved samples, all the same value.
@(private="file")
fill :: proc(s: ^Stream, value: f32, count: int) {
    buf := make([]f32, count)
    defer delete(buf)
    for i in 0..<count do buf[i] = value
    ring_write(&s.ring, buf)
}

@(test)
mix_sums_sources :: proc(t: ^testing.T) {
    CH :: 2
    BLOCK :: BLOCK_SAMPLES * CH

    a := fake_stream(65536); defer destroy_fake(a)
    b := fake_stream(65536); defer destroy_fake(b)
    fill(a, 0.5, BLOCK)
    fill(b, 0.5, BLOCK)

    inputs := []Mix_Input{
        {stream = a, volume = 1.0},
        {stream = b, volume = 1.0},
    }

    dst := make([]f32, BLOCK); defer delete(dst)
    testing.expect(t, mix_block(inputs, dst, CH), "expected a block")
    testing.expect_value(t, dst[0], f32(1.0))
    testing.expect_value(t, dst[BLOCK-1], f32(1.0))
}

@(test)
mix_applies_volume :: proc(t: ^testing.T) {
    CH :: 2
    BLOCK :: BLOCK_SAMPLES * CH

    a := fake_stream(65536); defer destroy_fake(a)
    fill(a, 1.0, BLOCK)

    inputs := []Mix_Input{{stream = a, volume = 0.5}}

    dst := make([]f32, BLOCK); defer delete(dst)
    testing.expect(t, mix_block(inputs, dst, CH), "expected a block")
    testing.expect_value(t, dst[0], f32(0.5))
}

// A muted source must still consume its ring, or unmuting would play a backlog
// of stale audio and the ring would eventually overflow.
@(test)
mix_muted_drains_but_is_silent :: proc(t: ^testing.T) {
    CH :: 2
    BLOCK :: BLOCK_SAMPLES * CH

    a := fake_stream(65536); defer destroy_fake(a)
    fill(a, 1.0, BLOCK * 2)

    inputs := []Mix_Input{{stream = a, volume = 1.0, muted = true}}

    dst := make([]f32, BLOCK); defer delete(dst)
    before := ring_available(&a.ring)

    testing.expect(t, mix_block(inputs, dst, CH), "expected a block")
    testing.expect_value(t, dst[0], f32(0))

    after := ring_available(&a.ring)
    testing.expect_value(t, before - after, BLOCK)
}

// One stalled source must not stop the mix -- it contributes silence and the
// ready sources still come through.
@(test)
mix_skips_empty_source :: proc(t: ^testing.T) {
    CH :: 2
    BLOCK :: BLOCK_SAMPLES * CH

    ready := fake_stream(65536); defer destroy_fake(ready)
    empty := fake_stream(65536); defer destroy_fake(empty)
    fill(ready, 0.25, BLOCK)

    inputs := []Mix_Input{
        {stream = ready, volume = 1.0},
        {stream = empty, volume = 1.0},
    }

    dst := make([]f32, BLOCK); defer delete(dst)
    testing.expect(t, mix_block(inputs, dst, CH), "expected a block")
    testing.expect_value(t, dst[0], f32(0.25))
}

@(test)
mix_returns_false_when_nothing_ready :: proc(t: ^testing.T) {
    CH :: 2
    BLOCK :: BLOCK_SAMPLES * CH

    a := fake_stream(65536); defer destroy_fake(a)
    // One sample short of a full block.
    fill(a, 1.0, BLOCK - 1)

    inputs := []Mix_Input{{stream = a, volume = 1.0}}

    dst := make([]f32, BLOCK); defer delete(dst)
    testing.expect(t, !mix_block(inputs, dst, CH), "expected no block")
}

@(test)
mix_clamps :: proc(t: ^testing.T) {
    CH :: 2
    BLOCK :: BLOCK_SAMPLES * CH

    a := fake_stream(65536); defer destroy_fake(a)
    b := fake_stream(65536); defer destroy_fake(b)
    c := fake_stream(65536); defer destroy_fake(c)
    fill(a, 0.8, BLOCK)
    fill(b, 0.8, BLOCK)
    fill(c, 0.8, BLOCK)

    inputs := []Mix_Input{
        {stream = a, volume = 1.0},
        {stream = b, volume = 1.0},
        {stream = c, volume = 1.0},
    }

    dst := make([]f32, BLOCK); defer delete(dst)
    testing.expect(t, mix_block(inputs, dst, CH), "expected a block")
    // 2.4 unclamped.
    testing.expect_value(t, dst[0], f32(1.0))
}

@(test)
mix_no_inputs :: proc(t: ^testing.T) {
    dst := make([]f32, BLOCK_SAMPLES * 2); defer delete(dst)
    testing.expect(t, !mix_block(nil, dst, 2), "expected no block with no inputs")
}