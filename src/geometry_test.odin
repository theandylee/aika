package main

import "core:sys/windows"
import "core:testing"

// Invoked serially by zoom_behavior: compute_layout/hit_test read the shared ui state.
geometry_behavior :: proc(t: ^testing.T) {
	old := ui
	defer ui = old
	ui = {}
	ui.zoom_start, ui.zoom_end = 0, 1

	for size in ([3][2]i32{{1320, 860}, {900, 600}, {720, 480}}) {
		w, h := size[0], size[1]
		lay := compute_layout(w, h)

		// Lanes: stacked with LANE_GAP, ending at lanes_bottom; lane_at agrees with lane_rect.
		for lane in Lane {
			r := lane_rect(lay, lane)
			testing.expect(t, r.left == lay.chart_x && r.right == lay.chart_x + lay.chart_w)
			testing.expect(t, r.top == lane_top(lay, lane) && r.bottom - r.top == lay.lane_h)
			found, ok := lane_at(lay, r.left, r.top)
			testing.expect(t, ok && found == lane)
			found, ok = lane_at(lay, r.right - 1, r.bottom - 1)
			testing.expect(t, ok && found == lane)
			_, ok = lane_at(lay, r.right, r.top)
			testing.expect(t, !ok)
		}
		testing.expect(t, lane_rect(lay, .Apps).bottom == lay.lanes_bottom)
		testing.expect(t, lane_rect(lay, .Computer).top - lane_rect(lay, .Tags).bottom == LANE_GAP)
		testing.expect(t, lane_rect(lay, .Tags) ==
			windows.RECT{lay.chart_x, lay.lane_y, lay.chart_x + lay.chart_w, lay.lane_y + lay.lane_h})
		_, gap := lane_at(lay, lay.chart_x + 5, lane_rect(lay, .Tags).bottom + 1)
		testing.expect(t, !gap)

		// Lower panes: list | splitter | totals tile the width with no overlap.
		list, totals := list_pane_rect(lay), totals_pane_rect(lay)
		testing.expect(t, list.right + SPLITTER_W == totals.left && lay.totals_split.left == list.right)
		testing.expect(t, list.left == lay.chart_x && totals.right == lay.chart_x + lay.chart_w)
		testing.expect(t, list.top == lay.list_top && list.bottom == lay.list_bottom && totals.bottom == lay.list_bottom)

		// Rows areas never extend past the pane, and clicks map to the rows they draw.
		rows := totals_rows_rect(lay)
		visible := totals_rows_visible(lay)
		testing.expect(t, rows.left == totals.left && rows.right == totals.right && rows.top == totals_rows_top(lay))
		testing.expect(t, rows.bottom - rows.top == visible * LIST_ROW && visible >= 1)
		testing.expect(t, totals_row_index(lay, rows.top) == 0 && totals_row_index(lay, rows.top + LIST_ROW) == 1)
		testing.expect(t, totals_row_index(lay, rows.bottom - 1) == visible - 1)
		testing.expect(t, totals_scroll_bottom(lay) == totals_footer_y(lay))
		testing.expect(t, list_rows_top(lay) == lay.list_top + LIST_HDR && list_rows_visible(lay) >= 1)

		cols := list_columns(list.left, list.right - list.left)
		testing.expect(t, cols.start < cols.end && cols.end < cols.duration && cols.duration < list.right)
		testing.expect(t, cols.duration - cols.end == 64 && cols.end - cols.start == 58)

		// hit_test, drawing helpers and the previous inline expressions agree everywhere.
		// Below the tab strip (which has priority) the lane and totals-row targets
		// must match the inline expressions they replaced, at every sampled point.
		ui.totals_tree = true
		mismatches := 0
		for y := i32(TAB_H); y < h; y += 1 {
			for x := i32(0); x < w; x += 2 {
				hit := hit_test(x, y, w, h)
				old_row := x >= lay.sidebar_x && x < lay.sidebar_x + lay.sidebar_w &&
					y >= lay.list_top + 32 &&
					y < lay.list_top + 32 + max(1, max(0, lay.list_bottom - lay.list_top - 52) / LIST_ROW) * LIST_ROW
				old_lane := Lane(-1)
				if y >= lay.ruler_y && x >= lay.chart_x && x < lay.chart_x + lay.chart_w {
					for lane in Lane {
						ly := lane_top(lay, lane)
						if y >= ly && y < ly + lay.lane_h { old_lane = lane }
					}
				}
				lane, is_lane := hit_as_lane(hit)
				if (hit == .Totals_Row) != old_row { mismatches += 1 }
				if is_lane != (old_lane != Lane(-1)) || (is_lane && lane != old_lane) { mismatches += 1 }
			}
		}
		testing.expect_value(t, mismatches, 0)
		ui.totals_tree = false
	}

	// Cursor-following tooltip: below-right of the cursor, flipped near edges, clamped.
	W, H :: i32(800), i32(600)
	x, y := tooltip_follow_origin(100, 100, 200, TOOLTIP_FOLLOW_H, W, H)
	testing.expect(t, x == 114 && y == 114)
	x, y = tooltip_follow_origin(700, 100, 200, TOOLTIP_FOLLOW_H, W, H) // would pass the right edge
	testing.expect(t, x == 700 - 200 - 14 && y == 114)
	x, y = tooltip_follow_origin(100, 580, 200, TOOLTIP_FOLLOW_H, W, H) // would pass the bottom edge
	testing.expect(t, x == 114 && y == 580 - TOOLTIP_FOLLOW_H - 14)
	x, y = tooltip_follow_origin(5, 5, 900, 700, W, H) // flipped above/left, clamped to the origin
	testing.expect(t, x == 0 && y == 0)

	// Single-line tooltips: fixed height below the tab strip, right-aligned.
	r := tab_tooltip_rect(W - 8, 120)
	testing.expect(t, r.right == W - 8 && r.left == W - 8 - 120 && r.top == TAB_H + TOOLTIP_GAP && r.bottom - r.top == TOOLTIP_H)
	lay := compute_layout(1320, 860)
	tr := totals_mode_tooltip_rect(lay, 130)
	testing.expect(t, tr.right == lay.sidebar_x + lay.sidebar_w - 5 && tr.bottom - tr.top == TOOLTIP_H && tr.top == lay.list_top - 26)
}
