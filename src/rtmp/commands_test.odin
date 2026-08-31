package rtmp

import "core:log"
import "core:testing"

// Needs an RTMP server on 127.0.0.1:1935:
//
//     ffmpeg -listen 1 -i rtmp://0.0.0.0:1935/live/test -c copy out.flv
//
// -listen 1 accepts exactly one connection and exits, so restart it between
// runs -- and note this test and the handshake test in rtmp_test.odin will
// fight over that single connection if the runner uses more than one thread.
// Run with -define:ODIN_TEST_THREADS=1, or run them individually.

@(test)
publish_sequence :: proc(t: ^testing.T) {
    c, ok := connect("127.0.0.1", 1935)
    if !ok {
        log.info("no RTMP server on 127.0.0.1:1935 -- skipping")
        return
    }
    defer close(&c)

    if !handshake(&c) do testing.fail_now(t, "handshake failed")
    if !send_connect(&c, "live", "rtmp://127.0.0.1:1935/live") {
        testing.fail_now(t, "send_connect failed")
    }

    if !send_set_chunk_size(&c, 4096) {
        testing.fail_now(t, "send_set_chunk_size failed")
    }

    // Drain the connect response -- window ack, peer bandwidth, stream begin,
    // and the _result. createStream's reply can't be read until these are off
    // the wire.
    for _ in 0..<4 {
        msg, msg_ok := read_message(&c)
        if !msg_ok do break
        log.infof("connect reply: type=%v len=%v", msg.type_id, len(msg.payload))
    }

    if !send_create_stream(&c) do testing.fail_now(t, "send_create_stream failed")

    stream_id, id_ok := read_create_stream_result(&c)
    testing.expect(t, id_ok, "createStream did not return a stream id")
    log.infof("stream id: %v", stream_id)

    testing.expect(t, send_publish(&c, "test", stream_id), "send_publish failed")

    // onStatus with NetStream.Publish.Start if it worked.
    msg, msg_ok := read_message(&c)
    testing.expect(t, msg_ok, "no reply to publish")
    if msg_ok {
        log.infof("publish reply: type=%v len=%v", msg.type_id, len(msg.payload))
    }
}
