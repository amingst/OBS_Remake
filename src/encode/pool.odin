package encode

import "base:runtime"
import "core:sync"
import "core:log"
import "base:intrinsics"

Nalu_Span :: struct {
	start:		int,
	length:		int,
}

Frame_Group :: struct {
	refcount:		u32,
	pts:			i64,
	duration:		i64,
	is_keyframe:	bool,
	buf:			[dynamic]u8,
	nalus:			[dynamic][]u8,
	pool:			^Frame_Pool,
	index:			int,
	offsets:		[dynamic]Nalu_Span,
}

Frame_Pool :: struct {
	slots:		[]Frame_Group,
	free:		[dynamic]int,
	min_free:	int,
	mutex:		sync.Mutex
}


@(private)
pool_init    :: proc(pool: ^Frame_Pool, slot_count: int, initial_buf_cap: int) -> bool {
	assert(pool.slots == nil, "pool_init on a pool that was never destroyed")
	err: runtime.Allocator_Error
	pool.slots, err = make([]Frame_Group, slot_count)
	if err != nil {
		log.error("Error allocating pool slots")
		pool_destroy(pool)
		return false
	}

	for &slot, i in pool.slots {
		assert(sync.atomic_load(&slot.refcount) == 0, "pool_destroy with groups still outstanding")
	    slot.buf, err = make([dynamic]u8, 0, initial_buf_cap)
	    if err != nil {
			log.errorf("pool_init: slot %d buffer (%d bytes) failed", i, initial_buf_cap)
	        pool_destroy(pool)
	        return false
	    }
	    slot.nalus, err = make([dynamic][]u8, 0, 16)
	    if err != nil {
			log.errorf("pool_init: nalus %d buffer (%d bytes) failed", i, initial_buf_cap)
	        pool_destroy(pool)
	        return false
	    }
	    slot.offsets, err = make([dynamic]Nalu_Span, 0, 16)
	    if err != nil {
			log.errorf("pool_init: offsets %d buffer (%d bytes) failed", i, initial_buf_cap)
	        pool_destroy(pool)
	        return false
	    }
	    slot.pool = pool
	    slot.refcount = 0
	    slot.index = i
	}

	pool.free, err = make([dynamic]int, 0, slot_count)
	if err != nil {
		log.error("Error allocating free slots on pool")
		pool_destroy(pool)
		return false
	}

	for i in 0 ..< slot_count {
		append(&pool.free, i)
	}

	pool.min_free = slot_count
	return true
}

@(private)
pool_destroy :: proc(pool: ^Frame_Pool) {
	for &slot in pool.slots {
		delete(slot.buf)
		delete(slot.nalus)
		delete(slot.offsets)
	}
	delete(pool.free)
	delete(pool.slots)
	pool^ = {}
}

@(private)
pool_acquire :: proc(pool: ^Frame_Pool) -> (^Frame_Group, bool){   // encoder thread only
	sync.mutex_lock(&pool.mutex)
	defer sync.mutex_unlock(&pool.mutex)
	if len(pool.free) == 0 {
		return nil, false
	}
	index := pop(&pool.free)
	slot := &pool.slots[index]
	assert(sync.atomic_load(&slot.refcount) == 0, "acquired a slot with a live refcount")
	return slot, true
}

@(private)
pool_recycle :: proc(g: ^Frame_Group) {
	pool := g.pool
	assert(g.index >= 0 && g.index < len(pool.slots))
	assert(g == &pool.slots[g.index], "frame group is not the slot it claims to be")
	sync.mutex_lock(&pool.mutex)
	append(&pool.free, g.index)
	sync.mutex_unlock(&pool.mutex)
}

@(private)
pool_free_count :: proc(pool: ^Frame_Pool) -> int {
	sync.mutex_lock(&pool.mutex)
	defer sync.mutex_unlock(&pool.mutex)
	return len(pool.free)
}

group_release :: proc(g: ^Frame_Group) {
	// any consumer thread
	prev := sync.atomic_sub_explicit(&g.refcount, 1, .Release)
	assert(prev != 0, "double release of frame group")
	if prev == 1 {
		intrinsics.atomic_thread_fence(.Acquire)
		pool_recycle(g)
	}
}

group_reset       :: proc(g: ^Frame_Group) {
	clear(&g.buf)
	clear(&g.nalus)
	clear(&g.offsets)
}

group_append_nalu :: proc(g: ^Frame_Group, nalu: []u8) {
	// append bytes, then push subslice
	append(&g.offsets, Nalu_Span{start = len(g.buf), length = len(nalu)})
	append(&g.buf, ..nalu)
}

group_finish :: proc(g: ^Frame_Group) {
	// build nalus[] from recorded offsets
	clear(&g.nalus)
	for span in g.offsets {
		append(&g.nalus, g.buf[span.start:][:span.length])
	}
}

@(private)
group_publish :: proc(g: ^Frame_Group, consumer_count: int) -> bool {
	if consumer_count <= 0 {
		pool_recycle(g)
		return false
	}

	sync.atomic_store_explicit(&g.refcount, u32(consumer_count), .Release)
	return true
}
