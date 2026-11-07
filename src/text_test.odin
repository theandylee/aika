package main

import "core:log"
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
	long := "Windows Terminal - src/file_12.odin - aika"
	long_units := windows.utf8_to_utf16(long, context.temp_allocator)
	cases := [?]struct {text: string, units: []u16}{
		{"", nil},
		{"ASCII", []u16{'A', 'S', 'C', 'I', 'I'}},
		{"café", []u16{'c', 'a', 'f', 0x00E9}},
		{"日本語", []u16{0x65E5, 0x672C, 0x8A9E}},
		{"A😀Z", []u16{'A', 0xD83D, 0xDE00, 'Z'}},
		{long, long_units},
	}
	// The app's ClearType fonts as well as the stock font. Widths cover text
	// that fits (ExtTextOutW fast path), an exact fit, and overflow (DrawTextW
	// ellipsis fallback). References are built from the explicit UTF-16 units.
	Pixels :: [40][240]windows.COLORREF
	capture :: proc(dc: windows.HDC, out: ^Pixels) {
		for y in 0 ..< 40 {
			for x in 0 ..< 240 { out[y][x] = GetPixel(dc, i32(x), i32(y)) }
		}
	}
	reference :: proc(dc: windows.HDC, f: windows.HFONT, units: []u16, max_w: i32, ellipsis: bool, out: ^Pixels) {
		fill_rect(dc, 0, 0, 240, 40, 0x00FFFFFF)
		if len(units) > 0 && max_w > 0 {
			old := windows.SelectObject(dc, windows.HGDIOBJ(f))
			r := windows.RECT{2, 2, 2 + max_w, 36}
			if ellipsis {
				windows.DrawTextW(dc, windows.LPCWSTR(raw_data(units)), i32(len(units)), &r,
					windows.DrawTextFormat.DT_SINGLELINE | windows.DrawTextFormat.DT_NOPREFIX |
					windows.DrawTextFormat.DT_END_ELLIPSIS)
			} else {
				ExtTextOutW(dc, 2, 2, ETO_CLIPPED, &r, windows.LPCWSTR(raw_data(units)), u32(len(units)), nil)
			}
			windows.SelectObject(dc, old)
		}
		capture(dc, out)
	}
	app_fonts := [3]windows.HFONT{ui_make_font(12, 400), ui_make_font(12, windows.FW_BOLD), ui_make_font(11, 400)}
	defer for f in app_fonts { windows.DeleteObject(windows.HGDIOBJ(f)) }
	fonts := [4]windows.HFONT{font, app_fonts[0], app_fonts[1], app_fonts[2]}
	for f in fonts {
		testing.expect(t, f != nil)
		for c in cases {
			actual := measure_text_dc(dc, c.text, f)
			expected: windows.SIZE
			old := windows.SelectObject(dc, windows.HGDIOBJ(f))
			if len(c.units) > 0 {
				testing.expect(t, bool(windows.GetTextExtentPoint32W(dc,
					windows.LPCWSTR(raw_data(c.units)), i32(len(c.units)), &expected)))
			}
			windows.SelectObject(dc, old)
			testing.expect(t, actual == expected, c.text)
			has_space := false
			for u in c.units { has_space ||= u == ' ' }
			for max_w in ([4]i32{230, expected.cx, max(1, expected.cx - 1), 40}) {
				// Compare actual rendering against a reference on the same DC.
				// This catches wrong lengths and fast-path placement/clipping.
				actual_px, expected_px, drawtext_px: Pixels
				fill_rect(dc, 0, 0, 240, 40, 0x00FFFFFF)
				draw_string(dc, c.text, 2, 4, f, 0, max_w)
				capture(dc, &actual_px)
				fits := expected.cx <= max_w
				reference(dc, f, c.units, max_w, !fits, &expected_px)
				testing.expectf(t, actual_px == expected_px, "%s font=%v max_w=%d cx=%d", c.text, f, max_w, expected.cx)
				// The space-free strings here have no kerned pairs, so the fast path
				// is also pixel-identical to DrawTextW (which kerns).
				if fits && !has_space {
					reference(dc, f, c.units, max_w, true, &drawtext_px)
					testing.expectf(t, actual_px == drawtext_px, "DrawTextW parity: %s max_w=%d", c.text, max_w)
				}
			}
		}
	}
}

foreign import text_test_gdi "system:gdi32.lib"
@(default_calling_convention = "system")
foreign text_test_gdi {
	CreateDIBSection :: proc(dc: windows.HDC, info: ^windows.BITMAPINFO, usage: u32, bits: ^rawptr, section: windows.HANDLE, offset: u32) -> windows.HBITMAP ---
	GdiFlush :: proc() -> windows.BOOL ---
}

