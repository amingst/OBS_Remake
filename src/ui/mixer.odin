package ui

import im "libs:odin-imgui"
import "../scene"
import "core:fmt"
import "core:math"

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
    p := panel_begin("Audio Mixer", "AUDIO MIXER")
    if p.visible {
        panel_header_end()

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

                // Name, then the level readout and mute toggle on the right.
                right_x := im.GetCursorPosX() + im.GetContentRegionAvail().x
                im.TextUnformatted(audio_src_label(src))

                peak: f32 = d.stream != nil ? d.stream.peak : 0
                db := peak_db(peak)

                mute_w := im.GetFrameHeight()
                readout := d.muted ? cstring("muted") : fmt.ctprintf("%.1f dB", db)
                im.PushFontFloat(fonts.mono, FONT_SIZE_TELEMETRY)
                readout_w := im.CalcTextSize(readout).x
                im.SameLine()
                im.SetCursorPosX(right_x - mute_w - readout_w - 8 * ui_scale())
                im.PushStyleColorVec4(.Text, rgba(TEXT_VARIANT))
                im.TextUnformatted(readout)
                im.PopStyleColor()
                im.PopFont()

                im.SameLine()
                im.SetCursorPosX(right_x - mute_w)
                im.PushStyleColorVec4(.Button, rgba(0, 0))
                im.PushStyleColorVec4(.ButtonHovered, rgba(SURFACE_HIGHEST))
                im.PushStyleColorVec4(.ButtonActive, rgba(OUTLINE_VARIANT))
                im.PushStyleColorVec4(.Text, rgba(d.muted ? DANGER : TEXT_VARIANT))
                if im.Button(d.muted ? ICON_VOLUME_XMARK : ICON_VOLUME_HIGH, {mute_w, mute_w}) {
                    d.muted = !d.muted
                }
                im.PopStyleColor(4)

                draw_meter(d.muted ? -60 : db)

                im.PushStyleColorVec4(.FrameBg, rgba(SLATE_SURFACE))
                im.SliderFloat("##vol", &d.volume, 0, 1, "%.2f")
                im.PopStyleColor()

                im.Spacing()
                im.PopID()
            }
            if !any do im.TextDisabled("No audio sources in this scene")
        }
    }
    panel_end(p)
}

// Linear peak (0..1) to dBFS, floored at the meter's bottom.
@(private="file")
peak_db :: proc(peak: f32) -> f32 {
    if peak <= 0.000_001 {
        return METER_FLOOR_DB
    }
    return max(20 * math.log10(peak), METER_FLOOR_DB)
}

METER_FLOOR_DB :: f32(-60)

// Horizontal level meter: green below -12 dB, amber to -3 dB, red above.
@(private="file")
draw_meter :: proc(db: f32) {
    scale  := ui_scale()
    height := 6 * scale
    width  := im.GetContentRegionAvail().x

    origin := im.GetCursorScreenPos()
    p_min  := origin
    p_max  := im.Vec2{origin.x + width, origin.y + height}

    dl := im.GetWindowDrawList()
    im.DrawList_AddRectFilled(dl, p_min, p_max, col32(SLATE_SURFACE), height * 0.5)

    norm := clamp((db - METER_FLOOR_DB) / -METER_FLOOR_DB, 0, 1)
    if norm > 0 {
        color := col32(SUCCESS)
        switch {
        case db > -3:  color = col32(DANGER)
        case db > -12: color = col32(WARNING)
        }
        fill_max := im.Vec2{origin.x + width * norm, p_max.y}
        im.DrawList_AddRectFilled(dl, p_min, fill_max, color, height * 0.5)
    }

    im.Dummy({width, height})
}