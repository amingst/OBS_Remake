package rtmp

import "libs:mf"
import "libs:flv"
import "libs:h264"
import "core:thread"
import "core:sys/windows"
import "core:log"
import "core:fmt"
import "core:strings"
import "base:intrinsics"

Rtmp_Stream :: struct {
    running:        bool,
    alive:          bool,
    dropped_frames: u32,
    thread:         ^thread.Thread,
    event:          windows.HANDLE,
    mailbox:        ^Frame_Mailbox,
    scratch:        []u8,
    conn:           Connection,
    processor:      ^mf.IMFTransform,
    encoder:        ^mf.IMFTransform,
    sps, pps:       []u8,
    width, height:  u32,
    fps:            u32,
    stream_key: 	string,
}

rtmp_stream_start :: proc(
	mbox: ^Frame_Mailbox,
	app,
	host: string,
	port: int,
	tc_url: string,
	stream_key: string,
	fps: u32,
	width, height, bitrate: u32,
) -> (^Rtmp_Stream, bool) {
	// ---- Connect to the RTMP Server ----
	conn, ok := connect(host, port)
	if !ok {
		log.infof("No RTMP Server On %v:%v", host, port)
		return {}, false
	}
	success := false
	defer if !success {
		close(&conn)
	}

	if !handshake(&conn) {
		log.infof("Handshake with %v:%v failed", host, port)
		return {}, false
	}
	if !send_connect(&conn, app, tc_url) {
		log.infof("Failed to send connection")
		return {}, false
	}

	if !send_set_chunk_size(&conn, 4096) {
		log.infof("send_set_chunk_size failed")
		return {}, false
	}

 	for _ in 0..<4 {
        msg, msg_ok := read_message(&conn)
        if !msg_ok do break
        log.infof("connect reply: type=%v len=%v", msg.type_id, len(msg.payload))
    }

    if !send_create_stream(&conn) {
    	log.infof("send_create_stream failed")
     	return {}, false
    }

    stream_id, id_ok := read_create_stream_result(&conn)
    if !id_ok {
    	log.infof("createStream did not return a stream id")
     	return {}, false
    }
    conn.stream_id = stream_id

    if !send_publish(&conn, stream_key) {
    	log.infof("send_publish failed")
     	return {}, false
    }

    msg, msg_ok := read_message(&conn)
    if !msg_ok {
    	log.infof("No Reply To Publish")
     	return {}, false
    }
    log.infof("publish reply: type=%v len=%v", msg.type_id, len(msg.payload))

    // ---- Init Encoder ----
    hr := mf.MFStartup(mf.MF_VERSION, mf.MFSTARTUP_FULL)
    if hr < 0 {
    	log.errorf("MFStartup failed: 0x%08X", u32(hr))
    	return {}, false
    }
    defer if !success {
    	mf.MFShutdown()
    }

    processor, proc_ok := mf.begin_video_processor(width, height)
    if !proc_ok {
    	log.error("begin_video_processor failed")
     	return {}, false
    }

    encoder, sps, pps, enc_ok := mf.begin_h264_encoder(width, height, u32(fps), bitrate)
    if !enc_ok {
    	mf.end_video_processor(processor)
     	log.error("Begin h264 encoder failed")
      	return {}, false
    }

    if !mf.set_encoder_gop_size(encoder, fps * 2) {
    	log.warnf("set_encoder_gop_size failed -- encoder will use its default keyframe interval")
    }

    // ---- send AVC sequence header (once, at timestamp 0) ----
    // Mirrors commands_test.odin's publish_sequence test -- this send was
    // missing here entirely, which is the likely cause of ffmpeg failing to
    // parse the stream: without it the decoder never receives SPS/PPS.
    avc_config := h264.build_avc_decoder_config(sps, pps)
    defer delete(avc_config)
    seq_header := flv.build_avc_sequence_header(avc_config)
    defer delete(seq_header)

    log.infof("seq header: sps=%v bytes, pps=%v bytes, avc_config=%v bytes, seq_header=%v bytes",
    	len(sps), len(pps), len(avc_config), len(seq_header))
    {
    	dump_n := min(len(seq_header), 32)
    	sb: strings.Builder
    	strings.builder_init(&sb, context.temp_allocator)
    	for b in seq_header[:dump_n] {
    		fmt.sbprintf(&sb, "%02X ", b)
    	}
    	log.infof("seq header first %v bytes: %v", dump_n, strings.to_string(sb))
    }

    seq_ok := send_media(&conn, 9, seq_header, 0, CSID_VIDEO)
    log.infof("send_media (sequence header) returned %v", seq_ok)
    if !seq_ok {
    	mf.end_video_processor(processor)
    	encoder.Release(encoder)
    	delete(sps)
    	delete(pps)
    	log.error("send_media (sequence header) failed")
    	return {}, false
    }

    stream := new(Rtmp_Stream)
    stream.scratch = make([]u8, int(width) * int(height) * 4)
    stream.conn = conn
    stream.processor = processor
    stream.encoder = encoder
    stream.sps = sps
    stream.pps = pps
    stream.width = width
    stream.height = height
    stream.fps = fps
    stream.mailbox = mbox
    stream.stream_key = stream_key

    event_handle := windows.CreateEventW(
    	lpEventAttributes = nil,
     	bManualReset = false,
      	bInitialState = false,
       	lpName = nil
    )
    if event_handle == nil {
    	log.errorf("CreateEventW failed for RTMP stream")
     	windows.CloseHandle(event_handle)
      	return {}, false
    }
    stream.event = event_handle

    intrinsics.atomic_store_explicit(&stream.running, true, .Release)
    intrinsics.atomic_store_explicit(&stream.alive, true, .Release)
    stream.thread = thread.create(rtmp_stream_thread)
    if stream.thread == nil {
    	// All connection/encoder teardown normally happens at the bottom of
    	// rtmp_stream_thread -- if the thread never starts, nothing else ever
    	// runs it, so it must be done here instead of falling through to
    	// success=true with a stream that will never clean itself up.
    	log.error("Failed to create RTMP thread -- aborting stream start")
    	mf.end_video_processor(processor)
    	encoder.Release(encoder)
    	delete(sps)
    	delete(pps)
    	windows.CloseHandle(stream.event)
    	delete(stream.scratch)
    	free(stream)
    	return {}, false
    }
    stream.thread.data = stream
    thread.start(stream.thread)

    success = true
    return stream, true
}

