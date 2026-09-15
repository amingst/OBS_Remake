package ui

import "core:log"
import im "libs:odin-imgui"
import "../scene"

HANDLE_SIZE :: 8.0
MIN_SIZE :: 10.0
HANDLE_HIT :: 12.0

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
    orig: [4]f32,
    drag_start: [2]f32
}

init_preview_state :: proc() -> Preview_State {
    return Preview_State{}
}


draw_preview :: proc(
    state:    ^Preview_State,
    sources:  ^Sources_State,
    scenes:   ^Scenes_State,
    controls: ^Controls_State,
    doc:      ^scene.Collection,
    tex:      im.TextureRef,
    canvas_w, canvas_h: f32,
) {
    p := panel_begin("Preview", "PROGRAM PREVIEW")
    if p.visible {
        panel_header_end()
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

            // Handle Source Selection From Click In Preview
            if im.IsItemHovered() && im.IsMouseClicked(.Left) {
                begin_drag(state, sources, scenes, doc, canvas_w, canvas_h)
            }
            apply_drag(state, scenes, doc, canvas_w, canvas_h)
            draw_overlay(state, sources, scenes, doc, canvas_w, canvas_h)
            draw_rec_badge(state, controls)
        } else if !state.logged_collapsed {
            log.warn("preview panel collapsed or too small to render")
            state.logged_collapsed = true
        }
    }
    panel_end(p)
}

// Recording/streaming badge, pinned to the bottom-right of the preview image.
@(private="file")
draw_rec_badge :: proc(state: ^Preview_State, controls: ^Controls_State) {
    label: cstring
    switch {
    case controls.streaming && controls.recording: label = "● LIVE + REC"
    case controls.streaming:                       label = "● LIVE"
    case controls.recording:                       label = "● REC"
    case:                                          return
    }

    scale := ui_scale()
    pad   := 8 * scale
    im.PushFontFloat(fonts.mono, FONT_SIZE_TELEMETRY)
    text_size := im.CalcTextSize(label)

    br := im.Vec2{
        state.image_min.x + state.image_size.x - pad,
        state.image_min.y + state.image_size.y - pad,
    }
    tl := im.Vec2{br.x - text_size.x - pad * 2, br.y - text_size.y - pad}

    dl := im.GetWindowDrawList()
    im.DrawList_AddRectFilled(dl, tl, br, col32(SURFACE_LOWEST, 0.85), 6 * scale)

    im.SetCursorScreenPos({tl.x + pad, tl.y + pad * 0.5})
    im.PushStyleColorVec4(.Text, rgba(DANGER))
    im.TextUnformatted(label)
    im.PopStyleColor()
    im.PopFont()
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

begin_drag :: proc(
    state: ^Preview_State,
    sources: ^Sources_State,
    scenes: ^Scenes_State,
    doc: ^scene.Collection,
    canvas_w, canvas_h: f32,
) {
    mouse := im.GetMousePos()
    canvas_pos := screen_to_canvas(state, canvas_w, canvas_h, {mouse.x, mouse.y})
    sc := scene.find(doc, scenes.selected_id)
    if sc != nil {
        if src := scene.find_source(sc, sources.selected_id); src != nil {
            positions := handle_positions(state, canvas_w, canvas_h, src)
            for hp, i in positions {
                if abs(mouse.x - hp.x) <= HANDLE_HIT/2 && abs(mouse.y - hp.y) <= HANDLE_HIT/2 {
                    state.mode = Drag_Mode(int(Drag_Mode.NW) + i)
                    state.drag_id = src.id
                    state.orig = {src.x, src.y, src.w, src.h}
                    state.drag_start = canvas_pos
                    return
                }
            }
        }
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

apply_drag :: proc(
    state: ^Preview_State,
    scenes: ^Scenes_State,
    doc: ^scene.Collection,
    canvas_w, canvas_h: f32,
) {
    if state.mode == .None do return
    if !im.IsMouseDown(.Left) {
        state.mode = .None
        return
    }

    mouse := im.GetMousePos()
    cp := screen_to_canvas(state, canvas_w, canvas_h, {mouse.x, mouse.y})

    sc := scene.find(doc, scenes.selected_id)
    if sc == nil do return
    src := scene.find_source(sc, state.drag_id)
    if src == nil do return

    if state.mode == .Move {
        src.x = cp.x - state.grab_offset.x
        src.y = cp.y - state.grab_offset.y
        return
    }

    dx := cp.x - state.drag_start.x
    dy := cp.y - state.drag_start.y
    ox, oy, ow, oh := state.orig[0], state.orig[1], state.orig[2], state.orig[3]

    west, east, north, south: bool
    switch state.mode {
    case .None, .Move:
    case .NW: west = true;  north = true
    case .N:                north = true
    case .NE: east = true;  north = true
    case .E:  east = true
    case .SE: east = true;  south = true
    case .S:                south = true
    case .SW: west = true;  south = true
    case .W:  west = true
    }

    if west {
        if new_w := ow - dx; new_w < MIN_SIZE {
            src.x = ox + ow - MIN_SIZE
            src.w = MIN_SIZE
        } else {
            src.x = ox + dx
            src.w = new_w
        }
    } else if east {
        src.w = max(ow + dx, MIN_SIZE)
    }

    if north {
        if new_h := oh - dy; new_h < MIN_SIZE {
            src.y = oy + oh - MIN_SIZE   // pin the bottom edge
            src.h = MIN_SIZE
        } else {
            src.y = oy + dy
            src.h = new_h
        }
    } else if south {
        src.h = max(oh + dy, MIN_SIZE)
    }
}

draw_overlay :: proc(
    state: ^Preview_State,
    sources: ^Sources_State,
    scenes: ^Scenes_State,
    doc: ^scene.Collection,
    canvas_w, canvas_h: f32,
) {
            if sc := scene.find(doc, scenes.selected_id); sc != nil {
                if src := scene.find_source(sc, sources.selected_id); src != nil {
                    dl := im.GetWindowDrawList()
                    positions := handle_positions(
                        state,
                        canvas_w,
                        canvas_h,
                        src
                    )

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

                    im.DrawList_AddRect(
                        dl,
                        im.Vec2{positions[0].x, positions[0].y},
                        im.Vec2{positions[4].x, positions[4].y},
                        0xFF00FF00,
                    )
                }
            }
}

@(private="file")
handle_positions :: proc(
    state: ^Preview_State,
    canvas_w, canvas_h: f32,
    src: ^scene.Source
) -> [8][2]f32 {
    tl := canvas_to_screen(state, canvas_w, canvas_h, {src.x, src.y})
    br := canvas_to_screen(state, canvas_w, canvas_h, {src.x + src.w, src.y + src.h})
    
    return [8][2]f32{
        {tl.x, tl.y},
        {(tl.x + br.x) * 0.5, tl.y},
        {br.x, tl.y},
        {br.x, (tl.y + br.y) * 0.5},
        {br.x, br.y},
        {(tl.x + br.x) * 0.5, br.y},
        {tl.x, br.y},
        {tl.x, (tl.y + br.y) * 0.5},
    }
}