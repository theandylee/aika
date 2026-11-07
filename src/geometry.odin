package main

import "core:sys/windows"

// Pure rectangle helpers for areas that BOTH drawing and hit-testing need. Each
// returns the rectangles the call sites used to compute inline, so the two can
// no longer drift apart. Rectangles are half-open: [left, right) x [top, bottom).

TOTALS_ROWS_DY  :: i32(32) // top of the totals rows, below the "Totals" title strip
TOTALS_FOOTER_H :: i32(20) // pinned "Total:" line at the bottom of the totals panel
TOTALS_CHROME_H :: TOTALS_ROWS_DY + TOTALS_FOOTER_H

TOOLTIP_FOLLOW_W_PAD :: i32(20)  // horizontal padding of the cursor-following tooltip
TOOLTIP_FOLLOW_H     :: i32(58)  // three text lines
TOOLTIP_LINE_PITCH   :: i32(16) // vertical distance between hint text rows (first at +6)
TOOLTIP_BOX_PAD      :: i32(10) // vertical padding around the hint rows (16*3+10 = 58)
TOOLTIP_MAX_W        :: i32(600)  // cap on the cursor-following hint width (bounds the dirty rect)
TOOLTIP_FOLLOW_GAP   :: i32(14)  // distance from the cursor
TOOLTIP_EDGE_MARGIN  :: i32(8)   // keep this far from the client edge when flipping

// --- Lanes ---

// Full rectangle of one timeline lane (label area and bars).
lane_rect :: proc(lay: Layout, lane: Lane) -> windows.RECT {
	top := lane_top(lay, lane)
	return windows.RECT{lay.chart_x, top, lay.chart_x + lay.chart_w, top + lay.lane_h}
}

// Lane containing the point, using the same rectangles lanes are drawn in.
lane_at :: proc(lay: Layout, x, y: i32) -> (lane: Lane, ok: bool) {
	for candidate in Lane {
		if rect_hit(lane_rect(lay, candidate), x, y) { return candidate, true }
	}
	return
}

// Wheel zoom area: the ruler and all lanes, down to the lower panes.
chart_wheel_rect :: proc(lay: Layout) -> windows.RECT {
	return windows.RECT{lay.chart_x, lay.ruler_y, lay.chart_x + lay.chart_w, lay.list_top}
}

// --- Details list (bottom left) ---

// The list panel, including its header row and scrollbar column.
list_pane_rect :: proc(lay: Layout) -> windows.RECT {
	return windows.RECT{lay.chart_x, lay.list_top, lay.sidebar_x - dpi_px(SPLITTER_W), lay.list_bottom}
}

list_rows_top :: proc(lay: Layout) -> i32 { return lay.list_top + dpi_px(LIST_HDR) }

list_rows_visible :: proc(lay: Layout) -> i32 {
	return max(1, max(0, lay.list_bottom - lay.list_top - dpi_px(LIST_HDR)) / dpi_px(LIST_ROW))
}

// Left edges of the Start / End / Duration columns of a list `w` wide at `x`.
List_Columns :: struct {
	start, end, duration: i32,
}

list_columns :: proc(x, w: i32) -> List_Columns {
	return {start = x + w - dpi_px(186), end = x + w - dpi_px(128), duration = x + w - dpi_px(64)}
}

// --- Totals panel (bottom right) ---

totals_pane_rect :: proc(lay: Layout) -> windows.RECT {
	return windows.RECT{lay.sidebar_x, lay.list_top, lay.sidebar_x + lay.sidebar_w, lay.list_bottom}
}

totals_rows_top :: proc(lay: Layout) -> i32 { return lay.list_top + dpi_px(TOTALS_ROWS_DY) }

totals_rows_visible :: proc(lay: Layout) -> i32 {
	return max(1, max(0, lay.list_bottom - lay.list_top - dpi_px(TOTALS_CHROME_H)) / dpi_px(LIST_ROW))
}

// Rows area that totals clicks land in (tree mode); drawn rows never exceed it.
totals_rows_rect :: proc(lay: Layout) -> windows.RECT {
	top := totals_rows_top(lay)
	return windows.RECT{lay.sidebar_x, top, lay.sidebar_x + lay.sidebar_w, top + totals_rows_visible(lay) * dpi_px(LIST_ROW)}
}

// Row index (before scrolling) under client y inside the totals rows area.
totals_row_index :: proc(lay: Layout, y: i32) -> i32 {
	return (y - totals_rows_top(lay)) / dpi_px(LIST_ROW)
}

// Bottom of the area the totals scrollbar may occupy.
totals_scroll_bottom :: proc(lay: Layout) -> i32 { return lay.list_bottom - dpi_px(TOTALS_FOOTER_H) }

// Baseline-ish y of the pinned "Total:" line.
totals_footer_y :: proc(lay: Layout) -> i32 { return lay.list_bottom - dpi_px(TOTALS_FOOTER_H) }

// --- Tooltips ---

// Single-line tooltip box with its right edge at `right`, below the tab strip.
tab_tooltip_rect :: proc(right, width: i32) -> windows.RECT {
	x := right - width
	return windows.RECT{x, dpi_px(TAB_H) + dpi_px(TOOLTIP_GAP), x + width, dpi_px(TAB_H) + dpi_px(TOOLTIP_GAP) + dpi_px(TOOLTIP_H)}
}

// Single-line tooltip box above the totals panel, right-aligned to its mode button.
totals_mode_tooltip_rect :: proc(lay: Layout, width: i32) -> windows.RECT {
	x, y := lay.sidebar_x + lay.sidebar_w - width - dpi_px(5), lay.list_top - dpi_px(26)
	return windows.RECT{x, y, x + width, y + dpi_px(TOOLTIP_H)}
}

draw_single_line_tooltip :: proc(dc: windows.HDC, r: windows.RECT, label: string) {
	w := r.right - r.left
	fill_rect(dc, r.left, r.top, w, dpi_px(TOOLTIP_H), C_TIP_BG)
	fill_frame(dc, r.left, r.top, w, dpi_px(TOOLTIP_H), C_TIP_BORDER)
	draw_string(dc, label, r.left + dpi_px(8), r.top + dpi_px(TOOLTIP_TEXT_DY), ui.font_normal, C_TXT)
}

// Top-left of the cursor-following tooltip: below-right of the cursor, flipped to
// the other side near the right/bottom edge, then clamped to the client origin.
tooltip_follow_origin :: proc(mouse_x, mouse_y, tw, th, w, h: i32) -> (x, y: i32) {
	x = mouse_x + dpi_px(TOOLTIP_FOLLOW_GAP)
	y = mouse_y + dpi_px(TOOLTIP_FOLLOW_GAP)
	if x + tw > w - dpi_px(TOOLTIP_EDGE_MARGIN) { x = mouse_x - tw - dpi_px(TOOLTIP_FOLLOW_GAP) }
	if y + th > h - dpi_px(TOOLTIP_EDGE_MARGIN) { y = mouse_y - th - dpi_px(TOOLTIP_FOLLOW_GAP) }
	if x < 0 { x = 0 }
	if y < 0 { y = 0 }
	return
}
