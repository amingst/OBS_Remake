package audio

import "core:log"
import "core:sys/windows"
import "../encode"

CHANNELS :: 2

// Per-frame mixer state -- allocated once at startup, freed at exit.
Mixer :: struct {
	buf:            []f32,
	blocks_emitted: u64,
	started:        bool,
}

mixer_state_init :: proc(m: ^Mixer) {
	m.buf = make([]f32, BLOCK_SAMPLES * CHANNELS)
}

mixer_state_destroy :: proc(m: ^Mixer) {
	delete(m.buf)
}

// Mixes and pushes as many blocks as are ready across `inputs` into enc's PCM
// queue. Resets the startup gate when every audio source disappears, so a
// newly added source after a gap starts buffered rather than picking up
// mid-stream. A nil enc still drains the mixer's readiness state each frame
// but pushes nothing.
mix_and_push :: proc(m: ^Mixer, inputs: []Mix_Input, enc: ^encode.Encoder) {
	if len(inputs) == 0 {
		m.started = false
	}

	if !m.started && mixer_ready(inputs, CHANNELS) {
		m.started = true
		log.debug("mixer_started -> true")
	}

	if !m.started do return

	for mix_block(inputs, m.buf, CHANNELS) {
		pts_100ns := i64(m.blocks_emitted) * BLOCK_SAMPLES * 10_000_000 / 48000
		pcm_buf := f32_to_pcm16(m.buf)

		if enc != nil {
			if encode.audio_queue_put(enc.pcm_queue, pcm_buf, pts_100ns) {
				windows.SetEvent(enc.audio_event)
			}
		}

		m.blocks_emitted += 1
	}
}

// Convert interleaved f32 samples (range [-1,1]) to interleaved 16-bit PCM
// packed as a byte slice. Uses the temp allocator -- freed at end of frame.
f32_to_pcm16 :: proc(src: []f32) -> []u8 {
	out := make([]u8, len(src) * 2, context.temp_allocator)
	for s, i in src {
		clamped := clamp(s, -1, 1)
		sample := i16(clamped * 32767)
		out[i * 2 + 0] = u8(sample & 0xFF)
		out[i * 2 + 1] = u8((sample >> 8) & 0xFF)
	}
	return out
}
