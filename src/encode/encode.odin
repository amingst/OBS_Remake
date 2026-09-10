package encode

import "base:intrinsics"
import mf "libs:mf"
import "core:log"
import "core:sync"
import "../applog"
import win32 "core:sys/windows"
import "core:thread"
import "libs:h264"

@(private) g_state: State
@(private) g_encoder:      ^Encoder
@(private) g_encoder_refs: int

VIDEO_POOL_SLOTS :: 64
AUDIO_POOL_SLOTS :: 64
AUDIO_BUF_CAP :: 2048

@(private)
State :: struct {
    sink_writer:        ^mf.IMFSinkWriter,
    video_stream_index: u32,
    audio_stream_index: u32,
    has_audio:          bool,
    width, height:      u32,
    frame_duration:     i64,
    recording:          bool,
}

Encoder :: struct {
	// consumers - main thread writes
	consumers: [8]Consumer,
	consumer_count: int,
	consumers_mutex: sync.Mutex,

	// inbound from main thread
	raw_mailbox: ^Raw_Mailbox,
	pcm_queue: ^Raw_Audio_Queue,
	video_event: win32.HANDLE,
	audio_event: win32.HANDLE,

	// MFT's created and owned
	// by the encoder thread
	processor: ^mf.IMFTransform,
	encoder: ^mf.IMFTransform,
	audio_encoder: ^mf.IMFTransform,

	// blobs produced by mft's
	sps, pps: []u8,
	aac_config: []u8,

	// pools
	video_pool: Frame_Pool,
	audio_pool: Frame_Pool,

	// thread
	thread: ^thread.Thread,
	running: bool, // atomic
	ready_event: win32.HANDLE,
	init_ok: bool,

	// config, frozen on first acquire
	width, height, fps, bitrate: u32,
	audio_sample_rate, audio_channels, audio_bitrate: u32,
	frame_duration: i64,

	// diagnostics, logged at release
	wake_video, wake_audio, wake_timeout: u64,
	pool_min_free: int,
	dropped_frames: u32,
	encoded_frames: u32,

	log_sink: ^applog.Sink,
	scratch: []u8,
}

Encoder_Config :: struct {
	width, height, fps, bitrate: u32,
	audio_sample_rate, audio_channels, audio_bitrate: u32,
	frame_duration: i64,
	log_sink: ^applog.Sink
}

Nalu_Sink :: struct {
	g:	^Frame_Group,
	is_keyframe: bool,
}

nalu_callback :: proc(ctx: rawptr, nalu: []u8) {
	s := (^Nalu_Sink)(ctx)
	if h264.nal_type(nalu) == h264.NAL_TYPE_IDR do s.is_keyframe = true
	group_append_nalu(s.g, nalu)
}

encoder_acquire :: proc(
	cfg: Encoder_Config,
) -> (^Encoder, bool) {
	if g_encoder_refs > 0 {
		g_encoder_refs += 1
		return g_encoder, true
	}

	e := new(Encoder)
	ok := false
	defer if !ok {
		if e.ready_event != nil do win32.CloseHandle(e.ready_event)
		if e.video_event != nil do win32.CloseHandle(e.video_event)
		if e.audio_event != nil do win32.CloseHandle(e.audio_event)
		pool_destroy(&e.video_pool)
		pool_destroy(&e.audio_pool)
		delete(e.scratch)
		mailbox_destroy(e.raw_mailbox)
		free(e)
	}

	e.width = cfg.width
	e.height = cfg.height
	e.fps = cfg.fps
	e.bitrate = cfg.bitrate
	e.audio_sample_rate = cfg.audio_sample_rate
	e.audio_channels = cfg.audio_channels
	e.audio_bitrate = cfg.audio_bitrate
	e.frame_duration = cfg.frame_duration
	e.log_sink = cfg.log_sink

	e.video_event = win32.CreateEventW(nil, false, false, nil)
	if e.video_event == nil {
		log.errorf("encoder_acquire: %v", win32.GetLastError())
		return nil, false
	}

	e.audio_event = win32.CreateEventW(nil, false, false, nil)
	if e.audio_event == nil {
		log.errorf("encoder_acquire: %v", win32.GetLastError())
		return nil, false
	}

	e.ready_event = win32.CreateEventW(nil, false, false, nil)
	if e.ready_event == nil {
		log.errorf("encoder_acquire: %v", win32.GetLastError())
		return nil, false
	}

	video_buf_cap := int(cfg.bitrate / 8 / max(cfg.fps, 1)) * 4

	video_pool_ok := pool_init(&e.video_pool, VIDEO_POOL_SLOTS, video_buf_cap)
	if !video_pool_ok {
		return nil, false
	}

	audio_pool_ok := pool_init(&e.audio_pool, AUDIO_POOL_SLOTS, AUDIO_BUF_CAP)
	if !audio_pool_ok {
		return nil, false
	}

	e.pool_min_free = VIDEO_POOL_SLOTS

	e.scratch = make([]u8, int(e.width) * int(e.height) * 4)
	e.raw_mailbox = mailbox_init(e.width, e.height)

	intrinsics.atomic_store(&e.running, true)
	e.thread = thread.create(encoder_thread)
	if e.thread == nil {
		log.errorf("encoder_acquire: %v", win32.GetLastError())
		return nil, false
	}
	e.thread.data = e
	thread.start(e.thread)

	wait := win32.WaitForSingleObject(e.ready_event, 5000)
	if wait != win32.WAIT_OBJECT_0 {
		log.errorf("encoder thread never signalled ready (0x%08X)", u32(wait))
		intrinsics.atomic_store(&e.running, false)
		thread.join(e.thread); thread.destroy(e.thread)
		return nil, false
	}

	if !e.init_ok {
		log.errorf("encoder thread MFT init failed")
		thread.join(e.thread); thread.destroy(e.thread)
		return nil, false
	}

	ok = true
	g_encoder = e
	g_encoder_refs = 1
	return e, true
}

