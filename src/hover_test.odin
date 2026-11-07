package main

import "core:sys/windows"
import "core:testing"

// Shared ui/tag_ui state is reset by the audit #25 harness, so this is an
// independent @(test).
@(test)
hover_repaint_behavior :: proc(t: ^testing.T) {
	g := ui_test_begin()
	defer ui_test_end(&g)
	defer free_all(context.temp_allocator)
	ui.zoom_start, ui.zoom_end = 0, 1
	W, H :: i32(1320), i32(860)
	lay := compute_layout(W, H)

	date := 20261107
	ds, _ := day_bounds_ms(date)
	HOUR :: i64(3_600_000)
	rows := [?]Activity{
		{id = 1, timeline_id = TIMELINE_APPS, group_id = 10, display_name = "main.odin - Editor",
			group_name = "Editor", start_ms = ds + 9 * HOUR, end_ms = ds + 10 * HOUR, start_date = date},
		{id = 2, timeline_id = TIMELINE_APPS, group_id = 11, display_name = "Docs - Browser",
			group_name = "Browser", start_ms = ds + 10 * HOUR, end_ms = ds + 11 * HOUR, start_date = date},
		{id = 3, timeline_id = TIMELINE_COMPUTER, group_id = 1, group_name = "Active",
			start_ms = ds + 9 * HOUR, end_ms = ds + 11 * HOUR, start_date = date},
	}
	app := App{date = date, loaded_date = date, activities = rows[:]}
	snapshot := build_day_snapshot(&app, ds + 12 * HOUR, 0)

	x_at :: proc(lay: Layout, hours: f64) -> i32 { return lay.chart_x + i32(hours / 24 * f64(lay.chart_w)) }
	apps_y := lay.lane_y + 2 * (lay.lane_h + dpi_px(LANE_GAP)) + lay.lane_h / 2
	usage_y := lay.lane_y + (lay.lane_h + dpi_px(LANE_GAP)) + lay.lane_h / 2
	sig :: proc(s: Day_Snapshot, x, y: i32) -> Hover_Signature { return hover_signature(s, x, y, true, 1320, 860) }

	// Empty areas (inside the details list, empty lane time): no repaint.
	list_a := sig(snapshot, lay.chart_x + 40, lay.list_top + 60)
	list_b := sig(snapshot, lay.chart_x + 90, lay.list_top + 120)
	testing.expect(t, list_a == Hover_Signature{} && list_b == list_a)
	testing.expect(t, !hover_needs_repaint(list_a, list_b))
	// Empty lane areas show no tooltip, but the cursor line follows the mouse,
	// so every move repaints while it is (or would become) visible.
	empty_lane := sig(snapshot, x_at(lay, 3), apps_y)
	testing.expect(t, empty_lane.bar == 0 && empty_lane.cursor)
	testing.expect(t, hover_needs_repaint(empty_lane, sig(snapshot, x_at(lay, 4), apps_y + 3)))
	testing.expect(t, !hover_needs_repaint(Hover_Signature{}, hover_signature(snapshot, 5, 5, false, W, H)))

	// Crossing onto and off a button repaints; moving within it does not.
	today := lay.btn_today
	on := sig(snapshot, today.left + 2, today.top + 2)
	testing.expect(t, on.targets != 0 && on.bar == 0)
	testing.expect(t, hover_needs_repaint(list_a, on))
	testing.expect(t, !hover_needs_repaint(on, sig(snapshot, today.right - 2, today.bottom - 2)))
	testing.expect(t, hover_needs_repaint(on, sig(snapshot, today.right, today.top + 2)))
	// Every hover-drawn rectangle owns a distinct bit.
	_, minus, plus, reset := zoom_rects(lay)
	hot := [?]windows.RECT{theme_switch_rect(W), settings_switch_rect(W), compute_tabs(.Day), compute_tabs(.Timesheet),
		compute_tabs(.Statistics), lay.btn_prev, lay.btn_next, lay.btn_today, lay.btn_track,
		totals_mode_rect(lay), minus, plus, reset, lay.timeline_split, lay.totals_split}
	seen: u32
	for r in hot {
		bits := hover_targets(r.left, r.top, W, H)
		testing.expect(t, bits != 0 && bits & (bits - 1) == 0 && seen & bits == 0)
		seen |= bits
	}
	// Placeholder tabs draw only the tab strip.
	ui.tab = .Timesheet
	testing.expect(t, sig(snapshot, today.left + 2, today.top + 2) == Hover_Signature{})
	testing.expect(t, sig(snapshot, x_at(lay, 9.5), apps_y) == Hover_Signature{})
	testing.expect(t, sig(snapshot, 3, 3).targets != 0)
	ui.tab = .Day

	// A visible bar tooltip follows the cursor: every move repaints. The cursor
	// line is visible over the same lanes, with or without a bar beneath it.
	editor := sig(snapshot, x_at(lay, 9.5), apps_y)
	testing.expect(t, editor.bar != 0 && editor.cursor && snapshot.rows[editor.bar - 1].activity.id == 1)
	editor_next := sig(snapshot, x_at(lay, 9.5) + 1, apps_y)
	testing.expect(t, editor_next == editor && hover_needs_repaint(editor, editor_next))
	testing.expect(t, hover_needs_repaint(editor, empty_lane) && hover_needs_repaint(empty_lane, editor))
	// Between two bars, and between lanes.
	browser := sig(snapshot, x_at(lay, 10.5), apps_y)
	testing.expect(t, browser.bar != 0 && browser != editor && snapshot.rows[browser.bar - 1].activity.id == 2)
	usage := sig(snapshot, x_at(lay, 9.5), usage_y)
	testing.expect(t, usage.bar != 0 && snapshot.rows[usage.bar - 1].activity.id == 3)

	// The lazy window-side variant matches the pure one, snapshot or not.
	for p in ([4][2]i32{{x_at(lay, 9.5), apps_y}, {x_at(lay, 3), apps_y}, {today.left + 2, today.top + 2},
		{lay.chart_x + 40, lay.list_top + 60}}) {
		testing.expect(t, hover_signature_for_app(&app, p[0], p[1], W, H) == sig(snapshot, p[0], p[1]))
	}

	// The cursor line shares the tooltip's lane gate: hidden off-lane, while a
	// drag is active, and while the tag picker or its menu is open.
	list_sig := sig(snapshot, lay.chart_x + 40, lay.list_top + 60)
	testing.expect(t, !list_sig.cursor)
	testing.expect(t, !sig(snapshot, lay.chart_x + 40, lay.ruler_y + 2).cursor)
	tag_begin(.New_Range, 0)
	testing.expect(t, sig(snapshot, x_at(lay, 9.5), apps_y).bar == 0)
	testing.expect(t, !sig(snapshot, x_at(lay, 9.5), apps_y).cursor)
	interaction_end()
	tag_ui.menu_open = true
	testing.expect(t, sig(snapshot, x_at(lay, 9.5), apps_y).bar == 0)
	testing.expect(t, !sig(snapshot, x_at(lay, 9.5), apps_y).cursor)
	tag_ui.menu_open = false
	pane_begin(.Timeline_Height, 0)
	testing.expect(t, sig(snapshot, x_at(lay, 9.5), apps_y).bar == 0)
	testing.expect(t, !sig(snapshot, x_at(lay, 9.5), apps_y).cursor)
	interaction_end()

	// A settings window owns the cursor: the lanes underneath are not hovered.
	settings_ui.hwnd = transmute(windows.HWND)(uintptr(4))
	testing.expect(t, settings_popup_open())
	suppressed := sig(snapshot, x_at(lay, 9.5), apps_y)
	testing.expect(t, suppressed.bar == 0 && !suppressed.cursor)
	testing.expect(t, !hover_needs_repaint(Hover_Signature{}, suppressed))
	settings_ui.hwnd = nil

	// A visible date-picker popup owns the cursor; hidden, it does not.
	hi := windows.HINSTANCE(windows.GetModuleHandleW(nil))
	cal := windows.CreateWindowExW(0, wtext("STATIC"), nil, windows.WS_POPUP,
		0, 0, 1, 1, nil, nil, hi, nil)
	testing.expect(t, cal != nil)
	if cal != nil {
		defer windows.DestroyWindow(cal)
		ui.date_popup = cal
		defer { ui.date_popup = nil }
		testing.expect(t, !date_popup_open()) // created hidden
		testing.expect(t, sig(snapshot, x_at(lay, 9.5), apps_y).cursor)
		windows.ShowWindow(cal, windows.SW_SHOWNA)
		testing.expect(t, date_popup_open())
		cal_sig := sig(snapshot, x_at(lay, 9.5), apps_y)
		testing.expect(t, cal_sig.bar == 0 && !cal_sig.cursor)
		windows.ShowWindow(cal, windows.SW_HIDE)
		testing.expect(t, !date_popup_open())
		testing.expect(t, sig(snapshot, x_at(lay, 9.5), apps_y).cursor)
	}

	// The filter hides a bar's block rows but not the time hint or cursor line:
	// moves over the hidden bar still repaint to follow the cursor.
	ui.filter = "browser"
	hidden := sig(snapshot, x_at(lay, 9.5), apps_y)
	testing.expect(t, hidden.bar == 0 && hidden.cursor && tooltip_bar_hit(snapshot, x_at(lay, 9.5), apps_y, true, W, H) == -1)
	testing.expect(t, hover_needs_repaint(hidden, sig(snapshot, x_at(lay, 9.5) + 1, apps_y)))
	testing.expect(t, sig(snapshot, x_at(lay, 10.5), apps_y) == browser)
	testing.expect(t, hover_needs_repaint(hidden, browser))

	// draw_tooltip always paints a time hint over the lanes; the block rows
	// below it appear exactly when the signature reports a bar.
	screen := windows.GetDC(nil)
	testing.expect(t, screen != nil)
	if screen == nil { return }
	defer windows.ReleaseDC(nil, screen)
	dc := windows.CreateCompatibleDC(screen)
	testing.expect(t, dc != nil)
	if dc == nil { return }
	defer windows.DeleteDC(dc)
	bmp := windows.CreateCompatibleBitmap(screen, W, H)
	testing.expect(t, bmp != nil)
	if bmp == nil { return }
	defer windows.DeleteObject(windows.HGDIOBJ(bmp))
	old_bmp := windows.SelectObject(dc, windows.HGDIOBJ(bmp))
	defer windows.SelectObject(dc, old_bmp)
	ui.font_normal = ui_make_font(12, 400)
	ui.font_small = ui_make_font(11, 400)
	defer { windows.DeleteObject(windows.HGDIOBJ(ui.font_normal)); windows.DeleteObject(windows.HGDIOBJ(ui.font_small)) }
	BLANK :: windows.COLORREF(0x00030201)
	for p in ([4][3]i32{{x_at(lay, 9.5), apps_y, 0}, {x_at(lay, 10.5), apps_y, 1},
		{x_at(lay, 3), apps_y, 0}, {x_at(lay, 9.5), usage_y, 0}}) {
		fill_rect(dc, 0, 0, W, H, BLANK)
		ui.mouse, ui.mouse_valid = windows.POINT{p[0], p[1]}, true
		draw_tooltip(snapshot, dc, W, H)
		// Time row: inside even the one-row box, left of the text padding.
		testing.expect(t, GetPixel(dc, p[0] + 17, p[1] + 17) == C_TIP_BG)
		testing.expect(t, sig(snapshot, p[0], p[1]).cursor)
		// Block rows: a fourth row exists only for a bar hit.
		testing.expect(t, (GetPixel(dc, p[0] + 17, p[1] + 45) == C_TIP_BG) == (p[2] == 1))
		testing.expect(t, (p[2] == 1) == (sig(snapshot, p[0], p[1]).bar != 0))
	}

	// draw_cursor_line paints one accent pixel column exactly when the
	// signature reports the cursor, spanning ruler to lanes bottom.
	ui.filter = ""
	for p in ([3][2]i32{{x_at(lay, 3), apps_y}, {x_at(lay, 9.5), apps_y}, {lay.chart_x + 40, lay.list_top + 60}}) {
		fill_rect(dc, 0, 0, W, H, BLANK)
		ui.mouse, ui.mouse_valid = windows.POINT{p[0], p[1]}, true
		draw_cursor_line(dc, W, H)
		want := sig(snapshot, p[0], p[1]).cursor
		testing.expect(t, (GetPixel(dc, p[0], apps_y) == C_ACCENT) == want)
		testing.expect(t, (GetPixel(dc, p[0], lay.ruler_y + 2) == C_ACCENT) == want)
		testing.expect(t, GetPixel(dc, p[0] + 5, apps_y) == BLANK)
	}
}