// Overflowing text is no longer drawn by DrawTextW. Sweep every width from 1 px
// to past the natural extent and require the ellipsized output to be
// pixel-identical to DrawTextW(DT_END_ELLIPSIS), plus the same kept prefix as
// DT_MODIFYSTRING reports. Text that fits keeps the ExtTextOutW contract.
@(test)
gdi_ellipsis_matches_drawtext :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	W, H :: 320, 40
	screen := windows.GetDC(nil)
	testing.expect(t, screen != nil)
	if screen == nil { return }
	defer windows.ReleaseDC(nil, screen)
	dc := windows.CreateCompatibleDC(screen)
	testing.expect(t, dc != nil)
	if dc == nil { return }
	defer windows.DeleteDC(dc)
	info := windows.BITMAPINFO{bmiHeader = {biSize = size_of(windows.BITMAPINFOHEADER), biWidth = W, biHeight = -H,
		biPlanes = 1, biBitCount = 32}}
	bits: rawptr
	bmp := CreateDIBSection(dc, &info, 0, &bits, nil, 0)
	testing.expect(t, bmp != nil && bits != nil)
	if bmp == nil || bits == nil { return }
	defer windows.DeleteObject(windows.HGDIOBJ(bmp))
	old_bmp := windows.SelectObject(dc, windows.HGDIOBJ(bmp))
	defer windows.SelectObject(dc, old_bmp)
	windows.SetBkMode(dc, windows.BKMODE.TRANSPARENT)
	pixels := ([^]u32)(bits)[:W * H]
	Px :: [W * H]u32
	snap :: proc(pixels: []u32, out: ^Px) { GdiFlush(); copy(out[:], pixels) }

	DOTS :: "..."
	// Fast: must take the GetCharacterPlacementW layout with the Latin UI fonts.
	// Font: takes it only where the font has its own glyphs (no font linking);
	// each such case must take it with at least one font.
	// Fallback: always DrawTextW (surrogates, combining marks, RTL, joiners).
	// Pixel parity with DrawTextW is required for all three.
	Path :: enum { Fast, Font, Fallback }
	cases := [?]struct {text: string, path: Path}{
		{"Work/Project 1/Task 3", .Fast}, // kerned pairs ("Wo", "Ta"), spaces
		{"Wo Te To Ta AV", .Fast},
		{"Windows Terminal - src/file_12.odin - aika", .Fast},
		{"src/file_12.odin", .Fast},
		{"iiiiiiiiiiiiiiii", .Fast},
		{"W", .Fast}, // single unit: nothing to cut
		{"café ünïcödé", .Fast}, // precomposed
		{"Привет, мир", .Font},
		{"Γειά σου κόσμε", .Font},
		{"日本語のテキストです", .Font},
		{"안녕하세요 세계", .Font},
		{"A😀😀😀😀Z", .Fallback}, // surrogate pairs at every cut point
		{"😀😀😀", .Fallback}, // the first kept character is a pair
		{"😀", .Fallback},
		{"Work 😀 Task", .Fallback},
		{"café ééé", .Fallback}, // combining marks
		{"مرحبا بالعالم", .Fallback}, // RTL
		{"👍🏽 thumbs", .Fallback}, // skin-tone modifier sequence
		{"a‍b‍c ZWJ", .Fallback},
		{"\xed\xa0\x80lone", .Fallback}, // invalid UTF-8 (lone surrogate bytes)
	}
	// The app fonts (normal, bold, small, title, icons), the stock font, and
	// CJK UI fonts so that ideographs and Hangul also take the layout path
	// (Yu Gothic UI also has an "fi" ligature, which must fall back).
	app_fonts := [7]windows.HFONT{ui_make_font(12, 400), ui_make_font(12, windows.FW_BOLD), ui_make_font(11, 400),
		ui_make_font(20, windows.FW_BOLD), ui_make_font(16, 400, "Segoe UI Symbol"), ui_make_font(12, 400, "Yu Gothic UI"),
		ui_make_font(12, 400, "Malgun Gothic")}
	defer for f in app_fonts { windows.DeleteObject(windows.HGDIOBJ(f)) }
	fonts := [8]windows.HFONT{windows.HFONT(windows.GetStockObject(windows.DEFAULT_GUI_FONT)),
		app_fonts[0], app_fonts[1], app_fonts[2], app_fonts[3], app_fonts[4], app_fonts[5], app_fonts[6]}
	flags := windows.DrawTextFormat.DT_SINGLELINE | windows.DrawTextFormat.DT_NOPREFIX | windows.DrawTextFormat.DT_END_ELLIPSIS
	overflow, fast_fit, layout_used := 0, 0, 0
	font_path_used: [len(cases)]int
	actual, expected: Px
	for f, fi in fonts {
		testing.expect(t, f != nil)
		dots_w := text_pixel_width_dc(dc, DOTS, f)
		latin_font := fi < 5 // stock font and the Segoe UI text fonts
		for c, ci in cases {
			units := windows.utf8_to_utf16(c.text, context.temp_allocator)
			cx := text_pixel_width_dc(dc, c.text, f)
			old := windows.SelectObject(dc, windows.HGDIOBJ(f))
			_, _, simple := end_ellipsis_layout(dc, units, 1)
			windows.SelectObject(dc, old)
			if c.path == .Fast && latin_font { testing.expectf(t, simple, "must take the layout path: %q font=%v", c.text, f) }
			if c.path == .Fallback { testing.expectf(t, !simple, "must fall back to DrawTextW: %q", c.text) }
			if simple { font_path_used[ci] += 1 }
			// Every width up to past the natural extent, so tiny widths (1, 5),
			// "..." width +-1, each cut point and the exact fit are all covered.
			for max_w in i32(1) ..= min(cx + 3, W - 4) {
				fill_rect(dc, 0, 0, W, H, 0x00FFFFFF)
				draw_string(dc, c.text, 2, 4, f, 0, max_w)
				snap(pixels, &actual)
				fill_rect(dc, 0, 0, W, H, 0x00FFFFFF)
				old = windows.SelectObject(dc, windows.HGDIOBJ(f))
				r := windows.RECT{2, 2, 2 + max_w, 36}
				if cx <= max_w {
					ExtTextOutW(dc, 2, 2, ETO_CLIPPED, &r, windows.LPCWSTR(raw_data(units)), u32(len(units)), nil)
				} else {
					windows.DrawTextW(dc, windows.LPCWSTR(raw_data(units)), i32(len(units)), &r, flags)
				}
				windows.SelectObject(dc, old)
				snap(pixels, &expected)
				if cx <= max_w {
					fast_fit += 1
					testing.expectf(t, actual == expected, "fit %q font=%v max_w=%d", c.text, f, max_w)
					continue
				}
				overflow += 1
				testing.expectf(t, actual == expected, "DrawTextW ellipsis parity %q font=%v max_w=%d cx=%d dots=%d",
					c.text, f, max_w, cx, dots_w)
				// Same kept prefix as DrawTextW reports with DT_MODIFYSTRING.
				old = windows.SelectObject(dc, windows.HGDIOBJ(f))
				out, dx, ok := end_ellipsis_layout(dc, units, max_w)
				modified := make([]u16, len(units) + 5, context.temp_allocator)
				copy(modified, units)
				mr := windows.RECT{0, 0, max_w, 34}
				windows.DrawTextW(dc, windows.LPCWSTR(raw_data(modified)), i32(len(units)), &mr, flags | windows.DrawTextFormat.DT_MODIFYSTRING)
				windows.SelectObject(dc, old)
				testing.expectf(t, ok == simple, "layout availability changed with width: %q font=%v max_w=%d", c.text, f, max_w)
				if !ok { continue }
				layout_used += 1
				testing.expect(t, len(dx) == len(out))
				m := 0
				for m < len(modified) && modified[m] != 0 { m += 1 }
				same := m == len(out)
				for u, i in out { same = same && i < m && modified[i] == u }
				if !same {
					a, _ := windows.utf16_to_utf8(out, context.temp_allocator)
					b, _ := windows.utf16_to_utf8(modified[:m], context.temp_allocator)
					testing.expectf(t, false, "kept prefix %q vs DrawTextW %q (max_w=%d)", a, b, max_w)
				}
				// The layout path never sees surrogates, so it cannot split a pair;
				// surrogate cases are covered by the DrawTextW pixel parity above.
				for u in out { testing.expect(t, u < 0xD800 || u > 0xDFFF) }
			}
		}
	}
	for c, ci in cases {
		if c.path == .Font { testing.expectf(t, font_path_used[ci] > 0, "no font took the layout path: %q", c.text) }
	}
	testing.expectf(t, overflow > 2000 && layout_used > 1500 && fast_fit > 50,
		"coverage overflow=%d layout=%d fit=%d", overflow, layout_used, fast_fit)
	log.infof("ellipsis sweep: overflow=%d (layout path %d, DrawTextW fallback %d) fit=%d",
		overflow, layout_used, overflow - layout_used, fast_fit)
}

text_pixel_width_dc :: proc(dc: windows.HDC, s: string, f: windows.HFONT) -> i32 {
	return measure_text_dc(dc, s, f).cx
}
