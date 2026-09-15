package mp4

import mf "libs:mf"
import "core:log"
import "core:sync"
import "core:thread"
import "core:sys/windows"
import "core:time"
import "base:intrinsics"
import "../applog"
import "../encode"

// ~4s of buffering each. When full, excess groups spill to a heap-backed list
// instead of being dropped -- the ring is the fast path, spillover the safety net.
VIDEO_RING_DEPTH :: 256
AUDIO_RING_DEPTH :: 192

// Total heap spillover across both rings before the feeder auto-stops recording.
SPILLOVER_CEILING : u64 : 256 * 1024 * 1024

Sink_State :: enum u32 {
	Running,
	Stopping,
	Stopped,
}

// Heap copy of a video Frame_Group's encoded data, made when the ring is full.
Video_Spill_Entry :: struct {
	buf:      []u8,
	offsets:  []encode.Nalu_Span,
	pts:      i64,
	duration: i64,
}

// Heap copy of an audio Frame_Group's encoded data, same purpose.
Audio_Spill_Entry :: struct {
	buf:      []u8,
	pts:      i64,
	duration: i64,
}

Video_Ring :: struct {
	mutex:       sync.Mutex,
	count:       int,
	read_index:  int,
	write_index: int,
	ring:        [VIDEO_RING_DEPTH]^encode.Frame_Group,
	spillover:   [dynamic]Video_Spill_Entry,
	spill_bytes: u64,
	spill_count: u32,
}

Audio_Ring :: struct {
	mutex:       sync.Mutex,
	count:       int,
	read_index:  int,
	write_index: int,
	ring:        [AUDIO_RING_DEPTH]^encode.Frame_Group,
	spillover:   [dynamic]Audio_Spill_Entry,
	spill_bytes: u64,
	spill_count: u32,
}

video_ring_destroy :: proc(r: ^Video_Ring) {
	sync.lock(&r.mutex)
	defer sync.unlock(&r.mutex)
	for i in 0 ..< r.count {
		slot := (r.read_index + i) % len(r.ring)
		encode.group_release(r.ring[slot])
		r.ring[slot] = nil
	}
	r.count = 0
	for entry in r.spillover {
		delete(entry.buf)
		delete(entry.offsets)
	}
	delete(r.spillover)
}

// Queues g in the ring, or spills its encoded bytes to heap if full. Runs on
// the encoder thread; must not block, log, or take any lock besides r.mutex.
// Returns spillover bytes added (0 when queued in the ring).
video_ring_put :: proc(r: ^Video_Ring, g: ^encode.Frame_Group) -> u64 {
	sync.lock(&r.mutex)
	defer sync.unlock(&r.mutex)
	if r.count < len(r.ring) {
		r.ring[r.write_index] = g
		r.write_index = (r.write_index + 1) % len(r.ring)
		r.count += 1
		return 0
	}
	// Ring full — copy to heap, release pool ref.
	buf_len := len(g.buf)
	buf_copy := make([]u8, buf_len)
	copy(buf_copy, g.buf[:])
	off_len := len(g.offsets)
	offsets_copy := make([]encode.Nalu_Span, off_len)
	copy(offsets_copy, g.offsets[:])
	append(&r.spillover, Video_Spill_Entry{
		buf      = buf_copy,
		offsets  = offsets_copy,
		pts      = g.pts,
		duration = g.duration,
	})
	encode.group_release(g)
	bytes := u64(buf_len) + u64(off_len * size_of(encode.Nalu_Span))
	r.spill_bytes += bytes
	r.spill_count += 1
	return bytes
}

video_ring_take :: proc(r: ^Video_Ring) -> (^encode.Frame_Group, bool) {
	sync.lock(&r.mutex)
	defer sync.unlock(&r.mutex)
	if r.count == 0 do return nil, false
	slot := r.read_index
	r.read_index = (r.read_index + 1) % len(r.ring)
	r.count -= 1
	g := r.ring[slot]
	r.ring[slot] = nil
	return g, true
}

// Takes and clears all spillover entries under the ring mutex.
@(private = "file")
video_spill_take_all :: proc(r: ^Video_Ring) -> []Video_Spill_Entry {
	sync.lock(&r.mutex)
	defer sync.unlock(&r.mutex)
	n := len(r.spillover)
	if n == 0 do return nil
	result := make([]Video_Spill_Entry, n, context.temp_allocator)
	copy(result, r.spillover[:])
	clear(&r.spillover)
	return result
}

