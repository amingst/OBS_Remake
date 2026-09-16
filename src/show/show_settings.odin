package show

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

Show_Stream_Recording_Destination :: struct {
	path: string, // file path, defaults to .../Videos/StreamSmith/{show_id}/
}

Show_Video_Settings :: struct {
	canvas_width, canvas_height: i32,
	output_width, output_height: i32,
	fps: i32,
}
