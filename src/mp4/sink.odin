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

// Deep enough to hold several seconds of encoded groups without dropping.
// Unlike src/rtmp (which drops to protect latency), a dropped video frame
// mid-GOP corrupts this file until the next IDR, so this trades memory for
// never hitting the ring in practice.
//
// VIDEO_RING_DEPTH: 4s of buffering at a generous 60fps upper bound
// (60*4=240), rounded up to 256.
// AUDIO_RING_DEPTH: AAC LC always emits 1024-sample frames regardless of
// input block size (see encode.odin's drain_audio), so at 48kHz that's
// 48000/1024 ≈ 46.9 frames/sec; 4s ≈ 188, rounded up to 192.
VIDEO_RING_DEPTH :: 256
AUDIO_RING_DEPTH :: 192

Video_Ring :: struct {
	mutex:       sync.Mutex,
	count:       int,
	read_index:  int,
	write_index: int,
	overflow:    u32,
	ring:        [VIDEO_RING_DEPTH]^encode.Frame_Group,
}

Audio_Ring :: struct {
	mutex:       sync.Mutex,
	count:       int,
	read_index:  int,
	write_index: int,
	overflow:    u32,
	ring:        [AUDIO_RING_DEPTH]^encode.Frame_Group,
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
}

// put takes ownership of exactly one reference on every path (kept or
// dropped), same contract as encode.Consumer.put_video/put_audio. Runs on
// the encoder thread with encode's consumers_mutex held: must not block, log,
// or take any lock other than r.mutex.
// Return value is diagnostics-only (recon instrumentation): true if the
// group was dropped (ring full) rather than queued. Does not change the
// drop behaviour itself.
video_ring_put :: proc(r: ^Video_Ring, g: ^encode.Frame_Group) -> bool {
	sync.lock(&r.mutex)
	defer sync.unlock(&r.mutex)
	if r.count == len(r.ring) {
		encode.group_release(g)
		r.overflow += 1
		return true
	}
	r.ring[r.write_index] = g
	r.write_index = (r.write_index + 1) % len(r.ring)
	r.count += 1
	return false
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

video_ring_take_overflow :: proc(r: ^Video_Ring) -> u32 {
	sync.lock(&r.mutex)
	defer sync.unlock(&r.mutex)
	n := r.overflow
	r.overflow = 0
	return n
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
}

// Return value is diagnostics-only (recon instrumentation): true if the
// group was dropped (ring full) rather than queued. Does not change the
// drop behaviour itself.
audio_ring_put :: proc(r: ^Audio_Ring, g: ^encode.Frame_Group) -> bool {
	sync.lock(&r.mutex)
	defer sync.unlock(&r.mutex)
	if r.count == len(r.ring) {
		encode.group_release(g)
		r.overflow += 1
		return true
	}
	r.ring[r.write_index] = g
	r.write_index = (r.write_index + 1) % len(r.ring)
	r.count += 1
	return false
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

audio_ring_take_overflow :: proc(r: ^Audio_Ring) -> u32 {
	sync.lock(&r.mutex)
	defer sync.unlock(&r.mutex)
	n := r.overflow
	r.overflow = 0
	return n
}

// Diagnostics only (recon instrumentation), touched exclusively by the
// encoder thread (the put_video/put_audio fields) or the feeder thread (the
// rest) -- never both at once, per the same happens-before guarantees the
// rest of this file already relies on. Read from mp4_sink_stop only after
// consumer_remove and thread.join have both returned, so no concurrent
// writer remains by the time it's logged.
Sink_Diag :: struct {
	put_video_groups_received: u64,
	put_video_groups_dropped:  u64,
	put_video_ns_total:        u64,
	put_video_ns_max:          u64,

	put_audio_groups_received: u64,
	put_audio_groups_dropped:  u64,
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
	running:     bool, // atomic
	event:       windows.HANDLE,
	log_sink:    ^applog.Sink,
	diag:        Sink_Diag,

	// PTS rebase state. enc's timeline is shared across every consumer and
	// runs for the encoder's whole lifetime (see main.odin), so a group
	// arriving here can carry an arbitrarily large PTS if this sink started
	// long after the encoder did. This file needs its own timestamps to
	// start near zero, so the feeder thread rebases every sample against a
	// baseline captured from the first group it dequeues -- from either
	// ring, whichever produces one first. Touched only by the feeder
	// thread, never by put_video/put_audio.
	pts_base:             i64,
	pts_base_set:         bool,
	negative_clamp_count: u64,
}

// Waits, per stream sink, for enough unrelated events that giving up means
// something is actually wrong rather than ordinary startup latency.
CLOCK_START_MAX_EVENTS :: 64

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

	// Wait for the actual OnClockStart notification (delivered to each
	// stream sink as MEStreamSinkStarted) before feeding anything -- a group
	// arriving before this has nowhere to go, and ProcessSample is rejected
	// (or worse) until the sink has actually seen its clock start.
	if !mf.mp4_sink_wait_started(s.handles.video_sink, CLOCK_START_MAX_EVENTS) {
		log.error("timed out waiting for video MEStreamSinkStarted")
		return {}, false
	}
	if !mf.mp4_sink_wait_started(s.handles.audio_sink, CLOCK_START_MAX_EVENTS) {
		log.error("timed out waiting for audio MEStreamSinkStarted")
		return {}, false
	}

	// Register the Consumer AFTER the sink is confirmed started -- unlike
	// RTMP, there's no benefit to early registration here and a group
	// arriving before OnClockStart has nowhere to go.
	if !encode.consumer_add(enc, encode.Consumer{
		put_video = put_video,
		put_audio = put_audio,
		ctx       = s,
		event     = s.event,
	}) {
		log.error("consumer_add failed (consumer array full)")
		return {}, false
	}

	intrinsics.atomic_store_explicit(&s.running, true, .Release)
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

// Blocking: signals and joins the feeder thread, drains and releases every
// queued group, finalizes the file, and frees everything. Callers should
// expect this to take on the order of a second.
mp4_sink_stop :: proc(s: ^Mp4_Sink) {
	// a. consumer_remove must return before anything else. encode holds
	//    consumers_mutex across put, so once remove returns no put is in
	//    flight and none can start.
	encode.consumer_remove(s.enc, s)

	// b. stop and join the feeder thread.
	if s.thread != nil {
		intrinsics.atomic_store_explicit(&s.running, false, .Release)
		windows.SetEvent(s.event)
		thread.join(s.thread)
		thread.destroy(s.thread)
		s.thread = nil
	}

	// c. drain both rings, releasing every queued reference.
	video_ring_destroy(&s.video_ring)
	audio_ring_destroy(&s.audio_ring)

	// Diagnostics only (recon instrumentation): logged here, never from
	// inside put_video/put_audio, because logging under encode's
	// consumers_mutex is exactly the hypothesis being investigated. By this
	// point consumer_remove and thread.join have both returned, so nothing
	// concurrent is still writing s.diag.
	log.debugf("mp4 sink video ProcessSample: attempted=%v ok=%v not_accepting=%v other_fail=%v",
		s.diag.video_stats.attempted, s.diag.video_stats.ok,
		s.diag.video_stats.not_accepting, s.diag.video_stats.other_fail)
	log.debugf("mp4 sink audio ProcessSample: attempted=%v ok=%v not_accepting=%v other_fail=%v",
		s.diag.audio_stats.attempted, s.diag.audio_stats.ok,
		s.diag.audio_stats.not_accepting, s.diag.audio_stats.other_fail)
	log.debugf("mp4 sink put_video: groups_received=%v groups_dropped=%v total_ns=%v max_ns=%v",
		s.diag.put_video_groups_received, s.diag.put_video_groups_dropped,
		s.diag.put_video_ns_total, s.diag.put_video_ns_max)
	log.debugf("mp4 sink put_audio: groups_received=%v groups_dropped=%v total_ns=%v max_ns=%v",
		s.diag.put_audio_groups_received, s.diag.put_audio_groups_dropped,
		s.diag.put_audio_ns_total, s.diag.put_audio_ns_max)

	log.infof("mp4 sink PTS rebase: baseline=%v negative_clamped=%v", s.pts_base, s.negative_clamp_count)

	// d. finalize: BeginFinalize -> wait -> EndFinalize -> Shutdown.
	if !mf.mp4_sink_finalize(s.handles.media_sink) {
		log.error("mp4_sink_finalize failed -- output file may be unplayable")
	}

	// e. release COM objects, close handles, free.
	s.handles.video_sink.Release(s.handles.video_sink)
	s.handles.audio_sink.Release(s.handles.audio_sink)
	s.handles.media_sink.Release(s.handles.media_sink)
	s.handles.clock.Stop(s.handles.clock)
	s.handles.clock.Release(s.handles.clock)
	if s.handles.time_source != nil do s.handles.time_source.Release(s.handles.time_source)
	mf.mp4_sink_close(s.handles.byte_stream)
	s.handles.byte_stream.Release(s.handles.byte_stream)

	if s.event != nil { windows.CloseHandle(s.event); s.event = nil }
	log.debug("mp4 sink closed")
	free(s)
}

// Diagnostics only (recon instrumentation) added below: a counter increment
// and a monotonic timer read/subtract around the ring put, accumulated into
// s.diag. No allocation, no logging, no COM call, no I/O, no wait, and no
// lock other than the ring's own -- same "put must never block" contract as
// before, just measured.
@(private = "file")
put_video :: proc(ctx: rawptr, g: ^encode.Frame_Group) {
	s := (^Mp4_Sink)(ctx)
	s.diag.put_video_groups_received += 1
	start := time.tick_now()
	dropped := video_ring_put(&s.video_ring, g)
	elapsed := u64(time.duration_nanoseconds(time.tick_since(start)))
	s.diag.put_video_ns_total += elapsed
	if elapsed > s.diag.put_video_ns_max do s.diag.put_video_ns_max = elapsed
	if dropped do s.diag.put_video_groups_dropped += 1
}

// Rebases pts against s.pts_base, capturing the base from the first group
// this sink ever dequeues (whichever ring -- video or audio -- produces one
// first). Feeder-thread-only; must never be called from put_video/put_audio.
// duration is never passed here -- it's a span, not a point in time, and
// rebasing it would be wrong.
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
	s.diag.put_audio_groups_received += 1
	start := time.tick_now()
	dropped := audio_ring_put(&s.audio_ring, g)
	elapsed := u64(time.duration_nanoseconds(time.tick_since(start)))
	s.diag.put_audio_ns_total += elapsed
	if elapsed > s.diag.put_audio_ns_max do s.diag.put_audio_ns_max = elapsed
	if dropped do s.diag.put_audio_groups_dropped += 1
}

@(private = "file")
feeder_thread :: proc(t: ^thread.Thread) {
	s := (^Mp4_Sink)(t.data)

	mp4_log_ctx := applog.Log_Context{sink = s.log_sink, tag = {.Mp4, 0}}
	context.logger = applog.make_logger(&mp4_log_ctx)

	windows.CoInitializeEx(nil, .MULTITHREADED)
	defer windows.CoUninitialize()

	for intrinsics.atomic_load_explicit(&s.running, .Acquire) {
		if windows.WaitForSingleObject(s.event, 200) != windows.WAIT_OBJECT_0 do continue

		// Drain audio fully before video on each wake, same order as RTMP.
		for {
			g, take_ok := audio_ring_take(&s.audio_ring)
			if !take_ok do break
			pts, duration := rebase_pts(s, g.pts), g.duration
			sample, payload_len, sample_ok := mf.mp4_sink_build_audio_sample(g.buf[:], pts, duration)
			// Release before the send, which can block on MF_E_NOTACCEPTING
			// backpressure -- same rule as RTMP's "release before send_media".
			encode.group_release(g)
			if sample_ok {
				if !mf.mp4_sink_send_sample(s.handles.audio_sink, sample, pts, duration, payload_len, &s.diag.audio_stats, "audio") {
					log.warnf("audio ProcessSample failed, frame lost")
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

		if n := video_ring_take_overflow(&s.video_ring); n > 0 {
			log.errorf("mp4 sink video ring overflowed, dropped %v group(s)", n)
		}
		if n := audio_ring_take_overflow(&s.audio_ring); n > 0 {
			log.errorf("mp4 sink audio ring overflowed, dropped %v group(s)", n)
		}

		free_all(context.temp_allocator)
	}
}