@(private)
encoder_thread :: proc(t: ^thread.Thread) {
	e := (^Encoder)(t.data)
	ctx := applog.Log_Context{sink = e.log_sink, tag = {.Encode, 0}}
	context.logger = applog.make_logger(&ctx)
	log.info("encoder thread started")
	win32.CoInitializeEx(nil, .MULTITHREADED)
	defer win32.CoUninitialize()

	e.init_ok = create_mfts(e)
	win32.SetEvent(e.ready_event)
	if !e.init_ok do return

	for intrinsics.atomic_load_explicit(&e.running, .Acquire) {
		handles := [2]win32.HANDLE{e.video_event, e.audio_event}
		r := win32.WaitForMultipleObjects(2, &handles[0], false, 200)
		switch r {
		case win32.WAIT_OBJECT_0:     e.wake_audio += 1   // fires on VIDEO
		case win32.WAIT_OBJECT_0 + 1: e.wake_video += 1   // fires on AUDIO
		case win32.WAIT_TIMEOUT:      e.wake_timeout += 1
		case:
			log.errorf("WaitForMultipleObjects failed: 0x%08X", u32(r))
		}

		drain_audio(e)
		drain_video(e)
		free_all(context.temp_allocator)
	}

	// teardown MFTs here, on the thread that made them
	if e.encoder != nil {
		tail := mf.end_h264_encoder(e.encoder)
		e.encoder = nil
		for n in tail do delete(n)
		delete(tail)
	}

	if e.audio_encoder != nil {
		audio_tail := mf.end_aac_encoder(e.audio_encoder)
		e.audio_encoder = nil
		for data in audio_tail do delete(data)
		delete(audio_tail)
	}

	if e.processor != nil {
		mf.end_video_processor(e.processor)
		e.processor = nil
	}

	delete(e.sps)
	delete(e.pps)
	delete(e.aac_config)
	e.sps = nil
	e.pps = nil
	e.aac_config = nil
}

@(private)
drain_audio :: proc(e: ^Encoder) {

}

@(private)
drain_video :: proc(e: ^Encoder) {
	_, _, pts, ok := mailbox_take(e.raw_mailbox, e.scratch)
	if !ok do return
	vid_group, vid_ok := pool_acquire(&e.video_pool)
	if !vid_ok {
		e.dropped_frames += 1
		if e.dropped_frames % 60 == 1 {
			log.warnf("video pool exhausted, dropped %v frame(s) so far", e.dropped_frames)
		}
		return
	}

	free_now := pool_free_count(&e.video_pool)
	if free_now < e.pool_min_free do e.pool_min_free = free_now
	group_reset(vid_group)
	vid_group.pts = pts
	vid_group.duration = e.frame_duration

	sink := Nalu_Sink{g = vid_group}
	n, enc_ok := mf.encode_bgra_frame_into(
    e.processor, e.encoder, e.scratch, pts, e.frame_duration,
    nalu_callback, &sink,
	)
	if !enc_ok || n == 0 {
    // Nothing was published, so refcount is still 0 — recycle directly.
    // group_release would decrement from 0 and trip the double-release assert.
    pool_recycle(vid_group)
    return
	}

	vid_group.is_keyframe = sink.is_keyframe
	group_finish(vid_group)

	e.encoded_frames += 1
	if e.encoded_frames % 60 == 1 {
		log.debugf("encoded frame group: nalus=%v keyframe=%v pts=%v", n, vid_group.is_keyframe, vid_group.pts)
	}

	sync.lock(&e.consumers_mutex)
	defer sync.unlock(&e.consumers_mutex)

	count := 0
	for c in e.consumers[:e.consumer_count] {
    	if c.put_video != nil do count += 1
	}

	if !group_publish(vid_group, count) do return   // zero receivers; already recycled

	for c in e.consumers[:e.consumer_count] {
    	if c.put_video != nil do c.put_video(c.ctx, vid_group)
	}
	for c in e.consumers[:e.consumer_count] {
    	if c.put_video != nil do win32.SetEvent(c.event)
	}
}

