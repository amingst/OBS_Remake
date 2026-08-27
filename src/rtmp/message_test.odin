// src/rtmp/message_test.odin
package rtmp

import "core:testing"

// Encoding is a pure function over data we control, so unlike the handshake
// tests these need no server and assert real byte values.
//
// What they can't catch: whether this is actually RTMP. They prove the encoder
// does what we think it does, not that what we think is correct. That check is
// a byte-for-byte diff against a Wireshark capture of OBS sending the same
// message, once AMF0 exists to build the same payload.

@(private="file")
CSID :: 3

@(test)
fmt0_header_layout :: proc(t: ^testing.T) {
    states := make(map[u32]Chunk_State); defer delete(states)

    payload := []u8{0xAA, 0xBB, 0xCC, 0xDD}
    msg := Message{
        csid      = CSID,
        type_id   = 20,          // AMF0 command
        stream_id = 0,
        timestamp = 0,
        payload   = payload,
    }

    dst: [64]u8
    n := encode_message(dst[:], msg, 128, &states)

    // 1 basic + 11 message header + 4 payload
    testing.expect_value(t, n, 16)

    // fmt 0 in the top two bits, csid in the bottom six.
    testing.expect_value(t, dst[0], u8(0x00 | CSID))
    // timestamp (3 bytes, big-endian)
    testing.expect_value(t, dst[1], u8(0))
    testing.expect_value(t, dst[2], u8(0))
    testing.expect_value(t, dst[3], u8(0))
    // message length (3 bytes, big-endian)
    testing.expect_value(t, dst[4], u8(0))
    testing.expect_value(t, dst[5], u8(0))
    testing.expect_value(t, dst[6], u8(4))
    // type id
    testing.expect_value(t, dst[7], u8(20))
    // stream id (4 bytes, LITTLE-endian -- the one such field in RTMP)
    testing.expect_value(t, dst[8], u8(0))
    testing.expect_value(t, dst[9], u8(0))
    testing.expect_value(t, dst[10], u8(0))
    testing.expect_value(t, dst[11], u8(0))
    // payload
    testing.expect_value(t, dst[12], u8(0xAA))
    testing.expect_value(t, dst[15], u8(0xDD))
}

@(test)
stream_id_is_little_endian :: proc(t: ^testing.T) {
    states := make(map[u32]Chunk_State); defer delete(states)

    msg := Message{
        csid = CSID, type_id = 9, stream_id = 1, timestamp = 0,
        payload = []u8{0x01},
    }

    dst: [64]u8
    encode_message(dst[:], msg, 128, &states)

    // 1 little-endian is 01 00 00 00, not 00 00 00 01.
    testing.expect_value(t, dst[8], u8(1))
    testing.expect_value(t, dst[9], u8(0))
    testing.expect_value(t, dst[10], u8(0))
    testing.expect_value(t, dst[11], u8(0))
}

// A message identical to the last one on this chunk stream needs no header
// fields at all beyond the basic header.
@(test)
repeated_message_shrinks_to_fmt3 :: proc(t: ^testing.T) {
    states := make(map[u32]Chunk_State); defer delete(states)

    msg := Message{
        csid = CSID, type_id = 20, stream_id = 0, timestamp = 0,
        payload = []u8{1, 2, 3, 4},
    }

    dst: [64]u8

    first := encode_message(dst[:], msg, 128, &states)
    testing.expect_value(t, first, 16)   // fmt 0: 1 + 11 + 4

    second := encode_message(dst[:], msg, 128, &states)
    testing.expect_value(t, second, 5)   // fmt 3: 1 + 0 + 4
    testing.expect_value(t, dst[0], u8(0xC0 | CSID))
}

// Same type, length and stream, but the timestamp moved: only the delta needs
// sending.
@(test)
timestamp_change_uses_fmt2 :: proc(t: ^testing.T) {
    states := make(map[u32]Chunk_State); defer delete(states)

    dst: [64]u8
    payload := []u8{1, 2, 3, 4}

    a := Message{csid = CSID, type_id = 20, stream_id = 0, timestamp = 0,  payload = payload}
    b := Message{csid = CSID, type_id = 20, stream_id = 0, timestamp = 40, payload = payload}

    encode_message(dst[:], a, 128, &states)
    n := encode_message(dst[:], b, 128, &states)

    testing.expect_value(t, n, 8)        // fmt 2: 1 + 3 + 4
    testing.expect_value(t, dst[0], u8(0x80 | CSID))
    // delta of 40
    testing.expect_value(t, dst[3], u8(40))
}

