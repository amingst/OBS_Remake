package encode

import "core:sync"
import "core:log"

Raw_Mailbox :: struct {
	mutex: sync.Mutex,
	buffer: []u8,
	width, height: u32,
	has_frame: bool,
}

Raw_Audio_Queue :: struct {
	mutex: sync.Mutex,
	buffer: []u8,
	pts_list: []i64,
	stride: u32,
	write_slot: u32,
	read_slot: u32,
	count: u32,
	capacity: u32
}

mailbox_init :: proc(max_w: u32, max_h: u32) -> ^Raw_Mailbox {
	buffer := make([]u8, max_w * max_h * 4)
	mbox := new(Raw_Mailbox)

	mbox^ = Raw_Mailbox{
		buffer = buffer,
		width = 0,
		height = 0,
		has_frame = false,
	}

	return mbox
}

mailbox_destroy :: proc(mbox: ^Raw_Mailbox) {
	if mbox != nil {
		delete(mbox.buffer)
		free(mbox)
	}
}

mailbox_put :: proc(mbox: ^Raw_Mailbox, frame: []u8, width, height: u32) {
    sync.lock(&mbox.mutex)
    defer sync.unlock(&mbox.mutex)
    frame_bytes := int(width) * int(height) * 4
    copy(mbox.buffer[:frame_bytes], frame)
    mbox.width, mbox.height = width, height
    mbox.has_frame = true
}

mailbox_take :: proc(mbox: ^Raw_Mailbox, dst: []u8) -> bool {
    sync.lock(&mbox.mutex)
    defer sync.unlock(&mbox.mutex)
    if !mbox.has_frame {
        return false
    }

    frame_bytes := int(mbox.height) * int(mbox.width) * 4
    copy(dst[:frame_bytes], mbox.buffer[:frame_bytes])
    mbox.has_frame = false
    return true
}

audio_queue_init :: proc(n: u32, block_byte_size: u32) -> ^Raw_Audio_Queue {
	buffer := make([]u8, n * block_byte_size)
	pts_list := make([]i64, n + 1)

	audio_queue := new(Raw_Audio_Queue)
	audio_queue^ = Raw_Audio_Queue{
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

audio_queue_destroy :: proc(audio_queue: ^Raw_Audio_Queue) {
	if audio_queue != nil {
		delete(audio_queue.buffer)
		delete(audio_queue.pts_list)
		free(audio_queue)
	}
}

audio_queue_put :: proc(audio_queue: ^Raw_Audio_Queue, samples: []u8, pts: i64) -> bool {
	sync.lock(&audio_queue.mutex)
	defer sync.unlock(&audio_queue.mutex)

	// Return when the count = capacity i.e. No room left
	// Caller (main.odin's audio_queue_put failed (queue full)) reports this
	// condition -- logging it here too was a redundant duplicate of the same
	// event.
	if audio_queue.count == audio_queue.capacity {
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

audio_queue_take :: proc(audio_queue: ^Raw_Audio_Queue, dst: []u8) -> (pts: i64, ok: bool) {
	sync.lock(&audio_queue.mutex)
	defer sync.unlock(&audio_queue.mutex)

	if audio_queue.count == 0 {
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
