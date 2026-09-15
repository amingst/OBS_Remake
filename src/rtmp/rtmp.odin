package rtmp

import "core:net"
import "core:log"
import "core:math/rand"
import "core:encoding/endian"
import "core:time"

Connection :: struct {
	socket: net.TCP_Socket,
	chunk_states: map[u32]Chunk_State,
	chunk_size: u32,
	incoming: map[u32]Incoming_Chunk_State,
	peer_chunk_size: u32,
	stream_id: u32
}

// TODO: Rename to dial
connect :: proc(host: string, port: int) -> (Connection, bool) {
	sock, err := net.dial_tcp(host, port)
	if err != nil {
		log.warnf("Failed to establish RTMP Connection to host %v, error: %v", host, err)
		return {}, false
	}
	// Heap-allocated: these maps outlive the main thread's per-frame temp arena.
	state := make(map[u32]Chunk_State)
	incoming_chunks := make(map[u32]Incoming_Chunk_State)

	return {
		socket = sock,
		chunk_size = 128,
		chunk_states = state,
		incoming = incoming_chunks,
		peer_chunk_size = 128
	}, true
}

handshake :: proc(c: ^Connection) -> bool {
	// Send C0 and C1 (1537 bytes)
	c0c1 := make([]byte, 1537)
	defer delete(c0c1)
	c0c1[0] = 0x03

	now_ms := u32(time.duration_milliseconds(time.tick_since(time.tick_now())))

	endian.put_u32(c0c1[1:5], endian.Byte_Order.Big, now_ms)

	for i in 9..<1537 {
		c0c1[i] = u8(rand.uint32() % 256)
	}

	if !send_all(c.socket, c0c1) {
	    log.warn("failed to send C0/C1")
	    return false
	}

	// Recieve S0, S1, and S2 (3073 bytes)
	s0s1s2 := make([]byte, 3073)
	defer delete(s0s1s2)

	did_read := read_exact(c.socket, s0s1s2)
	if !did_read {
		log.warnf("Failed to read s0s1s2")
		return false
	}

	if s0s1s2[0] != 0x03 {
		log.warnf("Invalid rtmp version from server %v", s0s1s2[0])
		return false
	}

	// Send C2 (1536 bytes)
	c2 := s0s1s2[1:1537]

	if !send_all(c.socket, c2) {
	    log.warn("failed to send C2")
	    return false
	}

	log.infof("RTMP Handshake Complete")
	return true
}

close :: proc(c: ^Connection) {
	net.set_option(c.socket, .Receive_Timeout, time.Second * 2)

	// Graceful half-close: without draining first, Windows sends RST instead
	// of FIN, which showed up as ffmpeg's "Error during demuxing" downstream.
	net.shutdown(c.socket, .Send)

	drain: [256]u8
	for {
		n, err := net.recv_tcp(c.socket, drain[:])
		if err != nil || n == 0 do break
	}

	for _, state in c.incoming {
		delete(state.buffer)
	}
	delete(c.chunk_states)
	delete(c.incoming)
	net.close(c.socket)
}

@(private)
read_exact :: proc(s: net.TCP_Socket, buf: []u8) -> bool {
	total := 0
	for total < len(buf) {
		n, err := net.recv_tcp(s, buf[total:])
		if err != nil || n == 0 do return false
		total += n
	}

	return true
}

@(private)
send_all :: proc(s: net.TCP_Socket, buf: []u8) -> bool {
    total := 0
    for total < len(buf) {
        n, err := net.send_tcp(s, buf[total:])
        if err != nil {
            log.warnf("send failed after %v/%v bytes: %v", total, len(buf), err)
            return false
        }
        if n == 0 do return false
        total += n
    }
    return true
}
