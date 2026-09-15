package ui

import "core:log"
import im "libs:odin-imgui"

// Palette tokens, RGB hex. Alpha is applied at the use site via rgba()/col32().
BG              :: 0x0b1326 // level 0: dock background
SURFACE_LOWEST  :: 0x060e20 // footer, inset data wells
SURFACE_LOW     :: 0x131b2e // sidebar
SURFACE         :: 0x171f33 // panels
SURFACE_HIGH    :: 0x222a3d // panel headers, popups
SURFACE_HIGHEST :: 0x2d3449 // selected rows, buttons
SLATE_SURFACE   :: 0x1e293b // inputs, meter troughs
BORDER          :: 0x334155
OUTLINE         :: 0x8c909f
OUTLINE_VARIANT :: 0x424754
TEXT            :: 0xdae2fd
TEXT_VARIANT    :: 0xc2c6d6
PRIMARY         :: 0x3b82f6
PRIMARY_DEEP    :: 0x2563eb
PRIMARY_SOFT    :: 0xadc6ff
VIOLET          :: 0x8b5cf6
SUCCESS         :: 0x10b981
WARNING         :: 0xeab308
DANGER          :: 0xef4444

// Unscaled pixel sizes; DPI scaling is applied on top by ImGui.
FONT_SIZE_BODY      :: 14
FONT_SIZE_LABEL     :: 12
FONT_SIZE_HEADLINE  :: 18
FONT_SIZE_TELEMETRY :: 11

Fonts :: struct {
    regular, medium, semibold: ^im.Font, // Inter, with Font Awesome icons merged in
    mono: ^im.Font,                      // JetBrains Mono, reserved for telemetry
}

fonts: Fonts

rgba :: proc "contextless" (hex: u32, a: f32 = 1) -> im.Vec4 {
    return {f32((hex >> 16) & 0xff) / 255, f32((hex >> 8) & 0xff) / 255, f32(hex & 0xff) / 255, a}
}

// Packs to ImU32 (ABGR) for DrawList calls.
col32 :: proc "contextless" (hex: u32, a: f32 = 1) -> u32 {
    r, g, b := (hex >> 16) & 0xff, (hex >> 8) & 0xff, hex & 0xff
    return u32(a * 255 + 0.5) << 24 | b << 16 | g << 8 | r
}

