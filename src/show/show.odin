package show

import "core:encoding/uuid"
import "core:strings"

Show :: struct {
	id: string,	// UUID v4
	name: string, // display name for folders
	version: int, // Current version of the show file
	video: Show_Video_Settings,
	sources: [dynamic]Show_Source,
	scenes: [dynamic]Show_Scene,
	outputs: [dynamic]Show_Stream_Output,
	recording: Show_Stream_Recording_Destination,
}

create_default :: proc() -> Show {
	return Show{
		id      = new_id(),
		name    = strings.clone("Default"),
		version = CURRENT_VERSION,
		video = {
			canvas_width  = 1920,
			canvas_height = 1080,
			output_width  = 1920,
			output_height = 1080,
			fps           = 60,
		},
	}
}

destroy_show :: proc(s: ^Show) {
	if s == nil do return

	for &src in s.sources {
		destroy_source(&src)
	}
	delete(s.sources)

	for &scene in s.scenes {
		destroy_scene(&scene)
	}
	delete(s.scenes)

	for &out in s.outputs {
		destroy_output(&out)
	}
	delete(s.outputs)

	delete(s.recording.path)
	delete(s.id)
	delete(s.name)
	s^ = {}
}

@(private)
new_id :: proc() -> string {
	return uuid.to_string(
		uuid.generate_v4(),
		context.allocator,
	)
}
