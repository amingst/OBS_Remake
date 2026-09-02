package rtmp

import "core:sync"

Frame_Mailbox :: struct {
	mutex: sync.Mutex,
	buffer: []u8,
	width, height: u32,
	pts: i64,
	has_frame: bool
}

mailbox_init :: proc(max_w: u32, max_h: u32) -> ^Frame_Mailbox {
	buffer := make([]u8, max_w * max_h * 4)
	mbox := new(Frame_Mailbox)

	mbox^ = Frame_Mailbox{
		buffer = buffer,
		width = 0,
		height = 0,
		pts = 0,
		has_frame = false
	}

	return mbox
}

mailbox_destroy :: proc(mbox: ^Frame_Mailbox) {
	if mbox != nil {
		delete(mbox.buffer)
		free(mbox)
	}
}

mailbox_put :: proc(mbox: ^Frame_Mailbox, frame: []u8, width, height: u32, pts: i64) {
    sync.lock(&mbox.mutex)
    defer sync.unlock(&mbox.mutex)
    frame_bytes := int(width) * int(height) * 4
    copy(mbox.buffer[:frame_bytes], frame)
    mbox.width, mbox.height = width, height
    mbox.pts = pts
    mbox.has_frame = true
}

mailbox_take :: proc(mbox: ^Frame_Mailbox, dst: []u8) -> (width, height: u32, pts: i64, ok: bool) {
    sync.lock(&mbox.mutex)
    defer sync.unlock(&mbox.mutex)
    if !mbox.has_frame {
        return 0, 0, 0, false
    }

    frame_bytes := int(mbox.height) * int(mbox.width) * 4
    copy(dst[:frame_bytes], mbox.buffer[:frame_bytes])
    width, height = mbox.width, mbox.height
    pts = mbox.pts
    mbox.has_frame = false
    ok = true
    return
}
