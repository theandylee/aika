package main

import "core:mem"
import "core:sys/windows"
import "core:testing"

@(test)
filter_conversion_owns_only_its_result :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	text := [?]u16{'H', 0x00C9, 'L', 'L', 'O', ' ', 0x4E2D, 0xD83D, 0xDE00}
	for _ in 0 ..< 1000 {
		filter := filter_from_utf16(text[:])
		testing.expect(t, filter == "héllo 中😀")
		delete(filter)
		testing.expect(t, len(track.allocation_map) == 0, "Conversion scratch must not leak on filter changes")
	}
	empty := filter_from_utf16(nil)
	testing.expect(t, empty == "")
	delete(empty)
	testing.expect(t, len(track.allocation_map) == 0)
}

@(test)
gdi_text_uses_utf16_code_units :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	screen := windows.GetDC(nil)
	testing.expect(t, screen != nil)
	if screen == nil { return }
	defer windows.ReleaseDC(nil, screen)
	dc := windows.CreateCompatibleDC(screen)
	testing.expect(t, dc != nil)
	if dc == nil { return }
	defer windows.DeleteDC(dc)
	bmp := windows.CreateCompatibleBitmap(screen, 240, 40)
	testing.expect(t, bmp != nil)
	if bmp == nil { return }
	defer windows.DeleteObject(windows.HGDIOBJ(bmp))
	old_bmp := windows.SelectObject(dc, windows.HGDIOBJ(bmp))
	defer windows.SelectObject(dc, old_bmp)
	font := windows.HFONT(windows.GetStockObject(windows.DEFAULT_GUI_FONT))
	old_font := windows.SelectObject(dc, windows.HGDIOBJ(font))
	defer windows.SelectObject(dc, old_font)
	windows.SetBkMode(dc, windows.BKMODE.TRANSPARENT)
	// Explicit UTF-16 reference lengths include a surrogate pair, not a rune
	// count, and deliberately differ from the corresponding UTF-8 byte counts.
	cases := [?]struct {text: string, units: []u16}{
		{"", nil},
		{"ASCII", []u16{'A', 'S', 'C', 'I', 'I'}},
		{"café", []u16{'c', 'a', 'f', 0x00E9}},
		{"日本語", []u16{0x65E5, 0x672C, 0x8A9E}},
		{"A😀Z", []u16{'A', 0xD83D, 0xDE00, 'Z'}},
	}
	for c in cases {
		actual := measure_text_dc(dc, c.text, font)
		expected: windows.SIZE
		if len(c.units) > 0 {
			testing.expect(t, bool(windows.GetTextExtentPoint32W(dc,
				windows.LPCWSTR(raw_data(c.units)), i32(len(c.units)), &expected)))
		}
		testing.expect(t, actual == expected, c.text)
		// Compare actual rendering against a wide-text reference on the same DC.
		// This catches wrong lengths in draw_string independently of measuring.
		fill_rect(dc, 0, 0, 240, 40, 0x00FFFFFF)
		draw_string(dc, c.text, 2, 4, font, 0, 230)
		pixels: [40][240]windows.COLORREF
		for y in 0 ..< 40 {
			for x in 0 ..< 240 { pixels[y][x] = GetPixel(dc, i32(x), i32(y)) }
		}
		fill_rect(dc, 0, 0, 240, 40, 0x00FFFFFF)
		if len(c.units) > 0 {
			r := windows.RECT{2, 2, 232, 36}
			windows.DrawTextW(dc, windows.LPCWSTR(raw_data(c.units)), i32(len(c.units)), &r,
				windows.DrawTextFormat.DT_SINGLELINE | windows.DrawTextFormat.DT_NOPREFIX |
				windows.DrawTextFormat.DT_END_ELLIPSIS)
		}
		matches := true
		for y in 0 ..< 40 {
			for x in 0 ..< 240 {
				if pixels[y][x] != GetPixel(dc, i32(x), i32(y)) { matches = false }
			}
		}
		testing.expect(t, matches, c.text)
	}
}
