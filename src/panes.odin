package main

import "core:sys/windows"

// Shared rectangles drive drawing, cursor feedback and captured mouse input.
pane_split_hit :: proc(x, y: i32, lay: Layout) -> i32 {
	if ui.tab != 0 { return 0 }
	if rect_hit(lay.timeline_split, x, y) { return 1 }
	if rect_hit(lay.totals_split, x, y) { return 2 }
	return 0
}

pane_pointer_down :: proc(x, y: i32, lay: Layout) -> bool {
	split := pane_split_hit(x, y, lay)
	if split == 0 { return false }
	ui.pane_saved_lane_h, ui.pane_saved_totals_w = ui.pane_lane_h, ui.pane_totals_w
	ui.pane_drag = split
	ui.pane_drag_offset = y - lay.list_top if split == 1 else x - lay.sidebar_x
	windows.SetFocus(ui.hwnd)
	windows.SetCapture(ui.hwnd)
	windows.InvalidateRect(ui.hwnd, nil, windows.FALSE)
	return true
}

pane_pointer_move :: proc(x, y: i32, lay: Layout) {
	switch ui.pane_drag {
	case 1:
		max_h := max(MIN_LANE_H, (lay.list_bottom - lay.lane_y -
			2 * LANE_GAP - 4 - ZOOM_H - SPLITTER_W - MIN_LOWER_H) / 3)
		ui.pane_lane_h = clamp((y - ui.pane_drag_offset - lay.lane_y -
			2 * LANE_GAP - 4 - ZOOM_H - SPLITTER_W) / 3, MIN_LANE_H, max_h)
	case 2:
		ui.pane_totals_w = clamp(lay.chart_x + lay.chart_w - x + ui.pane_drag_offset,
			MIN_TOTALS_W, max(MIN_TOTALS_W, lay.chart_w - SPLITTER_W - MIN_LIST_W))
	}
}

pane_drag_cancel :: proc() {
	if ui.pane_drag == 0 { return }
	ui.pane_lane_h, ui.pane_totals_w = ui.pane_saved_lane_h, ui.pane_saved_totals_w
	ui.pane_drag = 0
}

draw_pane_splitters :: proc(dc: windows.HDC, lay: Layout) {
	for r, i in ([2]windows.RECT{lay.timeline_split, lay.totals_split}) {
		hot := ui.pane_drag == i32(i + 1) ||
			(ui.mouse_valid && rect_hit(r, ui.mouse.x, ui.mouse.y))
		_fill(dc, r, C_BTN_HOVER if hot else C_BG)
		color := windows.COLORREF(C_BTN_BORDER if hot else C_BORDER_SOFT)
		if i == 0 {
			line_h(dc, (r.left + r.right) / 2 - 20, r.top + SPLITTER_W / 2, 40, color)
		} else {
			line_v(dc, r.left + SPLITTER_W / 2, (r.top + r.bottom) / 2 - 20, 40, color)
		}
	}
}
