package show

Show_Source_Placement :: struct {
	id: string, // UUID v4
	source_id: string, // UUID v4
	x, y, w, h: f32, // X and Y positions, width and height
	order: int, // layer order
	color: [4]f32,
	visible: bool, // whether this placement is shown in this scene
	mute_override: bool, // Whether the show mutes the source on the scene
}

Show_Scene :: struct {
	id: string, // UUID v4
	name: string, // display name
	order: int, // layer order
	sources: []Show_Source_Placement,
}
