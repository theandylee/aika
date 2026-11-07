package main

import "core:strings"
import "core:sys/windows"
import "core:testing"

rect_contains :: proc(outer, inner: windows.RECT) -> bool {
	return rect_empty(inner) ||
		(outer.left <= inner.left && outer.top <= inner.top && outer.right >= inner.right && outer.bottom >= inner.bottom)
}

@(test)
paint_rect_helpers :: proc(t: ^testing.T) {
	g := ui_test_begin()
	defer ui_test_end(&g)
	r := windows.RECT{10, 10, 20, 20}
	ui.paint_rect = {}
	testing.expect(t, paint_needs(r)) // empty = full repaint
	ui.paint_rect = windows.RECT{15, 15, 30, 30}
	testing.expect(t, paint_needs(r))
	testing.expect(t, !paint_needs(windows.RECT{30, 15, 40, 25})) // touching the right edge only
	testing.expect(t, !paint_needs(windows.RECT{0, 0, 10, 10}))
	ui.paint_rect = {}
	u := rect_union(windows.RECT{0, 0, 5, 5}, windows.RECT{10, 2, 12, 20})
	testing.expect(t, u == windows.RECT{0, 0, 12, 20})
	testing.expect(t, rect_union({}, r) == r && rect_union(r, {}) == r)
}

// The dirty rect for a hover move must always cover what the last frame drew
// (so it is erased) and everything the next frame can draw (so it is shown),
// for every hint shape: time-only, block rows, a title long enough to hit the
// width cap, and flipped placements near the right and bottom edges.
@(test)
hover_dirty_rect_covers_hint :: proc(t: ^testing.T) {
	g := ui_test_begin()
	defer ui_test_end(&g)
	defer free_all(context.temp_allocator)
	ui.zoom_start, ui.zoom_end = 0, 1

	screen := windows.GetDC(nil)
	testing.expect(t, screen != nil)
	if screen == nil { return }
	defer windows.ReleaseDC(nil, screen)
	dc := windows.CreateCompatibleDC(screen)
	testing.expect(t, dc != nil)
	if dc == nil { return }
	defer windows.DeleteDC(dc)
	bmp := windows.CreateCompatibleBitmap(screen, 1320, 860)
	testing.expect(t, bmp != nil)
	if bmp == nil { return }
	defer windows.DeleteObject(windows.HGDIOBJ(bmp))
	old_bmp := windows.SelectObject(dc, windows.HGDIOBJ(bmp))
	defer windows.SelectObject(dc, old_bmp)
	ui.font_normal = ui_make_font(12, 400)
	ui.font_small = ui_make_font(11, 400)
	defer { windows.DeleteObject(windows.HGDIOBJ(ui.font_normal)); windows.DeleteObject(windows.HGDIOBJ(ui.font_small)) }

	date := 20261107
	ds, _ := day_bounds_ms(date)
	HOUR :: i64(3_600_000)
	long_title := strings.repeat("W", 400, context.temp_allocator)
	rows := [?]Activity{
		{id = 1, timeline_id = TIMELINE_APPS, group_id = 10, display_name = "short",
			group_name = "Editor", start_ms = ds + 9 * HOUR, end_ms = ds + 10 * HOUR, start_date = date},
		{id = 2, timeline_id = TIMELINE_APPS, group_id = 11, display_name = long_title,
			group_name = "Browser", start_ms = ds + 10 * HOUR, end_ms = ds + 23 * HOUR + HOUR / 2, start_date = date},
		{id = 3, timeline_id = TIMELINE_COMPUTER, group_id = 1, group_name = "Active",
			start_ms = ds + 9 * HOUR, end_ms = ds + 23 * HOUR, start_date = date},
	}
	app := App{date = date, loaded_date = date, activities = rows[:]}
	snapshot := build_day_snapshot(&app, ds + 12 * HOUR, 0)

	// Paints the hover visuals for the cursor at (x, y), returning their bounds.
	paint :: proc(snapshot: Day_Snapshot, dc: windows.HDC, x, y, w, h: i32) -> windows.RECT {
		ui.mouse, ui.mouse_valid = windows.POINT{x, y}, true
		ui.hover_rect = {}
		draw_cursor_line(dc, w, h)
		draw_tooltip(snapshot, dc, w, h)
		return ui.hover_rect
	}

	for size in ([2][2]i32{{1320, 860}, {1000, 520}}) {
		W, H := size[0], size[1]
		lay := compute_layout(W, H)
		x_at :: proc(lay: Layout, hours: f64) -> i32 { return lay.chart_x + i32(hours / 24 * f64(lay.chart_w)) }
		lane_y :: proc(lay: Layout, lane: Lane) -> i32 { return lane_top(lay, lane) + lay.lane_h / 2 }
		pts: [dynamic][2]i32
		defer delete(pts)
		for lane in Lane {
			for hours in ([?]f64{0.2, 3, 9.5, 11, 18, 23.8}) {
				append(&pts, [2]i32{x_at(lay, hours), lane_y(lay, lane)})
			}
			append(&pts, [2]i32{lay.chart_x + lay.chart_w - 1, lane_y(lay, lane)}) // right edge: hint flips left
			append(&pts, [2]i32{lay.chart_x, lane_y(lay, lane)})
		}
		append(&pts, [2]i32{x_at(lay, 10.5), lane_top(lay, .Apps) + lay.lane_h - 1}) // lowest lane row
		for a in pts {
			for b in pts {
				sig_a := hover_signature(snapshot, a.x, a.y, true, W, H)
				rect_a := paint(snapshot, dc, a.x, a.y, W, H)
				rect_b := paint(snapshot, dc, b.x, b.y, W, H)
				dirty, partial := hover_dirty_rect(sig_a, rect_a, b.x, b.y, W, H)
				testing.expectf(t, partial && rect_contains(dirty, rect_a) && rect_contains(dirty, rect_b),
					"%dx%d a=%v b=%v dirty=%v old=%v new=%v", W, H, a, b, dirty, rect_a, rect_b)
			}
		}
		// The width cap holds even for a very long title (the recorded rect is the
		// hint box plus the cursor-line column, so it may add the follow gap).
		long_hit := paint(snapshot, dc, x_at(lay, 11), lane_y(lay, .Apps), W, H)
		testing.expect(t, long_hit.right - long_hit.left <= dpi_px(TOOLTIP_MAX_W) + dpi_px(TOOLTIP_FOLLOW_GAP) + 1)
	}

	// Fallbacks: a non-lane hover target changing, or a missing previous rect,
	// invalidates everything; leaving the lanes erases just the old visuals.
	W, H := i32(1320), i32(860)
	lay := compute_layout(W, H)
	ax, ay := lay.chart_x + 300, lane_top(lay, .Apps) + lay.lane_h / 2
	sig_lane := hover_signature(snapshot, ax, ay, true, W, H)
	rect_lane := paint(snapshot, dc, ax, ay, W, H)
	testing.expect(t, sig_lane.cursor && !rect_empty(rect_lane))
	today := lay.btn_today
	_, full := hover_dirty_rect(sig_lane, rect_lane, today.left + 2, today.top + 2, W, H)
	testing.expect(t, !full)
	_, full = hover_dirty_rect(sig_lane, {}, ax + 5, ay, W, H) // cursor was painted, rect lost
	testing.expect(t, !full)
	off_x, off_y := lay.chart_x + 40, lay.list_top + 60
	erase, partial := hover_dirty_rect(sig_lane, rect_lane, off_x, off_y, W, H)
	testing.expect(t, partial && erase == rect_lane)
}
