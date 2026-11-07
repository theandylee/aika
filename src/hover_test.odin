package main

import "core:sys/windows"
import "core:testing"

// Invoked serially by zoom_behavior: mutates the shared ui/tag_ui state.
hover_repaint_behavior :: proc(t: ^testing.T) {
	old := ui
	defer ui = old
	old_tags := tag_ui
	defer tag_ui = old_tags
	defer free_all(context.temp_allocator)
	ui = {}
	tag_ui = {}
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
	apps_y := lay.lane_y + 2 * (lay.lane_h + LANE_GAP) + lay.lane_h / 2
	usage_y := lay.lane_y + (lay.lane_h + LANE_GAP) + lay.lane_h / 2
	sig :: proc(s: Day_Snapshot, x, y: i32) -> Hover_Signature { return hover_signature(s, x, y, true, 1320, 860) }

	// Empty areas (inside the details list, empty lane time): no repaint.
	list_a := sig(snapshot, lay.chart_x + 40, lay.list_top + 60)
	list_b := sig(snapshot, lay.chart_x + 90, lay.list_top + 120)
	testing.expect(t, list_a == Hover_Signature{} && list_b == list_a)
	testing.expect(t, !hover_needs_repaint(list_a, list_b))
	empty_lane := sig(snapshot, x_at(lay, 3), apps_y)
	testing.expect(t, empty_lane.bar == 0)
	testing.expect(t, !hover_needs_repaint(empty_lane, sig(snapshot, x_at(lay, 4), apps_y + 3)))
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
	hot := [?]windows.RECT{theme_switch_rect(W), settings_switch_rect(W), compute_tabs(0), compute_tabs(1),
		compute_tabs(2), lay.btn_prev, lay.btn_next, lay.btn_today, lay.btn_track,
		totals_mode_rect(lay), minus, plus, reset, lay.timeline_split, lay.totals_split}
	seen: u32
	for r in hot {
		bits := hover_targets(r.left, r.top, W, H)
		testing.expect(t, bits != 0 && bits & (bits - 1) == 0 && seen & bits == 0)
		seen |= bits
	}
	// Placeholder tabs draw only the tab strip.
	ui.tab = 1
	testing.expect(t, sig(snapshot, today.left + 2, today.top + 2) == Hover_Signature{})
	testing.expect(t, sig(snapshot, x_at(lay, 9.5), apps_y) == Hover_Signature{})
	testing.expect(t, sig(snapshot, 3, 3).targets != 0)
	ui.tab = 0

	// A visible bar tooltip follows the cursor: every move repaints.
	editor := sig(snapshot, x_at(lay, 9.5), apps_y)
	testing.expect(t, editor.bar != 0 && snapshot.rows[editor.bar - 1].activity.id == 1)
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

	// Drags, the tag picker and context menu suppress the tooltip as draw_tooltip does.
	tag_ui.drag = 1
	testing.expect(t, sig(snapshot, x_at(lay, 9.5), apps_y).bar == 0)
	tag_ui.drag = 0
	tag_ui.menu_open = true
	testing.expect(t, sig(snapshot, x_at(lay, 9.5), apps_y).bar == 0)
	tag_ui.menu_open = false
	ui.pane_drag = 1
	testing.expect(t, sig(snapshot, x_at(lay, 9.5), apps_y).bar == 0)
	ui.pane_drag = 0

	// The filter hides a bar's tooltip: no tooltip and no follow-the-cursor repaints.
	ui.filter = "browser"
	hidden := sig(snapshot, x_at(lay, 9.5), apps_y)
	testing.expect(t, hidden.bar == 0 && tooltip_bar_hit(snapshot, x_at(lay, 9.5), apps_y, true, W, H) == -1)
	testing.expect(t, !hover_needs_repaint(hidden, sig(snapshot, x_at(lay, 9.5) + 1, apps_y)))
	testing.expect(t, sig(snapshot, x_at(lay, 10.5), apps_y) == browser)
	testing.expect(t, hover_needs_repaint(hidden, browser))

	// draw_tooltip paints a box exactly when the signature reports a bar.
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
		shown := GetPixel(dc, p[0] + 17, p[1] + 17) == C_TIP_BG
		testing.expect(t, shown == (p[2] == 1))
		testing.expect(t, shown == (sig(snapshot, p[0], p[1]).bar != 0))
	}
}
