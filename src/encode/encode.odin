package encode

import "base:runtime"
import "core:sync"
import mf "libs:mf"
import "core:log"

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

Frame_Group :: struct {
	refcount:		u32,
	pts:			i64,
	duration:		i64,
	is_keyframe:	bool,
	buf:			[dynamic]u8,
	nalus:			[dynamic][]u8,
	pool:			^Frame_Pool,
	index:			int
}

Frame_Pool :: struct {
	slots:		[]Frame_Group,
	free:		[dynamic]int,
	mutex:		sync.Mutex
}

@(private)
g_state: State

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
			log.errorf("pool_init: slot %d buffer (%d bytes) failed", i, initial_buf_cap)
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
		return false
	}

	for i in 0 ..< slot_count {
		append(&pool.free, i)
	}
	return true
}

@(private)
pool_destroy :: proc(pool: ^Frame_Pool) {
	for &slot in pool.slots {
		delete(slot.buf)
		delete(slot.nalus)
	}
	delete(pool.free)
	delete(pool.slots)
	pool^ = {}
}

@(private)
pool_acquire :: proc(pool: ^Frame_Pool) -> (^Frame_Group, bool)  // encoder thread only

@(private)
pool_recycle :: proc(g: ^Frame_Group) {
	pool := g.pool
	assert(g.index >= 0 && g.index < len(pool.slots))
	assert(g == &pool.slots[g.index], "frame group is not the slot it claims to be")
	sync.mutex_lock(&pool.mutex)
	append(&pool.free, g.index)
	sync.mutex_unlock(&pool.mutex)
}

group_release :: proc(g: ^Frame_Group)        // any consumer thread
group_reset       :: proc(g: ^Frame_Group)                  // clear(&g.buf); clear(&g.nalus)
group_append_nalu :: proc(g: ^Frame_Group, nalu: []u8)      // append bytes, then push subslice
group_finish :: proc(g: ^Frame_Group)  // build nalus[] from recorded offsets
