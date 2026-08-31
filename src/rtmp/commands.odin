package rtmp

import "core:log"

send_connect :: proc(
	c: ^Connection,
	app,
	tc_url: string
) -> bool {
	payload := make([dynamic]u8, context.temp_allocator)
	// Connect Header
	amf_write_string(&payload, "connect")
	amf_write_number(&payload, 1)

	// Write Object
	amf_begin_object(&payload)
	amf_write_key(&payload, "app")
	amf_write_string(&payload, app)
	amf_write_key(&payload, "flashVer")
	amf_write_string(&payload, "FMLE/3.0 (compatible; OBSRemake)")
	amf_write_key(&payload, "tcUrl")
	amf_write_string(&payload, tc_url)
	amf_write_key(&payload, "fpad")
	amf_write_boolean(&payload, false)
	amf_write_key(&payload, "capabilities")
	amf_write_number(&payload, 15)
	amf_write_key(&payload, "audioCodecs")
	amf_write_number(&payload, 4071)
	amf_write_key(&payload, "videoCodecs")
	amf_write_number(&payload, 252)
	amf_write_key(&payload, "videoFunction")
	amf_write_number(&payload, 1)
	amf_end_object(&payload)

	msg := Message{
		csid = 3,
		type_id = 20,
		stream_id = 0,
		timestamp = 0,
		payload = payload[:]
	}

	buf := make([]u8, len(payload) + 256, context.temp_allocator)
	n := encode_message(buf, msg, c.chunk_size, &c.chunk_states)
	if n < 0 {
		log.warn("connect: message did not fit in encode buffer")
		return false
	}

	if !send_all(c.socket, buf[:n]) {
		log.warn("connect: send failed")
		return false
	}

	log.infof("RTMP connect sent (app=%q tcUrl=%q)", app, tc_url)
	return true
}

send_set_chunk_size :: proc(c: ^Connection, size: u32) -> bool {
	if size == 0 || size & 0x8000_0000 != 0 {
		log.warnf("setChunkSize: invalid size %v (must be 1..0x7FFFFFFF)", size)
		return false
	}

	payload := make([]u8, 4, context.temp_allocator)
	payload[0] = u8(size >> 24)
	payload[1] = u8(size >> 16)
	payload[2] = u8(size >> 8)
	payload[3] = u8(size)

	msg := Message{
		csid = 2,
		type_id = 1,
		stream_id = 0,
		timestamp = 0,
		payload = payload,
	}

	buf := make([]u8, len(payload) + 256, context.temp_allocator)
	// Encode at the current chunk size -- the server doesn't know about the
	// new size until this message arrives, so it must go out at the old one.
	n := encode_message(buf, msg, c.chunk_size, &c.chunk_states)
	if n < 0 {
		log.warn("setChunkSize: message did not fit in encode buffer")
		return false
	}

	if !send_all(c.socket, buf[:n]) {
		log.warn("setChunkSize: send failed")
		return false
	}

	c.chunk_size = size
	log.infof("RTMP set chunk size sent (size=%v)", size)
	return true
}

