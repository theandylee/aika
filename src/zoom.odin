package main

import "core:sys/windows"

// Fractions of the selected local day keep the view stable across date changes.
// The overview always shows the whole day; lists and totals are never filtered.
ZOOM_H :: 34
ZOOM_MIN_SPAN :: 1.0 / 1440.0

zoom_rects :: proc(lay: Layout) -> (bar, minus, plus, reset: windows.RECT) {
	y := lay.zoom_y + 4
	right := lay.chart_x + lay.chart_w
	reset = windows.RECT{right - 80, y, right, y + 26}
	plus = windows.RECT{reset.left - 30, y, reset.left - 4, y + 26}
	minus = windows.RECT{plus.left - 30, y, plus.left - 4, y + 26}
	bar = windows.RECT{lay.chart_x + 42, y, minus.left - 8, y + 26}
	return
}

zoom_bounds :: proc(day_start, day_end: i64) -> (start, end: i64) {
	span := f64(day_end - day_start)
	return day_start + i64(ui.zoom_start * span), day_start + i64(ui.zoom_end * span)
}

zoom_scale :: proc(factor, anchor: f64) {
	old_span := ui.zoom_end - ui.zoom_start
	span := clamp(old_span * factor, ZOOM_MIN_SPAN, 1.0)
	if span >= 1.0 - 0.000000001 {
		ui.zoom_start, ui.zoom_end = 0, 1
		return
	}
	start := ui.zoom_start + old_span * anchor - span * anchor
	ui.zoom_start = clamp(start, 0.0, 1.0 - span)
	ui.zoom_end = ui.zoom_start + span
}

zoom_pointer_down :: proc(x, y: i32, lay: Layout) -> bool {
	if ui.tab != 0 { return false }
	bar, _, _, _ := zoom_rects(lay)
	if !rect_hit(bar, x, y) { return false }
	ui.zoom_drag_start, ui.zoom_drag_end = ui.zoom_start, ui.zoom_end
	w := f64(bar.right - bar.left)
	left := bar.left + i32(ui.zoom_start * w)
	right := bar.left + i32(ui.zoom_end * w)
	f := clamp(f64(x - bar.left) / w, 0.0, 1.0)
	if abs(x - left) <= 6 && abs(x - left) <= abs(x - right) {
		ui.zoom_drag = .Left
	} else if abs(x - right) <= 6 {
		ui.zoom_drag = .Right
	} else {
		ui.zoom_drag = .Overview
		if x < left || x > right {
			span := ui.zoom_end - ui.zoom_start
			ui.zoom_start = clamp(f - span / 2, 0.0, 1.0 - span)
			ui.zoom_end = ui.zoom_start + span
		}
	}
	// A click outside recenters immediately; anchor that move while retaining
	// the original range for cancellation.
	ui.zoom_drag_anchor = f - (ui.zoom_start - ui.zoom_drag_start)
	windows.SetFocus(ui.hwnd)
	windows.SetCapture(ui.hwnd)
	return true
}

// Grab the ruler or lanes, not the whole-day overview or its controls.
zoom_pan_down :: proc(x, y: i32, lay: Layout) -> bool {
	if ui.tab != 0 || ui.zoom_drag != .None || ui.pane_drag != 0 ||
	   tag_ui.drag != 0 || ui.pressed_hit != HIT_NONE { return false }
	if x < lay.chart_x || x >= lay.chart_x + lay.chart_w ||
	   y < lay.ruler_y || y >= lay.lanes_bottom { return false }
	ui.zoom_drag = .Timeline
	ui.zoom_drag_anchor = f64(x - lay.chart_x) / f64(max(1, lay.chart_w))
	ui.zoom_drag_start, ui.zoom_drag_end = ui.zoom_start, ui.zoom_end
	windows.SetFocus(ui.hwnd)
	return true
}

