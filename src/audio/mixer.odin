package audio

import "core:log"
import "core:time"

BLOCK_SAMPLES :: 1024
BLOCK_LATENCY :: 4

Mix_Input :: struct {
    stream: ^Stream,
    volume: f32,
    muted:  bool,
}


mix_block :: proc(inputs: []Mix_Input, dst: []f32, channels: int) -> bool {
    if len(inputs) == 0 do return false

    block_len := BLOCK_SAMPLES * channels
    if len(dst) < block_len do return false

    // All-ready gate: every input must have a full block available.
    all_ready := true
    any_ready := false
    for inp in inputs {
        if ring_available(&inp.stream.ring) >= block_len {
            any_ready = true
        } else {
            all_ready = false
        }
    }

    if !any_ready do return false

    // Starvation escape: if some inputs have been short for >100ms while
    // at least one other is ready, proceed without them.
    if !all_ready {
        now := time.now()
        for inp in inputs {
            if ring_available(&inp.stream.ring) >= block_len do continue
            if inp.stream.starved_since._nsec == 0 {
                inp.stream.starved_since = now
            }
            if time.duration_milliseconds(time.diff(inp.stream.starved_since, now)) < 100 {
                return false
            }
        }
    }

    for i in 0..<len(dst) do dst[i] = 0

    scratch: [BLOCK_SAMPLES * 8]f32

    for inp, idx in inputs {
        if ring_available(&inp.stream.ring) < block_len {
            // Starved — log once per episode, contribute zeros, don't consume.
            if !inp.stream.starvation_logged {
                log.warnf("audio input %v starved for >100ms, mixing without it", idx)
                inp.stream.starvation_logged = true
            }
            inp.stream.peak *= 0.92
            continue
        }

        // Ready — clear starvation state if recovering.
        if inp.stream.starved_since._nsec != 0 {
            inp.stream.starved_since = {}
            inp.stream.starvation_logged = false
        }

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
            dst[i] += scratch[i] * inp.volume
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
	    // A silent loopback source may never cross the threshold; only
	    // non-loopback inputs must buffer before mixing starts.
		if inp.stream.is_loopback do continue
        if ring_available(&inp.stream.ring) < threshold do return false
    }

    return true
}
