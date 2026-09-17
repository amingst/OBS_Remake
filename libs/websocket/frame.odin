package websocket

MAX_HEADER :: 14
MAX_CONTROL_PAYLOAD :: 125

Opcode :: enum u8 {
	Continuation = 0x0,
	Text         = 0x1,
	Binary       = 0x2,
	Close        = 0x8,
	Ping         = 0x9,
	Pong         = 0xA,
}

is_control :: proc(op: Opcode) -> bool {
	return op == .Close || op == .Ping || op == .Pong
}

Frame_Header :: struct {
	fin:         bool,
	opcode:      Opcode,
	masked:      bool,
	mask_key:    [4]u8, // only meaningful when masked
	payload_len: u64,   // bytes of payload following the header
}

Frame_Error :: enum {
	None,
	Need_More,          // src doesn't hold a whole header yet -- read more, not an error
	Reserved_Bits,      // RSV1..3 set, but no extension was negotiated
	Bad_Opcode,         // reserved opcode
	Fragmented_Control, // control frame with FIN clear
	Control_Too_Long,   // control frame payload over 125 bytes
	Length_Not_Minimal, // 126/127 used for a length that fits a shorter form
	Length_Too_Large,   // 64-bit length with the top bit set, or over max(int)
}


encode_header :: proc(h: Frame_Header, dst: ^[MAX_HEADER]u8) -> int {
	// TODO
	return 0
}

decode_header :: proc(src: []u8) -> (h: Frame_Header, header_len: int, err: Frame_Error) {
	// TODO
	return {}, 0, .Need_More
}

apply_mask :: proc(payload: []u8, key: [4]u8, offset := 0) {
	// TODO
}

close_code_for :: proc(err: Frame_Error) -> u16 {
	// TODO
	return 1002
}
