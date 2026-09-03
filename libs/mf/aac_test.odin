package mf

import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:sys/windows"
import "core:testing"

// Mirrors audio.BLOCK_SAMPLES (1024) -- duplicated here rather than importing
// the audio package, since libs/mf has no business depending on it.
@(private="file") AAC_TEST_BLOCK_SAMPLES :: 1024

// ---------------------------------------------------------------------
// ADTS wrapping -- TEST-ONLY. encode_aac_frame's real output is raw AAC
// (MF_MT_AAC_PAYLOAD_TYPE = 0), which is correct for FLV tags but has no
// self-contained framing an external player can find. This wraps each
// frame in a minimal 7-byte ADTS header so ffprobe/ffplay can decode the
// dumped file to confirm the encoder actually produced valid AAC --
// nothing here belongs in or should be copied into production code.
// ---------------------------------------------------------------------

@(private="file")
adts_sample_rate_index :: proc(rate: u32) -> (index: u8, ok: bool) {
    switch rate {
    case 96000: return 0, true
    case 88200: return 1, true
    case 64000: return 2, true
    case 48000: return 3, true
    case 44100: return 4, true
    case 32000: return 5, true
    case 24000: return 6, true
    case 22050: return 7, true
    case 16000: return 8, true
    case 12000: return 9, true
    case 11025: return 10, true
    case 8000:  return 11, true
    case 7350:  return 12, true
    }
    return 0, false
}

@(private="file")
write_adts_frame :: proc(file: ^os.File, payload: []u8, sample_rate_idx: u8, channels: u32) {
    frame_len := u32(7 + len(payload)) // header (no CRC) + payload
    profile: u32 = 1                   // AAC-LC; ADTS "profile" field = object_type - 1

    header: [7]u8
    header[0] = 0xFF
    header[1] = 0xF1 // syncword tail, MPEG-4, layer 00, protection_absent=1 (no CRC)
    header[2] = u8(profile << 6) | u8(sample_rate_idx << 2) | u8((channels >> 2) & 0x1)
    header[3] = u8((channels & 0x3) << 6) | u8((frame_len >> 11) & 0x3)
    header[4] = u8((frame_len >> 3) & 0xFF)
    header[5] = u8((frame_len & 0x7) << 5) | 0x1F // buffer_fullness upper bits (VBR: all 1s)
    header[6] = 0xFC                              // buffer_fullness low bits (VBR) | 0 raw data blocks

    os.write(file, header[:])
    os.write(file, payload)
}

// Generates `seconds` of a continuous sine tone as interleaved 16-bit PCM,
// one AAC_TEST_BLOCK_SAMPLES-sample block at a time, and feeds it through
// begin_aac_encoder/encode_aac_frame. Output is ADTS-wrapped and written to
// disk (see note above) so it can be checked with:
//     ffprobe build/test-output/aac_transform_solid_tone.aac
//     ffplay  build/test-output/aac_transform_solid_tone.aac
@(private)
test_encode_solid_tone :: proc(output_path: string, sample_rate, channels, bitrate, seconds: u32) -> bool {
    hr := MFStartup(MF_VERSION, MFSTARTUP_FULL)
    if hr < 0 {
        log.errorf("MFStartup failed: 0x%08X", u32(hr))
        return false
    }
    defer MFShutdown()

    encoder, aac_config, ok := begin_aac_encoder(sample_rate, channels, bitrate)
    if !ok do return false
    defer delete(aac_config)

    if len(aac_config) == 0 {
        log.errorf("begin_aac_encoder returned an empty AudioSpecificConfig")
        encoder.Release(encoder)
        return false
    }
    log.infof("AudioSpecificConfig: % X (%d bytes)", aac_config, len(aac_config))

    sr_idx, sr_ok := adts_sample_rate_index(sample_rate)
    if !sr_ok {
        log.errorf("sample rate %d has no ADTS table entry", sample_rate)
        encoder.Release(encoder)
        return false
    }

    file, ferr := os.open(output_path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
    if ferr != nil {
        log.errorf("failed to open %s: %v", output_path, ferr)
        encoder.Release(encoder)
        return false
    }
    defer os.close(file)

    block_align := channels * 2 // 16-bit samples
    block_bytes := AAC_TEST_BLOCK_SAMPLES * int(block_align)
    block_duration := i64(AAC_TEST_BLOCK_SAMPLES) * 10_000_000 / i64(sample_rate)

    total_samples := int(sample_rate * seconds)
    block_count := total_samples / AAC_TEST_BLOCK_SAMPLES

    FREQ :: 440.0    // A4 -- audible and easy to recognize on playback
    AMPLITUDE :: 8000.0 // headroom below i16 max, avoids any clipping edge cases

    pcm := make([]u8, block_bytes, context.temp_allocator)

    frames_written := 0
    for block_index := 0; block_index < block_count; block_index += 1 {
        for i := 0; i < AAC_TEST_BLOCK_SAMPLES; i += 1 {
            sample_index := block_index * AAC_TEST_BLOCK_SAMPLES + i
            angle := 2.0 * math.PI * FREQ * f64(sample_index) / f64(sample_rate)
            v := i16(AMPLITUDE * math.sin(angle))

            for ch: u32 = 0; ch < channels; ch += 1 {
                byte_offset := (i * int(channels) + int(ch)) * 2
                pcm[byte_offset+0] = u8(v & 0xFF)
                pcm[byte_offset+1] = u8((v >> 8) & 0xFF)
            }
        }

        pts := i64(block_index) * i64(AAC_TEST_BLOCK_SAMPLES) * 10_000_000 / i64(sample_rate)

        aac_frames, enc_ok := encode_aac_frame(encoder, pcm, pts, block_duration)
        if !enc_ok {
            log.errorf("encode_aac_frame failed on block %d", block_index)
            encoder.Release(encoder)
            os.remove(output_path)
            return false
        }
        for frame in aac_frames {
            write_adts_frame(file, frame, sr_idx, channels)
            frames_written += 1
            delete(frame)
        }
        delete(aac_frames)
    }

    // ---- drain tail frames ----
    // No end_aac_encoder exists yet (mirroring end_h264_encoder is a gap
    // worth filling before this goes into Rtmp_Stream's real teardown path)
    // -- inlined here for the test's own cleanup.
    encoder.ProcessMessage(encoder, MFT_MESSAGE_COMMAND_DRAIN, 0)
    tail, _ := drain_transform_samples(encoder, 0)
    for frame in tail {
        write_adts_frame(file, frame, sr_idx, channels)
        frames_written += 1
        delete(frame)
    }
    delete(tail)
    encoder.Release(encoder)

    log.infof("wrote %d AAC frames (%d blocks in) to %s", frames_written, block_count, output_path)
    return frames_written > 0
}

@(test)
test_aac_transform_solid_tone :: proc(t: ^testing.T) {
    hr := windows.CoInitializeEx(nil, .MULTITHREADED)
    testing.expect(t, hr >= 0)
    defer windows.CoUninitialize()

    if !testing.expect(t, ensure_test_output_dir(), "could not create test output directory") do return

    path, jerr := filepath.join({test_output_dir, "aac_transform_solid_tone.aac"})
    if !testing.expect(t, jerr == nil, "could not build test output path") do return
    defer delete(path)

    // 16000 bytes/sec is one of valid_aac_bitrate's fixed accepted values
    // for non-5.1 channel counts -- not an arbitrary choice, see
    // valid_aac_bitrate's base table.
    ok := test_encode_solid_tone(path, 48000, 2, 16000, 2)
    if ok do log_test_output_path(path)
    testing.expect(t, ok, "test_encode_solid_tone failed")
}
