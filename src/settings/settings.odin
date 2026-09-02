package settings

import "core:encoding/uuid"
import "core:strings"

Video_Settings :: struct {
    canvas_width, canvas_height: i32,
    output_width, output_height: i32,
    fps: i32
}

// Nothing enforces an upper bound on canvas_width/canvas_height today --
// custom canvas input (menubar.odin) and monitor-output presets both accept
// whatever the user picks. This is the ceiling fixed-size buffers sized off
// "the canvas" (e.g. rtmp.Frame_Mailbox) are allowed to assume; it is not
// itself an input-validation clamp.
MAX_CANVAS_WIDTH  :: 3840
MAX_CANVAS_HEIGHT :: 2160

Stream_Settings :: struct {
    host: string,
    port: i32,
    app: string,
    tc_url: string,
    stream_key: string,
    bitrate: i32,
}

Profile :: struct {
    id: string,
    name: string,
    video: Video_Settings,
    stream: Stream_Settings,
}

destroy_profile :: proc(p: ^Profile) {
    delete(p.id)
    delete(p.name)
    delete(p.stream.host)
    delete(p.stream.app)
    delete(p.stream.tc_url)
    delete(p.stream.stream_key)
    p^ = {}
}

create_default :: proc() -> Profile {
    return Profile{
        id = new_id(),
        name = strings.clone("Default"),
        video = {
            canvas_width = 1920,
            canvas_height = 1080,
            output_width = 1920,
            output_height = 1080,
            fps = 60,
        },
        stream = {
            host = strings.clone(""),
            app = strings.clone(""),
            tc_url = strings.clone(""),
            stream_key = strings.clone(""),
            bitrate = 2_000_000,
        },
    }
}

@(private="file")
new_id :: proc() -> string {
    return uuid.to_string(
        uuid.generate_v4(),
        context.allocator
    )
}