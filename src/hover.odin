package main

import "core:sys/windows"

// Everything the painted frame derives from the mouse position. WM_MOUSEMOVE
// repaints only when this changes, or while the cursor-following timeline hint
// or cursor line is (or would become) visible. Other state (pressed button,
// drags, data, filter, zoom, theme) invalidates on its own paths, and the next
// paint records the signature it actually drew.
Hover_Signature :: struct {
	targets: u32, // bit i: hover-sensitive rectangle i contains the cursor
	bar:     int, // snapshot row index + 1 of the hovered block; 0 = empty space (time-only hint)
	cursor:  bool, // cursor line and hint on the timeline; follows x pixel-exactly
}

// Rectangles whose drawing reads ui.mouse: tabs, theme/settings switches (and
// their tooltips), toolbar and zoom buttons, the totals-mode button (and its
// tooltip) and the pane splitters. They are the same rectangles the draw code
// tests, so a bit flips exactly when a hover visual can change.
hover_targets :: proc(x, y, w, h: i32) -> u32 {
	rects: [18]windows.RECT
	n := 0
	rects[n] = theme_switch_rect(w); n += 1
	rects[n] = settings_switch_rect(w); n += 1
	rects[n] = version_rect(w, h); n += 1
	rects[n] = update_rect(w, h); n += 1 // empty (never hit) when no update is offered
	for tab in Tab {
		rects[n] = compute_tabs(tab); n += 1
	}
	// Placeholder tabs draw only the shared tab/theme/settings strip.
	if ui.tab == .Day {
		lay := compute_layout(w, h)
		_, minus, plus, reset := zoom_rects(lay)
		for r in ([10]windows.RECT{lay.btn_prev, lay.btn_next, lay.btn_today, lay.btn_track,
			totals_mode_rect(lay), minus, plus, reset, lay.timeline_split, lay.totals_split}) {
			rects[n] = r; n += 1
		}
	}
	mask: u32
	for i in 0 ..< n {
		if rect_hit(rects[i], x, y) { mask |= u32(1) << uint(i) }
	}
	return mask
}

// Pure: the snapshot is consulted only when the cursor is over a lane bar.
// The cursor line shares the tooltip's lane gate (Day tab, no drag/popup),
// so it never fights tag/zoom interactions.
hover_signature :: proc(snapshot: Day_Snapshot, x, y: i32, valid: bool, w, h: i32) -> Hover_Signature {
	if !valid { return {} }
	_, in_lane := tooltip_lane(x, y, valid, w, h)
	return Hover_Signature{targets = hover_targets(x, y, w, h),
		bar = tooltip_bar_hit(snapshot, x, y, valid, w, h) + 1, cursor = in_lane}
}

// Same result as hover_signature, building the snapshot only over the lanes.
hover_signature_for_app :: proc(app: ^App, x, y, w, h: i32) -> Hover_Signature {
	snapshot: Day_Snapshot
	if _, in_lane := tooltip_lane(x, y, true, w, h); in_lane {
		snapshot = build_day_snapshot(app, tracker_now(app), tracker_monotonic(app))
	}
	return hover_signature(snapshot, x, y, true, w, h)
}

// Repaint decision for a mouse move. Inside a lane the cursor line follows the
// pointer, so hover_needs_repaint is true regardless of the hovered bar; the
// (allocating, sorting) day snapshot would not change the answer, so skip it.
hover_move_needs_repaint :: proc(painted: Hover_Signature, x, y, w, h: i32) -> bool {
	return hover_needs_repaint(painted, hover_signature({}, x, y, true, w, h))
}

rect_empty :: proc(r: windows.RECT) -> bool { return r.right <= r.left || r.bottom <= r.top }

rect_union :: proc(a, b: windows.RECT) -> windows.RECT {
	if rect_empty(a) { return b }
	if rect_empty(b) { return a }
	return windows.RECT{min(a.left, b.left), min(a.top, b.top), max(a.right, b.right), max(a.bottom, b.bottom)}
}

// Region that can differ between the last painted hover frame and the one for
// the cursor at (x, y): the previously drawn line/hint plus everything the new
// line/hint can cover (hint width is capped at TOOLTIP_MAX_W, at most four rows).
// partial = false means a non-lane hover visual changed: invalidate everything.
hover_dirty_rect :: proc(painted: Hover_Signature, painted_rect: windows.RECT, x, y, w, h: i32) -> (r: windows.RECT, partial: bool) {
	next := hover_signature({}, x, y, true, w, h)
	if painted.targets != next.targets { return {}, false }
	if painted.cursor && rect_empty(painted_rect) { return {}, false }
	r = painted_rect
	if next.cursor {
		lay := compute_layout(w, h)
		gap := dpi_px(TOOLTIP_FOLLOW_GAP) + 2
		mw := dpi_px(TOOLTIP_MAX_W)
		mh := dpi_px(TOOLTIP_LINE_PITCH * 4 + TOOLTIP_BOX_PAD)
		bound := windows.RECT{max(0, x - gap - mw), max(0, y - gap - mh), min(w, x + gap + mw), min(h, y + gap + mh)}
		column := windows.RECT{x, lay.ruler_y, x + 1, lay.lanes_bottom}
		r = rect_union(r, rect_union(bound, column))
	}
	return r, !rect_empty(r)
}

// The timeline hint and the cursor line both follow the cursor, so every
// move repaints while either is painted or about to be painted.
hover_needs_repaint :: proc(painted, next: Hover_Signature) -> bool {
	return painted != next || painted.bar != 0 || next.bar != 0 ||
		painted.cursor || next.cursor
}

// Ask for WM_MOUSELEAVE so hover visuals clear when the cursor leaves the
// client area (including onto a child control). Re-armed on the next move.
hover_track_leave :: proc(hwnd: windows.HWND) {
	if ui.mouse_tracking { return }
	tme := windows.TRACKMOUSEEVENT{cbSize = size_of(windows.TRACKMOUSEEVENT),
		dwFlags = windows.TME_LEAVE, hwndTrack = hwnd}
	ui.mouse_tracking = bool(windows.TrackMouseEvent(&tme))
}
