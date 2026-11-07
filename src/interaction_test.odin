package main

import "core:sys/windows"
import "core:testing"

// Interaction coverage: overview zoom drags, middle-button timeline pan, wheel
// routing, cancellation and the placeholder-tab gate. Holds the audit #25
// shared-state lock once for the whole test; the sub-cases below only
// snapshot the globals (ui_test_guard_*) so they must stay nested here.
@(test)
interaction_behavior :: proc(t: ^testing.T) {
	g := ui_test_begin()
	defer ui_test_end(&g)
	interaction_zoom_overview_drag(t)
	interaction_zoom_edge_drags(t)
	interaction_timeline_pan(t)
	interaction_wheel_routing(t)
	interaction_cancel_is_idempotent(t)
	interaction_blocked_off_day_tab(t)
}

near :: proc(a, b: f64, tolerance := 0.000001) -> bool { return abs(a - b) < tolerance }

interaction_zoom_overview_drag :: proc(t: ^testing.T) {
	g := ui_test_guard_begin()
	defer ui_test_guard_end(&g)
	lay := compute_layout(1320, 860)
	bar, _, _, _ := zoom_rects(lay)
	bw := f64(bar.right - bar.left)
	at := proc(bar: windows.RECT, bw, f: f64) -> i32 { return bar.left + i32(f * bw) }

	// Grabbing inside the selection pans without recentring; the span is kept.
	ui.zoom_start, ui.zoom_end = 0.2, 0.4
	testing.expect(t, zoom_pointer_down(at(bar, bw, 0.3), bar.top + 5, lay))
	testing.expect(t, zoom_drag() == .Overview)
	testing.expect(t, ui.zoom_start == 0.2 && ui.zoom_end == 0.4)
	zoom_pointer_move(at(bar, bw, 0.4), lay)
	testing.expect(t, near(ui.zoom_start, 0.3, 0.005) && near(ui.zoom_end - ui.zoom_start, 0.2, 0.000000001))
	zoom_pointer_move(at(bar, bw, 5), lay) // far right: clamped to the day
	testing.expect(t, ui.zoom_start == 0.8 && ui.zoom_end == 1)
	zoom_pointer_move(at(bar, bw, -5), lay)
	testing.expect(t, ui.zoom_start == 0 && near(ui.zoom_end, 0.2, 0.000000001))
	ui_cancel_interaction()
	testing.expect(t, zoom_drag() == .None && ui.zoom_start == 0.2 && ui.zoom_end == 0.4)

	// Clicking outside recentres at once and keeps that anchor while dragging.
	testing.expect(t, zoom_pointer_down(at(bar, bw, 0.8), bar.top + 5, lay))
	testing.expect(t, zoom_drag() == .Overview)
	testing.expect(t, near(ui.zoom_start, 0.7, 0.005) && near(ui.zoom_end - ui.zoom_start, 0.2, 0.000000001))
	recentred := ui.zoom_start
	zoom_pointer_move(at(bar, bw, 0.8), lay) // same x: no jump
	testing.expect(t, near(ui.zoom_start, recentred))
	zoom_pointer_move(at(bar, bw, 0.7), lay)
	testing.expect(t, near(ui.zoom_start, recentred - 0.1, 0.005))
	ui_cancel_interaction()
	testing.expect(t, ui.zoom_start == 0.2 && ui.zoom_end == 0.4)

	// Presses outside the bar are not overview drags.
	testing.expect(t, !zoom_pointer_down(bar.left - 1, bar.top + 5, lay))
	testing.expect(t, !zoom_pointer_down(bar.left + 5, bar.top - 1, lay))
	testing.expect(t, !zoom_pointer_down(bar.left + 5, bar.bottom, lay))
	testing.expect(t, zoom_drag() == .None)
}