audio_ring_destroy :: proc(r: ^Audio_Ring) {
	sync.lock(&r.mutex)
	defer sync.unlock(&r.mutex)
	for i in 0 ..< r.count {
		slot := (r.read_index + i) % len(r.ring)
		encode.group_release(r.ring[slot])
		r.ring[slot] = nil
	}
	r.count = 0
	for entry in r.spillover {
		delete(entry.buf)
	}
	delete(r.spillover)
}

// Returns the number of spillover bytes added (0 when queued in the ring).
audio_ring_put :: proc(r: ^Audio_Ring, g: ^encode.Frame_Group) -> u64 {
	sync.lock(&r.mutex)
	defer sync.unlock(&r.mutex)
	if r.count < len(r.ring) {
		r.ring[r.write_index] = g
		r.write_index = (r.write_index + 1) % len(r.ring)
		r.count += 1
		return 0
	}
	buf_len := len(g.buf)
	buf_copy := make([]u8, buf_len)
	copy(buf_copy, g.buf[:])
	append(&r.spillover, Audio_Spill_Entry{
		buf      = buf_copy,
		pts      = g.pts,
		duration = g.duration,
	})
	encode.group_release(g)
	bytes := u64(buf_len)
	r.spill_bytes += bytes
	r.spill_count += 1
	return bytes
}

audio_ring_take :: proc(r: ^Audio_Ring) -> (^encode.Frame_Group, bool) {
	sync.lock(&r.mutex)
	defer sync.unlock(&r.mutex)
	if r.count == 0 do return nil, false
	slot := r.read_index
	r.read_index = (r.read_index + 1) % len(r.ring)
	r.count -= 1
	g := r.ring[slot]
	r.ring[slot] = nil
	return g, true
}

@(private = "file")
audio_spill_take_all :: proc(r: ^Audio_Ring) -> []Audio_Spill_Entry {
	sync.lock(&r.mutex)
	defer sync.unlock(&r.mutex)
	n := len(r.spillover)
	if n == 0 do return nil
	result := make([]Audio_Spill_Entry, n, context.temp_allocator)
	copy(result, r.spillover[:])
	clear(&r.spillover)
	return result
}

// Diagnostics only; put_video/put_audio fields are encoder-thread-only, rest feeder-thread-only.
Sink_Diag :: struct {
	put_video_groups_received: u64,
	put_video_groups_spilled:  u64,
	put_video_ns_total:        u64,
	put_video_ns_max:          u64,

	put_audio_groups_received: u64,
	put_audio_groups_spilled:  u64,
	put_audio_ns_total:        u64,
	put_audio_ns_max:          u64,

	video_stats: mf.Sample_Stats,
	audio_stats: mf.Sample_Stats,
}

Mp4_Sink :: struct {
	enc:         ^encode.Encoder,
	handles:     mf.Mp4_Sink_Handles,
	video_ring:  Video_Ring,
	audio_ring:  Audio_Ring,
	thread:      ^thread.Thread,
	state:       Sink_State, // atomic
	event:       windows.HANDLE,
	log_sink:    ^applog.Sink,
	diag:        Sink_Diag,

	// Running total of spillover bytes; written by put_video/put_audio, read by feeder.
	spillover_bytes:  u64,  // atomic
	spillover_breach: bool, // atomic

	// PTS rebase state so this file's timestamps start near zero regardless
	// of when it joined the encoder's shared timeline. Feeder-thread-only.
	pts_base:             i64,
	pts_base_set:         bool,
	negative_clamp_count: u64,
}

// Max unrelated events to wait through per stream sink before giving up.
CLOCK_START_MAX_EVENTS :: 64

