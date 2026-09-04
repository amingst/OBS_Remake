package applog

import "core:fmt"
import "core:log"
import "core:testing"

@(test)
partial_ring_does_not_underflow :: proc(t: ^testing.T) {
	sink := sink_init(8)
	defer sink_destroy(sink)

	for i in 0 ..< 3 {
		sink_push(sink, .Info, {.Main, 0}, fmt.tprintf("early %d", i))
	}

	oldest, newest, count := sink_range(sink)
	testing.expect_value(t, oldest, u64(0))
	testing.expect_value(t, newest, u64(3))
	testing.expect_value(t, count, u64(3))
}

@(test)
wrapped_ring_reports_live_window :: proc(t: ^testing.T) {
	sink := sink_init(8)
	defer sink_destroy(sink)

	for i in 0 ..< 20 {
		sink_push(sink, .Info, {.Main, 0}, fmt.tprintf("message %d", i))
	}

	oldest, newest, count := sink_range(sink)
	testing.expect_value(t, oldest, u64(12))
	testing.expect_value(t, newest, u64(20))
	testing.expect_value(t, count, u64(8))
}

@(test)
read_rejects_evicted_and_future :: proc(t: ^testing.T) {
	sink := sink_init(8)
	defer sink_destroy(sink)

	for i in 0 ..< 20 {
		sink_push(sink, .Info, {.Main, 0}, fmt.tprintf("message %d", i))
	}

	_, ok_evicted := sink_read(sink, 11)
	testing.expect(t, !ok_evicted, "seq 11 should be evicted")

	_, ok_future := sink_read(sink, 20)
	testing.expect(t, !ok_future, "seq 20 has not been written")

	_, ok_live := sink_read(sink, 12)
	testing.expect(t, ok_live, "seq 12 should be the oldest live entry")
}

@(test)
entry_fields_round_trip :: proc(t: ^testing.T) {
	sink := sink_init(8)
	defer sink_destroy(sink)

	sink_push(sink, .Warning, {.Rtmp, 2}, "publish failed")

	entry, ok := sink_read(sink, 0)
	testing.expect(t, ok, "seq 0 should be live")
	testing.expect_value(t, entry.seq, u64(0))
	testing.expect_value(t, entry.level, log.Level.Warning)
	testing.expect_value(t, entry.tag.cat, Category.Rtmp)
	testing.expect_value(t, entry.tag.index, u8(2))
	testing.expect_value(t, string(entry.text[:entry.len]), "publish failed")
	testing.expect(t, entry.when_ > 0, "timestamp should be populated")
}

@(test)
overwrite_does_not_expose_stale_bytes :: proc(t: ^testing.T) {
	sink := sink_init(1)
	defer sink_destroy(sink)

	sink_push(sink, .Info, {.Main, 0}, "a very long first message indeed")
	sink_push(sink, .Info, {.Main, 0}, "short")

	entry, ok := sink_read(sink, 1)
	testing.expect(t, ok, "seq 1 should be live")
	testing.expect_value(t, string(entry.text[:entry.len]), "short")
}

@(test)
long_message_truncates_to_capacity :: proc(t: ^testing.T) {
	sink := sink_init(4)
	defer sink_destroy(sink)

	long := make([]u8, 400)
	defer delete(long)
	for &b in long {
		b = 'x'
	}

	sink_push(sink, .Info, {.Main, 0}, string(long))

	entry, ok := sink_read(sink, 0)
	testing.expect(t, ok, "seq 0 should be live")
	testing.expect_value(t, entry.len, u16(240))
}
