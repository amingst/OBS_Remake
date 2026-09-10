package encode

import win32 "core:sys/windows"
import "core:sync"
import "core:log"

Consumer :: struct {
	// put takes ownership of exactly one reference
	// regardless of whether the group is dropped
	// or kept.
	put_video: proc(ctx: rawptr, g: ^Frame_Group),
    put_audio: proc(ctx: rawptr, g: ^Frame_Group),
	ctx: rawptr,
	event: win32.HANDLE
}

consumer_add :: proc(e: ^Encoder, c: Consumer) -> bool {
	assert(c.ctx != nil, "consumer ctx must be non-nil")

	sync.lock(&e.consumers_mutex)
	defer sync.unlock(&e.consumers_mutex)

	if e.consumer_count == len(e.consumers) {
		log.errorf("consumer_add: array full (%d)", e.consumer_count)
		return false
	}
	for consumer in e.consumers[:e.consumer_count] {
		assert(consumer.ctx != c.ctx, "consumer already registered")
	}

	e.consumers[e.consumer_count] = c
	e.consumer_count += 1
	return true
}

consumer_remove :: proc(e: ^Encoder, ctx: rawptr) -> bool {
	assert(ctx != nil, "consumer ctx must be non-nil")

	sync.lock(&e.consumers_mutex)
	defer sync.unlock(&e.consumers_mutex)

	for i in 0 ..< e.consumer_count {
		if e.consumers[i].ctx == ctx {
			e.consumers[i] = e.consumers[e.consumer_count - 1]
			e.consumers[e.consumer_count - 1] = {}
			e.consumer_count -= 1
			return true
		}
	}

	log.errorf("consumer_remove: ctx not registered")
	return false
}
