package remote

import "core:slice"
import ws "libs:websocket"
import "protocol"
import "core:log"
import "core:mem"
import "core:net"
import "core:sync"
import "core:time"
import "core:thread"

Client :: struct {
	id:        u32,
	conn:      ws.WS_Connection,
	topics:    protocol.Topic_Set,
	topics_mu: sync.Mutex,

	out:       [dynamic][]u8,
	out_mu:    sync.Mutex,
	out_cond:  sync.Cond,

	allocator: mem.Allocator,

	reader:    ^thread.Thread,
	writer:    ^thread.Thread,
	alive:     bool,
	last_rx:   time.Time,
	last_ping: time.Time,
}

MAX_CLIENTS :: 8
MAX_MESSAGE :: 64 * 1024
HELLO_DEADLINE :: 10 * time.Second
MAX_OUT :: 256

client_admit :: proc(server: ^Server, sock: net.TCP_Socket) -> bool {
	net.set_option(sock, .Receive_Timeout, HELLO_DEADLINE)

	req, req_err := ws.read_http_request(sock)
	defer ws.http_request_destroy(&req)
	if req_err != .None {
		ws.write_http_error(sock, ws.http_status_for(req_err))
		return false
	}

	if req.path != "/" {
		ws.write_http_error(sock, ws.Http_Status{404, "Not Found", ""})
		return false
	}

	if origin, has_origin := ws.http_header(&req, "Origin"); has_origin && !origin_allowed(server, origin) {
		log.warnf("remote: rejected a connection from origin %q", origin)
		ws.write_http_error(sock, ws.Http_Status{403, "Forbidden", ""})
		return false
	}

	if client_count(server) >= MAX_CLIENTS {
		log.warnf("remote: refused a connection, %v clients already attached", MAX_CLIENTS)
		ws.write_http_error(sock, ws.Http_Status{503, "Service Unavailable", ""})
		return false
	}

	if up_err := ws.server_upgrade(sock, &req); up_err != .None {
		ws.write_http_error(sock, ws.http_status_for(up_err))
		return false
	}

	client := new(Client, server.allocator)
	client.allocator = server.allocator
	client.alive = true
	client.last_rx = time.now()
	client.last_ping = client.last_rx
	client.out = make([dynamic][]u8, 0, 16, server.allocator)
	ws.conn_init(&client.conn, sock, .Server, MAX_MESSAGE, req.leftover, server.allocator)

	sync.lock(&server.clients_mu)
	server.next_id += 1
	client.id = server.next_id
	append(&server.clients, client)
	sync.unlock(&server.clients_mu)

	client.writer = thread.create_and_start_with_poly_data(client, writer_loop)
	log.infof("remote: client %v attached", client.id)
	return true
}

client_kill :: proc(client: ^Client) {
	sync.lock(&client.out_mu)
	client.alive = false
	sync.unlock(&client.out_mu)
	sync.cond_broadcast(&client.out_cond)
}

client_is_alive :: proc(client: ^Client) -> bool {
	sync.guard(&client.out_mu)
	return client.alive
}

client_shutdown :: proc(client: ^Client) {
	ws.ws_send_close(&client.conn, 1001)
	client_kill(client)
	net.close(client.conn.sock)

	if client.reader != nil {
		thread.join(client.reader)
		thread.destroy(client.reader)
		client.reader = nil
	}

	if client.writer != nil {
		thread.join(client.writer)
		thread.destroy(client.writer)
		client.writer = nil
	}

	ws.conn_destroy(&client.conn)

	for payload in client.out {
		delete(payload, client.allocator)
	}
	delete(client.out)
	free(client, client.allocator)
}

client_enqueue :: proc(client: ^Client, payload: []u8) -> bool {
	sync.lock(&client.out_mu)

	if !client.alive {
		sync.unlock(&client.out_mu)
		return false
	}

	if len(client.out) >= MAX_OUT {
		client.alive = false
		sync.unlock(&client.out_mu)
		sync.cond_broadcast(&client.out_cond)
		log.warnf("remote: client %v fell %v messages behind, dropping it", client.id, MAX_OUT)
		return false
	}

	append(&client.out, slice.clone(payload, client.allocator))
	sync.unlock(&client.out_mu)
	sync.cond_signal(&client.out_cond)
	return true
}

writer_loop :: proc(client: ^Client) {
	for {
		sync.lock(&client.out_mu)
		for client.alive && len(client.out) == 0 {
			sync.cond_wait(&client.out_cond, &client.out_mu)
		}
		if !client.alive {
			sync.unlock(&client.out_mu)
			return
		}
		batch := client.out
		client.out = make([dynamic][]u8, 0, 16, client.allocator)
		sync.unlock(&client.out_mu)

		failed: ws.Conn_Error
		for payload in batch {
			if failed == .None {
				failed = ws.ws_send_text(&client.conn, string(payload))
			}
			delete(payload, client.allocator)
		}
		delete(batch)

		if failed != .None {
			log.debugf("remote: client %v send failed (%v), dropping it", client.id, failed)
			client_kill(client)
			return
		}
	}
}

@(private)
origin_allowed :: proc(server: ^Server, origin: string) -> bool {
	for allowed in server.cfg.allowed_origins {
		if allowed == origin do return true
	}
	return false
}

@(private)
client_count :: proc(server: ^Server) -> int {
	sync.guard(&server.clients_mu)
	return len(server.clients)
}
