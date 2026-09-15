package rtmp

import "core:encoding/endian"

Message :: struct {
	csid:      u32,
	type_id:   u8,
	stream_id: u32,
	timestamp: u32,
	payload:   []u8,
}

// Per-chunk-stream memory of the last message sent, so headers 1-3 can omit
// fields that haven't changed. Keyed by csid in the caller's map.
Chunk_State :: struct {
	has_previous:    bool,
	timestamp:       u32,
	timestamp_delta: u32,
	length:          u32,
	type_id:         u8,
	stream_id:       u32,
}

Incoming_Chunk_State :: struct {
	timestamp:       u32,
	timestamp_delta: u32,
	length:          u32,
	type_id:         u8,
	stream_id:       u32,
	buffer: 		 [dynamic]u8,
	extended: 		 bool
}

// Writes msg into dst as one or more chunks. Returns bytes written, or -1 if
// dst is too small (dst and states are left untouched in that case).
encode_message :: proc(dst: []u8, msg: Message, chunk_size: u32, states: ^map[u32]Chunk_State) -> int {
	state := states[msg.csid]

	// Pick the smallest header format the previous message allows.
	fmt_type: u8
	delta: u32 = 0
	if !state.has_previous || state.stream_id != msg.stream_id || msg.timestamp < state.timestamp {
		fmt_type = 0 // New stream, first chunk, or time went backwards
	} else {
		delta = msg.timestamp - state.timestamp

		if len(msg.payload) != int(state.length) || msg.type_id != state.type_id {
			fmt_type = 1 // Length or type changed
		} else if delta != state.timestamp_delta {
			fmt_type = 2 // Only timestamp changed
		} else {
			fmt_type = 3 // Everything is the same
		}
	}

	// Bounds check before writing anything, so a short buffer can't desync the chunk state.
	if required := encoded_size(msg, fmt_type, delta, chunk_size); required > len(dst) {
		return -1
	}

	payload_len := len(msg.payload)
	bytes_written := 0
	bytes_processed := 0

	// do-while: a zero-length payload is legal and still needs its header
	// written, which a plain `for bytes_processed < payload_len` would skip.
	for {
		remaining := payload_len - bytes_processed
		current_chunk_size := min(int(chunk_size), remaining)

		current_fmt: u8 = bytes_processed == 0 ? fmt_type : 3

		bytes_written += write_basic_header(dst[bytes_written:], current_fmt, msg.csid)
		bytes_written += write_message_header(dst[bytes_written:], current_fmt, msg, delta, fmt_type)

		if current_chunk_size > 0 {
			copy(dst[bytes_written:], msg.payload[bytes_processed:bytes_processed + current_chunk_size])
			bytes_written += current_chunk_size
			bytes_processed += current_chunk_size
		}

		if bytes_processed >= payload_len do break
	}

	states[msg.csid] = Chunk_State{
		has_previous    = true,
		timestamp       = msg.timestamp,
		timestamp_delta = delta,
		length          = u32(payload_len),
		type_id         = msg.type_id,
		stream_id       = msg.stream_id,
	}

	return bytes_written
}

// Exact byte count encode_message will produce, so the bounds check above can
// be a single up-front comparison rather than a check at every write.
	@(private = "file")
	encoded_size :: proc(msg: Message, fmt_type: u8, delta: u32, chunk_size: u32) -> int {
		basic := 1
		if msg.csid > 319 {
			basic = 3
		} else if msg.csid > 63 {
			basic = 2
		}

		header: int
		switch fmt_type {
		case 0: header = 11
		case 1: header = 7
		case 2: header = 3
		case:   header = 0
		}

		// The extended timestamp is repeated on every chunk of the message, not
		// just the first -- including fmt-3 continuations, whose message header is
		// otherwise zero bytes.
		ts := fmt_type == 0 ? msg.timestamp : delta
		ext := ts >= 0xFFFFFF ? 4 : 0

		payload_len := len(msg.payload)
		chunks := 1
		if payload_len > 0 {
			chunks = (payload_len + int(chunk_size) - 1) / int(chunk_size)
		}

		// First chunk carries the chosen header; the rest are fmt 3 (basic header
		// only, plus the extended timestamp if there is one).
		total := basic + header + ext + min(payload_len, int(chunk_size))
		total += (chunks - 1) * (basic + ext)
		total += payload_len - min(payload_len, int(chunk_size))
		return total
	}


@(private = "file")
write_basic_header :: proc(dst: []u8, fmt_type: u8, csid: u32) -> int {
	// fmt_type occupies the top 2 bits.
	fmt_bits := fmt_type << 6

	if csid <= 63 {
		// 1-byte form (CSIDs 2-63)
		dst[0] = fmt_bits | u8(csid)
		return 1
	} else if csid <= 319 {
		// 2-byte form: a CSID field of 0 signals it
		dst[0] = fmt_bits
		dst[1] = u8(csid - 64)
		return 2
	} else {
		// 3-byte form: a CSID field of 1 signals it
		dst[0] = fmt_bits | 1
		calc := csid - 64
		// Little-endian here, unlike almost everything else in RTMP.
		dst[1] = u8(calc & 0xFF)
		dst[2] = u8(calc >> 8)
		return 3
	}
}

@(private = "file")
put_u24_be :: proc(dst: []u8, val: u32) {
	dst[0] = u8((val >> 16) & 0xFF)
	dst[1] = u8((val >> 8) & 0xFF)
	dst[2] = u8(val & 0xFF)
}

// msg_fmt is the message's own format; fmt_type is this chunk's (3 for continuations).
@(private = "file")
write_message_header :: proc(dst: []u8, fmt_type: u8, msg: Message, delta: u32, msg_fmt: u8) -> int {
	time_val := msg_fmt == 0 ? msg.timestamp : delta

	// A 24-bit field can't hold it, so write the sentinel and follow with the
	// full 32-bit value.
	extended := time_val >= 0xFFFFFF
	field_val := extended ? u32(0xFFFFFF) : time_val

	bytes_written := 0
	payload_len := u32(len(msg.payload))

	switch fmt_type {
	case 0: // 11 bytes
		put_u24_be(dst[0:3], field_val)
		put_u24_be(dst[3:6], payload_len)
		dst[6] = msg.type_id
		// Stream ID is little-endian in fmt 0 -- the one such field in RTMP.
		endian.put_u32(dst[7:11], .Little, msg.stream_id)
		bytes_written = 11

	case 1: // 7 bytes
		put_u24_be(dst[0:3], field_val)
		put_u24_be(dst[3:6], payload_len)
		dst[6] = msg.type_id
		bytes_written = 7

	case 2: // 3 bytes
		put_u24_be(dst[0:3], field_val)
		bytes_written = 3

	case 3: // 0 bytes
		bytes_written = 0
	}

	if extended {
		endian.put_u32(dst[bytes_written:bytes_written + 4], .Big, time_val)
		bytes_written += 4
	}

	return bytes_written
}