interaction_zoom_edge_drags :: proc(t: ^testing.T) {
	g := ui_test_guard_begin()
	defer ui_test_guard_end(&g)
	lay := compute_layout(1320, 860)
	bar, _, _, _ := zoom_rects(lay)
	bw := f64(bar.right - bar.left)
	left := bar.left + i32(0.2 * bw)
	right := bar.left + i32(0.6 * bw)

	ui.zoom_start, ui.zoom_end = 0.2, 0.6
	testing.expect(t, zoom_pointer_down(left + 2, bar.top + 5, lay))
	testing.expect(t, zoom_drag() == .Left)
	zoom_pointer_move(bar.left + i32(0.1 * bw), lay)
	testing.expect(t, near(ui.zoom_start, 0.1, 0.005) && ui.zoom_end == 0.6)
	ui_cancel_interaction()
	testing.expect(t, ui.zoom_start == 0.2 && ui.zoom_end == 0.6)

	testing.expect(t, zoom_pointer_down(right - 2, bar.top + 5, lay))
	testing.expect(t, zoom_drag() == .Right)
	zoom_pointer_move(bar.left + i32(0.9 * bw), lay)
	testing.expect(t, ui.zoom_start == 0.2 && near(ui.zoom_end, 0.9, 0.005))
	zoom_pointer_move(bar.left - 100, lay) // cannot cross the other handle
	testing.expect(t, near(ui.zoom_end - ui.zoom_start, ZOOM_MIN_SPAN))
	ui_cancel_interaction()
	testing.expect(t, ui.zoom_start == 0.2 && ui.zoom_end == 0.6)

	// With the full day selected both handles coincide with the bar ends.
	ui.zoom_start, ui.zoom_end = 0, 1
	testing.expect(t, zoom_pointer_down(bar.left, bar.top + 5, lay) && zoom_drag() == .Left)
	ui_cancel_interaction()
	testing.expect(t, zoom_pointer_down(bar.right - 1, bar.top + 5, lay) && zoom_drag() == .Right)
	ui_cancel_interaction()
}

interaction_timeline_pan :: proc(t: ^testing.T) {
	g := ui_test_guard_begin()
	defer ui_test_guard_end(&g)
	lay := compute_layout(1320, 860)
	x := lay.chart_x + lay.chart_w / 2
	ui.zoom_start, ui.zoom_end = 0.25, 0.75

	// Only the ruler and lanes start a pan.
	testing.expect(t, !zoom_pan_down(x, lay.ruler_y - 1, lay))
	testing.expect(t, !zoom_pan_down(x, lay.lanes_bottom, lay))
	testing.expect(t, !zoom_pan_down(lay.chart_x - 1, lay.lane_y, lay))
	testing.expect(t, !zoom_pan_down(lay.chart_x + lay.chart_w, lay.lane_y, lay))
	testing.expect(t, zoom_drag() == .None)
	testing.expect(t, zoom_pan_down(x, lay.lane_y + 5, lay) && zoom_drag() == .Timeline)
	zoom_pointer_move(x - lay.chart_w / 5, lay) // content follows the pointer: view moves right
	testing.expect(t, near(ui.zoom_start, 0.25 + 0.1, 0.002) && near(ui.zoom_end - ui.zoom_start, 0.5, 0.000000001))
	ui_cancel_interaction()
	testing.expect(t, zoom_drag() == .None && ui.zoom_start == 0.25 && ui.zoom_end == 0.75)

	// A pan never begins over another interaction (the caller captures only on true).
	other := [3]string{"pane", "tag", "press"}
	for name in other {
		ui.interaction = nil
		switch name {
		case "pane": pane_begin(.Timeline_Height, 0)
		case "tag": tag_begin(.New_Range, 0)
		case "press": press_begin(.Zoom_In)
		}
		testing.expect(t, !zoom_pan_down(x, lay.lane_y + 5, lay), name)
		testing.expect(t, zoom_drag() == .None, name)
	}
	ui.interaction = nil

	// Placeholder tabs ignore it entirely.
	ui.tab = .Statistics
	testing.expect(t, !zoom_pan_down(x, lay.lane_y + 5, lay) && zoom_drag() == .None)
}

