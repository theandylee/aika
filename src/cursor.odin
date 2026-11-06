package main

import "core:sys/windows"

// Win32's IDC_HAND is a pointing finger, not a closed grabbing hand.
// A monochrome cursor uses AND=1/XOR=0 for transparency, 0/0 for black,
// and 0/1 for white. Keep this small outlined fist readable on either theme.
ui_grab_cursor :: proc() -> windows.HCURSOR {
	if ui.grab_cursor == nil {
		pixels := [?]string{
			".....##.##.......",
			"....#ww#ww###....",
			"....#ww#ww#ww##..",
			"....#ww#ww#ww#w#.",
			"....#wwwwwwww#w#.",
			"..###wwwwwwwwww#.",
			".#ww#wwwwwwwwww#.",
			".#www#wwwwwwwww#.",
			".#wwwwwwwwwwwww#.",
			"..#wwwwwwwwwwww#.",
			"...#wwwwwwwwww#..",
			"....#wwwwwwwww#..",
			".....#wwwwwww#...",
			".....#wwwwwww#...",
			".....#########...",
		}
		and_mask, xor_mask: [128]u8
		for &b in and_mask { b = 0xFF }
		for row, y in pixels {
			for x in 0..<len(row) {
				if row[x] == '.' { continue }
				px, py := x + 7, y + 8
				index := py * 4 + px / 8
				bit := u8(0x80) >> u32(px % 8)
				and_mask[index] &= ~bit
				if row[x] == 'w' { xor_mask[index] |= bit }
			}
		}
		ui.grab_cursor = windows.CreateCursor(nil, 15, 15, 32, 32, &and_mask[0], &xor_mask[0])
	}
	if ui.grab_cursor != nil { return ui.grab_cursor }
	return windows.LoadCursorW(nil, transmute(cstring16)(u64(32646))) // IDC_SIZEALL fallback
}