// Length changed, so the header has to carry it again.
@(test)
length_change_uses_fmt1 :: proc(t: ^testing.T) {
    states := make(map[u32]Chunk_State); defer delete(states)

    dst: [64]u8

    a := Message{csid = CSID, type_id = 20, stream_id = 0, timestamp = 0, payload = []u8{1, 2, 3, 4}}
    b := Message{csid = CSID, type_id = 20, stream_id = 0, timestamp = 0, payload = []u8{1, 2, 3, 4, 5}}

    encode_message(dst[:], a, 128, &states)
    n := encode_message(dst[:], b, 128, &states)

    testing.expect_value(t, n, 13)       // fmt 1: 1 + 7 + 5
    testing.expect_value(t, dst[0], u8(0x40 | CSID))
}

@(test)
payload_splits_across_chunks :: proc(t: ^testing.T) {
    states := make(map[u32]Chunk_State); defer delete(states)

    payload := make([]u8, 300); defer delete(payload)
    for i in 0..<300 do payload[i] = u8(i)

    msg := Message{csid = CSID, type_id = 9, stream_id = 1, timestamp = 0, payload = payload}

    dst: [512]u8
    n := encode_message(dst[:], msg, 128, &states)

    // (1 + 11 + 128) + (1 + 128) + (1 + 44)
    testing.expect_value(t, n, 314)

    // Continuation chunks are fmt 3, basic header only.
    testing.expect_value(t, dst[0], u8(0x00 | CSID))
    testing.expect_value(t, dst[140], u8(0xC0 | CSID))
    testing.expect_value(t, dst[269], u8(0xC0 | CSID))
}

// A zero-length message is legal and still needs its header on the wire --
// this was silently dropped by a `for bytes_processed < payload_len` loop.
@(test)
empty_payload_still_writes_header :: proc(t: ^testing.T) {
    states := make(map[u32]Chunk_State); defer delete(states)

    msg := Message{csid = CSID, type_id = 20, stream_id = 0, timestamp = 0, payload = nil}

    dst: [64]u8
    n := encode_message(dst[:], msg, 128, &states)

    testing.expect_value(t, n, 12)       // 1 + 11 + 0
    testing.expect_value(t, dst[0], u8(0x00 | CSID))
    testing.expect_value(t, dst[6], u8(0)) // length 0
}

// A short buffer must leave the chunk state untouched, or every subsequent
// delta is computed against a message that never went out.
@(test)
short_buffer_returns_error_and_preserves_state :: proc(t: ^testing.T) {
    states := make(map[u32]Chunk_State); defer delete(states)

    msg := Message{csid = CSID, type_id = 20, stream_id = 0, timestamp = 0, payload = []u8{1, 2, 3, 4}}

    small: [8]u8
    n := encode_message(small[:], msg, 128, &states)
    testing.expect_value(t, n, -1)

    _, had_state := states[CSID]
    testing.expect(t, !had_state, "chunk state must not advance on a failed encode")
}

@(test)
extended_timestamp_on_every_chunk :: proc(t: ^testing.T) {
    states := make(map[u32]Chunk_State); defer delete(states)

    payload := make([]u8, 300); defer delete(payload)
    msg := Message{
        csid = CSID, type_id = 9, stream_id = 1,
        timestamp = 0x01000000,   // past what 24 bits can hold
        payload = payload,
    }

    dst: [512]u8
    n := encode_message(dst[:], msg, 128, &states)

    // Each of the 3 chunks carries the 4-byte extended timestamp.
    // (1 + 11 + 4 + 128) + (1 + 4 + 128) + (1 + 4 + 44)
    testing.expect_value(t, n, 326)

    // Sentinel in the 24-bit field, real value in the extension.
    testing.expect_value(t, dst[1], u8(0xFF))
    testing.expect_value(t, dst[2], u8(0xFF))
    testing.expect_value(t, dst[3], u8(0xFF))
    testing.expect_value(t, dst[12], u8(0x01))
}
