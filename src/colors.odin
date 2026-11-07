package main

import "core:sys/windows"

// Two color representations meet in this program; keep them apart by type.
//
//   Colorref  0x00BBGGRR, what GDI draws with (windows.COLORREF). Every C_* palette
//             value and every fill/text parameter is one.
//   Argb      0xAARRGGBB, what the database stores in "Group".Color and what rows
//             carry (Activity.color, ListRow.color, ...). 0 means "unset": the
//             renderer then derives a color from the group id (activity_colorref).
//
// Argb is a distinct type, so a stored value cannot be passed to GDI by accident;
// argb_to_colorref is the only crossing.

Colorref :: windows.COLORREF
Argb     :: distinct u32

ARGB_UNSET :: Argb(0)

// Fixed (theme-independent) colors that used to be inline literals.
C_LIVE_FRAME  :: 0x00FFFFFF // outline of the live (still growing) bar; rgb(255,255,255)
C_TRACKER_OFF :: 0x00D0CCC8 // status-bar dot while tracking is paused; rgb(200,204,208)

// Readable text on arbitrary tag fills: dark text from this luma up (weights 299/587/114
// are integer ITU-R BT.601 luma, so the value is 1000 * 255 * 0.549).
BAR_LUMA_WEIGHT_R :: 299
BAR_LUMA_WEIGHT_G :: 587
BAR_LUMA_WEIGHT_B :: 114
BAR_LUMA_DARK_TEXT_MIN :: 140000

colorref_r :: proc(c: Colorref) -> u32 { return u32(c) & 0xFF }
colorref_g :: proc(c: Colorref) -> u32 { return (u32(c) >> 8) & 0xFF }
colorref_b :: proc(c: Colorref) -> u32 { return (u32(c) >> 16) & 0xFF }

argb_is_unset :: proc(c: Argb) -> bool { return c == ARGB_UNSET }

// Stored 0 stays 0 (unset); the alpha byte is otherwise ignored.
argb_to_colorref :: proc(c: Argb) -> Colorref {
	if argb_is_unset(c) { return 0 }
	return rgb(i32((u32(c) >> 16) & 0xFF), i32((u32(c) >> 8) & 0xFF), i32(u32(c) & 0xFF))
}

// Tag fills retain their stored colors; choose readable text independently.
bar_text_color :: proc(color: Colorref) -> Colorref {
	luma := colorref_r(color) * BAR_LUMA_WEIGHT_R + colorref_g(color) * BAR_LUMA_WEIGHT_G +
		colorref_b(color) * BAR_LUMA_WEIGHT_B
	return TEXT_DARK if luma >= BAR_LUMA_DARK_TEXT_MIN else TEXT_LIGHT
}
