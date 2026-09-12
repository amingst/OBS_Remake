package mp4

// Integration/leak check for mp4_sink_start/mp4_sink_stop, run manually via
// `odin test src/mp4 -collection:libs=libs -vet -vet-shadowing -debug` --
// not wired into test.bat since it needs a real encoder thread + real MFTs,
// same category as libs/mf's solid-clip tests. Exercises the same path
// main.odin's frame loop uses (encode.mailbox_put/audio_queue_put ->
// encoder thread -> consumer fan-out -> this package's put_video/put_audio),
// not a hand-crafted shortcut into the sink.

import "core:testing"
import "core:sys/windows"
import "core:os"
import "core:mem"
import "core:log"
import "core:path/filepath"
import mf "libs:mf"
import "../encode"
import "../applog"

@(test)
test_mp4_sink_start_stop_leak_clean :: proc(t: ^testing.T) {
	hr := windows.CoInitializeEx(nil, .MULTITHREADED)
	if !testing.expect(t, hr >= 0, "CoInitializeEx failed") do return
	defer windows.CoUninitialize()

	mf_hr := mf.MFStartup(mf.MF_VERSION, mf.MFSTARTUP_FULL)
	if !testing.expect(t, mf_hr >= 0, "MFStartup failed") do return
	defer mf.MFShutdown()

	// Not deferred -- everything allocated under the tracking allocator
	// (encoder pools, log sink, local buffers, the sink itself) must be
	// explicitly freed BEFORE the leak check below, or this would flag its
	// own still-alive-on-purpose state as a leak. See the explicit cleanup
	// block at the end of this test, mirroring main.odin's own end-of-run
	// tracking-allocator check.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	log_sink := applog.sink_init(256)

	WIDTH  :: 160
	HEIGHT :: 120
	FPS    :: 10

	enc, enc_ok := encode.encoder_acquire(encode.Encoder_Config{
		width              = WIDTH,
		height             = HEIGHT,
		fps                = FPS,
		bitrate            = 500_000,
		audio_sample_rate  = 48000,
		audio_channels     = 2,
		audio_bitrate      = 16000,
		frame_duration     = i64(10_000_000) / i64(FPS),
		log_sink           = log_sink,
	})
	if !testing.expect(t, enc_ok, "encoder_acquire failed") {
		applog.sink_destroy(log_sink)
		mem.tracking_allocator_destroy(&track)
		return
	}

	if err := os.make_directory("build"); err != nil && err != os.General_Error.Exist {
		log.warnf("could not create build directory: %v", err)
	}
	test_output_dir :: "build/test-output"
	if err := os.make_directory(test_output_dir); err != nil && err != os.General_Error.Exist {
		log.warnf("could not create %s directory: %v", test_output_dir, err)
	}

	out_path, jerr := filepath.join({test_output_dir, "mp4_sink_leak_check.mp4"})
	if !testing.expect(t, jerr == nil, "could not build test output path") {
		encode.encoder_release()
		applog.sink_destroy(log_sink)
		mem.tracking_allocator_destroy(&track)
		return
	}

	sink, sink_ok := mp4_sink_start(enc, out_path)
	if !testing.expect(t, sink_ok, "mp4_sink_start failed") {
		delete(out_path)
		encode.encoder_release()
		applog.sink_destroy(log_sink)
		mem.tracking_allocator_destroy(&track)
		return
	}

	bgra := make([]u8, WIDTH * HEIGHT * 4)
	for i in 0 ..< len(bgra) do bgra[i] = 128

	AUDIO_BLOCK_SAMPLES :: 1024
	pcm := make([]u8, AUDIO_BLOCK_SAMPLES * 2 * 2) // samples * channels * 2 bytes

	FRAME_COUNT :: 30
	frame_duration := i64(10_000_000) / i64(FPS)
	for i in 0 ..< FRAME_COUNT {
		pts := i64(i) * frame_duration
		encode.mailbox_put(enc.raw_mailbox, bgra, WIDTH, HEIGHT)
		// Video wake is now driven by the encoder's waitable timer, not an
		// event from the main thread. The encoder thread picks up mailbox
		// contents on its next timer tick.
		if encode.audio_queue_put(enc.pcm_queue, pcm, pts) {
			windows.SetEvent(enc.audio_event)
		}
		windows.Sleep(20)
	}
	windows.Sleep(300) // let the encoder thread and this sink's feeder thread drain

	mp4_sink_signal_stop(sink)
	for !mp4_sink_is_stopped(sink) {
		windows.Sleep(50)
	}
	mp4_sink_reap(sink)

	info, stat_err := os.stat(out_path, context.allocator)
	if testing.expect(t, stat_err == nil, "os.stat on output file failed") {
		testing.expectf(t, info.size > 1000, "output file suspiciously small: %v bytes", info.size)
		os.file_info_delete(info, context.allocator)
	}

	// Everything above is explicitly torn down here, BEFORE the leak check --
	// see the comment on `track`'s declaration.
	delete(pcm)
	delete(bgra)
	delete(out_path)
	encode.encoder_release()
	applog.sink_destroy(log_sink)

	leaked := len(track.allocation_map)
	if leaked > 0 {
		for _, entry in track.allocation_map {
			log.errorf("leaked %v byte(s) @ %v", entry.size, entry.location)
		}
	}
	testing.expectf(t, leaked == 0, "%v allocation(s) leaked", leaked)

	mem.tracking_allocator_destroy(&track)
}
