package h264

// NAL unit types we care about (low 5 bits of the NAL header byte).
NAL_TYPE_SLICE_NON_IDR :: 1
NAL_TYPE_IDR           :: 5
NAL_TYPE_SPS           :: 7
NAL_TYPE_PPS           :: 8

nal_type :: #force_inline proc(nalu: []u8) -> u8 {
    return nalu[0] & 0x1F
}

// Splits a buffer of Annex B NAL units (each preceded by a 3- or 4-byte start
// code: 00 00 01 or 00 00 00 01) into individual NALU slices, start codes
// stripped. Returned slices reference the original buffer - no copying.
// Emulation-prevention bytes (00 00 03 xx) inside each NALU's payload are
// left untouched; that escaping is part of both Annex B and AVCC - only the
// delimiter mechanism changes between the two, not the payload bytes.
// Assumes well-formed, MF-encoder-produced input; not a hardened parser for
// arbitrary third-party streams (no handling of stray trailing padding).
split_annexb :: proc(data: []u8, allocator := context.allocator) -> [][]u8 {
    Start :: struct { code_pos, payload_pos: int }
    starts := make([dynamic]Start, context.temp_allocator)

    i := 0
    for i + 2 < len(data) {
        if data[i] == 0 && data[i+1] == 0 && data[i+2] == 1 {
            append(&starts, Start{i, i + 3})
            i += 3
            continue
        }
        if i + 3 < len(data) && data[i] == 0 && data[i+1] == 0 && data[i+2] == 0 && data[i+3] == 1 {
            append(&starts, Start{i, i + 4})
            i += 4
            continue
        }
        i += 1
    }

    nalus := make([dynamic][]u8, 0, len(starts), context.temp_allocator)
    for idx in 0 ..< len(starts) {
        payload_start := starts[idx].payload_pos
        payload_end := len(data)
        if idx + 1 < len(starts) {
            payload_end = starts[idx + 1].code_pos
        }
        if payload_end > payload_start { // skip a start code with nothing after it
            append(&nalus, data[payload_start:payload_end])
        }
    }
    result := make([][]u8, len(nalus), allocator)
    copy(result, nalus[:])
    return result
}

// Converts NALUs (as returned by split_annexb) into AVCC: each NALU prefixed
// with its length as a 4-byte big-endian u32, no start codes.
to_avcc :: proc(nalus: [][]u8, allocator := context.allocator) -> []u8 {
    total := 0
    for nalu in nalus do total += 4 + len(nalu)

    out := make([]u8, total, allocator)
    offset := 0
    for nalu in nalus {
        length := u32(len(nalu))
        out[offset+0] = u8(length >> 24)
        out[offset+1] = u8(length >> 16)
        out[offset+2] = u8(length >> 8)
        out[offset+3] = u8(length)
        offset += 4
        copy(out[offset:offset+len(nalu)], nalu)
        offset += len(nalu)
    }
    return out
}

contains_idr :: proc(nalus: [][]u8) -> bool {
    for nalu in nalus {
        if nal_type(nalu) == NAL_TYPE_IDR do return true
    }
    return false
}

// Splits MF_MT_MPEG_SEQUENCE_HEADER's Annex-B SPS+PPS blob into the two
// NALUs. ok=false if either wasn't found - shouldn't happen for a real H.264
// encoder's sequence header, but don't trust that blindly at the call site.
split_sequence_header :: proc(seq_header: []u8) -> (sps, pps: []u8, ok: bool) {
    nalus := split_annexb(seq_header, context.temp_allocator)
    for nalu in nalus {
        switch nal_type(nalu) {
        case NAL_TYPE_SPS: sps = nalu
        case NAL_TYPE_PPS: pps = nalu
        }
    }
    return sps, pps, len(sps) > 0 && len(pps) > 0
}

// Builds an AVCDecoderConfigurationRecord (ISO/IEC 14496-15) from one SPS and
// one PPS NALU - the FLV/MP4 "extradata" blob. Profile/level are read
// directly from the SPS's first 3 bytes after its NAL header byte
// (profile_idc, profile_compatibility, level_idc) - universal practice, since
// an escape sequence landing on exactly those bytes doesn't happen in
// real-world SPS data, so full RBSP de-escaping isn't needed to reach them.
build_avc_decoder_config :: proc(sps, pps: []u8, allocator := context.allocator) -> []u8 {
    assert(len(sps) >= 4, "SPS too short to contain profile/level bytes")

    out := make([dynamic]u8, allocator)
    append(&out, u8(1))    // configurationVersion
    append(&out, sps[1])   // AVCProfileIndication
    append(&out, sps[2])   // profile_compatibility
    append(&out, sps[3])   // AVCLevelIndication
    append(&out, u8(0xFF)) // reserved(6)=111111, lengthSizeMinusOne(2)=11 -> 4-byte lengths
    append(&out, u8(0xE1)) // reserved(3)=111, numOfSequenceParameterSets(5)=1

    sps_len := u16(len(sps))
    append(&out, u8(sps_len >> 8), u8(sps_len))
    for b in sps do append(&out, b)

    append(&out, u8(1)) // numOfPictureParameterSets
    pps_len := u16(len(pps))
    append(&out, u8(pps_len >> 8), u8(pps_len))
    for b in pps do append(&out, b)

    return out[:]
}
