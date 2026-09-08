package encode

import "core:testing"
import "core:sync"
import "core:slice"

@(test)
pool_round_trip :: proc(t: ^testing.T) {
	pool: Frame_Pool
	if !pool_init(&pool, 4, 256) {
		testing.expect(t, false, "pool_init failed")
		return
	}
	defer pool_destroy(&pool)

	g, ok := pool_acquire(&pool)
	testing.expect(t, ok, "pool_acquire failed")
	if !ok do return

	group_reset(g)
	g.pts = 1000
	g.duration = 333
	g.is_keyframe = true

	nalu_a := []u8{0x65, 0x88, 0x84, 0x00}
	nalu_b := []u8{0x06, 0x01, 0x02}
	group_append_nalu(g, nalu_a)
	group_append_nalu(g, nalu_b)
	group_finish(g)

	testing.expect_value(t, len(g.nalus), 2)
	testing.expect(t, slice.equal(g.nalus[0], nalu_a), "nalu[0] bytes mismatch")
	testing.expect(t, slice.equal(g.nalus[1], nalu_b), "nalu[1] bytes mismatch")

	group_publish(g, 2)
	group_release(g)
	group_release(g)

	testing.expect_value(t, len(pool.free), 4)
}

@(test)
pool_buffer_growth_preserves_slices :: proc(t: ^testing.T) {
	pool: Frame_Pool
	if !pool_init(&pool, 1, 8) {
		testing.expect(t, false, "pool_init failed")
		return
	}
	defer pool_destroy(&pool)

	g, ok := pool_acquire(&pool)
	testing.expect(t, ok, "pool_acquire failed")
	if !ok do return

	group_reset(g)

	// Build 32 NALUs of increasing size so the buffer must grow well past 8.
	NALU_COUNT :: 32
	patterns: [NALU_COUNT]u8
	lengths:  [NALU_COUNT]int
	for i in 0 ..< NALU_COUNT {
		sz := 4 + i * 3
		lengths[i] = sz
		patterns[i] = u8(i)
		nalu := make([]u8, sz)
		defer delete(nalu)
		for &b in nalu {
			b = u8(i)
		}
		group_append_nalu(g, nalu)
	}

	group_finish(g)
	testing.expect_value(t, len(g.nalus), NALU_COUNT)

	for i in 0 ..< NALU_COUNT {
		testing.expect_value(t, len(g.nalus[i]), lengths[i])
		all_correct := true
		for b in g.nalus[i] {
			if b != patterns[i] {
				all_correct = false
				break
			}
		}
		testing.expect(t, all_correct, "byte content mismatch after buffer growth")
	}

	group_publish(g, 1)
	group_release(g)
}

@(test)
pool_exhaustion :: proc(t: ^testing.T) {
	N :: 4
	pool: Frame_Pool
	if !pool_init(&pool, N, 64) {
		testing.expect(t, false, "pool_init failed")
		return
	}
	defer pool_destroy(&pool)

	acquired: [N]^Frame_Group
	for i in 0 ..< N {
		g, ok := pool_acquire(&pool)
		testing.expect(t, ok, "pool_acquire should succeed")
		acquired[i] = g
	}

	extra, ok_extra := pool_acquire(&pool)
	testing.expect(t, extra == nil, "exhausted pool should return nil")
	testing.expect(t, !ok_extra, "exhausted pool should return false")

	// Clean up: publish and release all acquired slots.
	for i in 0 ..< N {
		group_publish(acquired[i], 1)
		group_release(acquired[i])
	}
}

@(test)
pool_reuse_after_release :: proc(t: ^testing.T) {
	N :: 4
	pool: Frame_Pool
	if !pool_init(&pool, N, 64) {
		testing.expect(t, false, "pool_init failed")
		return
	}
	defer pool_destroy(&pool)

	acquired: [N]^Frame_Group
	for i in 0 ..< N {
		g, ok := pool_acquire(&pool)
		testing.expect(t, ok)
		acquired[i] = g
	}

	for i in 0 ..< N {
		group_publish(acquired[i], 1)
		group_release(acquired[i])
	}

	for _ in 0 ..< N {
		g, ok := pool_acquire(&pool)
		testing.expect(t, ok, "second-round acquire should succeed")
		testing.expect(t, g != nil)
		testing.expect_value(t, sync.atomic_load(&g.refcount), u32(0))
		group_publish(g, 1)
		group_release(g)
	}
}

@(test)
pool_multiple_consumers :: proc(t: ^testing.T) {
	N :: 4
	pool: Frame_Pool
	if !pool_init(&pool, N, 64) {
		testing.expect(t, false, "pool_init failed")
		return
	}
	defer pool_destroy(&pool)

	g, ok := pool_acquire(&pool)
	testing.expect(t, ok)
	if !ok do return

	group_publish(g, 3)

	group_release(g)
	group_release(g)

	// After 2 releases the slot should NOT be back on the free list.
	testing.expect_value(t, len(pool.free), N - 1)

	group_release(g)

	// Now the slot should be recycled.
	testing.expect_value(t, len(pool.free), N)
}

@(test)
pool_publish_zero_consumers :: proc(t: ^testing.T) {
	pool: Frame_Pool
	if !pool_init(&pool, 4, 64) {
		testing.expect(t, false, "pool_init failed")
		return
	}
	defer pool_destroy(&pool)

	g, ok := pool_acquire(&pool)
	testing.expect(t, ok)
	if !ok do return

	result := group_publish(g, 0)
	testing.expect(t, !result, "publish with 0 consumers should return false")

	// Slot should already be back on the free list.
	testing.expect_value(t, len(pool.free), 4)
}

@(test)
pool_init_destroy_init :: proc(t: ^testing.T) {
	pool: Frame_Pool

	// First cycle.
	if !pool_init(&pool, 2, 64) {
		testing.expect(t, false, "first pool_init failed")
		return
	}

	g, ok := pool_acquire(&pool)
	testing.expect(t, ok)
	if ok {
		group_reset(g)
		group_append_nalu(g, []u8{0xAA, 0xBB})
		group_finish(g)
		group_publish(g, 1)
		group_release(g)
	}

	pool_destroy(&pool)

	// Second cycle — the "pool_init on a pool that was never destroyed"
	// assert must not fire.
	if !pool_init(&pool, 3, 128) {
		testing.expect(t, false, "second pool_init failed")
		return
	}
	defer pool_destroy(&pool)

	g2, ok2 := pool_acquire(&pool)
	testing.expect(t, ok2, "acquire after re-init should succeed")
	if ok2 {
		group_publish(g2, 1)
		group_release(g2)
	}

	testing.expect_value(t, len(pool.free), 3)
}
