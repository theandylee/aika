package main

import "core:testing"

@(test)
zoom_behavior :: proc(t: ^testing.T) {
	// Exercise the shared UI state serially, even with a parallel test runner.
	zoom_scale_keeps_anchor(t)
	zoom_limits(t)
	zoom_bounds_uses_actual_day_length(t)
	zoom_pan_and_edges_clamp(t)
	zoom_middle_pan(t)
	zoom_layout_and_ticks(t)
	pane_resize_behavior(t)
	tag_drag_behavior(t)
	totals_tree_behavior(t)
	ui_visibility_and_cancellation(t)
	ui_startup_unwinds_every_stage(t)
}

zoom_scale_keeps_anchor :: proc(t: ^testing.T) {
	old := ui
	defer ui = old
	ui.zoom_start, ui.zoom_end = 0, 1
	zoom_scale(0.5, 0.25)
	testing.expect(t, abs(ui.zoom_start - 0.125) < 0.000001)
	testing.expect(t, abs(ui.zoom_end - 0.625) < 0.000001)
	zoom_scale(2, 0.25)
	testing.expect(t, ui.zoom_start == 0 && ui.zoom_end == 1)
	zoom_scale(1.0 / 1.5, 0.5)
	zoom_scale(1.5, 0.5)
	testing.expect(t, ui.zoom_start == 0 && ui.zoom_end == 1)
}

zoom_limits :: proc(t: ^testing.T) {
	old := ui
	defer ui = old
	ui.zoom_start, ui.zoom_end = 0, 1
	for _ in 0..<100 { zoom_scale(0.5, 1) }
	testing.expect(t, ui.zoom_start >= 0 && ui.zoom_end <= 1)
	testing.expect(t, abs(ui.zoom_end - ui.zoom_start - ZOOM_MIN_SPAN) < 0.000001)
	for _ in 0..<100 { zoom_scale(2, 0) }
	testing.expect(t, ui.zoom_start == 0 && ui.zoom_end == 1)
}

zoom_bounds_uses_actual_day_length :: proc(t: ^testing.T) {
	old := ui
	defer ui = old
	ui.zoom_start, ui.zoom_end = 0.25, 0.75
	for hours in ([3]i64{23, 24, 25}) {
		span := hours * 3600_000
		start, end := zoom_bounds(1000, 1000 + span)
		testing.expect(t, start == 1000 + span / 4)
		testing.expect(t, end == 1000 + span * 3 / 4)
	}
}

zoom_pan_and_edges_clamp :: proc(t: ^testing.T) {
	old := ui
	defer ui = old
	lay := compute_layout(1320, 860)
	bar, _, _, _ := zoom_rects(lay)
	ui.zoom_start, ui.zoom_end = 0.25, 0.75
	ui.zoom_drag_start, ui.zoom_drag_end = 0.25, 0.75
	ui.zoom_drag_anchor = 0.5
	ui.zoom_drag = .Overview
	zoom_pointer_move(bar.right + 500, lay)
	testing.expect(t, ui.zoom_start == 0.5 && ui.zoom_end == 1)
	zoom_pointer_move(bar.left - 500, lay)
	testing.expect(t, ui.zoom_start == 0 && ui.zoom_end == 0.5)
	ui.zoom_drag = .Left
	zoom_pointer_move(bar.right, lay)
	testing.expect(t, abs(ui.zoom_end - ui.zoom_start - ZOOM_MIN_SPAN) < 0.000001)
	ui.zoom_drag = .Right
	zoom_pointer_move(bar.left, lay)
	testing.expect(t, abs(ui.zoom_end - ui.zoom_start - ZOOM_MIN_SPAN) < 0.000001)
}

zoom_middle_pan :: proc(t: ^testing.T) {
	old := ui
	defer ui = old
	ui.tab, ui.zoom_drag, ui.pane_drag, ui.pressed_hit = 0, .None, 0, HIT_NONE
	lay := compute_layout(1320, 860)
	x := lay.chart_x + lay.chart_w / 2
	ui.zoom_start, ui.zoom_end = 0.25, 0.75
	testing.expect(t, !zoom_pan_down(x, lay.zoom_y, lay))
	testing.expect(t, !zoom_pan_down(lay.chart_x - 1, lay.ruler_y, lay))
	testing.expect(t, zoom_pan_down(x, lay.ruler_y, lay))
	zoom_pointer_move(x + lay.chart_w / 4, lay)
	expected := 0.25 - f64(lay.chart_w / 4) / f64(lay.chart_w) * 0.5
	testing.expect(t, abs(ui.zoom_start - expected) < 0.000001)
	testing.expect(t, abs(ui.zoom_end - ui.zoom_start - 0.5) < 0.000001)
	zoom_pointer_move(lay.chart_x + lay.chart_w * 3, lay)
	testing.expect(t, ui.zoom_start == 0 && ui.zoom_end == 0.5)
	zoom_pointer_move(lay.chart_x - lay.chart_w * 3, lay)
	testing.expect(t, ui.zoom_start == 0.5 && ui.zoom_end == 1)
	zoom_pointer_move(x, lay)
	testing.expect(t, ui.zoom_start == 0.25 && ui.zoom_end == 0.75)
	testing.expect(t, !zoom_pan_down(x, lay.lane_y, lay)) // no nested drag
	ui.zoom_drag = .None
	ui.zoom_start, ui.zoom_end = 0, 1
	testing.expect(t, zoom_pan_down(x, lay.lane_y, lay))
	zoom_pointer_move(x + 200, lay)
	testing.expect(t, ui.zoom_start == 0 && ui.zoom_end == 1)
}

zoom_layout_and_ticks :: proc(t: ^testing.T) {
	for width in ([3]i32{704, 1320, 1920}) {
		lay := compute_layout(width, 440)
		bar, minus, plus, reset := zoom_rects(lay)
		testing.expect(t, bar.right > bar.left)
		testing.expect(t, bar.bottom < lay.list_top)
		testing.expect(t, lay.btn_prev.right < lay.btn_today.left)
		testing.expect(t, lay.btn_today.right < lay.btn_next.left)
		testing.expect(t, lay.btn_next.right < lay.date_pick.left)
		testing.expect(t, lay.date_pick.right < lay.btn_track.left)
		testing.expect(t, lay.btn_prev.top == lay.btn_today.top && lay.btn_today.top == lay.btn_next.top)
		testing.expect(t, bar.right < minus.left && minus.right < plus.left && plus.right < reset.left)
	}
	testing.expect(t, zoom_tick_step(0, 24 * 3600_000, 1320) == 3600_000)
	testing.expect(t, zoom_tick_step(0, 60_000, 1320) == 60_000)
}
