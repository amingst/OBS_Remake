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
connect_command_accepted :: proc(t: ^testing.T) {
    c, ok := connect("127.0.0.1", 1935)
    if !ok {
        log.info("no RTMP server on 127.0.0.1:1935 -- skipping (see commands_test.odin header)")
        return
    }
    defer close(&c)

    if !handshake(&c) {
        testing.fail_now(t, "handshake failed before connect could be tested")
    }

    testing.expect(t, send_connect(&c, "live", "rtmp://127.0.0.1:1935/live"),
        "send_connect failed")



    // Window Ack Size (5), Set Peer Bandwidth (6), Set Chunk Size (1), then
    // the AMF0 _result (20). Set Chunk Size is consumed inside read_message,
    // so it won't appear here -- watch the log for it instead.
    msgs := 0
    for i in 0..<4 {
        msg, msg_ok := read_message(&c)
        if !msg_ok {
            log.infof("read_message returned false after %v messages", i)
            break
        }
        msgs += 1
        log.infof("msg type=%v csid=%v len=%v stream=%v",
            msg.type_id, msg.csid, len(msg.payload), msg.stream_id)
    }

    testing.expect(t, msgs > 0, "server sent nothing -- connect was likely rejected")
}
