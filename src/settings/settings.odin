package settings

// i32 rather than u32 because ImGui's integer widgets are signed-only
// (InputInt/InputInt2, no unsigned equivalent) and nothing here needs a range
// past 2 billion. The render layer takes u32, so the cast happens at that call.
Video_Settings :: struct {
    canvas_width, canvas_height: i32,
    output_width, output_height: i32,
    fps: i32
}

Settings :: struct {
    video: Video_Settings
}

init :: proc() -> Settings {
    return Settings{
        video = {canvas_width = 1920, canvas_height = 1080,
                 output_width = 1920, output_height = 1080, fps = 60},
    }
}