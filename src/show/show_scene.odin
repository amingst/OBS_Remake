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

destroy_placement :: proc(p: ^Show_Source_Placement) {
	if p == nil do return
	delete(p.id)
	delete(p.source_id)
}

destroy_scene :: proc(s: ^Show_Scene) {
	if s == nil do return
	for &p in s.sources {
		destroy_placement(&p)
	}
	delete(s.sources)
	delete(s.id)
	delete(s.name)
}
