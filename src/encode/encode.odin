package encode

import "base:intrinsics"
import mf "libs:mf"
import "core:log"
import "core:sync"
import "../applog"
import win32 "core:sys/windows"
import "core:thread"
import "libs:h264"

@(private) g_encoder:      ^Encoder
@(private) g_encoder_refs: int

VIDEO_POOL_SLOTS :: 64
AUDIO_POOL_SLOTS :: 64
AUDIO_BUF_CAP :: 2048

// Matches audio.BLOCK_SAMPLES / audio.BLOCK_LATENCY (src/audio/mixer.odin) --
// this package can't import src/audio without a cycle, so the values are
// mirrored here, same as src/rtmp/commands_test.odin already does.
AUDIO_BLOCK_SAMPLES :: 1024
AUDIO_QUEUE_CAPACITY :: 4

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
	dropped_audio_frames: u32,
	encoded_frames: u32,

	log_sink: ^applog.Sink,
	scratch: []u8,
	audio_scratch: []u8,
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
		delete(e.audio_scratch)
		mailbox_destroy(e.raw_mailbox)
		audio_queue_destroy(e.pcm_queue)
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

	audio_stride := AUDIO_BLOCK_SAMPLES * e.audio_channels * 2
	e.audio_scratch = make([]u8, audio_stride)
	e.pcm_queue = audio_queue_init(AUDIO_QUEUE_CAPACITY, audio_stride)

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
		// handles order and the switch case labels below must stay tied together
		handles := [2]win32.HANDLE{e.video_event, e.audio_event}
		r := win32.WaitForMultipleObjects(2, &handles[0], false, 200)
		switch r {
		case win32.WAIT_OBJECT_0:     e.wake_video += 1
		case win32.WAIT_OBJECT_0 + 1: e.wake_audio += 1
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
Aac_Sink :: struct {
	e:              ^Encoder,
	block_pts:      i64,
	frame_duration: i64,
	index:          int,
}

@(private)
aac_frame_callback :: proc(ctx: rawptr, frame: []u8) {
	sink := (^Aac_Sink)(ctx)
	e := sink.e
	defer sink.index += 1

	aud_group, aud_ok := pool_acquire(&e.audio_pool)
	if !aud_ok {
		e.dropped_audio_frames += 1
		if e.dropped_audio_frames % 60 == 1 {
			log.warnf("audio pool exhausted, dropped %v frame(s) so far", e.dropped_audio_frames)
		}
		return
	}

	group_reset(aud_group)
	append(&aud_group.buf, ..frame)
	aud_group.pts = sink.block_pts + i64(sink.index) * sink.frame_duration
	aud_group.duration = sink.frame_duration
	group_finish(aud_group)

	sync.lock(&e.consumers_mutex)
	defer sync.unlock(&e.consumers_mutex)

	count := 0
	for c in e.consumers[:e.consumer_count] {
		if c.put_audio != nil do count += 1
	}

	if !group_publish(aud_group, count) do return   // zero receivers; already recycled

	for c in e.consumers[:e.consumer_count] {
		if c.put_audio != nil do c.put_audio(c.ctx, aud_group)
	}
	for c in e.consumers[:e.consumer_count] {
		if c.put_audio != nil do win32.SetEvent(c.event)
	}
}

@(private)
drain_audio :: proc(e: ^Encoder) {
	pts, ok := audio_queue_take(e.pcm_queue, e.audio_scratch)
	if !ok do return

	// AAC LC emits 1024 samples per frame regardless of input block size;
	// AUDIO_BLOCK_SAMPLES happens to match that, so the same duration serves
	// both as this PCM block's input duration and each output frame's duration.
	aac_frame_duration := i64(AUDIO_BLOCK_SAMPLES) * 10_000_000 / i64(e.audio_sample_rate)

	sink := Aac_Sink{e = e, block_pts = pts, frame_duration = aac_frame_duration}
	_, enc_ok := mf.encode_aac_frame_into(
		e.audio_encoder, e.audio_scratch, pts, aac_frame_duration,
		aac_frame_callback, &sink,
	)
	if !enc_ok {
		log.warnf("encode_aac_frame_into failed")
	}
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

	if !mf.set_encoder_gop_size(e.encoder, e.fps * 2) {
		log.warnf("set_encoder_gop_size failed -- encoder will use its default keyframe interval")
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
	log.debugf("encoder created: sps=%v pps=%v sample_rate=%v", e.sps, e.pps, e.audio_sample_rate)
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
	delete(e.audio_scratch)
	mailbox_destroy(e.raw_mailbox)
	audio_queue_destroy(e.pcm_queue)
	free(e)

	g_encoder = nil
}

