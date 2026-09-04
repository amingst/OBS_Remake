package applog

import "core:log"
import "core:sync"
import "core:time"
import "core:fmt"

CONSOLE_OUTPUT :: true

Category :: enum u8 {
	Main, Audio, Encode, Capture, Rtmp, Ui,
}

Tag :: struct {
	cat: 	Category,
	index: 	u8
}

Entry :: struct {
	seq: 	u64,
	when_:	i64,
	level:	log.Level,
	len:	u16,
	tag:	Tag,
	text:	[240]u8,
}

Sink :: struct {
	entries: 	[]Entry,
	total: 		u64,
	mutex: 		sync.Mutex
}

Log_Context :: struct {
	sink: ^Sink,
	tag: Tag
}

sink_init :: proc(capacity: u64) -> ^Sink {
	assert(capacity > 0, "applog: sink capacity must be non-zero")

	sink, err := new(Sink)
	ensure(err == nil, "applog: failed to allocate log sink")

	sink.entries, err = make([]Entry, capacity)
	ensure(err == nil, "applog: failed to allocate entry ring")

	return sink
}

sink_destroy :: proc(sink: ^Sink) {
	if sink.entries != nil {
		delete(sink.entries)
	}
	free(sink)
}

sink_push :: proc(sink: ^Sink, level: log.Level, tag: Tag, msg: string) {
	sync.lock(&sink.mutex)
	defer sync.unlock(&sink.mutex)

	sink_cap := capacity(sink)

	entry := &sink.entries[sink.total % sink_cap]
	entry.level = level
	entry.tag = tag
	entry.seq = sink.total
	entry.len = u16(copy_from_string(entry.text[:], msg))
	entry.when_ = time.time_to_unix_nano(time.now())
	sink.total += 1
}

sink_read :: proc(sink: ^Sink, seq: u64) -> (Entry, bool) {
	sync.lock(&sink.mutex)
	defer sync.unlock(&sink.mutex)

	if seq >= sink.total {
		return {}, false
	}

	sink_cap := capacity(sink)
	if seq < oldest_live_seq(sink) {
		return {}, false
	}

	return sink.entries[seq % sink_cap], true
}

sink_range :: proc(sink: ^Sink) -> (oldest: u64, newest: u64, count: u64) {
	sync.lock(&sink.mutex)
	defer sync.unlock(&sink.mutex)

	oldest = oldest_live_seq(sink)
	newest = sink.total
	count = newest - oldest
	return
}

logger_proc :: proc(
	data:      rawptr,
	level:     log.Level,
	text:      string,
	options:   log.Options,
	location := #caller_location,
) {
	ctx := (^Log_Context)(data)
	sink_push(ctx.sink, level, ctx.tag, text)

	when CONSOLE_OUTPUT {
		if ctx.tag.index == 0 {
			fmt.eprintf("[%s] %s: %s\n", level_short(level), category_names[ctx.tag.cat], text)
		} else {
			fmt.eprintf("[%s] %s[%d]: %s\n", level_short(level), category_names[ctx.tag.cat], ctx.tag.index, text)
		}
	}
}

make_logger :: proc(ctx: ^Log_Context) -> log.Logger {
	return log.Logger{
		procedure = logger_proc,
		data = ctx,
		lowest_level = ODIN_DEBUG ? .Debug : .Info,
		options = {}
	}
}

@(private="file")
category_names := [Category]string{
	.Main = "main", .Audio = "audio", .Encode = "encode",
	.Capture = "capture", .Rtmp = "rtmp", .Ui = "ui",
}

@(private="file")
level_short :: proc(level: log.Level) -> string {
	switch level {
	case .Debug:   return "DBG"
	case .Info:    return "INF"
	case .Warning: return "WRN"
	case .Error:   return "ERR"
	case .Fatal:   return "FTL"
	case:          return "???"
	}
}

@(private="file")
capacity :: proc(sink: ^Sink) -> u64 {
    return u64(len(sink.entries))
}

@(private="file")
// Caller must hold the mutex
oldest_live_seq :: proc(sink: ^Sink) -> u64 {
	sink_cap := capacity(sink)
	if sink.total > sink_cap do return sink.total - sink_cap
	return 0
}