// Sets style sizes and colors. Sizes are unscaled, so call before Style_ScaleAllSizes.
apply_theme :: proc() {
    style := im.GetStyle()

    style.FontSizeBase = FONT_SIZE_BODY

    style.WindowPadding    = {12, 12}
    style.FramePadding     = {10, 6}
    style.ItemSpacing      = {8, 8}
    style.ItemInnerSpacing = {6, 6}
    style.CellPadding      = {8, 6}
    style.IndentSpacing    = 20
    style.ScrollbarSize    = 10
    style.GrabMinSize      = 10

    style.WindowRounding     = 12
    style.ChildRounding      = 12
    style.PopupRounding      = 8
    style.FrameRounding      = 8
    style.TabRounding        = 8
    style.MenuItemRounding   = 6
    style.SelectableRounding = 6
    style.GrabRounding       = 5
    style.ScrollbarRounding  = 5

    style.WindowBorderSize     = 1
    style.ChildBorderSize      = 1
    style.PopupBorderSize      = 1
    style.FrameBorderSize      = 0
    style.TabBorderSize        = 0
    style.TabBarBorderSize     = 1
    style.TabBarOverlineSize   = 2
    style.DockingSeparatorSize = 2

    style.WindowTitleAlign         = {0, 0.5}
    style.WindowMenuButtonPosition = .None
    style.DisabledAlpha            = 0.5

    set := proc(style: ^im.Style, col: im.Col, v: im.Vec4) { style.Colors[int(col)] = v }

    set(style, .Text,                      rgba(TEXT))
    set(style, .TextDisabled,              rgba(OUTLINE))
    set(style, .WindowBg,                  rgba(SURFACE))
    set(style, .ChildBg,                   rgba(SURFACE, 0))
    set(style, .PopupBg,                   rgba(SURFACE_HIGH, 0.98))
    set(style, .Border,                    rgba(BORDER))
    set(style, .BorderShadow,              rgba(0, 0))
    set(style, .FrameBg,                   rgba(SLATE_SURFACE))
    set(style, .FrameBgHovered,            rgba(SURFACE_HIGHEST))
    set(style, .FrameBgActive,             rgba(BORDER))
    set(style, .TitleBg,                   rgba(SURFACE_LOW))
    set(style, .TitleBgActive,             rgba(SURFACE_HIGH))
    set(style, .TitleBgCollapsed,          rgba(SURFACE_LOW))
    set(style, .MenuBarBg,                 rgba(SURFACE))
    set(style, .ScrollbarBg,               rgba(0, 0))
    set(style, .ScrollbarGrab,             rgba(SURFACE_HIGHEST))
    set(style, .ScrollbarGrabHovered,      rgba(OUTLINE_VARIANT))
    set(style, .ScrollbarGrabActive,       rgba(OUTLINE))
    set(style, .CheckMark,                 rgba(PRIMARY))
    set(style, .CheckboxSelectedBg,        rgba(SLATE_SURFACE))
    set(style, .SliderGrab,                rgba(PRIMARY))
    set(style, .SliderGrabActive,          rgba(PRIMARY_SOFT))
    set(style, .Button,                    rgba(SURFACE_HIGHEST))
    set(style, .ButtonHovered,             rgba(OUTLINE_VARIANT))
    set(style, .ButtonActive,              rgba(BORDER))
    set(style, .Header,                    rgba(PRIMARY, 0.20))
    set(style, .HeaderHovered,             rgba(SURFACE_HIGHEST))
    set(style, .HeaderActive,              rgba(PRIMARY, 0.30))
    set(style, .Separator,                 rgba(BORDER))
    set(style, .SeparatorHovered,          rgba(PRIMARY, 0.60))
    set(style, .SeparatorActive,           rgba(PRIMARY))
    set(style, .ResizeGrip,                rgba(0, 0))
    set(style, .ResizeGripHovered,         rgba(PRIMARY, 0.40))
    set(style, .ResizeGripActive,          rgba(PRIMARY, 0.80))
    set(style, .InputTextCursor,           rgba(PRIMARY_SOFT))
    set(style, .TabHovered,                rgba(SURFACE_HIGHEST))
    set(style, .Tab,                       rgba(SURFACE_LOW))
    set(style, .TabSelected,               rgba(SURFACE))
    set(style, .TabSelectedOverline,       rgba(PRIMARY))
    set(style, .TabDimmed,                 rgba(SURFACE_LOW))
    set(style, .TabDimmedSelected,         rgba(SURFACE))
    set(style, .TabDimmedSelectedOverline, rgba(BORDER))
    set(style, .DockingPreview,            rgba(PRIMARY, 0.35))
    set(style, .DockingEmptyBg,            rgba(BG))
    set(style, .PlotLines,                 rgba(PRIMARY))
    set(style, .PlotLinesHovered,          rgba(PRIMARY_SOFT))
    set(style, .PlotHistogram,             rgba(PRIMARY))
    set(style, .PlotHistogramHovered,      rgba(VIOLET))
    set(style, .TableHeaderBg,             rgba(SURFACE_HIGH))
    set(style, .TableBorderStrong,         rgba(BORDER))
    set(style, .TableBorderLight,          rgba(BORDER, 0.5))
    set(style, .TableRowBg,                rgba(0, 0))
    set(style, .TableRowBgAlt,             rgba(0xffffff, 0.02))
    set(style, .TextLink,                  rgba(PRIMARY_SOFT))
    set(style, .TextSelectedBg,            rgba(PRIMARY, 0.35))
    set(style, .TreeLines,                 rgba(BORDER))
    set(style, .DragDropTarget,            rgba(PRIMARY))
    set(style, .DragDropTargetBg,          rgba(PRIMARY, 0.15))
    set(style, .UnsavedMarker,             rgba(TEXT))
    set(style, .NavCursor,                 rgba(PRIMARY))
    set(style, .NavWindowingHighlight,     rgba(0xffffff, 0.70))
    set(style, .NavWindowingDimBg,         rgba(0, 0.50))
    set(style, .ModalWindowDimBg,          rgba(SURFACE_LOWEST, 0.70))
}

