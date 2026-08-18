package settings

import "core:encoding/uuid"
import "core:strings"

Video_Settings :: struct {
    canvas_width, canvas_height: i32,
    output_width, output_height: i32,
    fps: i32
}

Profile :: struct {
    id: string,
    name: string,
    video: Video_Settings,
}

destroy_profile :: proc(p: ^Profile) {
    delete(p.id)
    delete(p.name)
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
    }
}

@(private="file")
new_id :: proc() -> string {
    return uuid.to_string(
        uuid.generate_v4(),
        context.allocator
    )
}