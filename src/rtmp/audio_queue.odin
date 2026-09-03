package rtmp

import "core:log"
import "core:sync"

Audio_Queue :: struct {
	mutex: sync.Mutex,
	buffer: []u8,
	pts_list: []i64,
	stride: u32,
	write_slot: u32,
	read_slot: u32,
	count: u32,
	capacity: u32
}

audio_queue_init :: proc(n: u32, block_byte_size: u32) -> ^Audio_Queue {
	buffer := make([]u8, n * block_byte_size)
	pts_list := make([]i64, n + 1)

	audio_queue := new(Audio_Queue)
	audio_queue^ = Audio_Queue{
		buffer = buffer,
		pts_list = pts_list,
		stride = block_byte_size,
		write_slot = 0,
		read_slot = 0,
		count = 0,
		capacity = n
	}

	return audio_queue
}

audio_queue_destroy :: proc(audio_queue: ^Audio_Queue) {
	if audio_queue != nil {
		delete(audio_queue.buffer)
		delete(audio_queue.pts_list)
		free(audio_queue)
	}
}

audio_queue_put :: proc(audio_queue: ^Audio_Queue, samples: []u8, pts: i64) -> bool {
	sync.lock(&audio_queue.mutex)
	defer sync.unlock(&audio_queue.mutex)

	// Return when the count = capacity i.e. No room left
	if audio_queue.count == audio_queue.capacity {
		log.warn("Audio queue full")
		return false
	}

	// Check for mismatch between samples and stride
	if len(samples) != int(audio_queue.stride) {
		log.warn("Mismatch sample size")
		return false
	}

	offset := audio_queue.write_slot * audio_queue.stride
	copy(
		audio_queue.buffer[offset:offset+audio_queue.stride],
		samples
	)
	audio_queue.pts_list[audio_queue.write_slot] = pts
	audio_queue.write_slot = (audio_queue.write_slot + 1) % audio_queue.capacity
	audio_queue.count += 1
	return true
}

audio_queue_take :: proc(audio_queue: ^Audio_Queue, dst: []u8) -> (pts: i64, ok: bool) {
	sync.lock(&audio_queue.mutex)
	defer sync.unlock(&audio_queue.mutex)

	if audio_queue.count == 0 {
		log.warn("No audio bytes to send to stream")
		return {}, false
	}

	if len(dst) != int(audio_queue.stride) {
		log.warn("Mismatch Sample Size")
		return {}, false
	}

	offset := audio_queue.read_slot * audio_queue.stride
	copy(dst, audio_queue.buffer[offset:offset+audio_queue.stride])

	pts = audio_queue.pts_list[audio_queue.read_slot]

	audio_queue.read_slot = (audio_queue.read_slot + 1) % audio_queue.capacity
	audio_queue.count -= 1

	ok = true
	return
}
