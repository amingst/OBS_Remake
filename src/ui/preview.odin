package ui

import "core:log"
import im "libs:odin-imgui"
import "../scene"

HANDLE_SIZE :: 8.0

Drag_Mode :: enum u8 {
    None,
    Move,
    NW, N, NE, E, SE, S, SW, W
}

Preview_State :: struct {
    logged_collapsed: bool,
    image_min: [2]f32,
    image_size: [2]f32,
    mode: Drag_Mode,
    drag_id: u64,
    grab_offset: [2]f32,
    orig: [4]f32
}

init_preview_state :: proc() -> Preview_State {
    return Preview_State{}
}


draw_preview :: proc(
    state:    ^Preview_State,
    sources:  ^Sources_State,
    scenes:   ^Scenes_State,
    doc:      ^scene.Collection,
    tex:      im.TextureRef,
    canvas_w, canvas_h: f32,
) {
    if im.Begin("Preview") {
        avail := im.GetContentRegionAvail()

        if avail.x > 0 && avail.y > 0 {
            if state.logged_collapsed {
                log.debug("preview panel visible again")
                state.logged_collapsed = false
            }
            size := im.Vec2{avail.x, avail.x / (canvas_w / canvas_h)}
            if size.y > avail.y {
                size = {avail.y * (canvas_w / canvas_h), avail.y}
            }

            pos := im.GetCursorScreenPos()
            centered := im.Vec2{
                pos.x + (avail.x - size.x) * 0.5,
                pos.y + (avail.y - size.y) * 0.5,
            }
            im.SetCursorScreenPos(centered)

            state.image_min = {centered.x, centered.y}
            state.image_size = {size.x, size.y}

            im.Image(tex, size)

            if sc := scene.find(doc, scenes.selected_id); sc != nil {
                if src := scene.find_source(sc, sources.selected_id); src != nil {
                    tl := canvas_to_screen(state, canvas_w, canvas_h, {src.x, src.y})
                    br := canvas_to_screen(state, canvas_w, canvas_h, {src.x + src.w, src.y + src.h})

                    dl := im.GetWindowDrawList()

                    positions := [8][2]f32{
                        {tl.x, tl.y},
                        {(tl.x + br.x) * 0.5, tl.y},
                        {br.x, tl.y},
                        {br.x, (tl.y + br.y) * 0.5},
                        {br.x, br.y},
                        {(tl.x + br.x) * 0.5, br.y},
                        {tl.x, br.y},
                        {tl.x, (tl.y + br.y) * 0.5},
                    }

                    for hp in positions {
                        p_min := im.Vec2{hp.x - HANDLE_SIZE/2, hp.y - HANDLE_SIZE/2}
                        p_max := im.Vec2{hp.x + HANDLE_SIZE/2, hp.y + HANDLE_SIZE/2}
                        im.DrawList_AddRectFilled(
                            dl,
                            p_min,
                            p_max,
                            0xFF00FF00
                        )
                    }

                    im.DrawList_AddRect(dl, {tl.x, tl.y}, {br.x, br.y}, 0xFF00FF00)
                }
            }

            // Handle Source Selection From Click In Preview
            if im.IsItemHovered() && im.IsMouseClicked(.Left) {
                mouse := im.GetMousePos()
                canvas_pos := screen_to_canvas(state, canvas_w, canvas_h, {mouse.x, mouse.y})
                sc := scene.find(doc, scenes.selected_id)
                if sc != nil {
                    #reverse for &src in sc.sources {
                        if !src.visible do continue
                        if canvas_pos.x >= src.x && canvas_pos.x < src.x + src.w &&
                           canvas_pos.y >= src.y && canvas_pos.y < src.y + src.h {
                                sources.selected_id = src.id
                                state.mode = .Move
                                state.drag_id = src.id
                                state.grab_offset = {
                                    canvas_pos.x - src.x,
                                    canvas_pos.y - src.y
                                }
                                break
                           }
                    }
                }
            }

            // Handle Dragging
            if state.mode != .None {
                if im.IsMouseDown(.Left) {
                    mouse := im.GetMousePos()
                    cp := screen_to_canvas(state, canvas_w, canvas_h, { mouse.x, mouse.y })
                    if sc := scene.find(doc, scenes.selected_id); sc != nil {
                        if src := scene.find_source(sc, state.drag_id); src != nil {
                            src.x = cp.x - state.grab_offset.x
                            src.y = cp.y - state.grab_offset.y
                        }
                    }
                } else {
                    state.mode = .None
                }
            }

        } else if !state.logged_collapsed {
            log.warn("preview panel collapsed or too small to render")
            state.logged_collapsed = true
        }
    }
    im.End()
}

screen_to_canvas :: proc(state: ^Preview_State, canvas_w, canvas_h: f32, p: [2]f32) -> [2]f32 {
    if state.image_size.x <= 0 || state.image_size.y <= 0 do return {0, 0}
    return {
        (p.x - state.image_min.x) * canvas_w / state.image_size.x,
        (p.y - state.image_min.y) * canvas_h / state.image_size.y,
    }
}

canvas_to_screen :: proc(state: ^Preview_State, canvas_w, canvas_h: f32, p: [2]f32) -> [2]f32 {
    return {
        state.image_min.x + p.x * state.image_size.x / canvas_w,
        state.image_min.y + p.y * state.image_size.y / canvas_h,
    }
}