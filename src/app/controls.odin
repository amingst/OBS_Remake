package app

import "core:fmt"
import "core:log"
import "core:path/filepath"
import "core:time"

import "../applog"
import "../config"
import "../encode"
import "../mp4"
import "../render"
import "../rtmp"
import "../show"
import "../ui"

Output_State :: struct {
	recording:       bool,
	streaming:       bool,
	rtmp_stream:     ^rtmp.Rtmp_Stream,
	mp4_sink:        ^mp4.Mp4_Sink,
	finalizing_sink: ^mp4.Mp4_Sink,
	enc:             ^encode.Encoder,
}

// Release encoder when the last output stops.  A finalizing sink still
// has its consumer registered (the feeder thread is still running), so
// the encoder must stay alive until the sink is reaped.
maybe_release_encoder :: proc(output: ^Output_State) {
	if output.recording || output.streaming || output.finalizing_sink != nil do return
	encode.encoder_release()
	output.enc = nil
}

// Dispatches a Controls panel request raised by ui; always clears the request.
// First output start acquires the encoder, last output stop releases it.
// stream_output is the show's single output (multi-output fan-out is future
// work -- see the show file spec) and feeds both recording and streaming,
// since there's one encode shared across everything, not one per output.
handle_controls_request :: proc(
	req:               ui.Controls_Request,
	state:             ^ui.Controls_State,
	output:            ^Output_State,
	paths:             ^config.Paths,
	target:            ^render.Target,
	fps:               i32,
	stream_output:     show.Show_Stream_Output,
	log_sink:          ^applog.Sink,
	blocks_emitted:    ^u64,
) {
	state.request = .None

	// Acquires the encoder on the first output start.
	ensure_encoder :: proc(
		output: ^Output_State, target: ^render.Target, fps: i32,
		bitrate_kbps: int, log_sink: ^applog.Sink,
		blocks_emitted: ^u64,
	) -> bool {
		if output.enc != nil do return true
		if fps <= 0 {
			log.errorf("ensure_encoder: fps is %v, cannot compute frame_duration", fps)
			return false
		}
		encoder_cfg := encode.Encoder_Config{
			width              = target.width,
			height             = target.height,
			fps                = u32(fps),
			bitrate            = u32(bitrate_kbps) * 1000,
			audio_sample_rate  = 48000,
			audio_channels     = 2,
			audio_bitrate      = 16000,
			frame_duration     = i64(10_000_000) / i64(fps),
			log_sink           = log_sink,
		}
		enc, enc_ok := encode.encoder_acquire(encoder_cfg)
		if !enc_ok do return false
		output.enc = enc
		blocks_emitted^ = 0
		return true
	}

	#partial switch req {
	case .Start_Recording:
		if output.recording do return
		if output.finalizing_sink != nil {
			log.warn("recording requested while previous recording is still finalizing")
			return
		}
		if paths.videos == "" {
			log.warn("recording requested, but no videos directory is available")
			return
		}

		if !ensure_encoder(output, target, fps, stream_output.bitrate_kbps, log_sink,
			blocks_emitted) {
			log.warn("recording requested, but encoder_acquire failed")
			return
		}

		year, month, day := time.date(time.now())
		hour, min, sec := time.clock(time.now())
		filename := fmt.aprintf("recording_%4d-%02d-%02d_%02d-%02d-%02d.mp4",
			year, int(month), day, hour, min, sec)
		defer delete(filename)

		out_path, jerr := filepath.join({paths.videos, filename})
		if jerr != nil {
			log.warnf("could not build recording output path: %v", jerr)
			maybe_release_encoder(output)
			return
		}
		// mp4_sink_start (via mf.begin_mp4_sink -> MFCreateFile) converts this
		// to a wide string synchronously and doesn't retain the Odin string,
		// so it's safe to free right after the call returns.
		defer delete(out_path)

		sink, sink_ok := mp4.mp4_sink_start(output.enc, out_path)
		if sink_ok {
			output.mp4_sink = sink
			output.recording = true
			log.infof("recording started (video+audio) -> %v", out_path)
		} else {
			log.warn("failed to start recording (cause logged above)")
			maybe_release_encoder(output)
		}

	case .Stop_Recording:
		if !output.recording do return
		mp4.mp4_sink_signal_stop(output.mp4_sink)
		output.finalizing_sink = output.mp4_sink
		output.mp4_sink = nil
		output.recording = false
		log.info("recording stop signalled, finalizing")

	case .Start_Streaming:
		if output.streaming do return

		rtmp_data, is_rtmp := stream_output.data.(show.RTMP_Output_Data)
		if !stream_output.enabled || !is_rtmp || rtmp_data.url == "" || rtmp_data.key == "" {
			log.warn("streaming requested, but no stream destination is configured")
			return
		}
		host, app, tc_url, port, parse_ok := rtmp.parse_url(rtmp_data.url, context.temp_allocator)
		if !parse_ok {
			log.warnf("streaming requested, but the server URL %q could not be parsed (expected rtmp://host[:port]/app)", rtmp_data.url)
			return
		}

		if !ensure_encoder(output, target, fps, stream_output.bitrate_kbps, log_sink,
			blocks_emitted) {
			log.warn("streaming requested, but encoder_acquire failed")
			return
		}

		STREAM_AUDIO_CHANNELS :: 2

		// stream_index 0: a single stream is all this build supports today.
		// A real id generator/registry belongs with fan-out, not here.
		stream, stream_ok := rtmp.rtmp_stream_start(
			output.enc, app, host, port, tc_url,
			rtmp_data.key, STREAM_AUDIO_CHANNELS,
			log_sink, 0)
		if stream_ok {
			output.rtmp_stream = stream
			output.streaming = true
			log.infof("streaming started -> %v:%v/%v", host, port, app)
		} else {
			log.warn("failed to start streaming (cause logged above)")
			maybe_release_encoder(output)
		}

	case .Stop_Streaming:
		if !output.streaming do return
		rtmp.rtmp_stream_close(output.rtmp_stream)
		output.rtmp_stream = nil
		output.streaming = false
		maybe_release_encoder(output)
		log.info("streaming stopped")
	}
}
