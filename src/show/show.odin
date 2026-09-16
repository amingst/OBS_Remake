package show

Show :: struct {
	id: string,	// UUID v4
	name: string, // display name for folders
	version: int, // Current version of the show file
	video: Show_Video_Settings,
	sources: []Show_Source,
	scenes: []Show_Scene,
	outputs: []Show_Stream_Output,
	recording: Show_Stream_Recording_Destination,
}