// Starts an MP4 sink writing to path: opens the file, waits for the clock to
// start, registers as an encoder consumer, and spawns the feeder thread.
mp4_sink_start :: proc(enc: ^encode.Encoder, path: string) -> (^Mp4_Sink, bool) {
	s := new(Mp4_Sink)
	s.enc = enc
	s.log_sink = enc.log_sink

	event_handle := windows.CreateEventW(
		lpEventAttributes = nil,
		bManualReset = false,
		bInitialState = false,
		lpName = nil,
	)
	if event_handle == nil {
		log.errorf("CreateEventW failed for mp4 sink")
		free(s)
		return {}, false
	}
	s.event = event_handle

	handles, begin_ok := mf.begin_mp4_sink(
		path, enc.sps, enc.pps, enc.aac_config,
		enc.width, enc.height, enc.fps, enc.bitrate,
		enc.audio_sample_rate, enc.audio_channels, enc.audio_bitrate,
	)
	if !begin_ok {
		log.error("mf.begin_mp4_sink failed")
		windows.CloseHandle(s.event)
		free(s)
		return {}, false
	}
	s.handles = handles

	success := false
	defer if !success {
		s.handles.video_sink.Release(s.handles.video_sink)
		s.handles.audio_sink.Release(s.handles.audio_sink)
		s.handles.media_sink.Shutdown(s.handles.media_sink)
		s.handles.media_sink.Release(s.handles.media_sink)
		s.handles.clock.Stop(s.handles.clock)
		s.handles.clock.Release(s.handles.clock)
		if s.handles.time_source != nil do s.handles.time_source.Release(s.handles.time_source)
		mf.mp4_sink_close(s.handles.byte_stream)
		s.handles.byte_stream.Release(s.handles.byte_stream)
		windows.CloseHandle(s.event)
		free(s)
	}

	// Wait for MEStreamSinkStarted before feeding anything.
	if !mf.mp4_sink_wait_started(s.handles.video_sink, CLOCK_START_MAX_EVENTS) {
		log.error("timed out waiting for video MEStreamSinkStarted")
		return {}, false
	}
	if !mf.mp4_sink_wait_started(s.handles.audio_sink, CLOCK_START_MAX_EVENTS) {
		log.error("timed out waiting for audio MEStreamSinkStarted")
		return {}, false
	}

	// Register the consumer only after the sink is confirmed started.
	if !encode.consumer_add(enc, encode.Consumer{
		put_video = put_video,
		put_audio = put_audio,
		ctx       = s,
		event     = s.event,
	}) {
		log.error("consumer_add failed (consumer array full)")
		return {}, false
	}

	intrinsics.atomic_store_explicit(&s.state, .Running, .Release)
	s.thread = thread.create(feeder_thread)
	if s.thread == nil {
		log.error("failed to create mp4 sink feeder thread")
		encode.consumer_remove(enc, s)
		return {}, false
	}
	s.thread.data = s
	thread.start(s.thread)

	success = true
	return s, true
}

// Non-blocking: signals the feeder thread to drain, finalize, and stop.
// Caller polls mp4_sink_is_stopped, then calls mp4_sink_reap.
mp4_sink_signal_stop :: proc(s: ^Mp4_Sink) {
	intrinsics.atomic_store_explicit(&s.state, .Stopping, .Release)
	windows.SetEvent(s.event)
}

mp4_sink_is_stopped :: proc(s: ^Mp4_Sink) -> bool {
	return intrinsics.atomic_load_explicit(&s.state, .Acquire) == .Stopped
}

