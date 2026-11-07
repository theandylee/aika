package main

import "core:math/rand"
import "core:sys/windows"
import "core:testing"

// Coalescing must be invisible: random dense/sparse, overlapping, adjacent and
// covering bar sequences render pixel-identically to one FillRect per bar.
@(test)
bar_run_matches_direct_fills :: proc(t: ^testing.T) {
	W, H :: 400, 8
	screen := windows.GetDC(nil)
	testing.expect(t, screen != nil)
	if screen == nil { return }
	defer windows.ReleaseDC(nil, screen)
	dc := windows.CreateCompatibleDC(screen)
	testing.expect(t, dc != nil)
	if dc == nil { return }
	defer windows.DeleteDC(dc)
	bmp := windows.CreateCompatibleBitmap(screen, W, H)
	testing.expect(t, bmp != nil)
	if bmp == nil { return }
	defer windows.DeleteObject(windows.HGDIOBJ(bmp))
	old := windows.SelectObject(dc, windows.HGDIOBJ(bmp))
	defer windows.SelectObject(dc, old)

	Bar :: struct { x, w: i32, color: windows.COLORREF }
	palette := [3]windows.COLORREF{0x000000FF, 0x0000FF00, 0x00FF0000}
	capture :: proc(dc: windows.HDC, out: ^[H][W]windows.COLORREF) {
		for y in 0 ..< H { for x in 0 ..< W { out[y][x] = GetPixel(dc, i32(x), i32(y)) } }
	}
	state := rand.create(20261107)
	context.random_generator = rand.default_random_generator(&state)
	fewer := false
	for trial in 0 ..< 200 {
		bars: [dynamic]Bar
		defer delete(bars)
		x := i32(rand.int31_max(4))
		for len(bars) < 120 && x < W {
			w := 1 + i32(rand.int31_max(3 if trial % 2 == 0 else 12))
			append(&bars, Bar{x, w, palette[rand.int31_max(len(palette))]})
			// Same pixel, overlap, adjacent or gap: the cases the tracker produces.
			x += i32(rand.int31_max(4)) - (1 if rand.int31_max(4) == 0 else 0)
			x = max(0, x)
		}
		direct, coalesced: [H][W]windows.COLORREF
		fill_rect(dc, 0, 0, W, H, 0x00FFFFFF)
		for b in bars { fill_rect(dc, b.x, 2, b.w, 4, b.color) }
		capture(dc, &direct)
		fill_rect(dc, 0, 0, W, H, 0x00FFFFFF)
		run := Bar_Run{dc = dc, y = 2, h = 4}
		for b in bars { bar_run_add(&run, b.x, b.w, b.color) }
		bar_run_flush(&run)
		bar_run_flush(&run) // idempotent
		capture(dc, &coalesced)
		testing.expectf(t, direct == coalesced, "trial %d differs", trial)
		testing.expect(t, run.fills <= len(bars))
		fewer ||= run.fills < len(bars)
	}
	testing.expect(t, fewer, "dense sequences should need fewer fills")
}
