package main

import "core:testing"

// Shared UI state is reset by the audit #25 harness, so this is an
// independent @(test).
@(test)
pane_resize_behavior :: proc(t: ^testing.T) {
	g := ui_test_begin()
	defer ui_test_end(&g)
	lay := compute_layout(1320, 860)
	testing.expect(t, lay.lane_h == 96 && lay.sidebar_w == dpi_px(SIDEBAR_W))
	testing.expect(t, pane_split_hit(100, lay.list_top - 4, lay) == .Timeline_Height)
	testing.expect(t, pane_split_hit(lay.sidebar_x - 4, lay.list_top + 40, lay) == .List_Width)
	testing.expect(t, pane_split_hit(100, lay.lane_y + 10, lay) == .None)
	ui.tab = .Timesheet
	testing.expect(t, pane_split_hit(100, lay.list_top - 4, lay) == .None)
	ui.tab = .Day

	pane_begin(.Timeline_Height, -4)
	pane_pointer_move(100, lay.list_top - 4 + 90, lay)
	grown := compute_layout(1320, 860)
	testing.expect(t, grown.lane_h == 126 && grown.list_top == lay.list_top + 90)
	testing.expect(t, grown.sidebar_w == lay.sidebar_w)
	pane_pointer_move(100, 10000, grown)
	grown = compute_layout(1320, 860)
	testing.expect(t, grown.list_bottom - grown.list_top >= dpi_px(MIN_LOWER_H))
	pane_pointer_move(100, -10000, grown)
	testing.expect(t, compute_layout(1320, 860).lane_h == dpi_px(MIN_LANE_H))

	pane_begin(.List_Width, -4)
	pane_pointer_move(lay.sidebar_x - 4 - 100, 600, lay)
	wide := compute_layout(1320, 860)
	testing.expect(t, wide.sidebar_w == dpi_px(SIDEBAR_W) + 100)
	pane_pointer_move(-10000, 600, wide)
	wide = compute_layout(1320, 860)
	testing.expect(t, wide.sidebar_x - dpi_px(SPLITTER_W) - wide.chart_x >= dpi_px(MIN_LIST_W))
	pane_pointer_move(10000, 600, wide)
	testing.expect(t, compute_layout(1320, 860).sidebar_w == dpi_px(MIN_TOTALS_W))

	ui.pane_lane_h, ui.pane_totals_w = 160, 600
	for size in ([3][2]i32{{704, 440}, {1320, 860}, {1920, 1080}}) {
		r := compute_layout(size[0], size[1])
		testing.expect(t, r.lane_h >= dpi_px(MIN_LANE_H))
		testing.expect(t, r.list_bottom - r.list_top >= dpi_px(MIN_LOWER_H))
		testing.expect(t, r.sidebar_w >= dpi_px(MIN_TOTALS_W))
		testing.expect(t, r.sidebar_x - dpi_px(SPLITTER_W) - r.chart_x >= dpi_px(MIN_LIST_W))
		bar, _, _, _ := zoom_rects(r)
		testing.expect(t, bar.bottom <= r.timeline_split.top)
	}
	testing.expect(t, compute_layout(1320, 860).lane_h == 160)
	testing.expect(t, compute_layout(1320, 860).sidebar_w == 600)
	ui.pane_lane_h, ui.pane_totals_w = 160, 600
	pane_begin(.Timeline_Height, -4)
	ui.pane_lane_h, ui.pane_totals_w = 0, 0
	ui_cancel_interaction()
	testing.expect(t, pane_drag() == .None && ui.pane_lane_h == 160 && ui.pane_totals_w == 600)
}
