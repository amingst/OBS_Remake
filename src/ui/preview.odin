package ui

import im "libs:odin-imgui"

Preview_State :: struct {

}

init_preview_state :: proc() -> Preview_State {
    return Preview_State{}
}

@(private="file")
PREVIEW_ASPECT :: 16.0 / 9.0

draw_preview :: proc(state: ^Preview_State, tex: im.TextureRef) {
    if im.Begin("Preview") {
        avail := im.GetContentRegionAvail()

        if avail.x > 0 && avail.y > 0 {
            size := im.Vec2{avail.x, avail.x / PREVIEW_ASPECT}
            if size.y > avail.y {
                size = {avail.y * PREVIEW_ASPECT, avail.y}
            }

            pos := im.GetCursorScreenPos()
            im.SetCursorScreenPos({
                pos.x + (avail.x - size.x) * 0.5,
                pos.y + (avail.y - size.y) * 0.5,
            })

            im.Image(tex, size)
        }
    }
    im.End()
}
