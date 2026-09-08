package flv

import "libs:h264"

FRAME_TYPE_KEYFRAME :: 1
FRAME_TYPE_INTER    :: 2

CODEC_ID_AVC :: 7

AVC_PACKET_TYPE_SEQUENCE_HEADER :: 0
AVC_PACKET_TYPE_NALU            :: 1
AVC_PACKET_TYPE_END_OF_SEQUENCE :: 2

AAC_SOUND_FORMAT :: 10
AAC_SOUND_RATE :: 3
AAC_PACKET_TYPE_SEQUENCE_HEADER :: 0
AAC_PACKET_TYPE_RAW :: 1

// The one-time AVC sequence header message, built from
// h264.build_avc_decoder_config's output. Send this exactly once, before
// any frame data, immediately after the publish sequence completes.
build_avc_sequence_header :: proc(avc_config: []u8, allocator := context.allocator) -> []u8 {
    out := make([dynamic]u8, allocator)
    append(&out, u8(FRAME_TYPE_KEYFRAME << 4 | CODEC_ID_AVC)) // 0x17
    append(&out, u8(AVC_PACKET_TYPE_SEQUENCE_HEADER))
    append(&out, u8(0), u8(0), u8(0)) // CompositionTime, unused for the sequence header
    for b in avc_config do append(&out, b)
    return out[:]
}

// Builds one video message body from a frame's full NALU list (as returned
// by the encoder, pre-split by h264.split_annexb). Parameter-set and
// delimiter NALUs (SPS, PPS, AUD, SEI) are filtered out here - those only
// belong in the sequence header, never in a per-frame payload - so callers
// can pass the encoder's raw output directly without pre-filtering it
// themselves.
build_avc_frame :: proc(nalus: [][]u8, is_keyframe: bool, composition_time: i32 = 0, allocator := context.allocator) -> []u8 {
    slice_nalus := make([dynamic][]u8, context.temp_allocator)
    for nalu in nalus {
        switch h264.nal_type(nalu) {
        case h264.NAL_TYPE_SLICE_NON_IDR:
            append(&slice_nalus, nalu)
        case h264.NAL_TYPE_IDR:
            append(&slice_nalus, nalu)
        }
    }

    avcc := h264.to_avcc(slice_nalus[:], context.temp_allocator)
    frame_type := is_keyframe ? FRAME_TYPE_KEYFRAME : FRAME_TYPE_INTER

    out := make([dynamic]u8, allocator)
    append(&out, u8(frame_type << 4 | CODEC_ID_AVC))
    append(&out, u8(AVC_PACKET_TYPE_NALU))
    append(&out, u8(composition_time >> 16), u8(composition_time >> 8), u8(composition_time)) // signed 24-bit, big-endian
    for b in avcc do append(&out, b)

    return out[:]
}

build_aac_sequence_header :: proc(aac_config: []u8, is_16_bit: bool, is_stereo: bool, allocator := context.allocator) -> []u8 {
	out := make([dynamic]u8, allocator)
	size_bits := is_16_bit ? u8(1) : u8(0)
	stereo_bits := is_stereo ? u8(1) : u8(0)
	append(&out, u8(AAC_SOUND_FORMAT << 4 | AAC_SOUND_RATE << 2 | size_bits << 1 | stereo_bits))
	append(&out, u8(AAC_PACKET_TYPE_SEQUENCE_HEADER))
	for b in aac_config do append(&out, b)

	return out[:]
}

build_aac_frame :: proc(encoded: []u8, is_16_bit: bool, is_stereo: bool, allocator := context.allocator) -> []u8 {
	out := make([dynamic]u8, allocator)
	size_bits := is_16_bit ? u8(1) : u8(0)
	stereo_bits := is_stereo ? u8(1) : u8(0)
	append(&out, u8(AAC_SOUND_FORMAT << 4 | AAC_SOUND_RATE << 2 | size_bits << 1 | stereo_bits))
	append(&out, u8(AAC_PACKET_TYPE_RAW))
	for b in encoded do append(&out, b)

	return out[:]
}