interaction_wheel_routing :: proc(t: ^testing.T) {
	g := ui_test_guard_begin()
	defer ui_test_guard_end(&g)
	lay := compute_layout(1320, 860)
	ui.list_scroll.rows, ui.list_scroll.page, ui.list_scroll.pos = 100, 10, 20
	ui.totals_scroll.rows, ui.totals_scroll.page, ui.totals_scroll.pos = 100, 10, 20
	cx := lay.chart_x + lay.chart_w / 2
	ui.zoom_start, ui.zoom_end = 0, 1

	// The areas are disjoint and match what is painted.
	zoom_area, list_area, totals_area := chart_wheel_rect(lay), list_pane_rect(lay), totals_pane_rect(lay)
	testing.expect(t, zoom_area.bottom <= list_area.top && zoom_area.bottom <= totals_area.top)
	testing.expect(t, list_area.right <= totals_area.left)

	// Ruler and lanes zoom around the pointer, notch up zooms in.
	testing.expect(t, wheel_apply(lay, cx, lay.lane_y + 10, 120))
	testing.expect(t, near(ui.zoom_end - ui.zoom_start, 0.8))
	testing.expect(t, near(ui.zoom_start, 0.1, 0.001) && ui.list_scroll.pos == 20 && ui.totals_scroll.pos == 20)
	testing.expect(t, wheel_apply(lay, cx, lay.ruler_y, -120))
	testing.expect(t, ui.zoom_start == 0 && ui.zoom_end == 1, "Zooming out re-clamps to the full day")
	ui.zoom_start, ui.zoom_end = 0.25, 0.75
	testing.expect(t, wheel_apply(lay, lay.chart_x, lay.lane_y + 10, 120)) // anchored at the left edge
	testing.expect(t, near(ui.zoom_start, 0.25) && near(ui.zoom_end, 0.65))
	ui.zoom_start, ui.zoom_end = 0.25, 0.75
	before := [2]f64{ui.zoom_start, ui.zoom_end}
	testing.expect(t, wheel_apply(lay, cx, lay.lane_y + 10, 0)) // a zero delta does nothing
	testing.expect(t, [2]f64{ui.zoom_start, ui.zoom_end} == before)
	testing.expect(t, wheel_apply(lay, cx, lay.zoom_y + 4, 120)) // the overview strip is inside the zoom area
	testing.expect(t, near(ui.zoom_end - ui.zoom_start, 0.4))
	ui.zoom_start, ui.zoom_end = 0.25, 0.75

	// The details list scrolls alone: a notch down moves rows ahead.
	testing.expect(t, wheel_apply(lay, lay.chart_x + 10, lay.list_top + 40, -120))
	testing.expect(t, ui.list_scroll.pos == 20 + WHEEL_ROWS_PER_NOTCH && ui.totals_scroll.pos == 20)
	testing.expect(t, [2]f64{ui.zoom_start, ui.zoom_end} == before)
	// The totals panel scrolls alone, and the first row below the zoom area is list/totals.
	testing.expect(t, wheel_apply(lay, lay.sidebar_x + 10, lay.list_top, 120))
	testing.expect(t, ui.totals_scroll.pos == 20 - WHEEL_ROWS_PER_NOTCH)
	testing.expect(t, ui.list_scroll.pos == 20 + WHEEL_ROWS_PER_NOTCH && [2]f64{ui.zoom_start, ui.zoom_end} == before)
	// Scrolling clamps to the rows.
	for _ in 0 ..< 100 { wheel_apply(lay, lay.sidebar_x + 10, lay.list_top + 40, -120) }
	testing.expect(t, ui.totals_scroll.pos == 90)
	for _ in 0 ..< 100 { wheel_apply(lay, lay.sidebar_x + 10, lay.list_top + 40, 120) }
	testing.expect(t, ui.totals_scroll.pos == 0)

	// Dead areas (toolbar, splitter strip between the panes) change nothing.
	list_before, totals_before := ui.list_scroll.pos, ui.totals_scroll.pos
	testing.expect(t, wheel_apply(lay, cx, 5, 120))
	testing.expect(t, wheel_apply(lay, lay.sidebar_x - 1, lay.list_top + 40, 120))
	testing.expect(t, ui.list_scroll.pos == list_before && ui.totals_scroll.pos == totals_before)
	testing.expect(t, [2]f64{ui.zoom_start, ui.zoom_end} == before)

	// Every drag, and the placeholder tabs, swallow the wheel completely.
	ignored := proc(t: ^testing.T, lay: Layout, label: string, before: [2]f64) {
		testing.expect(t, !wheel_apply(lay, lay.chart_x + 10, lay.lane_y + 10, 120), label)
		testing.expect(t, !wheel_apply(lay, lay.chart_x + 10, lay.list_top + 40, -120), label)
		testing.expect(t, !wheel_apply(lay, lay.sidebar_x + 10, lay.list_top + 40, -120), label)
		testing.expect(t, [2]f64{ui.zoom_start, ui.zoom_end} == before, label)
		testing.expect(t, ui.list_scroll.pos == 0 && ui.totals_scroll.pos == 0, label)
	}
	ui.list_scroll.pos, ui.totals_scroll.pos = 0, 0
	pane_begin(.List_Width, 0)
	ignored(t, lay, "pane drag", before)
	interaction_end()
	zoom_begin(.Overview, 0.5)
	ignored(t, lay, "zoom drag", before)
	zoom_begin(.Timeline, 0.5)
	ignored(t, lay, "timeline pan", before)
	interaction_end()
	tag_begin(.Left_Edge, 0)
	ignored(t, lay, "tag drag", before)
	interaction_end()
	ui.tab = .Timesheet
	ignored(t, lay, "timesheet tab", before)
	ui.tab = .Statistics
	ignored(t, lay, "statistics tab", before)
}

