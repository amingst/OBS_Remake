package rtmp

import "libs:flv"
import "libs:h264"
import "core:thread"
import "core:sys/windows"
import "core:log"
import "base:intrinsics"
import "../applog"
import "../encode"

Rtmp_Stream :: struct {
    running:              bool,
    alive:                bool,
    dropped_frames:       u32,
    dropped_audio_blocks: u32,
    thread:               ^thread.Thread,
    event:                windows.HANDLE,
    conn:                 Connection,
    stream_key:           string,
    audio_channels:       u32,
    log_sink:             ^applog.Sink,
    stream_index:         u8,
    log_level:            log.Level,
    enc:                  ^encode.Encoder,
    group_mailbox:        Group_Mailbox,
    group_audio_queue:    Group_Audio_Queue,
}

rtmp_stream_start :: proc(
	enc: ^encode.Encoder,
	app,
	host: string,
	port: int,
	tc_url: string,
	stream_key: string,
	audio_channels: u32,
	log_sink: ^applog.Sink,
	stream_index: u8,
) -> (^Rtmp_Stream, bool) {
	// Register the consumer before connect() -- cheaper to back out of here.
	stream := new(Rtmp_Stream)
	stream.enc = enc
	stream.audio_channels = audio_channels
	stream.stream_key = stream_key
	stream.log_sink = log_sink
	stream.stream_index = stream_index
	intrinsics.atomic_store(&stream.log_level, ODIN_DEBUG ? log.Level.Debug : log.Level.Info)

	event_handle := windows.CreateEventW(
		lpEventAttributes = nil,
		bManualReset = false,
		bInitialState = false,
		lpName = nil,
	)
	if event_handle == nil {
		log.errorf("CreateEventW failed for RTMP stream")
		free(stream)
		return {}, false
	}
	stream.event = event_handle

	if !encode.consumer_add(enc, encode.Consumer{
		put_video = put_video,
		put_audio = put_audio,
		ctx       = stream,
		event     = stream.event,
	}) {
		log.error("consumer_add failed (consumer array full)")
		windows.CloseHandle(stream.event)
		free(stream)
		return {}, false
	}

	// ---- Connect to the RTMP Server ----
	conn, ok := connect(host, port)
	if !ok {
		log.infof("No RTMP Server On %v:%v", host, port)
		encode.consumer_remove(enc, stream)
		windows.CloseHandle(stream.event)
		free(stream)
		return {}, false
	}
	success := false
	defer if !success {
		encode.consumer_remove(enc, stream)
		close(&conn)
		windows.CloseHandle(stream.event)
		free(stream)
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

    // ---- send AVC sequence header (once, at timestamp 0) ----
    avc_config := h264.build_avc_decoder_config(enc.sps, enc.pps)
    defer delete(avc_config)
    seq_header := flv.build_avc_sequence_header(avc_config)
    defer delete(seq_header)

    seq_ok := send_media(&conn, 9, seq_header, 0, CSID_VIDEO)
    if !seq_ok {
    	log.error("send_media (sequence header) failed")
    	return {}, false
    }

    // ---- send AAC sequence header (once, at timestamp 0) ----
    is_stereo := audio_channels == 2
    aac_seq_header := flv.build_aac_sequence_header(enc.aac_config, true, is_stereo)
    defer delete(aac_seq_header)
    audio_seq_ok := send_media(&conn, 8, aac_seq_header, 0, CSID_AUDIO)
    if !audio_seq_ok {
    	log.error("send_media (AAC sequence header) failed")
    	return {}, false
    }

    stream.conn = conn

    intrinsics.atomic_store_explicit(&stream.running, true, .Release)
    intrinsics.atomic_store_explicit(&stream.alive, true, .Release)
    stream.thread = thread.create(rtmp_stream_thread)
    if stream.thread == nil {
    	log.error("Failed to create RTMP thread -- aborting stream start")
    	return {}, false
    }
    stream.thread.data = stream
    thread.start(stream.thread)

    success = true
    return stream, true
}

rtmp_stream_close :: proc(s: ^Rtmp_Stream) {
	// a. consumer_remove must return before anything else. encode holds
	//    consumers_mutex across put, so once remove returns no put is in
	//    flight and none can start.
	encode.consumer_remove(s.enc, s)

	// b. stop and join the thread.
	if s.thread != nil {
		intrinsics.atomic_store_explicit(&s.running, false, .Release)
		windows.SetEvent(s.event)
		thread.join(s.thread)
		thread.destroy(s.thread)
		s.thread = nil
	}

	// c. release every reference still queued.
	group_mailbox_destroy(&s.group_mailbox)
	group_audio_queue_destroy(&s.group_audio_queue)

	// d. close event handle, free stream.
	if s.event != nil { windows.CloseHandle(s.event); s.event = nil }
	log.debug("rtmp stream closed")
	free(s)
}

@(private="file")
put_video :: proc(ctx: rawptr, g: ^encode.Frame_Group) {
	stream := (^Rtmp_Stream)(ctx)
	group_mailbox_put(&stream.group_mailbox, g)
}

@(private="file")
put_audio :: proc(ctx: rawptr, g: ^encode.Frame_Group) {
	stream := (^Rtmp_Stream)(ctx)
	group_audio_queue_put(&stream.group_audio_queue, g)
}

@(private="file")
rtmp_stream_thread :: proc(t: ^thread.Thread) {
	stream := (^Rtmp_Stream)(t.data)

	rtmp_log_ctx := applog.Log_Context{sink = stream.log_sink, tag = {.Rtmp, stream.stream_index}}
	context.logger = applog.make_logger(&rtmp_log_ctx)

	windows.CoInitializeEx(nil, .MULTITHREADED)
	defer windows.CoUninitialize()

	is_stereo := stream.audio_channels == 2

	for intrinsics.atomic_load_explicit(&stream.running, .Acquire) {
		context.logger.lowest_level = intrinsics.atomic_load(&stream.log_level)
 		if windows.WaitForSingleObject(stream.event, 200) != windows.WAIT_OBJECT_0 do continue

		// Drain audio fully before video on each wake.
		for {
			g, take_ok := group_audio_queue_take(&stream.group_audio_queue)
			if !take_ok do break
			aac_frame := flv.build_aac_frame(g.buf[:], true, is_stereo)
			pts := g.pts
			encode.group_release(g)
			send_ok := send_media(&stream.conn, 8, aac_frame, pts, CSID_AUDIO)
			if !send_ok {
				intrinsics.atomic_add(&stream.dropped_audio_blocks, 1)
			}
			delete(aac_frame)
		}

		for {
			g, take_ok := group_mailbox_take(&stream.group_mailbox)
			if !take_ok do break
			payload := flv.build_avc_frame(g.nalus[:], g.is_keyframe)
			pts := g.pts
			encode.group_release(g)
			send_ok := send_media(&stream.conn, 9, payload, pts, CSID_VIDEO)
			if !send_ok {
				intrinsics.atomic_add(&stream.dropped_frames, 1)
				log.warnf("send_media failed, dropped frame")
			}
			delete(payload)
		}

		free_all(context.temp_allocator)
	}

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
