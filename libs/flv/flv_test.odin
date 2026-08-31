package flv

import "core:testing"
import "core:slice"

@(test)
test_build_avc_sequence_header :: proc(t: ^testing.T) {
    config := []u8{0x01, 0x42, 0x00, 0x1E, 0xFF, 0xE1, 0x00, 0x06, 0x67, 0x42, 0x00, 0x1E, 0xAB, 0xCD, 0x01, 0x00, 0x04, 0x68, 0xCE, 0x3C, 0x80}
    payload := build_avc_sequence_header(config)
    defer delete(payload)

    testing.expect_value(t, payload[0], u8(0x17)) // keyframe(1)<<4 | AVC(7)
    testing.expect_value(t, payload[1], u8(0))     // sequence header
    testing.expect(t, slice.equal(payload[2:5], []u8{0, 0, 0}))
    testing.expect(t, slice.equal(payload[5:], config))
}

@(test)
test_build_avc_frame_keyframe :: proc(t: ^testing.T) {
    aud := []u8{0x09, 0x10}
    idr := []u8{0x65, 0x88, 0x84, 0x00}

    payload, is_key := build_avc_frame([][]u8{aud, idr})
    defer delete(payload)

    testing.expect(t, is_key)
    testing.expect_value(t, payload[0], u8(0x17))
    testing.expect_value(t, payload[1], u8(1))
    testing.expect(t, slice.equal(payload[2:5], []u8{0, 0, 0}))
    testing.expect(t, slice.equal(payload[5:9], []u8{0, 0, 0, 4})) // 4-byte length prefix
    testing.expect(t, slice.equal(payload[9:], idr))               // AUD dropped entirely
}

@(test)
test_build_avc_frame_interframe :: proc(t: ^testing.T) {
    p_slice := []u8{0x41, 0x9a, 0x02, 0x05}
    payload, is_key := build_avc_frame([][]u8{p_slice})
    defer delete(payload)

    testing.expect(t, !is_key)
    testing.expect_value(t, payload[0], u8(0x27)) // inter(2)<<4 | AVC(7)
}