rtmp_stream_close :: proc(s: ^Rtmp_Stream) {
	if s.thread != nil {
		intrinsics.atomic_store_explicit(&s.running, false, .Release)
		windows.SetEvent(s.event)
		thread.join(s.thread)
		thread.destroy(s.thread)
		s.thread = nil
	}

	if s.scratch != nil { delete(s.scratch) }
	if s.event != nil { windows.CloseHandle(s.event); s.event = nil}
	log.debug("rtmp stream closed")
	free(s)
}

@(private="file")
rtmp_stream_thread :: proc(t: ^thread.Thread) {
	// thread.create starts with a fresh default context -- context.logger is
	// NOT inherited from the spawning thread, so every log call in this proc
	// was silently discarded until this was added. Own instance rather than
	// sharing main's: console_logger_proc's fmt.fprintf to os.stdout/stderr
	// is documented not-yet-thread-safe regardless of whether the Logger
	// instance is shared, so a separate instance costs nothing extra and
	// avoids any cross-thread lifetime/destroy-ordering question.
	when ODIN_DEBUG {
		context.logger = log.create_console_logger(.Debug)
	} else {
		context.logger = log.create_console_logger(.Info)
	}
	defer log.destroy_console_logger(context.logger)

	stream := (^Rtmp_Stream)(t.data)

	windows.CoInitializeEx(nil, .MULTITHREADED)
	defer windows.CoUninitialize()

	frame_duration := i64(10_000_000) / i64(stream.fps)
	last_pts: i64 = 0
	take_count: u64 = 0

	for intrinsics.atomic_load_explicit(&stream.running, .Acquire) {
 		if windows.WaitForSingleObject(stream.event, 200) != windows.WAIT_OBJECT_0 do continue
   		_, _, pts, mbox_take_ok := mailbox_take(stream.mailbox, stream.scratch)
      	if !mbox_take_ok do continue

      	take_count += 1
       	if take_count % 60 == 0 {
        	log.infof("mailbox_take #%v: pts=%v, first pixel BGRA = %v %v %v %v",
         	take_count, pts, stream.scratch[0], stream.scratch[1], stream.scratch[2], stream.scratch[3])
        }

       	nalus, encode_bgra_ok := mf.encode_bgra_frame(
        	stream.processor,
         	stream.encoder,
          	stream.scratch,
           	i64(pts),
            frame_duration
        )

        if !encode_bgra_ok {
			intrinsics.atomic_add(&stream.dropped_frames, 1)
			log.infof("encode_bgra_frame failed, dropped frame")
			free_all(context.temp_allocator)
			continue
		}

		if len(nalus) > 0 {
			payload, _ := flv.build_avc_frame(nalus)
			if !send_media(&stream.conn, 9, payload, i64(pts), CSID_VIDEO) {
				intrinsics.atomic_add(&stream.dropped_frames, 1)
				log.warnf("send_media failed, dropped frame")
			}
			delete(payload)
		}

		last_pts = i64(pts)
		for n in nalus do delete(n)
		delete(nalus)
		free_all(context.temp_allocator)
	}

	// ---- drain tail frames from encoder ----
	tail := mf.end_h264_encoder(stream.encoder)
	if len(tail) > 0 {
		payload, _ := flv.build_avc_frame(tail)
		send_media(&stream.conn, 9, payload, last_pts, CSID_VIDEO)
		delete(payload)
	}
	for n in tail do delete(n)
	delete(tail)

	mf.end_video_processor(stream.processor)
	delete(stream.sps)
	delete(stream.pps)
	mf.MFShutdown()

	if !send_fc_unpublish(stream) {
		log.errorf("Failed to unpublish stream")
	}

	if !send_delete_stream(stream) {
		log.errorf("Failed to delete stream")
	}

	close(&stream.conn)

	intrinsics.atomic_store_explicit(&stream.alive, false, .Release)
	intrinsics.atomic_store_explicit(&stream.running, false, .Release)
	log.infof("rtmp stream stopped: dropped %v frames", intrinsics.atomic_load_explicit(&stream.dropped_frames, .Acquire))
}
