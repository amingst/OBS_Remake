package websocket

import "core:encoding/base64"
import "core:crypto/legacy/sha1"
import "core:fmt"
import "core:net"
import "core:strings"

Http_Header :: struct {
	name, value: string, // slices into Http_Request.buf
}

Http_Request :: struct {
	method:   string,
	path:     string,
	headers:  [dynamic]Http_Header,
	leftover: []u8,        // bytes read past the blank line: the start of the first frame
	buf:      [dynamic]u8, // owns every string above
}

Handshake_Error :: enum {
	None,

	// Reading the request.
	Closed,    // peer closed before sending a full request
	Too_Large, // no blank line within max_bytes
	Malformed, // bad request line or header
	Network,   // recv/send failed or timed out

	// Checking it. The caller picks the HTTP status: see http_status_for.
	Not_Get,     // method isn't GET
	Not_Upgrade, // Upgrade/Connection headers don't ask for a websocket
	Bad_Version, // Sec-WebSocket-Version isn't 13
	Bad_Key,     // Sec-WebSocket-Key missing, or not 16 bytes of base64
}

WEBSOCKET_GUID :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
WEBSOCKET_VERSION :: "13"

accept_key :: proc(client_key: string, allocator := context.allocator) -> string {
	ctx: sha1.Context
	sha1.init(&ctx)
	sha1.update(&ctx, transmute([]byte)client_key)
	sha1.update(&ctx, transmute([]byte)string(WEBSOCKET_GUID))
	digest: [sha1.DIGEST_SIZE]byte
	sha1.final(&ctx, digest[:])
	return base64.encode(digest[:], allocator = allocator)
}

// Reads an HTTP request up to and including the blank line. Doesn't set a
// timeout; the caller sets .Receive_Timeout on sock first.
read_http_request :: proc(sock: net.TCP_Socket, max_bytes: int = 8 * 1024, allocator := context.allocator) -> (req: Http_Request, err: Handshake_Error) {
	req.buf = make([dynamic]u8, 0, 1024, allocator)
	chunk: [1024]u8

	for {
		if end := strings.index(string(req.buf[:]), "\r\n\r\n"); end >= 0 {
			err = parse_http_request(&req, end, allocator)
			if err != .None do http_request_destroy(&req)
			return
		}

		if len(req.buf) >= max_bytes {
			http_request_destroy(&req)
			return {}, .Too_Large
		}

		n, recv_err := net.recv_tcp(sock, chunk[:])
		if recv_err != nil {
			http_request_destroy(&req)
			return {}, .Network
		}

		if n == 0 {
			http_request_destroy(&req)
			return {}, .Closed
		}

		append(&req.buf, ..chunk[:n])
	}
}

// Checks that req is a valid websocket upgrade. No socket I/O.
check_upgrade :: proc(req: ^Http_Request) -> Handshake_Error {
	if req.method != "GET" do return .Not_Get
	if !header_has_token(req, "Upgrade", "websocket") || !header_has_token(req, "Connection", "Upgrade") {
		return .Not_Upgrade
	}
	if version, ok := http_header(req, "Sec-WebSocket-Version"); !ok || version != WEBSOCKET_VERSION {
		return .Bad_Version
	}

	key, has_key := http_header(req, "Sec-WebSocket-Key")
	if !has_key do return .Bad_Key
	// base64.decode ignores dst and allocates; decode_into_buf doesn't. Check
	// the length first so a long key can't overrun the buffer.
	if base64.decoded_len(key) != 16 do return .Bad_Key
	decoded_buf: [16]byte
	if _, decode_err := base64.decode_into_buf(decoded_buf[:], key); decode_err != nil do return .Bad_Key

	return .None
}

// Checks req and, if it's a valid upgrade, writes the 101 response. On a check
// failure nothing is written: reply with write_http_error(sock, http_status_for(err)).
// After success, hand req.leftover to the connection before destroying req.
server_upgrade :: proc(sock: net.TCP_Socket, req: ^Http_Request) -> Handshake_Error {
	if err := check_upgrade(req); err != .None do return err

	key, _ := http_header(req, "Sec-WebSocket-Key")
	accept := accept_key(key, context.temp_allocator)

	buf: [256]u8
	response := fmt.bprintf(buf[:],
		"HTTP/1.1 101 Switching Protocols\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Accept: %s\r\n" +
		"\r\n", accept)

	if _, send_err := net.send_tcp(sock, transmute([]u8)response); send_err != nil {
		return .Network
	}
	return .None
}

Http_Status :: struct {
	code:          int,
	reason:        string,
	extra_headers: string, // each line ends in "\r\n"
}

// The response for a failed handshake.
http_status_for :: proc(err: Handshake_Error) -> Http_Status {
	#partial switch err {
	case .Bad_Version:
		return {426, "Upgrade Required", "Sec-WebSocket-Version: " + WEBSOCKET_VERSION + "\r\n"}
	case .Too_Large:
		return {431, "Request Header Fields Too Large", ""}
	}
	return {400, "Bad Request", ""}
}

// Writes a body-less HTTP error response. The caller closes the socket afterwards.
write_http_error :: proc(sock: net.TCP_Socket, status: Http_Status) -> Handshake_Error {
	buf: [512]u8
	response := fmt.bprintf(buf[:],
		"HTTP/1.1 %d %s\r\n" +
		"Content-Length: 0\r\n" +
		"Connection: close\r\n" +
		"%s" +
		"\r\n", status.code, status.reason, status.extra_headers)

	if _, send_err := net.send_tcp(sock, transmute([]u8)response); send_err != nil {
		return .Network
	}
	return .None
}

@(private)
parse_http_request :: proc(req: ^Http_Request, end: int, allocator := context.allocator) -> Handshake_Error {
	head := string(req.buf[:end])
	req.leftover = req.buf[end + 4:]
	req.headers = make([dynamic]Http_Header, 0, 16, allocator)

	req_line, _ := strings.split_iterator(&head, "\r\n")
	parts := req_line
	method, m_ok := strings.split_iterator(&parts, " ")
	path, p_ok := strings.split_iterator(&parts, " ")
	if !m_ok || !p_ok || !strings.has_prefix(parts, "HTTP/1.") do return .Malformed

	req.method = method
	req.path = path

	for line in strings.split_iterator(&head, "\r\n") {
		colon := strings.index_byte(line, ':')
		if colon <= 0 do return .Malformed
		append(&req.headers, Http_Header{
			name = strings.trim_space(line[:colon]),
			value = strings.trim_space(line[colon + 1:])
		})
	}

	return .None
}

http_header :: proc(req: ^Http_Request, name: string) -> (value: string, ok: bool) {
	for h in req.headers {
		if strings.equal_fold(h.name, name) do return h.value, true
	}

	return "", false
}

// True if the header is a comma-separated list containing token, ignoring
// case -- browsers send e.g. "Connection: keep-alive, Upgrade".
header_has_token :: proc(req: ^Http_Request, name, token: string) -> bool {
	value, ok := http_header(req, name)
	if !ok do return false
	for part in strings.split_iterator(&value, ",") {
		if strings.equal_fold(strings.trim_space(part), token) do return true
	}
	return false
}

http_request_destroy :: proc(req: ^Http_Request) {
	delete(req.headers)
	delete(req.buf)
	req^ = {}
}
