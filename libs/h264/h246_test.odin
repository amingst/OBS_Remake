package h264

import "core:testing"
import "core:slice"

@(test)
test_split_and_avcc :: proc(t: ^testing.T) {
    sps := []u8{0x67, 0x42, 0x00, 0x1E, 0xAB, 0xCD}
    pps := []u8{0x68, 0xCE, 0x3C, 0x80}
    idr := []u8{0x65, 0x88, 0x84, 0x00}

    buf: [dynamic]u8
    defer delete(buf)
    append(&buf, 0x00, 0x00, 0x00, 0x01)
    append(&buf, ..sps)
    append(&buf, 0x00, 0x00, 0x01)
    append(&buf, ..pps)
    append(&buf, 0x00, 0x00, 0x01)
    append(&buf, ..idr)

    nalus := split_annexb(buf[:])
    defer delete(nalus)
    testing.expect_value(t, len(nalus), 3)
    testing.expect(t, slice.equal(nalus[0], sps))
    testing.expect(t, slice.equal(nalus[1], pps))
    testing.expect(t, slice.equal(nalus[2], idr))
    testing.expect(t, contains_idr(nalus))

    avcc := to_avcc(nalus)
    defer delete(avcc)
    testing.expect_value(t, avcc[0], u8(0))
    testing.expect_value(t, avcc[1], u8(0))
    testing.expect_value(t, avcc[2], u8(0))
    testing.expect_value(t, avcc[3], u8(6))
    testing.expect(t, slice.equal(avcc[4:10], sps))

    // Built directly, rather than sliced out of `buf` by a hand-computed
    // offset - that's exactly the kind of arithmetic that caused this crash.
    seq_header: [dynamic]u8
    defer delete(seq_header)
    append(&seq_header, 0x00, 0x00, 0x00, 0x01)
    append(&seq_header, ..sps)
    append(&seq_header, 0x00, 0x00, 0x01)
    append(&seq_header, ..pps)

    s, p, ok := split_sequence_header(seq_header[:])
    testing.expect(t, ok)
    testing.expect(t, slice.equal(s, sps))
    testing.expect(t, slice.equal(p, pps))

    config := build_avc_decoder_config(sps, pps)
    defer delete(config)
    testing.expect_value(t, config[0], u8(1))
    testing.expect_value(t, config[1], u8(0x42))
    testing.expect_value(t, config[2], u8(0x00))
    testing.expect_value(t, config[3], u8(0x1E))
}
