package main

import "core:sys/windows"

// Shared rectangles drive drawing, cursor feedback and captured mouse input.
pane_split_hit :: proc(x, y: i32, lay: Layout) -> Pane_Drag {
	if ui.tab != .Day { return .None }
	if rect_hit(lay.timeline_split, x, y) { return .Timeline_Height }
	if rect_hit(lay.totals_split, x, y) { return .List_Width }
	return .None
}

pane_pointer_down :: proc(x, y: i32, lay: Layout) -> bool {
	split := pane_split_hit(x, y, lay)
	if split == .None || interaction_active() { return false }
	pane_begin(split, y - lay.list_top if split == .Timeline_Height else x - lay.sidebar_x)
	windows.SetFocus(ui.hwnd)
	windows.SetCapture(ui.hwnd)
	windows.InvalidateRect(ui.hwnd, nil, windows.FALSE)
	return true
}

pane_pointer_move :: proc(x, y: i32, lay: Layout) {
	s, ok := pane_state()
	if !ok { return }
	switch s.kind {
	case .None:
	case .Timeline_Height:
		max_h := max(dpi_px(MIN_LANE_H), (lay.list_bottom - lay.lane_y -
			2 * dpi_px(LANE_GAP) - dpi_px(ZOOM_LANES_GAP) - dpi_px(ZOOM_H) - dpi_px(SPLITTER_W) - dpi_px(MIN_LOWER_H)) / 3)
		lane_h := clamp((y - s.offset - lay.lane_y -
			2 * dpi_px(LANE_GAP) - dpi_px(ZOOM_LANES_GAP) - dpi_px(ZOOM_H) - dpi_px(SPLITTER_W)) / 3, dpi_px(MIN_LANE_H), max_h)
		span := max(1, lay.list_bottom - lay.lane_y)
		ui.pane_lane_frac = f32(3 * lane_h) / f32(span)
	case .List_Width:
		totals_w := clamp(lay.chart_x + lay.chart_w - x + s.offset,
			dpi_px(MIN_TOTALS_W), max(dpi_px(MIN_TOTALS_W), lay.chart_w - dpi_px(SPLITTER_W) - dpi_px(MIN_LIST_W)))
		ui.pane_totals_frac = f32(totals_w) / f32(max(1, lay.chart_w))
	}
}

	draw_pane_splitters :: proc(dc: windows.HDC, lay: Layout) {
	for drag in ([2]Pane_Drag{.Timeline_Height, .List_Width}) {
		r := lay.timeline_split if drag == .Timeline_Height else lay.totals_split
		hot := pane_drag() == drag ||
			(ui.mouse_valid && rect_hit(r, ui.mouse.x, ui.mouse.y))
		_fill(dc, r, C_SPLITTER_HOT if hot else C_BG)
		color := windows.COLORREF(C_BTN_BORDER if hot else C_BORDER_SOFT)
		if drag == .Timeline_Height {
			line_h(dc, (r.left + r.right) / 2 - dpi_px(SPLITTER_GRIP_LEN) / 2, r.top + dpi_px(SPLITTER_W) / 2, dpi_px(SPLITTER_GRIP_LEN), color)
		} else {
			line_v(dc, r.left + dpi_px(SPLITTER_W) / 2, (r.top + r.bottom) / 2 - dpi_px(SPLITTER_GRIP_LEN) / 2, dpi_px(SPLITTER_GRIP_LEN), color)
		}
	}
}
