package applog

import "core:log"
import "core:sync"
import "core:time"
import "core:fmt"
import "core:os"

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
	entries: 	  []Entry,
	total: 		  u64,
	mutex: 		  sync.Mutex,
	file:         ^os.File,      // owned by the sink: opened in sink_open_file, closed in sink_destroy
	file_ok:      bool,
	file_scratch: [320]u8,       // formatting scratch for the file line -- sink_push runs on the audio thread and must not touch the temp allocator
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
	if sink.file_ok {
		os.close(sink.file)
	}
	if sink.entries != nil {
		delete(sink.entries)
	}
	free(sink)
}

// sink_open_file opens the sink's log file. The sink owns the resulting
// handle from here on: sink_destroy is the only thing that closes it. This
// is deliberately the opposite of core:log's create_file_logger /
// destroy_file_logger, which closes a handle that was opened (and is owned)
// by the caller -- that contract doesn't fit a sink that outlives its logger.
//
// Failure is non-fatal: the sink keeps working with just the ring buffer and
// console, and the caller is told via the returned bool so it can say so once.
sink_open_file :: proc(sink: ^Sink, path: string) -> bool {
	f, err := os.open(path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
	if err != nil {
		return false
	}
	sink.file = f
	sink.file_ok = true
	return true
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

	// Written under the same lock as the ring push above, one formatted line
	// per call, so lines from concurrent threads can't interleave mid-string.
	// Console output (logger_proc, below) stays outside the lock.
	if sink.file_ok {
		t := time.Time{_nsec = entry.when_}
		year, month, day := time.date(t)
		hour, min, sec, nanos := time.precise_clock_from_time(t)
		ms := nanos / 1_000_000

		line := fmt.bprintf(
			sink.file_scratch[:],
			"%4d-%02d-%02d %02d:%02d:%02d.%03d [%s] %s[%d]: %s\n",
			year, int(month), day, hour, min, sec, ms,
			level_short(level), category_names[tag.cat], tag.index, msg,
		)
		os.write(sink.file, transmute([]u8)line)

		// Buffer normal writes -- flushing every line is a syscall on a
		// real-time (audio) thread. Flush on Error/Fatal so the last lines
		// before a crash are the ones guaranteed to survive it.
		if level >= log.Level.Error {
			os.flush(sink.file)
		}
	}
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
