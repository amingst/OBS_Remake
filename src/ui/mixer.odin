package ui

import im "libs:odin-imgui"
import "../scene"
import "core:fmt"

Mixer_State :: struct {

}

init_mixer_state :: proc() -> Mixer_State {
    return Mixer_State{}
}

@(private="file")
audio_src_label :: proc (o: scene.Source) -> cstring {
    return fmt.ctprintf("%v", o.name)
}

draw_mixer :: proc(state: ^Mixer_State, scenes: ^Scenes_State, doc: ^scene.Collection) {
    if im.Begin("Audio Mixer") {
        sc := scene.find(doc, scenes.selected_id)
        if sc == nil {
            im.TextDisabled("No Scenes Selected")
        } else {
            any := false
            for &src in sc.sources {
                d, is_audio := &src.data.(scene.Audio_Data)
                if !is_audio do continue
                any = true

                im.PushIDInt(i32(src.id))
                label := audio_src_label(src)
                im.TextUnformatted(label)

                level: f32 = d.stream != nil ? d.stream.peak : 0
                im.ProgressBar(level, {-1, 6}, "")

                im.SliderFloat("##vol", &d.volume, 0, 1)
                im.SameLine()
                im.Checkbox("Mute", &d.muted)
                im.Separator()
                im.PopID()
            }
            if !any do im.TextDisabled("No audio sources in this scene")
        }
    }
    im.End();
}