read_message :: proc(c: ^Connection) -> (Message, bool) {
	for {
		// Read 1 byte basic header
		bh: [1]u8
		if !read_exact(c.socket, bh[:]) do return {}, false
		fmt_type := bh[0] >> 6
		csid := u32(bh[0] & 0x3F)

		// Check the csid extended forms
		if csid == 0 {
			ext: [1]u8
			if !read_exact(c.socket, ext[:]) do return {}, false
			csid = u32(ext[0]) + 64
		} else if csid == 1 {
			ext: [2]u8
			if !read_exact(c.socket, ext[:]) do return {}, false
			csid = u32(ext[0]) + u32(ext[1]) * 256 + 64
		}

		hdr: [11]u8
		hdr_len := 0

		// Read message header
		// Set size with respect to fmt_type
		switch fmt_type {
		case 0: hdr_len = 11
		case 1: hdr_len = 7
		case 2: hdr_len = 3
		case 3: hdr_len = 0
		}

		if hdr_len > 0 {
			if !read_exact(c.socket, hdr[:hdr_len]) do return {}, false
		}

		_, seen := c.incoming[csid]
		if !seen {
			if fmt_type != 0 {
				log.warnf("rtmp: fmt %v chunk on unseen csid %v", fmt_type, csid)
			}
			c.incoming[csid] = Incoming_Chunk_State{}
		}
		state := &c.incoming[csid]

		ts_field: u32
		if hdr_len > 0 do ts_field = read_u24(hdr[0:3])

		// Interperet hdr with respect to fmt_type
		switch fmt_type {
		case 0:
			state.timestamp = ts_field
			state.length = read_u24(hdr[3:6])
			state.type_id = hdr[6]
			state.stream_id = u32(hdr[7]) | u32(hdr[8])<<8 | u32(hdr[9])<<16 | u32(hdr[10])<<24
			state.timestamp_delta = 0
		case 1:
			state.timestamp_delta = ts_field
			state.timestamp += state.timestamp_delta
			state.length = read_u24(hdr[3:6])
			state.type_id = hdr[6]
		case 2:
			state.timestamp_delta = ts_field
			state.timestamp += state.timestamp_delta
		case 3:
			if len(state.buffer) == 0 {
				state.timestamp += state.timestamp_delta
			}
		}

		if fmt_type == 3 ? state.extended : ts_field == 0xFFFFFF {
			ext: [4]u8
			if !read_exact(c.socket, ext[:]) do return {}, false
			actual := u32(ext[0])<<24 | u32(ext[1])<<16 | u32(ext[2])<<8 | u32(ext[3])
			switch fmt_type {
			case 0:
				state.timestamp = actual
			case 1, 2:
				state.timestamp_delta = actual
				state.timestamp = state.timestamp - 0xFFFFFF + actual
			}
			state.extended = true
		} else if fmt_type != 3 {
			state.extended = false
		}

		// Read Payload
		to_read := min(int(c.peer_chunk_size), int(state.length) - len(state.buffer))
		if to_read < 0 || state.length > 16 * 1024 * 1024 {
			log.errorf("rtmp: implausible message length %v on csid %v -- stream desynced",
				state.length, csid)
			return {}, false
		}
		start := len(state.buffer)
		resize(&state.buffer, start + to_read)
		if !read_exact(c.socket, state.buffer[start:]) do return {}, false

		if len(state.buffer) < int(state.length) do continue

		if state.type_id == 1 {
			if len(state.buffer) >= 4 {
				c.peer_chunk_size = u32(state.buffer[0])<<24 | u32(state.buffer[1])<<16 |
					u32(state.buffer[2])<<8 | u32(state.buffer[3])
				log.infof("rtmp: peer chunk size now %v (raw bytes %v)",
					c.peer_chunk_size, state.buffer[0:4])
			}
			clear(&state.buffer)
			continue
		}

		msg: Message = {
			type_id = state.type_id,
			csid = csid,
			stream_id = state.stream_id,
			timestamp = state.timestamp,
			payload = state.buffer[:],
		}

		clear(&state.buffer)
		return msg, true
	}
}

send_create_stream :: proc(c: ^Connection) -> bool {
	payload := make([dynamic]u8, context.temp_allocator)

	amf_write_string(&payload, "createStream")
	amf_write_number(&payload, 2)
	amf_write_null(&payload)

	if !send_command(c, payload[:], 3, 0) {
		log.warn("createStream: send failed")
		return false
	}

	log.info("RTMP createStream sent")
	return true
}

read_create_stream_result :: proc(c: ^Connection) -> (u32, bool) {
	for {
		msg, ok := read_message(c)
		if !ok do return 0, false

		if msg.type_id != 20 do continue

		offset := 0
		name, name_ok := amf_read_string(msg.payload, &offset)
		if !name_ok do return 0, false

		if name != "_result" {
			// Servers interleave other commands -- ffmpeg sends onBWDone after
			// the connect result. Only _error is worth failing on.
			if name == "_error" {
				log.warn("createStream: server returned _error")
				return 0, false
			}
			log.debugf("createStream: skipping %q while waiting for _result", name)
			continue
		}

		if !amf_skip_value(msg.payload, &offset) do return 0, false  // transaction id
		if !amf_skip_value(msg.payload, &offset) do return 0, false  // command object

		id, id_ok := amf_read_number(msg.payload, &offset)
		if !id_ok do return 0, false

		return u32(id), true
	}
}

send_publish :: proc(c: ^Connection, stream_key: string, stream_id: u32) -> bool {
	payload := make([dynamic]u8, context.temp_allocator)
	amf_write_string(&payload, "publish")
	amf_write_number(&payload, 3)
	amf_write_null(&payload)
	amf_write_string(&payload, stream_key)
	amf_write_string(&payload, "live")

	if !send_command(c, payload[:], 4, stream_id) {
		log.warn("publish: send failed")
		return false
	}

	log.info("RTMP publish sent")
	return true
}

@(private)
read_u24 :: proc(b: []u8) -> u32 {
	return u32(b[0])<<16 | u32(b[1])<<8 | u32(b[2])
}

@(private="file")
send_command :: proc(c: ^Connection, payload: []u8, csid: u32, stream_id: u32) -> bool {
	msg := Message{
		csid = csid,
		type_id = 20,
		stream_id = stream_id,
		timestamp = 0,
		payload = payload
	}

	buf := make([]u8, len(payload) + 256, context.temp_allocator)
	n := encode_message(buf, msg, c.chunk_size, &c.chunk_states)
	if n < 0 {
		log.warn("rtmp: command did not fit in encode buffer")
		return false
	}

	return send_all(c.socket, buf[:n])
}