zoom_pointer_move :: proc(x: i32, lay: Layout) {
	if ui.zoom_drag == .Timeline {
		// Move the content with the pointer, at the current zoom's pixel scale.
		// Leave the pointer unclamped so capture also works outside the window.
		f := f64(x - lay.chart_x) / f64(max(1, lay.chart_w))
		span := ui.zoom_drag_end - ui.zoom_drag_start
		ui.zoom_start = clamp(ui.zoom_drag_start - (f - ui.zoom_drag_anchor) * span, 0.0, 1.0 - span)
		ui.zoom_end = ui.zoom_start + span
		return
	}
	bar, _, _, _ := zoom_rects(lay)
	f := clamp(f64(x - bar.left) / f64(max(1, bar.right - bar.left)), 0.0, 1.0)
	#partial switch ui.zoom_drag {
	case .Left:
		ui.zoom_start = clamp(f, 0.0, ui.zoom_end - ZOOM_MIN_SPAN)
	case .Right:
		ui.zoom_end = clamp(f, ui.zoom_start + ZOOM_MIN_SPAN, 1.0)
	case .Overview:
		span := ui.zoom_drag_end - ui.zoom_drag_start
		ui.zoom_start = clamp(ui.zoom_drag_start + f - ui.zoom_drag_anchor, 0.0, 1.0 - span)
		ui.zoom_end = ui.zoom_start + span
	}
}

// Tick spacing adapts to the visible range, down to one minute.
zoom_tick_step :: proc(start, end: i64, width: i32) -> i64 {
	for minutes in ([10]i64{1, 2, 5, 10, 15, 30, 60, 120, 180, 360}) {
		step := minutes * 60_000
		if f64(step) * f64(width) / f64(max(1, end - start)) >= 55 { return step }
	}
	return 360 * 60_000
}

draw_zoom_bar :: proc(snapshot: Day_Snapshot, dc: windows.HDC, lay: Layout, day_start, day_end: i64) {
	bar, minus, plus, reset := zoom_rects(lay)
	draw_string(dc, "Zoom", lay.chart_x, bar.top + 7, ui.font_normal, C_DIM)
	fill_rect(dc, bar.left, bar.top, bar.right - bar.left, bar.bottom - bar.top, C_PANEL)
	width := bar.right - bar.left
	left := bar.left + i32(ui.zoom_start * f64(width))
	right := bar.left + i32(ui.zoom_end * f64(width))
	// Keep the selection compatible with the theme's timestamp text color.
	selection := rgb(90, 65, 32) if ui.dark else rgb(255, 221, 168)
	fill_rect(dc, left, bar.top + 1, max(1, right - left), 24, selection)
	// A thin activity strip makes the overview useful when zoomed far in.
	run := Bar_Run{dc = dc, y = bar.bottom - 5, h = 4}
	for row in snapshot.rows {
		a := row.activity
		if a.timeline_id != TIMELINE_APPS { continue }
		s, e := row.start_ms, row.end_ms
		if e <= s { continue }
		x1 := x_for_ms(s, day_start, day_end, bar.left, width)
		x2 := x_for_ms(e, day_start, day_end, bar.left, width)
		bar_run_add(&run, x1, max(1, x2 - x1), activity_colorref(a))
	}
	bar_run_flush(&run)
	for tick := day_start; tick <= day_end; tick += 2 * 3600_000 {
		x := x_for_ms(tick, day_start, day_end, bar.left, width)
		line_v(dc, x, bar.top + 2, 3, C_DIM)
		text := fmt_clock_hm(tick)
		if tick >= day_end { text = "24:00" }
		tw := text_pixel_width(text, ui.font_small)
		draw_string(dc, text, clamp(x - tw / 2, bar.left + 3, bar.right - tw - 3),
			bar.top + 7, ui.font_small, C_TXT)
	}
	fill_frame(dc, bar.left, bar.top, width, 26, C_BORDER_SOFT)
	for edge in ([2]i32{left, right - 4}) {
		fill_rect(dc, edge, bar.top, 4, 26, C_ACCENT)
		line_v(dc, edge + 2, bar.top + 9, 8, C_PANEL)
	}
	draw_button(dc, minus, "-", HIT_ZOOM_OUT)
	draw_button(dc, plus, "+", HIT_ZOOM_IN)
	draw_button(dc, reset, "Full day", HIT_ZOOM_RESET)
}