@(private)
create_mfts :: proc(e: ^Encoder) -> bool {
	proc_ok: bool
	e.processor, proc_ok = mf.begin_video_processor(e.width, e.height)
	if !proc_ok do return false

	enc_ok: bool
	e.encoder, e.sps, e.pps, enc_ok = mf.begin_h264_encoder(e.width, e.height, e.fps, e.bitrate)
	if !enc_ok {
		mf.end_video_processor(e.processor)
		e.processor = nil
		return false
	}

	audio_ok: bool
	e.audio_encoder, e.aac_config, audio_ok = mf.begin_aac_encoder(
		e.audio_sample_rate, e.audio_channels, e.audio_bitrate)
	if !audio_ok {
		mf.end_video_processor(e.processor)
		e.processor = nil

		tail := mf.end_h264_encoder(e.encoder)
		e.encoder = nil
		for n in tail do delete(n)
		delete(tail)

		delete(e.sps)
		delete(e.pps)
		e.sps = nil
		e.pps = nil
		return false
	}
	return true
}

// consumers must be stopped and joined before encoder_release
encoder_release :: proc() {
	if g_encoder_refs == 0 {
		log.warnf("encoder_release with no active encoder")
		return
	}
	g_encoder_refs -= 1
	if g_encoder_refs > 0 do return

	e := g_encoder
	intrinsics.atomic_store(&e.running, false)
	win32.SetEvent(e.video_event)   // wake it out of the 200ms wait
	win32.SetEvent(e.audio_event)
	thread.join(e.thread)
	thread.destroy(e.thread)

	log.infof("encoder wakeups: video=%v audio=%v timeout=%v; pool min free=%v; dropped=%v",
		e.wake_video, e.wake_audio, e.wake_timeout, e.pool_min_free, e.dropped_frames)

	pool_destroy(&e.video_pool)
	pool_destroy(&e.audio_pool)
	win32.CloseHandle(e.ready_event)
	win32.CloseHandle(e.video_event)
	win32.CloseHandle(e.audio_event)
	delete(e.scratch)
	mailbox_destroy(e.raw_mailbox)
	free(e)

	g_encoder = nil
}

start :: proc(
    output_path: string,
    width, height, fps: u32,
    video_bitrate: u32 = 4_000_000,
    audio_sample_rate: u32 = 0,  // 0 = no audio stream
    audio_channels: u32 = 0,
    audio_bitrate: u32 = 16_000, // bytes/sec - must be 12000/16000/20000/24000 for mono/stereo
) -> bool {
    if g_state.recording {
        log.errorf("encode.start called with an already active recording")
        return false
    }

    ok := mf.begin_recording(
        output_path, width, height, fps, video_bitrate,
        audio_sample_rate, audio_channels, audio_bitrate,
        &g_state.sink_writer,
        &g_state.video_stream_index,
        &g_state.audio_stream_index,
    )
    if !ok do return false

    g_state.width = width
    g_state.height = height
    g_state.frame_duration = i64(10_000_000) / i64(fps)
    g_state.has_audio = audio_channels > 0
    g_state.recording = true
    return true
}

push_video :: proc(pixels: []u8, pts_100ns: i64) -> bool {
    if !g_state.recording {
        log.errorf("encode.push_video called with no active recording")
        return false
    }

    expected := int(g_state.width) * int(g_state.height) * 4
    if len(pixels) != expected {
        log.errorf("encode.push_video: expected %d bytes, got %d", expected, len(pixels))
        return false
    }

    return mf.write_video_frame(g_state.sink_writer, g_state.video_stream_index, pixels, pts_100ns, g_state.frame_duration)
}

// Caller supplies the timestamp explicitly, in 100ns units - the video/audio
// clock strategy isn't decided yet, so this package isn't computing one for
// audio internally either. samples is already-converted interleaved 16-bit
// PCM matching whatever audio_channels was passed to start.
push_audio :: proc(samples: []u8, pts_100ns, duration_100ns: i64) -> bool {
    if !g_state.recording {
        log.errorf("encode.push_audio called with no active recording")
        return false
    }
    if !g_state.has_audio {
        log.errorf("encode.push_audio called but recording was started without an audio stream")
        return false
    }
    if duration_100ns <= 0 {
        log.errorf("encode.push_audio: duration_100ns must be > 0 (zero duration causes a divide-by-zero inside the AAC encoder's ProcessOutput)")
        return false
    }

    return mf.write_audio_frame(g_state.sink_writer, g_state.audio_stream_index, samples, pts_100ns, duration_100ns)
}

stop :: proc() -> bool {
    if !g_state.recording {
        log.errorf("encode.stop called with no active recording")
        return false
    }

    // NOTE: Look to see if I should be handling !ok
    ok := mf.end_recording(g_state.sink_writer)
    g_state.sink_writer = nil
    g_state.recording = false
    return ok;
}
