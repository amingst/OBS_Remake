package audio

import "base:intrinsics"
import "core:log"
import "core:sync"
import "core:thread"
import "core:sys/windows"
import "../applog"
import "../encode"

// Runs the mixer on its own thread so that a stall in the render loop cannot
// stall the audio timeline.
//
// Why this exists: audio PTS is derived from the count of blocks the mixer
// has emitted. When mixing ran on the main thread, any UI stall (a modal, a
// slow source switch) stopped block emission while the encoder thread kept
// producing video, leaving audio timestamps permanently behind video and the
// MP4 muxer refusing every video frame from then on.
//
// Threading contract:
//   - The main thread publishes the input list once per frame
//     (mix_publish_inputs) and swaps the encoder pointer when an output
//     starts or stops (mix_set_encoder). Both take mt.mutex.
//   - The mixer thread holds mt.mutex for the whole of each mix pass, so a
//     stream or encoder can never be torn down while a pass is using it, as
//     long as teardown first goes through mix_forget_stream / mix_set_encoder(nil).
//   - Capture threads signal mt.wake after writing to their rings, so the
//     mixer runs as soon as data lands rather than on a fixed poll.
//   - Stream.peak is written here and read by the UI thread without a lock.
//     It is a single aligned f32 used only for meters, so a torn read is
//     impossible on x64 and a stale one is harmless.
Mix_Thread :: struct {
	mutex:   sync.Mutex,
	inputs:  [dynamic]Mix_Input,
	enc:     ^encode.Encoder,
	mixer:   Mixer,
	thread:  ^thread.Thread,
	running: bool,           // atomic
	wake:    windows.HANDLE, // auto-reset event, signalled by capture threads

	// Diagnostics, mixer-thread-only except where noted.
	passes:      u64,
	wake_signal: u64,
	wake_timeout: u64,
}

// Fallback poll interval. A block is ~21ms of audio; capture threads normally
// wake the mixer every WASAPI period (~10ms), so this only matters if no
// capture thread is running.
MIX_WAKE_TIMEOUT_MS :: 10

@(private) g_mix_thread: ^Mix_Thread

mix_thread_start :: proc(mt: ^Mix_Thread) -> bool {
	assert(g_mix_thread == nil, "mix_thread_start called twice")
	mixer_state_init(&mt.mixer)
	mt.inputs = make([dynamic]Mix_Input, 0, 8)

	mt.wake = windows.CreateEventW(nil, false, false, nil)
	if mt.wake == nil {
		log.errorf("mix_thread_start: CreateEventW failed: %v", windows.GetLastError())
		mixer_state_destroy(&mt.mixer)
		delete(mt.inputs)
		return false
	}

	intrinsics.atomic_store_explicit(&mt.running, true, .Release)
	mt.thread = thread.create(mix_thread_proc)
	if mt.thread == nil {
		log.errorf("mix_thread_start: thread.create failed: %v", windows.GetLastError())
		windows.CloseHandle(mt.wake)
		mixer_state_destroy(&mt.mixer)
		delete(mt.inputs)
		return false
	}
	mt.thread.data = mt
	// Publish before start so capture threads can find the wake event.
	intrinsics.atomic_store_explicit(&g_mix_thread, mt, .Release)
	thread.start(mt.thread)
	log.info("audio mixer thread started")
	return true
}

// Stops the thread and frees mixer state. Must run before audio.shutdown()
// closes the streams the mixer may still reference.
mix_thread_stop :: proc(mt: ^Mix_Thread) {
	if mt.thread == nil do return
	intrinsics.atomic_store_explicit(&g_mix_thread, nil, .Release)
	intrinsics.atomic_store_explicit(&mt.running, false, .Release)
	windows.SetEvent(mt.wake)
	thread.join(mt.thread)
	thread.destroy(mt.thread)
	mt.thread = nil
	windows.CloseHandle(mt.wake)
	mt.wake = nil
	log.infof("audio mixer thread stopped: passes=%v wake_signal=%v wake_timeout=%v blocks=%v",
		mt.passes, mt.wake_signal, mt.wake_timeout, mt.mixer.blocks_emitted)
	mixer_state_destroy(&mt.mixer)
	delete(mt.inputs)
}