interaction_cancel_is_idempotent :: proc(t: ^testing.T) {
	g := ui_test_guard_begin()
	defer ui_test_guard_end(&g)
	lay := compute_layout(1320, 860)

	// Nothing active: cancelling changes nothing at all.
	ui.zoom_start, ui.zoom_end = 0.3, 0.6
	ui.pane_lane_h, ui.pane_totals_w = 101, 402
	tag_ui.id, tag_ui.start_ms, tag_ui.end_ms = 7, 100, 200
	ui_cancel_interaction()
	testing.expect(t, ui.zoom_start == 0.3 && ui.zoom_end == 0.6 && ui.pane_lane_h == 101 && ui.pane_totals_w == 402)
	testing.expect(t, tag_ui.id == 7 && tag_ui.start_ms == 100 && tag_ui.end_ms == 200)

	// Pane: restores once. A later change must not be rolled back by a second
	// cancel (WM_CAPTURECHANGED re-enters after Escape/WM_CANCELMODE).
	testing.expect(t, pane_pointer_down(100, lay.list_top - 4, lay))
	testing.expect(t, pane_drag() == .Timeline_Height)
	pane_pointer_move(100, lay.list_top + 40, lay)
	testing.expect(t, ui.pane_lane_h != 101)
	ui_cancel_interaction()
	testing.expect(t, pane_drag() == .None && ui.pane_lane_h == 101 && ui.pane_totals_w == 402)
	ui.pane_lane_h, ui.pane_totals_w = 140, 500
	ui_cancel_interaction()
	testing.expect(t, ui.pane_lane_h == 140 && ui.pane_totals_w == 500)

	// Zoom: same.
	bar, _, _, _ := zoom_rects(lay)
	testing.expect(t, zoom_pointer_down(bar.left + (bar.right - bar.left) / 2, bar.top + 5, lay))
	zoom_pointer_move(bar.left + 10, lay)
	ui_cancel_interaction()
	testing.expect(t, zoom_drag() == .None && ui.zoom_start == 0.3 && ui.zoom_end == 0.6)
	ui.zoom_start, ui.zoom_end = 0.5, 0.9
	ui_cancel_interaction()
	testing.expect(t, ui.zoom_start == 0.5 && ui.zoom_end == 0.9)

	// Press: cleared, nothing else touched.
	press_begin(.Settings)
	ui_cancel_interaction()
	ui_cancel_interaction()
	testing.expect(t, press_hit() == .None && ui.zoom_start == 0.5 && ui.zoom_end == 0.9)

	// Tag drag: the dragged range survives for the picker; only the drag clears.
	app := App{date = 20261106}
	ui.tab, ui.zoom_start, ui.zoom_end = .Day, 0, 1
	lane := lane_rect(lay, .Tags)
	testing.expect(t, tag_pointer_down(&app, lane.left + 100, lane.top + 10, lay))
	testing.expect(t, tag_drag() == .New_Range)
	tag_pointer_move(lane.left + 300, lay, nil)
	start, end := tag_ui.start_ms, tag_ui.end_ms
	testing.expect(t, end > start)
	ui_cancel_interaction()
	ui_cancel_interaction()
	testing.expect(t, tag_drag() == .None && tag_ui.start_ms == start && tag_ui.end_ms == end)
}

