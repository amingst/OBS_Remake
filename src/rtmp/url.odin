package rtmp

import "core:strconv"
import "core:strings"

DEFAULT_PORT :: 1935

// Splits a server URL like "rtmp://live.example.com:1935/app" into the
// host/port/app/tc_url rtmp_stream_start wants. tc_url is the connect URL
// (the input, minus a trailing slash) -- app is the first path segment.
// Only the single "Server URL + Stream Key" shape is supported (matches
// what mainstream streaming tools show users), not arbitrary RTMP URLs
// with extra path segments or query strings.
parse_url :: proc(url: string, allocator := context.allocator) -> (host, app, tc_url: string, port: int, ok: bool) {
	rest := url
	if strings.has_prefix(rest, "rtmp://") {
		rest = rest[len("rtmp://"):]
	} else {
		return
	}
	rest = strings.trim_suffix(rest, "/")
	if rest == "" {
		return
	}

	hostport := rest
	path := ""
	if i := strings.index_byte(rest, '/'); i >= 0 {
		hostport = rest[:i]
		path = rest[i + 1:]
	}
	if hostport == "" || path == "" {
		return
	}

	port = DEFAULT_PORT
	if i := strings.index_byte(hostport, ':'); i >= 0 {
		host = strings.clone(hostport[:i], allocator)
		port_str := hostport[i + 1:]
		parsed, parsed_ok := strconv.parse_int(port_str)
		if !parsed_ok {
			delete(host, allocator)
			return
		}
		port = parsed
	} else {
		host = strings.clone(hostport, allocator)
	}

	app = strings.clone(path, allocator)
	tc_url = strings.clone(url, allocator)
	ok = true
	return
}
