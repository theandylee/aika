package main

import "core:testing"

// Called by zoom_behavior so shared UI state is tested serially.
pane_resize_behavior :: proc(t: ^testing.T) {
	old := ui
	defer ui = old
	ui = {}
	lay := compute_layout(1320, 860)
	testing.expect(t, lay.lane_h == 96 && lay.sidebar_w == SIDEBAR_W)
	testing.expect(t, pane_split_hit(100, lay.list_top - 4, lay) == 1)
	testing.expect(t, pane_split_hit(lay.sidebar_x - 4, lay.list_top + 40, lay) == 2)
	testing.expect(t, pane_split_hit(100, lay.lane_y + 10, lay) == 0)
	ui.tab = 1
	testing.expect(t, pane_split_hit(100, lay.list_top - 4, lay) == 0)
	ui.tab = 0

	ui.pane_drag = 1
	ui.pane_drag_offset = -4
	pane_pointer_move(100, lay.list_top - 4 + 90, lay)
	grown := compute_layout(1320, 860)
	testing.expect(t, grown.lane_h == 126 && grown.list_top == lay.list_top + 90)
	testing.expect(t, grown.sidebar_w == lay.sidebar_w)
	pane_pointer_move(100, 10000, grown)
	grown = compute_layout(1320, 860)
	testing.expect(t, grown.list_bottom - grown.list_top >= MIN_LOWER_H)
	pane_pointer_move(100, -10000, grown)
	testing.expect(t, compute_layout(1320, 860).lane_h == MIN_LANE_H)

	ui.pane_drag = 2
	ui.pane_drag_offset = -4
	pane_pointer_move(lay.sidebar_x - 4 - 100, 600, lay)
	wide := compute_layout(1320, 860)
	testing.expect(t, wide.sidebar_w == SIDEBAR_W + 100)
	pane_pointer_move(-10000, 600, wide)
	wide = compute_layout(1320, 860)
	testing.expect(t, wide.sidebar_x - SPLITTER_W - wide.chart_x >= MIN_LIST_W)
	pane_pointer_move(10000, 600, wide)
	testing.expect(t, compute_layout(1320, 860).sidebar_w == MIN_TOTALS_W)

	ui.pane_lane_h, ui.pane_totals_w = 160, 600
	for size in ([3][2]i32{{704, 440}, {1320, 860}, {1920, 1080}}) {
		r := compute_layout(size[0], size[1])
		testing.expect(t, r.lane_h >= MIN_LANE_H)
		testing.expect(t, r.list_bottom - r.list_top >= MIN_LOWER_H)
		testing.expect(t, r.sidebar_w >= MIN_TOTALS_W)
		testing.expect(t, r.sidebar_x - SPLITTER_W - r.chart_x >= MIN_LIST_W)
		bar, _, _, _ := zoom_rects(r)
		testing.expect(t, bar.bottom <= r.timeline_split.top)
	}
	testing.expect(t, compute_layout(1320, 860).lane_h == 160)
	testing.expect(t, compute_layout(1320, 860).sidebar_w == 600)
	ui.pane_saved_lane_h, ui.pane_saved_totals_w = 0, 0
	pane_drag_cancel()
	testing.expect(t, ui.pane_drag == 0 && ui.pane_lane_h == 0 && ui.pane_totals_w == 0)
}