interaction_blocked_off_day_tab :: proc(t: ^testing.T) {
	g := ui_test_guard_begin()
	defer ui_test_guard_end(&g)
	lay := compute_layout(1320, 860)
	bar, _, _, _ := zoom_rects(lay)
	app := App{date = 20261106}
	ds, de := day_bounds_ms(app.date)
	activities := [1]Activity{{id = 42, timeline_id = TIMELINE_TAGS, start_ms = ds + 3600_000, end_ms = ds + 7200_000}}
	app.activities = activities[:]
	lane := lane_rect(lay, .Tags)
	_ = de

	// Sanity on the Day tab: these all begin an interaction.
	testing.expect(t, pane_pointer_down(100, lay.list_top - 4, lay))
	ui_cancel_interaction()
	testing.expect(t, zoom_pointer_down(bar.left + 5, bar.top + 5, lay))
	ui_cancel_interaction()
	testing.expect(t, zoom_pan_down(lay.chart_x + 50, lay.ruler_y + 2, lay))
	ui_cancel_interaction()
	testing.expect(t, tag_pointer_down(&app, lane.left + 100, lane.top + 10, lay))
	ui_cancel_interaction()

	for tab in ([2]Tab{.Timesheet, .Statistics}) {
		ui.tab = tab
		testing.expect(t, !pane_pointer_down(100, lay.list_top - 4, lay))
		testing.expect(t, !pane_pointer_down(lay.sidebar_x - 4, lay.list_top + 40, lay))
		testing.expect(t, !zoom_pointer_down(bar.left + 5, bar.top + 5, lay))
		testing.expect(t, !zoom_pan_down(lay.chart_x + 50, lay.ruler_y + 2, lay))
		testing.expect(t, !tag_pointer_down(&app, lane.left + 100, lane.top + 10, lay))
		testing.expect(t, !tag_gap_double_click(&app, lane.left + 100, lane.top + 10, lay))
		testing.expect(t, !wheel_apply(lay, lay.chart_x + 10, lay.lane_y + 10, 120))
		testing.expect(t, pane_drag() == .None && zoom_drag() == .None && tag_drag() == .None && press_hit() == .None)
		// Only the always-visible switches may start a button press.
		for y := i32(0); y < 860; y += 6 {
			for x := i32(0); x < 1320; x += 6 {
				hit := hit_test(x, y, 1320, 860)
				testing.expect(t, !hit_is_pressable(hit) || hit == .Theme || hit == .Settings)
			}
		}
	}
}
