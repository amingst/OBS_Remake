package websocket

import "core:net"
import "core:sync"

WS_Role :: enum {
	Server,
	Client,
}

WS_Connection :: struct {
	sock:        net.TCP_Socket,
	role:        WS_Role,
	max_message: int,        // 64 KiB for the server
	send_mutex:  sync.Mutex, // guards whole frames
	recv_buf:    [dynamic]u8,
}

Message_Kind :: enum {
	Text,
	Binary,
	Close,
}
