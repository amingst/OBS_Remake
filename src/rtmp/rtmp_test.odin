// src/rtmp/rtmp_test.odin
package rtmp

import "core:log"
import "core:testing"

// These need an RTMP server listening on 127.0.0.1:1935. Start one with:
//
//     ffmpeg -listen 1 -i rtmp://0.0.0.0:1935/live/test -c copy out.flv
//
// ffmpeg's -listen accepts exactly one connection and exits when the stream
// ends, so it has to be restarted between runs.
//
// When no server is up these skip rather than fail: a red test that means
// "you forgot to start ffmpeg" trains you to ignore red tests. The skip
// message says what to do instead.
@(private="file") TEST_HOST :: "127.0.0.1"
@(private="file") TEST_PORT :: 1935

// @(test)
// connect_to_local_server :: proc(t: ^testing.T) {
//     c, ok := connect(TEST_HOST, TEST_PORT)
//     if !ok {
//         log.infof("no RTMP server on %v:%v -- skipping (see rtmp_test.odin header)",
//             TEST_HOST, TEST_PORT)
//         return
//     }
//     defer close(&c)
//     testing.expect(t, true, "connected")
// }

@(test)
handshake_with_local_server :: proc(t: ^testing.T) {
    c, ok := connect(TEST_HOST, TEST_PORT)
    if !ok {
        log.infof("no RTMP server on %v:%v -- skipping (see rtmp_test.odin header)",
            TEST_HOST, TEST_PORT)
        return
    }
    defer close(&c)

    testing.expect(t, handshake(&c), "handshake failed -- check the server's log for why")
}