// Joins the feeder thread, unregisters the consumer, frees the rings, logs
// diagnostics, and frees the sink. Call after mp4_sink_is_stopped is true.
mp4_sink_reap :: proc(s: ^Mp4_Sink) {
	if s.thread != nil {
		thread.join(s.thread)
		thread.destroy(s.thread)
		s.thread = nil
	}

	encode.consumer_remove(s.enc, s)
	video_ring_destroy(&s.video_ring)
	audio_ring_destroy(&s.audio_ring)

	log.debugf("mp4 sink video ProcessSample: attempted=%v ok=%v not_accepting=%v other_fail=%v",
		s.diag.video_stats.attempted, s.diag.video_stats.ok,
		s.diag.video_stats.not_accepting, s.diag.video_stats.other_fail)
	log.debugf("mp4 sink audio ProcessSample: attempted=%v ok=%v not_accepting=%v other_fail=%v",
		s.diag.audio_stats.attempted, s.diag.audio_stats.ok,
		s.diag.audio_stats.not_accepting, s.diag.audio_stats.other_fail)
	log.debugf("mp4 sink put_video: groups_received=%v groups_spilled=%v total_ns=%v max_ns=%v",
		s.diag.put_video_groups_received, s.diag.put_video_groups_spilled,
		s.diag.put_video_ns_total, s.diag.put_video_ns_max)
	log.debugf("mp4 sink put_audio: groups_received=%v groups_spilled=%v total_ns=%v max_ns=%v",
		s.diag.put_audio_groups_received, s.diag.put_audio_groups_spilled,
		s.diag.put_audio_ns_total, s.diag.put_audio_ns_max)
	log.infof("mp4 sink PTS rebase: baseline=%v negative_clamped=%v", s.pts_base, s.negative_clamp_count)
	log.infof("mp4 sink spillover: video=%v (%v bytes) audio=%v (%v bytes)",
		s.video_ring.spill_count, s.video_ring.spill_bytes,
		s.audio_ring.spill_count, s.audio_ring.spill_bytes)

	if s.event != nil { windows.CloseHandle(s.event); s.event = nil }
	log.debug("mp4 sink reaped")
	free(s)
}

@(private = "file")
put_video :: proc(ctx: rawptr, g: ^encode.Frame_Group) {
	s := (^Mp4_Sink)(ctx)
	if intrinsics.atomic_load_explicit(&s.state, .Acquire) != .Running {
		encode.group_release(g)
		return
	}
	s.diag.put_video_groups_received += 1
	start := time.tick_now()
	spill_bytes := video_ring_put(&s.video_ring, g)
	elapsed := u64(time.duration_nanoseconds(time.tick_since(start)))
	s.diag.put_video_ns_total += elapsed
	if elapsed > s.diag.put_video_ns_max do s.diag.put_video_ns_max = elapsed
	if spill_bytes > 0 {
		s.diag.put_video_groups_spilled += 1
		intrinsics.atomic_add_explicit(&s.spillover_bytes, spill_bytes, .Release)
		if intrinsics.atomic_load_explicit(&s.spillover_bytes, .Acquire) > SPILLOVER_CEILING {
			intrinsics.atomic_store_explicit(&s.spillover_breach, true, .Release)
		}
	}
}

// Rebases pts against s.pts_base, set from the first group dequeued. Feeder-thread-only.
@(private = "file")
rebase_pts :: proc(s: ^Mp4_Sink, pts: i64) -> i64 {
	if !s.pts_base_set {
		s.pts_base = pts
		s.pts_base_set = true
		log.infof("mp4 sink PTS baseline set to %v", s.pts_base)
	}
	rebased := pts - s.pts_base
	if rebased < 0 {
		rebased = 0
		s.negative_clamp_count += 1
	}
	return rebased
}

@(private = "file")
put_audio :: proc(ctx: rawptr, g: ^encode.Frame_Group) {
	s := (^Mp4_Sink)(ctx)
	if intrinsics.atomic_load_explicit(&s.state, .Acquire) != .Running {
		encode.group_release(g)
		return
	}
	s.diag.put_audio_groups_received += 1
	start := time.tick_now()
	spill_bytes := audio_ring_put(&s.audio_ring, g)
	elapsed := u64(time.duration_nanoseconds(time.tick_since(start)))
	s.diag.put_audio_ns_total += elapsed
	if elapsed > s.diag.put_audio_ns_max do s.diag.put_audio_ns_max = elapsed
	if spill_bytes > 0 {
		s.diag.put_audio_groups_spilled += 1
		intrinsics.atomic_add_explicit(&s.spillover_bytes, spill_bytes, .Release)
		if intrinsics.atomic_load_explicit(&s.spillover_bytes, .Acquire) > SPILLOVER_CEILING {
			intrinsics.atomic_store_explicit(&s.spillover_breach, true, .Release)
		}
	}
}

