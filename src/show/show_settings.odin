package show

import "core:strings"

Bitrate_Mode :: enum {
	Manual,
	Auto,
}

RTMP_Output_Data :: struct {
	url: string,
	key: string,
}

Show_Stream_Output_Data :: union {
	RTMP_Output_Data,
}

Show_Stream_Output :: struct {
	id: string, // UUID v4
	label: string, // display name
	enabled: bool, // whether the output is enabled
	platform: string, // platform (e.g. "twitch", "youtube", "rumble") - applies regardless of output kind
	bitrate_kbps: int, // bitrate in kilobits per second
	bitrate_mode: Bitrate_Mode, // bitrate mode (manual or auto)
	data: Show_Stream_Output_Data,
}

// Returns the show's single output, creating a default one first if it has
// none (e.g. a show.json saved before outputs existed). A show always has
// exactly one to edit, same as a Profile always had exactly one Stream_Settings.
ensure_output :: proc(s: ^Show) -> ^Show_Stream_Output {
	if len(s.outputs) == 0 {
		append(&s.outputs, Show_Stream_Output{
			id           = new_id(),
			label        = strings.clone("Default"),
			enabled      = true,
			platform     = strings.clone("custom"),
			bitrate_kbps = DEFAULT_BITRATE_KBPS,
			bitrate_mode = .Manual,
			data         = RTMP_Output_Data{
				url = strings.clone(""),
				key = strings.clone(""),
			},
		})
	}
	return &s.outputs[0]
}

destroy_output :: proc(o: ^Show_Stream_Output) {
	if o == nil do return

	switch &d in o.data {
	case RTMP_Output_Data:
		delete(d.url)
		delete(d.key)
	}

	delete(o.id)
	delete(o.label)
	delete(o.platform)
}

Show_Stream_Recording_Destination :: struct {
	path: string, // file path, defaults to .../Videos/StreamSmith/{show_id}/
}

Show_Video_Settings :: struct {
	canvas_width, canvas_height: i32,
	output_width, output_height: i32,
	fps: i32,
}
