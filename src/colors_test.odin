package main

import "core:testing"

// The formula bar_text_color used before it moved to named constants/accessors.
previous_bar_text_color :: proc(color: u32) -> u32 {
	r, g, b := color & 255, (color >> 8) & 255, (color >> 16) & 255
	return 0x0028221E if r * 299 + g * 587 + b * 114 >= 140000 else 0x00FFFFFF
}

@(test)
color_accessors_and_conversion :: proc(t: ^testing.T) {
	c := rgb(1, 2, 3) // 0x00030201: BBGGRR
	testing.expect(t, c == 0x00030201 && colorref_r(c) == 1 && colorref_g(c) == 2 && colorref_b(c) == 3)
	// Argb is 0xAARRGGBB; the alpha byte is dropped, red/blue swap into COLORREF order.
	testing.expect(t, argb_to_colorref(Argb(0xFF112233)) == 0x00332211)
	testing.expect(t, argb_to_colorref(Argb(0x00112233)) == 0x00332211)
	// Stored 0 means unset and stays 0; it is not "opaque black".
	testing.expect(t, argb_is_unset(ARGB_UNSET) && argb_to_colorref(ARGB_UNSET) == 0)
	testing.expect(t, !argb_is_unset(Argb(0xFF000000)) && argb_to_colorref(Argb(0xFF000000)) == 0)
	testing.expect(t, C_LIVE_FRAME == 0x00FFFFFF && C_TRACKER_OFF == rgb(200, 204, 208))
}

@(test)
bar_text_color_matches_previous_formula :: proc(t: ^testing.T) {
	mismatches := 0
	for r in 0 ..< 256 {
		for g := 0; g < 256; g += 5 {
			for b := 0; b < 256; b += 5 {
				c := rgb(i32(r), i32(g), i32(b))
				if u32(bar_text_color(c)) != previous_bar_text_color(u32(c)) { mismatches += 1 }
			}
		}
	}
	testing.expect_value(t, mismatches, 0)
	testing.expect(t, bar_text_color(rgb(255, 224, 138)) == TEXT_DARK) // light fill
	testing.expect(t, bar_text_color(rgb(32, 48, 64)) == TEXT_LIGHT)   // dark fill
	// Threshold edge: luma exactly BAR_LUMA_DARK_TEXT_MIN is dark text.
	testing.expect(t, bar_text_color(rgb(140, 140, 140)) == TEXT_DARK) // 140*1000 = 140000
	testing.expect(t, bar_text_color(rgb(139, 140, 140)) == TEXT_LIGHT) // luma 139701, just below
}
