package rtmp

import "core:log"

amf_write_number  :: proc(buf: ^[dynamic]u8, v: f64) {
	append(buf, u8(0x00))
	append_be(buf, transmute(u64)v, 8)
}

amf_write_boolean :: proc(buf: ^[dynamic]u8, v: bool) {
	append(buf, u8(0x01))
	append(buf, v ? u8(1) : u8(0))
}

amf_write_string  :: proc(buf: ^[dynamic]u8, s: string) {
	append(buf, u8(0x02))
	append_be(buf, u64(len(s)), 2)
	append(buf, ..transmute([]u8)s)
}

amf_write_null    :: proc(buf: ^[dynamic]u8) {
	append(buf, u8(0x05))
}

// Objects are written as a marker, then key/value pairs, then the terminator.
amf_begin_object  :: proc(buf: ^[dynamic]u8) {
	append(buf, u8(0x03))
}

// object keys carry no type marker
// terminator is an empty key plus the end marker rather than just 0x09
amf_write_key     :: proc(buf: ^[dynamic]u8, key: string) {
	append_be(buf, u64(len(key)), 2)
	append(buf, ..transmute([]u8)key)
}

amf_end_object    :: proc(buf: ^[dynamic]u8) {
	append(buf, u8(0x00), u8(0x00), u8(0x09))
}

amf_read_string :: proc(data: []u8, offset: ^int) -> (string, bool) {
	if offset^ + 3 > len(data) do return "", false
	if data[offset^] != 0x02 do return "", false

	length := int(data[offset^ + 1]) << 8 | int(data[offset^ + 2])
	start := offset^ + 3
	if start + length > len(data) do return "", false

	offset^ = start + length
	return string(data[start:start+length]), true
}

amf_read_number :: proc(data: []u8, offset: ^int) -> (f64, bool) {
    // Marker plus 8 bytes; no length prefix -- AMF0 numbers are always doubles.
    if offset^ + 9 > len(data) do return 0, false
    if data[offset^] != 0x00 do return 0, false

    start := offset^ + 1
    bits: u64
    for i in 0..<8 {
        bits = bits << 8 | u64(data[start + i])
    }

    offset^ = start + 8
    return transmute(f64)bits, true
}

amf_skip_value :: proc(data: []u8, offset: ^int) -> bool {
    if offset^ >= len(data) do return false

    marker := data[offset^]
    switch marker {
    case 0x00: // number
        if offset^ + 9 > len(data) do return false
        offset^ += 9

    case 0x01: // boolean
        if offset^ + 2 > len(data) do return false
        offset^ += 2

    case 0x02: // string
        if offset^ + 3 > len(data) do return false
        length := int(data[offset^ + 1]) << 8 | int(data[offset^ + 2])
        if offset^ + 3 + length > len(data) do return false
        offset^ += 3 + length

    case 0x05, 0x06: // null, undefined
        offset^ += 1

    case 0x03: // object
        offset^ += 1
        for {
            if offset^ + 2 > len(data) do return false
            key_len := int(data[offset^]) << 8 | int(data[offset^ + 1])
            if key_len == 0 {
                // Empty key means the terminator: 00 00 09.
                if offset^ + 3 > len(data) do return false
                offset^ += 3
                return true
            }
            offset^ += 2 + key_len
            if !amf_skip_value(data, offset) do return false
        }

    case:
        log.warnf("amf: unhandled type marker 0x%02X", marker)
        return false
    }

    return true
}

// Over 65535 bytes, AMF0 requires the long-string marker (0x0C) with a u32 length
// a stream key from a text field could theoretically be long.
// An assert or a warning costs nothing.
@(private="file")
append_be :: proc(buf: ^[dynamic]u8, value: u64, bytes: int) {
    for i := bytes - 1; i >= 0; i -= 1 {
        append(buf, u8(value >> (uint(i) * 8)))
    }
}
