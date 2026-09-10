package rtmp

import "../encode"
import "core:sync"

Group_Mailbox :: struct {
	mutex: sync.Mutex,
	count: int,
	read_index: int,
	write_index: int,
	need_keyframe: bool,
	ring: [16]^encode.Frame_Group
}

Group_Audio_Queue :: struct {
	mutex: sync.Mutex,
	count: int,
	read_index: int,
	write_index: int,
	ring: [16]^encode.Frame_Group
}

group_mailbox_destroy :: proc(m: ^Group_Mailbox) {
	sync.lock(&m.mutex)
	defer sync.unlock(&m.mutex)

	for i in 0 ..< m.count {
		slot := (m.read_index + i) % len(m.ring)
		encode.group_release(m.ring[slot])
		m.ring[slot] = nil
	}
	m.count = 0
}

group_mailbox_put :: proc(m: ^Group_Mailbox, g: ^encode.Frame_Group) {
	sync.lock(&m.mutex)
	defer sync.unlock(&m.mutex)
	if m.count == len(m.ring) {
		encode.group_release(g)
		m.need_keyframe = true
		return
	}

	if m.need_keyframe && !g.is_keyframe {
		encode.group_release(g)
		return
	}

	m.need_keyframe = false

	m.ring[m.write_index] = g
	m.write_index = (m.write_index + 1) % len(m.ring)
	m.count += 1
}

group_mailbox_take :: proc(m: ^Group_Mailbox) -> (^encode.Frame_Group, bool) {
	sync.lock(&m.mutex)
	defer sync.unlock(&m.mutex)
	if m.count == 0 {
		return nil, false
	}

	slot := m.read_index
	m.read_index = (m.read_index + 1) % len(m.ring)
	m.count -= 1
	g := m.ring[slot]
	m.ring[slot] = nil
	return g, true
}

group_audio_queue_destroy :: proc(m: ^Group_Audio_Queue) {
	sync.lock(&m.mutex)
	defer sync.unlock(&m.mutex)

	for i in 0 ..< m.count {
		slot := (m.read_index + i) % len(m.ring)
		encode.group_release(m.ring[slot])
		m.ring[slot] = nil
	}
	m.count = 0
}

group_audio_queue_put :: proc(m: ^Group_Audio_Queue, g: ^encode.Frame_Group) {
	sync.lock(&m.mutex)
	defer sync.unlock(&m.mutex)
	if m.count == len(m.ring) {
		encode.group_release(g)
		return
	}
	m.ring[m.write_index] = g
	m.write_index = (m.write_index + 1) % len(m.ring)
	m.count += 1
}

group_audio_queue_take :: proc(m: ^Group_Audio_Queue) -> (^encode.Frame_Group, bool) {
	sync.lock(&m.mutex)
	defer sync.unlock(&m.mutex)
	if m.count == 0 {
		return nil, false
	}

	slot := m.read_index
	m.read_index = (m.read_index + 1) % len(m.ring)
	m.count -= 1
	g := m.ring[slot]
	m.ring[slot] = nil
	return g, true
}
