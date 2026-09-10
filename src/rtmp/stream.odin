package rtmp

import "libs:mf"
import "libs:flv"
import "libs:h264"
import "core:thread"
import "core:sys/windows"
import "core:log"
import "base:intrinsics"
import "../applog"
import "../encode"

Rtmp_Stream :: struct {
    running:        bool,
    alive:          bool,
    dropped_frames: u32,
    thread:         ^thread.Thread,
    event:          windows.HANDLE,
    mailbox:        ^encode.Raw_Mailbox,
    scratch:        []u8,
    conn:           Connection,
    processor:      ^mf.IMFTransform,
    encoder:        ^mf.IMFTransform,
    sps, pps:       []u8,
    width, height:  u32,
    fps:            u32,
    stream_key:     string,
    aac_config:         []u8,
    audio_encoder:      ^mf.IMFTransform,
    audio_queue:        ^encode.Raw_Audio_Queue,
    audio_sample_rate:  u32,
    audio_scratch:      []u8,
    dropped_audio_blocks: u32,
    audio_channels:     u32,
    log_sink:       ^applog.Sink,
    stream_index:   u8,
    log_level: log.Level
}

rtmp_stream_start :: proc(
	mbox: ^encode.Raw_Mailbox,
	app,
	host: string,
	port: int,
	tc_url: string,
	stream_key: string,
	fps: u32,
	width, height, bitrate: u32,
	audio_channels, audio_bitrate, audio_sample_rate: u32,
	audio_queue: ^encode.Raw_Audio_Queue,
	log_sink: ^applog.Sink,
	stream_index: u8,
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

    // ---- Init Audio Encoder ----
    audio_encoder, aac_config, audio_ok := mf.begin_aac_encoder(audio_sample_rate, audio_channels, audio_bitrate)
    if !audio_ok {
     	mf.end_video_processor(processor)
     	encoder.Release(encoder)
     	delete(sps)
     	delete(pps)
    	log.error("begin_aac_encoder failed")
    	return {}, false
    }

    // ---- send AVC sequence header (once, at timestamp 0) ----
    // Mirrors commands_test.odin's publish_sequence test -- this send was
    // missing here entirely, which is the likely cause of ffmpeg failing to
    // parse the stream: without it the decoder never receives SPS/PPS.
    avc_config := h264.build_avc_decoder_config(sps, pps)
    defer delete(avc_config)
    seq_header := flv.build_avc_sequence_header(avc_config)
    defer delete(seq_header)

    seq_ok := send_media(&conn, 9, seq_header, 0, CSID_VIDEO)
    if !seq_ok {
    	mf.end_video_processor(processor)
    	encoder.Release(encoder)
    	delete(sps)
    	delete(pps)
    	audio_encoder.Release(audio_encoder)
     	delete(aac_config)
    	log.error("send_media (sequence header) failed")
    	return {}, false
    }


    // ---- send AAC sequence header (once, at timestamp 0) ----
    is_stereo := audio_channels == 2
    aac_seq_header := flv.build_aac_sequence_header(aac_config, true, is_stereo)
    defer delete(aac_seq_header)
    audio_seq_ok := send_media(&conn, 8, aac_seq_header, 0, CSID_AUDIO)
    if !audio_seq_ok {
    	mf.end_video_processor(processor)
    	encoder.Release(encoder)
    	delete(sps)
    	delete(pps)
    	audio_encoder.Release(audio_encoder)
    	delete(aac_config)
    	log.error("send_media (AAC sequence header) failed")
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
    stream.aac_config = aac_config
    stream.audio_encoder = audio_encoder
    stream.audio_queue = audio_queue
    stream.audio_sample_rate = audio_sample_rate
    stream.audio_scratch = make([]u8, int(audio_queue.stride))
    stream.audio_channels = audio_channels
    stream.log_sink = log_sink
    stream.stream_index = stream_index
    intrinsics.atomic_store(&stream.log_level, ODIN_DEBUG ? log.Level.Debug : log.Level.Info)

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
     	audio_encoder.Release(audio_encoder)
      	delete(stream.audio_scratch)
        delete(aac_config)
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
	if s.audio_scratch != nil { delete(s.audio_scratch) }
	log.debug("rtmp stream closed")
	free(s)
}

@(private="file")
rtmp_stream_thread :: proc(t: ^thread.Thread) {
	stream := (^Rtmp_Stream)(t.data)

	// thread.create starts with a fresh default context -- context.logger is
	// NOT inherited from the spawning thread, so every log call in this proc
	// was silently discarded until this was added. rtmp_log_ctx is a local of
	// this proc (not the spawning proc) so the pointer make_logger stashes in
	// the Logger stays valid for the thread's whole lifetime.
	rtmp_log_ctx := applog.Log_Context{sink = stream.log_sink, tag = {.Rtmp, stream.stream_index}}
	context.logger = applog.make_logger(&rtmp_log_ctx)

	windows.CoInitializeEx(nil, .MULTITHREADED)
	defer windows.CoUninitialize()

	samples_per_block := stream.audio_queue.stride / (stream.audio_channels * 2)
	is_stereo := stream.audio_channels == 2
	audio_block_duration := i64(samples_per_block) * 10_000_000 / i64(stream.audio_sample_rate)
	frame_duration := i64(10_000_000) / i64(stream.fps)
	last_pts: i64 = 0
	last_audio_pts: i64 = 0
	audio_take_count: u64 = 0

	for intrinsics.atomic_load_explicit(&stream.running, .Acquire) {
		// Loaded every iteration (not just once at thread start) so a runtime
		// change to stream.log_level takes effect without restarting the
		// stream. core:log's logf checks this before formatting/allocating,
		// so this is the only place the per-packet noise below is actually
		// gated -- a check inside the backend would still pay the cost.
		context.logger.lowest_level = intrinsics.atomic_load(&stream.log_level)
 		if windows.WaitForSingleObject(stream.event, 200) != windows.WAIT_OBJECT_0 do continue
	   for {
		       audio_pts, take_ok := encode.audio_queue_take(stream.audio_queue, stream.audio_scratch)
		       if !take_ok do break
		      	audio_take_count += 1
		       	if audio_take_count % 60 == 0 {
		        	log.debugf("audio_queue_take #%v: pts=%v",
		         	audio_take_count, audio_pts)
		        }
			   aac_data, encode_aac_ok := mf.encode_aac_frame(stream.audio_encoder, stream.audio_scratch, audio_pts, audio_block_duration)
			   if !encode_aac_ok {
					intrinsics.atomic_add(&stream.dropped_audio_blocks, 1)
					log.infof("encode_aac_frame failed, dropped block")
					continue
				}

				if len(aac_data) > 0 {
					for data in aac_data {
						aac_frame := flv.build_aac_frame(data, true, is_stereo)
						if !send_media(&stream.conn, 8, aac_frame, i64(audio_pts), CSID_AUDIO) {
							intrinsics.atomic_add(&stream.dropped_audio_blocks, 1)
							log.infof("send_media failed, dropped block")
						}
						delete(aac_frame)
					}
				}

				last_audio_pts = i64(audio_pts)
				for data in aac_data do delete(data)
				delete(aac_data)
				free_all(context.temp_allocator)
	   }
   		_, _, pts, mbox_take_ok := encode.mailbox_take(stream.mailbox, stream.scratch)
      	if !mbox_take_ok do continue

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
			// TEMPORARY: recomputed here. Once the shared encoder thread lands, the
			// flag travels on the frame group and this becomes g.is_keyframe.
			payload := flv.build_avc_frame(nalus, h264.contains_idr(nalus))
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
		// TEMPORARY: recomputed here. Once the shared encoder thread lands, the
		// flag travels on the frame group and this becomes g.is_keyframe.
		payload := flv.build_avc_frame(tail, h264.contains_idr(tail))
		send_media(&stream.conn, 9, payload, last_pts, CSID_VIDEO)
		delete(payload)
	}
	for n in tail do delete(n)
	delete(tail)

	audio_tail := mf.end_aac_encoder(stream.audio_encoder)
	if len(audio_tail) > 0 {
		for data in audio_tail {
			aac_frame := flv.build_aac_frame(data, true, is_stereo)
			if !send_media(&stream.conn, 8, aac_frame, i64(last_audio_pts), CSID_AUDIO) {
				intrinsics.atomic_add(&stream.dropped_audio_blocks, 1)
				log.infof("send_media failed, dropped block")
			}
			delete(aac_frame)
		}
	}
	for data in audio_tail do delete(data)
	delete(audio_tail)

	mf.end_video_processor(stream.processor)
	delete(stream.sps)
	delete(stream.pps)
	delete(stream.aac_config)

	if !send_fc_unpublish(stream) {
		log.errorf("Failed to unpublish stream")
	}

	if !send_delete_stream(stream) {
		log.errorf("Failed to delete stream")
	}

	close(&stream.conn)

	intrinsics.atomic_store_explicit(&stream.alive, false, .Release)
	intrinsics.atomic_store_explicit(&stream.running, false, .Release)
	log.infof("rtmp stream stopped: dropped %v video frame(s), %v audio block(s)",
	    intrinsics.atomic_load_explicit(&stream.dropped_frames, .Acquire),
	    intrinsics.atomic_load_explicit(&stream.dropped_audio_blocks, .Acquire))
}
