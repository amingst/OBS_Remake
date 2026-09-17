package remote

import "core:mem"
import "core:net"
import "core:sync"
import "core:thread"
import "base:intrinsics"
import "core:log"

import "../action"
import "protocol"

Server_Config :: struct {
	port:            u16,
	allowed_origins: []string,
	server_name:     string,
}

Server :: struct {
	cfg:      Server_Config,
	listener: net.TCP_Socket,
	listener_thread: ^thread.Thread,
	ticker_thread:   ^thread.Thread,
	queue:    ^action.Envelope_Queue,
	clients:   [dynamic]^Client,
	clients_mu: sync.Mutex,
	next_id:   u32,
	snapshot:    []u8,
	snapshot_mu: sync.Mutex,

	allocator: mem.Allocator,
	running: bool,
}

server_init :: proc(cfg: Server_Config, queue: ^action.Envelope_Queue, allocator := context.allocator) -> Server {
	return Server{cfg = cfg, queue = queue, allocator = allocator}
}

server_start :: proc(server: ^Server) -> bool {
	ep := net.Endpoint{
		address = net.IP4_Loopback,
		port    = int(server.cfg.port),
	}

	sock, sock_err := net.listen_tcp(ep)
	if sock_err != nil {
		return false
	}
	server.listener = sock
	server.clients = make([dynamic]^Client, 0, MAX_CLIENTS, server.allocator)

	intrinsics.atomic_store(&server.running, true)
	server.listener_thread = thread.create_and_start_with_poly_data(server, listen_loop)
	if server.listener_thread == nil {
		log.warnf("listen_loop: server not running %v", server.running)
		return false
	}
	return true
}

server_stop :: proc(server: ^Server) {
	if !intrinsics.atomic_exchange(&server.running, false) do return

	net.close(server.listener)

	if server.listener_thread != nil {
		thread.join(server.listener_thread)
		thread.destroy(server.listener_thread)
		server.listener_thread = nil
	}

	if server.ticker_thread != nil {
		thread.join(server.ticker_thread)
		thread.destroy(server.ticker_thread)
		server.ticker_thread = nil
	}

	leaving: [dynamic]^Client
	{
		sync.guard(&server.clients_mu)
		leaving = server.clients
		server.clients = nil
	}

	for client in leaving {
		client_shutdown(client)
	}
	delete(leaving)

	sync.guard(&server.snapshot_mu)
	delete(server.snapshot)
	server.snapshot = nil
}

server_respond :: proc(server: ^Server, client_id: u32, payload: []u8) {
	sync.lock(&server.clients_mu)
	for client in server.clients {
		if client.id == client_id {
			client_enqueue(client, payload)
			break
		}
	}
	sync.unlock(&server.clients_mu)
}

server_broadcast :: proc(server: ^Server, topic: protocol.Topic, payload: []u8) {
	sync.lock(&server.clients_mu)
	for client in server.clients {
		subscribed := false
		sync.lock(&client.topics_mu)
		subscribed = topic in client.topics
		sync.unlock(&client.topics_mu)
		if subscribed {
			client_enqueue(client, payload)
		}
	}
	sync.unlock(&server.clients_mu)
}

listen_loop :: proc(server: ^Server) {
	if server == nil {
		log.warnf("listen_loop: server is nil")
		return
	}

	for intrinsics.atomic_load(&server.running) {
		sock, _, err := net.accept_tcp(server.listener)
		if err != nil {
			if !intrinsics.atomic_load(&server.running) do break
			continue
		}
		if !client_admit(server, sock) do net.close(sock)
	}
}