// Embedded in the binary, so the atlas must never free them (see font_config).
@(private="file") inter_regular   := #load("../../assets/fonts/Inter-Regular.ttf")
@(private="file") inter_medium    := #load("../../assets/fonts/Inter-Medium.ttf")
@(private="file") inter_semibold  := #load("../../assets/fonts/Inter-SemiBold.ttf")
@(private="file") jetbrains_mono  := #load("../../assets/fonts/JetBrainsMono-Medium.ttf")
@(private="file") icon_font       := #load("../../assets/fonts/fa-solid-900.otf") // Font Awesome Free Solid (CFF outlines)

// Font Awesome lives in the Private Use Area; restricting the merge keeps its
// ASCII-mapped glyphs from overriding Inter. ImGui holds this pointer for the atlas lifetime.
@(private="file") icon_ranges := [?]im.Wchar{0xe000, 0xf8ff, 0}

// Loads the embedded fonts into the atlas. Call once, after CreateContext.
load_fonts :: proc() {
    atlas := im.GetIO().Fonts
    fonts.regular  = add_font(atlas, "Inter Regular",  inter_regular,  FONT_SIZE_BODY, with_icons = true)
    fonts.medium   = add_font(atlas, "Inter Medium",   inter_medium,   FONT_SIZE_BODY, with_icons = true)
    fonts.semibold = add_font(atlas, "Inter SemiBold", inter_semibold, FONT_SIZE_BODY, with_icons = true)
    fonts.mono     = add_font(atlas, "JetBrains Mono", jetbrains_mono, FONT_SIZE_TELEMETRY)
    im.GetIO().FontDefault = fonts.regular
}

@(private="file")
add_font :: proc(atlas: ^im.FontAtlas, name: string, data: []u8, size: f32, with_icons := false) -> ^im.Font {
    cfg := font_config()
    font := im.FontAtlas_AddFontFromMemoryTTF(atlas, raw_data(data), i32(len(data)), size, cast(^im.FontConfig)&cfg)
    if font == nil {
        log.errorf("failed to load font %v", name)
        return nil
    }

    if with_icons {
        icon_cfg := font_config()
        icon_cfg.MergeMode = true
        icon_cfg.GlyphMinAdvanceX = size // fixed-width icons so list rows line up
        icon_cfg.GlyphRanges = &icon_ranges[0]
        if im.FontAtlas_AddFontFromMemoryTTF(atlas, raw_data(icon_font), i32(len(icon_font)), size * 0.9, cast(^im.FontConfig)&icon_cfg) == nil {
            log.errorf("failed to merge icon font into %v", name)
        }
    }
    return font
}

// The binding's im.FontConfig declares Name as [40]cstring instead of char[40], shifting
// every later field by 280 bytes (ImGui then reads zero sizes and draws no text).
// This mirrors the real C layout of ImFontConfig from imgui.h 1.92.
@(private="file")
Font_Config :: struct {
    Name:                 [40]u8,
    FontData:             rawptr,
    FontDataSize:         i32,
    FontDataOwnedByAtlas: bool,
    MergeMode:            bool,
    PixelSnapH:           bool,
    OversampleH:          i8,
    OversampleV:          i8,
    EllipsisChar:         im.Wchar,
    SizePixels:           f32,
    GlyphRanges:          ^im.Wchar,
    GlyphExcludeRanges:   ^im.Wchar,
    GlyphOffset:          im.Vec2,
    GlyphMinAdvanceX:     f32,
    GlyphMaxAdvanceX:     f32,
    GlyphExtraAdvanceX:   f32,
    FontNo:               u32,
    FontLoaderFlags:      u32,
    RasterizerMultiply:   f32,
    RasterizerDensity:    f32,
    ExtraSizeScale:       f32,
    Flags:                i32,
    DstFont:              rawptr,
    FontLoader:           rawptr,
    FontLoaderData:       rawptr,
    PixelSnapV:           bool, // obsolete, only present without IMGUI_DISABLE_OBSOLETE_FUNCTIONS
}
#assert(size_of(Font_Config) == 160)

// Mirrors ImFontConfig's C++ constructor, which the bindings don't expose.
// Font data is #load-ed into the binary, so the atlas must not own (free) it.
@(private="file")
font_config :: proc() -> Font_Config {
    return {
        FontDataOwnedByAtlas = false,
        ExtraSizeScale       = 1,
        GlyphMaxAdvanceX     = max(f32),
        RasterizerMultiply   = 1,
        RasterizerDensity    = 1,
        PixelSnapV           = true,
    }
}
