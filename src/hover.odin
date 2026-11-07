package main

import "core:sys/windows"

// Everything the painted frame derives from the mouse position. WM_MOUSEMOVE
// repaints only when this changes, or while the cursor-following bar tooltip is
// (or would become) visible. Other state (pressed button, drags, data, filter,
// zoom, theme) invalidates on its own paths, and the next paint records the
// signature it actually drew.
Hover_Signature :: struct {
	targets: u32, // bit i: hover-sensitive rectangle i contains the cursor
	bar:     int, // snapshot row index + 1 of the bar tooltip; 0 = none
}

// Rectangles whose drawing reads ui.mouse: tabs, theme/settings switches (and
// their tooltips), toolbar and zoom buttons, the totals-mode button (and its
// tooltip) and the pane splitters. They are the same rectangles the draw code
// tests, so a bit flips exactly when a hover visual can change.
hover_targets :: proc(x, y, w, h: i32) -> u32 {
	rects: [16]windows.RECT
	n := 0
	rects[n] = theme_switch_rect(w); n += 1
	rects[n] = settings_switch_rect(w); n += 1
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
hover_signature :: proc(snapshot: Day_Snapshot, x, y: i32, valid: bool, w, h: i32) -> Hover_Signature {
	if !valid { return {} }
	return Hover_Signature{targets = hover_targets(x, y, w, h),
		bar = tooltip_bar_hit(snapshot, x, y, valid, w, h) + 1}
}

// Same result as hover_signature, building the snapshot only over the lanes.
hover_signature_for_app :: proc(app: ^App, x, y, w, h: i32) -> Hover_Signature {
	snapshot: Day_Snapshot
	if _, in_lane := tooltip_lane(x, y, true, w, h); in_lane {
		snapshot = build_day_snapshot(app, tracker_now(app), tracker_monotonic(app))
	}
	return hover_signature(snapshot, x, y, true, w, h)
}

// The bar tooltip box follows the cursor, so every move repaints while one is
// painted or about to be painted.
hover_needs_repaint :: proc(painted, next: Hover_Signature) -> bool {
	return painted != next || painted.bar != 0 || next.bar != 0
}

// Ask for WM_MOUSELEAVE so hover visuals clear when the cursor leaves the
// client area (including onto a child control). Re-armed on the next move.
hover_track_leave :: proc(hwnd: windows.HWND) {
	if ui.mouse_tracking { return }
	tme := windows.TRACKMOUSEEVENT{cbSize = size_of(windows.TRACKMOUSEEVENT),
		dwFlags = windows.TME_LEAVE, hwndTrack = hwnd}
	ui.mouse_tracking = bool(windows.TrackMouseEvent(&tme))
}
