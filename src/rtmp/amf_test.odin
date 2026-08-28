// src/rtmp/amf_test.odin
package rtmp

import "core:testing"

// AMF0 is a type marker byte followed by the value. These assert exact bytes,
// since the encoding is fully specified and there's no room for interpretation
// -- a mismatch here is a bug, not a style difference.

@(test)
number_is_big_endian_double :: proc(t: ^testing.T) {
    buf := make([dynamic]u8); defer delete(buf)
    amf_write_number(&buf, 1.0)

    // Marker 0x00, then IEEE 754 for 1.0: 3F F0 00 00 00 00 00 00.
    expected := []u8{0x00, 0x3F, 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}
    testing.expect_value(t, len(buf), len(expected))
    for b, i in expected {
        testing.expect_value(t, buf[i], b)
    }
}

@(test)
number_zero :: proc(t: ^testing.T) {
    buf := make([dynamic]u8); defer delete(buf)
    amf_write_number(&buf, 0)

    expected := []u8{0x00, 0, 0, 0, 0, 0, 0, 0, 0}
    testing.expect_value(t, len(buf), len(expected))
    for b, i in expected {
        testing.expect_value(t, buf[i], b)
    }
}

// Everything numeric in AMF0 is a double, including values that are logically
// integers -- stream IDs, transaction IDs, and so on.
@(test)
number_integral_value :: proc(t: ^testing.T) {
    buf := make([dynamic]u8); defer delete(buf)
    amf_write_number(&buf, 1)

    // Same bytes as 1.0 -- there is no integer type.
    testing.expect_value(t, buf[1], u8(0x3F))
    testing.expect_value(t, buf[2], u8(0xF0))
}

@(test)
boolean_encoding :: proc(t: ^testing.T) {
    tbuf := make([dynamic]u8); defer delete(tbuf)
    amf_write_boolean(&tbuf, true)
    testing.expect_value(t, len(tbuf), 2)
    testing.expect_value(t, tbuf[0], u8(0x01))
    testing.expect_value(t, tbuf[1], u8(1))

    fbuf := make([dynamic]u8); defer delete(fbuf)
    amf_write_boolean(&fbuf, false)
    testing.expect_value(t, fbuf[1], u8(0))
}

@(test)
string_is_marker_length_bytes :: proc(t: ^testing.T) {
    buf := make([dynamic]u8); defer delete(buf)
    amf_write_string(&buf, "live")

    expected := []u8{0x02, 0x00, 0x04, 'l', 'i', 'v', 'e'}
    testing.expect_value(t, len(buf), len(expected))
    for b, i in expected {
        testing.expect_value(t, buf[i], b)
    }
}

@(test)
empty_string :: proc(t: ^testing.T) {
    buf := make([dynamic]u8); defer delete(buf)
    amf_write_string(&buf, "")

    testing.expect_value(t, len(buf), 3)
    testing.expect_value(t, buf[0], u8(0x02))
    testing.expect_value(t, buf[1], u8(0))
    testing.expect_value(t, buf[2], u8(0))
}

@(test)
null_is_marker_only :: proc(t: ^testing.T) {
    buf := make([dynamic]u8); defer delete(buf)
    amf_write_null(&buf)

    testing.expect_value(t, len(buf), 1)
    testing.expect_value(t, buf[0], u8(0x05))
}

// Object keys are length-prefixed but carry no type marker, unlike values.
// Getting that wrong shifts every byte after it.
@(test)
object_key_has_no_type_marker :: proc(t: ^testing.T) {
    buf := make([dynamic]u8); defer delete(buf)
    amf_write_key(&buf, "app")

    expected := []u8{0x00, 0x03, 'a', 'p', 'p'}
    testing.expect_value(t, len(buf), len(expected))
    for b, i in expected {
        testing.expect_value(t, buf[i], b)
    }
}

// The terminator is an empty key (u16 length of 0) followed by the object-end
// marker -- three bytes, not just 0x09.
@(test)
object_terminator :: proc(t: ^testing.T) {
    buf := make([dynamic]u8); defer delete(buf)
    amf_end_object(&buf)

    testing.expect_value(t, len(buf), 3)
    testing.expect_value(t, buf[0], u8(0x00))
    testing.expect_value(t, buf[1], u8(0x00))
    testing.expect_value(t, buf[2], u8(0x09))
}

// The shape a real command payload takes: a small object with two properties.
@(test)
object_round_shape :: proc(t: ^testing.T) {
    buf := make([dynamic]u8); defer delete(buf)

    amf_begin_object(&buf)
    amf_write_key(&buf, "app")
    amf_write_string(&buf, "live")
    amf_write_key(&buf, "fpad")
    amf_write_boolean(&buf, false)
    amf_end_object(&buf)

    expected := []u8{
        0x03,                                  // object marker
        0x00, 0x03, 'a', 'p', 'p',             // key "app"
        0x02, 0x00, 0x04, 'l', 'i', 'v', 'e',  // string "live"
        0x00, 0x04, 'f', 'p', 'a', 'd',        // key "fpad"
        0x01, 0x00,                            // boolean false
        0x00, 0x00, 0x09,                      // terminator
    }

    testing.expect_value(t, len(buf), len(expected))
    for b, i in expected {
        testing.expect_value(t, buf[i], b)
    }
}