// Feeds spillover then ring entries to MF, oldest first to preserve PTS order.
@(private = "file")
drain_audio :: proc(s: ^Mp4_Sink) {
	for entry in audio_spill_take_all(&s.audio_ring) {
		pts := rebase_pts(s, entry.pts)
		sample, payload_len, sample_ok := mf.mp4_sink_build_audio_sample(entry.buf, pts, entry.duration)
		delete(entry.buf)
		if sample_ok {
			if !mf.mp4_sink_send_sample(s.handles.audio_sink, sample, pts, entry.duration, payload_len, &s.diag.audio_stats, "audio") {
				log.warnf("audio ProcessSample failed, frame lost")
			}
		}
	}

	for {
		g, take_ok := audio_ring_take(&s.audio_ring)
		if !take_ok do break
		pts, duration := rebase_pts(s, g.pts), g.duration
		sample, payload_len, sample_ok := mf.mp4_sink_build_audio_sample(g.buf[:], pts, duration)
		encode.group_release(g)
		if sample_ok {
			if !mf.mp4_sink_send_sample(s.handles.audio_sink, sample, pts, duration, payload_len, &s.diag.audio_stats, "audio") {
				log.warnf("audio ProcessSample failed, frame lost")
			}
		}
	}
}

@(private = "file")
drain_video :: proc(s: ^Mp4_Sink) {
	for entry in video_spill_take_all(&s.video_ring) {
		// Reconstruct nalus slices from the copied buf and offsets.
		nalus := make([][]u8, len(entry.offsets), context.temp_allocator)
		for span, i in entry.offsets {
			nalus[i] = entry.buf[span.start:][:span.length]
		}
		pts := rebase_pts(s, entry.pts)
		sample, payload_len, sample_ok := mf.mp4_sink_build_video_sample(nalus, pts, entry.duration)
		delete(entry.buf)
		delete(entry.offsets)
		if sample_ok {
			if !mf.mp4_sink_send_sample(s.handles.video_sink, sample, pts, entry.duration, payload_len, &s.diag.video_stats, "video") {
				log.warnf("video ProcessSample failed, frame lost")
			}
		}
	}

	for {
		g, take_ok := video_ring_take(&s.video_ring)
		if !take_ok do break
		pts, duration := rebase_pts(s, g.pts), g.duration
		sample, payload_len, sample_ok := mf.mp4_sink_build_video_sample(g.nalus[:], pts, duration)
		encode.group_release(g)
		if sample_ok {
			if !mf.mp4_sink_send_sample(s.handles.video_sink, sample, pts, duration, payload_len, &s.diag.video_stats, "video") {
				log.warnf("video ProcessSample failed, frame lost")
			}
		}
	}
}

@(private = "file")
feeder_thread :: proc(t: ^thread.Thread) {
	s := (^Mp4_Sink)(t.data)

	mp4_log_ctx := applog.Log_Context{sink = s.log_sink, tag = {.Mp4, 0}}
	context.logger = applog.make_logger(&mp4_log_ctx)

	windows.CoInitializeEx(nil, .MULTITHREADED)
	defer windows.CoUninitialize()

	for intrinsics.atomic_load_explicit(&s.state, .Acquire) == .Running {
		if windows.WaitForSingleObject(s.event, 200) != windows.WAIT_OBJECT_0 do continue

		// Audio before video on each wake, same order as RTMP.
		drain_audio(s)
		drain_video(s)

		if intrinsics.atomic_load_explicit(&s.spillover_breach, .Acquire) {
			log.error("spillover ceiling exceeded (>256 MiB), auto-stopping recording")
			intrinsics.atomic_store_explicit(&s.state, .Stopping, .Release)
			break
		}

		free_all(context.temp_allocator)
	}

	// Final drain of everything remaining.
	drain_audio(s)
	drain_video(s)

	if !mf.mp4_sink_finalize(s.handles.media_sink) {
		log.error("mp4_sink_finalize failed -- output file may be unplayable")
	}

	s.handles.video_sink.Release(s.handles.video_sink)
	s.handles.audio_sink.Release(s.handles.audio_sink)
	s.handles.media_sink.Release(s.handles.media_sink)
	s.handles.clock.Stop(s.handles.clock)
	s.handles.clock.Release(s.handles.clock)
	if s.handles.time_source != nil do s.handles.time_source.Release(s.handles.time_source)
	mf.mp4_sink_close(s.handles.byte_stream)
	s.handles.byte_stream.Release(s.handles.byte_stream)

	free_all(context.temp_allocator)

	log.debug("mp4 sink feeder thread finished, file finalized")
	intrinsics.atomic_store_explicit(&s.state, .Stopped, .Release)
}