// Replaces the mixer's input list with a copy of `inputs`. Called by the main
// thread once per frame; cheap (a handful of small structs).
mix_publish_inputs :: proc(inputs: []Mix_Input) {
	mt := intrinsics.atomic_load_explicit(&g_mix_thread, .Acquire)
	if mt == nil do return
	sync.lock(&mt.mutex)
	defer sync.unlock(&mt.mutex)
	clear(&mt.inputs)
	append(&mt.inputs, ..inputs)
}

// Points the mixer at the encoder to feed (or nil to stop feeding). Attaching
// a new encoder restarts the block counter so audio PTS begins at zero on the
// encoder's fresh timeline, matching the video tick counter.
//
// Callers must pass nil BEFORE releasing an encoder: the mixer thread
// dereferences enc under mt.mutex, and this call takes that mutex, so once it
// returns no pass can still be using the old pointer.
mix_set_encoder :: proc(enc: ^encode.Encoder) {
	mt := intrinsics.atomic_load_explicit(&g_mix_thread, .Acquire)
	if mt == nil do return
	sync.lock(&mt.mutex)
	defer sync.unlock(&mt.mutex)
	if enc != nil && enc != mt.enc {
		mt.mixer.blocks_emitted = 0
	}
	mt.enc = enc
}

// Removes every input that refers to `s`. Must be called before the stream
// is closed or freed; returns once no mix pass can still be reading it.
mix_forget_stream :: proc(s: ^Stream) {
	mt := intrinsics.atomic_load_explicit(&g_mix_thread, .Acquire)
	if mt == nil do return
	sync.lock(&mt.mutex)
	defer sync.unlock(&mt.mutex)
	for i := len(mt.inputs) - 1; i >= 0; i -= 1 {
		if mt.inputs[i].stream == s do unordered_remove(&mt.inputs, i)
	}
}

// Total blocks the mixer has emitted on the current encoder timeline.
mix_blocks_emitted :: proc() -> u64 {
	mt := intrinsics.atomic_load_explicit(&g_mix_thread, .Acquire)
	if mt == nil do return 0
	sync.lock(&mt.mutex)
	defer sync.unlock(&mt.mutex)
	return mt.mixer.blocks_emitted
}

// Called by capture threads after they write to their ring.
@(private)
mix_signal_data :: proc() {
	mt := intrinsics.atomic_load_explicit(&g_mix_thread, .Acquire)
	if mt == nil do return
	windows.SetEvent(mt.wake)
}

@(private = "file")
mix_thread_proc :: proc(t: ^thread.Thread) {
	mt := (^Mix_Thread)(t.data)

	// thread.create doesn't inherit the spawning thread's context.logger.
	log_ctx := applog.Log_Context{sink = g_log_sink, tag = {.Audio, 0}}
	context.logger = applog.make_logger(&log_ctx)

	for intrinsics.atomic_load_explicit(&mt.running, .Acquire) {
		switch windows.WaitForSingleObject(mt.wake, MIX_WAKE_TIMEOUT_MS) {
		case windows.WAIT_OBJECT_0: mt.wake_signal += 1
		case windows.WAIT_TIMEOUT:  mt.wake_timeout += 1
		case:
			log.errorf("mix thread: WaitForSingleObject failed: %v", windows.GetLastError())
		}
		if !intrinsics.atomic_load_explicit(&mt.running, .Acquire) do break

		sync.lock(&mt.mutex)
		mix_and_push(&mt.mixer, mt.inputs[:], mt.enc)
		sync.unlock(&mt.mutex)
		mt.passes += 1

		// f32_to_pcm16 and core:log allocate from the per-thread temp arena.
		free_all(context.temp_allocator)
	}

	log.debug("audio mixer thread exiting")
}
