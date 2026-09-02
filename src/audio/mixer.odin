package audio

import "core:log"

BLOCK_SAMPLES :: 1024
BLOCK_LATENCY :: 4

Mix_Input :: struct {
    stream: ^Stream,
    volume: f32,
    muted:  bool,
}


mix_block :: proc(inputs: []Mix_Input, dst: []f32, channels: int) -> bool {
    if len(inputs) == 0 do return false;
    any_ready := false
    for inp in inputs {
        if ring_available(&inp.stream.ring) >= BLOCK_SAMPLES * channels {
            any_ready = true
            break
        }
    }

    if !any_ready do return false;

    for i in 0..<len(dst) do dst[i] = 0

    // TODO: Make package level priate scratch var
    scratch: [BLOCK_SAMPLES * 8]f32
    block_len := BLOCK_SAMPLES * channels
    if len(dst) < block_len do return false

    for inp in inputs {
        if ring_available(&inp.stream.ring) < block_len do continue

        n := ring_read(&inp.stream.ring, scratch[:block_len])
        if n < block_len do continue

        frame_peak: f32
        for i in 0..<block_len {
            a := abs(scratch[i])
            if a > frame_peak do frame_peak = a
        }
        inp.stream.peak = max(frame_peak, inp.stream.peak * 0.92)

        if inp.muted do continue

        for i in 0..<block_len {
            dst[i] += scratch[i] *  inp.volume
        }
    }

    clipped := false
    for i in 0..<block_len {
        if dst[i] > 1 || dst[i] < -1 {
            dst[i] = clamp(dst[i], -1, 1)
            clipped = true
        }
    }

    if clipped {
        log.warn("audio mix clipped")
    }
    return true
}

mixer_ready :: proc(inputs: []Mix_Input, channels: int) -> bool {
    if len(inputs) == 0 do return false

    threshold := BLOCK_SAMPLES * channels * BLOCK_LATENCY
    for inp in inputs {
	    // Loopback (render-endpoint) sources deliver zero packets when
	    // nothing is playing on the device -- that's not "slow to buffer,"
	    // it's silence by design, and may never cross the threshold. Only
	    // non-loopback inputs (mic capture) are required to buffer before
	    // mixing starts; a silent loopback is handled by mix_block's
	    // per-input skip once mixing is running.
		if inp.stream.is_loopback do continue
        if ring_available(&inp.stream.ring) < threshold do return false
    }

    return true
}
