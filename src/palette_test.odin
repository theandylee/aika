package main

import "core:testing"
import "core:sys/windows"

// Values copied from the positional light/dim arrays and C_* literals that the
// Palette struct replaced (git HEAD 36aa199), in their original order:
// bg, panel, border, border_soft, lane_bg, lane_grid, lane_txt, txt, dim,
// tab_bg, tab_active, btn_face, btn_border, btn_hover, head_bg, row_alt, tip_bg, tip_border.
PREVIOUS_LIGHT :: [18]u32{0xFAF7F5, 0xFFFFFF, 0xC0AF9C, 0xE2D8CD,
	0xF4ECE2, 0xE4D8CB, 0x746658, 0x28221E, 0x908478,
	0xF5EFE8, 0xFFFFFF, 0xFFFFFF, 0xEAB47E, 0xFCE0E4,
	0xF8F4EF, 0xFCF9F6, 0xE1FFFF, 0x8C8278}
PREVIOUS_DARK :: [18]u32{0x201B18, 0x282320, 0x6B594B, 0x4C4036,
	0x302820, 0x40362D, 0xB8A99A, 0xF0E8E0, 0xB8A99A,
	0x201B18, 0x282320, 0x382F28, 0x907050, 0x504030,
	0x342C25, 0x2E2722, 0x382F28, 0x907050}

palette_old_order :: proc(p: Palette) -> [18]u32 {
	return {u32(p.bg), u32(p.panel), u32(p.border), u32(p.border_soft),
		u32(p.lane_bg), u32(p.lane_grid), u32(p.lane_text), u32(p.text), u32(p.text_dim),
		u32(p.tab_bg), u32(p.tab_active), u32(p.button_face), u32(p.button_border), u32(p.button_hover),
		u32(p.header_bg), u32(p.row_alt), u32(p.tooltip_bg), u32(p.tooltip_border)}
}

@(test)
palette_matches_previous_values :: proc(t: ^testing.T) {
	testing.expect(t, palette_old_order(PALETTE_LIGHT) == PREVIOUS_LIGHT)
	testing.expect(t, palette_old_order(PALETTE_DARK) == PREVIOUS_DARK)
	// Previously inline in zoom.odin: rgb(255,221,168) light, rgb(90,65,32) dark.
	testing.expect(t, PALETTE_LIGHT.zoom_selection == rgb(255, 221, 168))
	testing.expect(t, PALETTE_DARK.zoom_selection == rgb(90, 65, 32))
	// Semantic aliases keep the value of the shared hover fill they replaced.
	for p in ([2]Palette{PALETTE_LIGHT, PALETTE_DARK}) {
		testing.expect(t, p.splitter_hot == p.button_hover && p.tag_preview == p.button_hover &&
			p.section_head == p.button_hover)
	}
	testing.expect(t, windows.COLORREF(TEXT_DARK) == PALETTE_LIGHT.text)
}

// The C_* mirror of the active palette is restored by the audit #25 harness,
// so this is an independent @(test).
@(test)
palette_apply_behavior :: proc(t: ^testing.T) {
	g := ui_test_begin()
	defer ui_test_end(&g)
	for p in ([2]Palette{PALETTE_DARK, PALETTE_LIGHT}) {
		palette_apply(p)
		testing.expect(t, palette_is_applied())
		testing.expect(t, palette_active == p)
	}
	palette_apply(PALETTE_DARK)
	testing.expect(t, C_TXT == windows.COLORREF(0xF0E8E0) && C_BG == windows.COLORREF(0x201B18))
	C_TXT = 0 // a stale variable must be detected
	testing.expect(t, !palette_is_applied())
}
