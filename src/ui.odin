package main

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sys/windows"

// ManicTime-style Day view, drawn with GDI into the winui backbuffer.
// Switchable light/dark theme, full 24h axis, three timeline lanes (Tags / Computer Usage /
// Applications), details list + totals panel below.
//
// Memory note: everything allocated during a paint uses context.temp_allocator
// and is released when its owning native callback returns (even inside a modal
// loop); no derived view data is cached between frames. Measured on a 900-row
// day, deriving rows/totals is ~0.2 ms of a ~4-6 ms frame: GDI calls dominate.

// Palette colors (C_*) live in palette.odin.

TAB_H     :: 26
TOOLBAR_H :: 52
RULER_H   :: 24
LANE_GAP  :: 4
LIST_HDR  :: 22
LIST_ROW  :: 20
FILTER_H  :: 30
STATUS_H  :: 22
SIDEBAR_W :: 320
MARGIN    :: 8
SPLITTER_W :: 8
MIN_LANE_H :: 44
MIN_LOWER_H :: 100
MIN_LIST_W :: 300
MIN_TOTALS_W :: 180
DATE_PICK_W :: 232 // weekday/date button with calendar icon

// --- Layout ---

Layout :: struct {
	w, h:          i32,
	toolbar_y:     i32,
	ruler_y:       i32,
	chart_x:       i32,
	chart_w:       i32,
	lane_y:        i32,
	lane_h:        i32,
	lanes_bottom:  i32,
	zoom_y:        i32,
	list_top:      i32,
	list_bottom:   i32, // exclusive; header row sits at the top
	sidebar_x:     i32,
	sidebar_w:     i32,
	filter_y:      i32,
	filter_edit_x, filter_edit_y: i32,
	filter_edit_w, filter_edit_h: i32,
	status_y:      i32,
	timeline_split, totals_split: windows.RECT,
	btn_prev:      windows.RECT,
	btn_next:      windows.RECT,
	date_pick:     windows.RECT,
	btn_today:     windows.RECT,
	btn_track:     windows.RECT,
	day_boxes:     [3]windows.RECT,
}

compute_layout :: proc(w, h: i32) -> Layout {
	lay: Layout
	lay.w = w
	lay.h = h
	bottom_limit := h - FILTER_H - STATUS_H

	lay.toolbar_y = TAB_H
	lay.ruler_y = TAB_H + TOOLBAR_H
	lay.chart_x = MARGIN
	lay.chart_w = w - MARGIN * 2 - 1

	// Start with the original layout; user sizes are clamped, not overwritten,
	// when the window shrinks so they return when it grows again.
	lane_area := bottom_limit - (lay.ruler_y + RULER_H) - 120 - LIST_HDR - 2 * LANE_GAP - ZOOM_H
	wanted_lane_h := ui.pane_lane_h
	if wanted_lane_h == 0 { wanted_lane_h = min(96, max(MIN_LANE_H, lane_area / 3)) }
	max_lane_h := max(MIN_LANE_H, (bottom_limit - (lay.ruler_y + RULER_H) -
		2 * LANE_GAP - ZOOM_LANES_GAP - ZOOM_H - SPLITTER_W - MIN_LOWER_H) / 3)
	lay.lane_h = clamp(wanted_lane_h, MIN_LANE_H, max_lane_h)
	lay.lane_y = lay.ruler_y + RULER_H
	lay.lanes_bottom = lay.lane_y + 3 * lay.lane_h + 2 * LANE_GAP
	lay.zoom_y = lay.lanes_bottom + ZOOM_LANES_GAP
	lay.list_top = lay.zoom_y + ZOOM_H + SPLITTER_W
	lay.list_bottom = bottom_limit
	wanted_totals_w := ui.pane_totals_w
	if wanted_totals_w == 0 { wanted_totals_w = SIDEBAR_W }
	lay.sidebar_w = clamp(wanted_totals_w, MIN_TOTALS_W,
		max(MIN_TOTALS_W, lay.chart_w - SPLITTER_W - MIN_LIST_W))
	lay.sidebar_x = lay.chart_x + lay.chart_w - lay.sidebar_w
	lay.timeline_split = windows.RECT{lay.chart_x, lay.list_top - SPLITTER_W,
		lay.chart_x + lay.chart_w, lay.list_top}
	lay.totals_split = windows.RECT{lay.sidebar_x - SPLITTER_W, lay.list_top,
		lay.sidebar_x, lay.list_bottom}

	lay.filter_y = bottom_limit
	lay.filter_edit_x = 56
	lay.filter_edit_y = bottom_limit + 4
	lay.filter_edit_w = w - 56 - 16
	lay.filter_edit_h = FILTER_H - 8
	lay.status_y = h - STATUS_H

	btn_h := TOOLBAR_BTN_H
	btn_y := lay.toolbar_y + 12
	lay.btn_prev = windows.RECT{left = MARGIN, top = btn_y, right = MARGIN + 26, bottom = btn_y + btn_h}
	lay.btn_today = windows.RECT{left = MARGIN + 30, top = btn_y, right = MARGIN + 98, bottom = btn_y + btn_h}
	lay.btn_next = windows.RECT{left = MARGIN + 102, top = btn_y, right = MARGIN + 128, bottom = btn_y + btn_h}
	lay.date_pick = windows.RECT{left = MARGIN + 140, top = btn_y, right = MARGIN + 140 + DATE_PICK_W, bottom = btn_y + btn_h}
	lay.btn_track = windows.RECT{left = MARGIN + 148 + DATE_PICK_W, top = btn_y, right = MARGIN + 280 + DATE_PICK_W, bottom = btn_y + btn_h}

	// Day start / day end / duration boxes anchored to the right.
	day_box_w := min(i32(108), (w - lay.btn_track.right - 24) / 3 - 4)
	day_box_h := i32(36)
	day_box_y := lay.toolbar_y + 8
	day_box_x := w - MARGIN - day_box_w
	for i := 2; i >= 0; i -= 1 {
		lay.day_boxes[i] = windows.RECT{left = day_box_x, top = day_box_y, right = day_box_x + day_box_w, bottom = day_box_y + day_box_h}
		day_box_x -= day_box_w + 4
	}
	return lay
}

compute_tabs :: proc(tab: Tab) -> windows.RECT {
	txs := [Tab]i32{.Day = 2, .Timesheet = 58, .Statistics = 148}
	tws := [Tab]i32{.Day = 54, .Timesheet = 88, .Statistics = 92}
	return windows.RECT{left = txs[tab], top = 0, right = txs[tab] + tws[tab], bottom = TAB_H}
}

tab_name :: proc(tab: Tab) -> string {
	switch tab {
	case .Day: return "Day"
	case .Timesheet: return "Timesheet"
	case .Statistics: return "Statistics"
	}
	return "Day"
}

lane_name :: proc(lane: Lane) -> string {
	switch lane {
	case .Tags: return "Tags"
	case .Computer: return "Computer Usage"
	case .Apps: return "Applications"
	}
	return ""
}

lane_timeline :: proc(lane: Lane) -> i64 {
	switch lane {
	case .Tags: return TIMELINE_TAGS
	case .Computer: return TIMELINE_COMPUTER
	case .Apps: return TIMELINE_APPS
	}
	return 0
}

// Top edge of a lane's rectangle; lanes are stacked with LANE_GAP between them.
lane_top :: proc(lay: Layout, lane: Lane) -> i32 {
	return lay.lane_y + i32(lane) * (lay.lane_h + LANE_GAP)
}

// --- Formatting ---

fmt_hm :: proc(ms: i64) -> string {
	st := unix_ms_to_local(max(0, ms))
	return fmt.tprintf("%d:%02d", st.hour, st.minute)
}

fmt_clock_hm :: proc(ms: i64) -> string {
	st := unix_ms_to_local(ms)
	return fmt.tprintf("%02d:%02d", st.hour, st.minute)
}

fmt_span_hm :: proc(ms: i64) -> string {
	mins := max(0, ms) / 60000
	return fmt.tprintf("%d:%02d", mins / 60, mins % 60)
}

fmt_hms :: proc(ms: i64) -> string {
	v := max(0, ms)
	return fmt.tprintf("%d:%02d:%02d", v / 3_600_000, (v / 60_000) % 60, (v / 1000) % 60)
}

// --- Top-level frame ---

draw_frame :: proc(app: ^App, dc: windows.HDC, w, h: i32) {
	ui_sync_day_controls()
	snapshot := build_day_snapshot(app, tracker_now(app), tracker_monotonic(app))
	windows.SetBkMode(dc, windows.BKMODE.TRANSPARENT)
	if ui.scroll_date != app.date {
		ui.scroll_date = app.date
		ui.list_scroll.pos = 0
		ui.totals_scroll.pos = 0
	}
	if ui.tab != .Day {
		pane_scroll_show(&ui.list_scroll, false)
		pane_scroll_show(&ui.totals_scroll, false)
	}
	fill_rect(dc, 0, 0, w, h, C_BG)
	switch ui.tab {
	case .Day:
		draw_day(app, snapshot, dc, w, h)
	case .Timesheet:
		draw_placeholder(dc, w, h, "Timesheet", "Timesheets are not implemented yet (see docs/ROADMAP.md).")
	case .Statistics:
		draw_placeholder(dc, w, h, "Statistics", "Statistics are not implemented yet (see docs/ROADMAP.md).")
	}
	draw_filter_row(dc, w, h)
	draw_status_bar(app, dc, w, h)
	if ui.tab == .Day {
		draw_tooltip(snapshot, dc, w, h)
	}
	draw_theme_tooltip(dc, w)
	draw_settings_tooltip(dc, w)
	draw_totals_mode_tooltip(dc, compute_layout(w, h))
	ui.hover_painted = hover_signature(snapshot, ui.mouse.x, ui.mouse.y, ui.mouse_valid, w, h)
}

draw_placeholder :: proc(dc: windows.HDC, w, h: i32, title, note: string) {
	draw_tabs(dc)
	draw_toolbar_background_rect(dc, 0, TAB_H, w, h - TAB_H - FILTER_H - STATUS_H)
	draw_string(dc, title, w / 2 - 120, h / 2 - 60, ui.font_title, C_TXT)
	draw_string(dc, note, w / 2 - 190, h / 2, ui.font_normal, C_DIM)
}

// Fills the main content area between the tabs and the filter row.
draw_toolbar_background_rect :: proc(dc: windows.HDC, x, y, w, h: i32) {
	fill_rect(dc, x, y, w, h, C_PANEL)
}

draw_tabs :: proc(dc: windows.HDC) {
	w := ui.mem_w
	fill_rect(dc, 0, 0, w, TAB_H, C_TAB_BG)
	line_h(dc, 0, TAB_H - 1, w, C_BORDER_SOFT)
	draw_theme_switch(dc, w)
	draw_settings_switch(dc, w)
	for tab in Tab {
		t := compute_tabs(tab)
		active := ui.tab == tab
		state := i32(3) if active else i32(1) // TIS_SELECTED / TIS_NORMAL
		if !active && ui.mouse_valid && rect_hit(t, ui.mouse.x, ui.mouse.y) {
			state = 2 // TIS_HOT
		}
		if draw_themed_control(dc, ui.theme_tab, 1, state, t, tab_name(tab)) {
			continue
		}
		bg: windows.COLORREF = C_TAB_ACTIVE if active else C_TAB_BG
		if !active && ui.mouse_valid && rect_hit(t, ui.mouse.x, ui.mouse.y) {
			bg = C_BTN_HOVER
		}		fill_rect(dc, t.left + 1, t.top, t.right - t.left - 1, TAB_H, bg)
		if active {
			line_h(dc, t.left + 1, t.top, t.right - t.left - 2, C_ACCENT)
		}
		fill_frame(dc, t.left, t.top + 1, t.right - t.left, TAB_H - 1, C_BORDER_SOFT)
		tw := text_pixel_width(tab_name(tab), ui.font_normal)
		draw_string(dc, tab_name(tab),
			t.left + (t.right - t.left - tw) / 2, t.top + 6,
			ui.font_normal, C_TXT if active else C_DIM)
	}
}

// --- Toolbar (date navigation + day start/end/duration) ---

draw_toolbar :: proc(app: ^App, snapshot: Day_Snapshot, dc: windows.HDC, lay: Layout) {
	draw_toolbar_background_rect(dc, 0, lay.toolbar_y, lay.w, TOOLBAR_H)
	draw_button(dc, lay.btn_prev, "<", .Btn_Prev)
	draw_button(dc, lay.btn_next, ">", .Btn_Next)
	draw_button(dc, lay.btn_today, "Today", .Btn_Today)

	label := "Start task"
	if app.task.id != 0 { label = fmt.tprintf("Stop task  %s", fmt_hms(app.task.end_ms - app.task.start_ms)) }
	draw_button(dc, lay.btn_track, label, .Btn_Task)

	// Day start / day end / duration, ManicTime-style.
	min_ms, max_ms := day_span(snapshot)
	captions := [3]string{"Day start", "Day end", "Duration"}
	values := [3]string{fmt_hm(min_ms), fmt_hm(max_ms), fmt_span_hm(max_ms - min_ms)}
	if max_ms <= min_ms {
		values = [3]string{"-:--", "-:--", "0:00"}
	}
	for i := 0; i < 3; i += 1 {
		b := lay.day_boxes[i]
		box_w := b.right - b.left
		box_h := b.bottom - b.top
		fill_rect(dc, b.left + 1, b.top + 1, box_w - 2, box_h - 2, C_PANEL)
		fill_frame(dc, b.left, b.top, box_w, box_h, C_BTN_BORDER)
		draw_string(dc, captions[i], b.left + 8, b.top + 3, ui.font_small, C_DIM)
		draw_string(dc, values[i], b.left + 8, b.top + 18, ui.font_bold, C_TXT)
	}
}

// Day span across both tracked lanes, clamped to the selected date.
day_span :: proc(snapshot: Day_Snapshot) -> (min_ms, max_ms: i64) {
	min_ms = snapshot.day_end
	max_ms = snapshot.day_start
	for row in snapshot.rows {
		a := row.activity
		if a.timeline_id != TIMELINE_COMPUTER && a.timeline_id != TIMELINE_APPS {
			continue
		}
		min_ms = min(min_ms, row.start_ms)
		max_ms = max(max_ms, row.end_ms)
	}
	if min_ms > max_ms {
		min_ms, max_ms = snapshot.day_end, snapshot.day_start
	}
	return
}

draw_button :: proc(dc: windows.HDC, r: windows.RECT, label: string, hit: Hit) {
	hot := ui.mouse_valid && rect_hit(r, ui.mouse.x, ui.mouse.y)
	state := i32(1) // PBS_NORMAL
	if hot {
		state = 3 if press_hit() == hit else 2 // PBS_PRESSED / PBS_HOT
	}
	if draw_themed_control(dc, ui.theme_button, 1, state, r, label) { return }
	w := r.right - r.left
	h := r.bottom - r.top
	bg: windows.COLORREF = C_BTN_FACE
	if ui.mouse_valid && rect_hit(r, ui.mouse.x, ui.mouse.y) {
		bg = C_BORDER_SOFT if press_hit() == hit else C_BTN_HOVER
	}
	fill_rect(dc, r.left + 1, r.top + 1, w - 2, h - 2, bg)
	fill_frame(dc, r.left, r.top, w, h, C_BTN_BORDER)
	draw_button_text(dc, label, r)
}

// --- Day view ---

draw_day :: proc(app: ^App, snapshot: Day_Snapshot, dc: windows.HDC, w, h: i32) {
	lay := compute_layout(w, h)
	draw_tabs(dc)
	draw_toolbar(app, snapshot, dc, lay)

	day_start, day_end := snapshot.day_start, snapshot.day_end
	view_start, view_end := zoom_bounds(day_start, day_end)

	// Ruler
	draw_toolbar_background_rect(dc, lay.chart_x, lay.ruler_y, lay.chart_w, RULER_H)
	step := zoom_tick_step(view_start, view_end, lay.chart_w)
	first_tick := day_start + ((view_start - day_start + step - 1) / step) * step
	for tick := first_tick; tick <= view_end; tick += step {
		x := x_for_ms(tick, view_start, view_end, lay.chart_x, lay.chart_w)
		s := fmt_clock_hm(tick)
		if tick >= day_end { s = "24:00" }
		tw := text_pixel_width(s, ui.font_small)
		draw_string(dc, s, clamp(x - tw / 2, lay.chart_x, lay.chart_x + lay.chart_w - tw),
			lay.ruler_y + 6, ui.font_small, C_DIM)
	}

	// Lanes
	for lane in Lane {
		r := lane_rect(lay, lane)
		draw_lane(snapshot, dc, lay, lane, r.left, r.top, r.right - r.left, r.bottom - r.top, view_start, view_end)
	}

	// Now marker (today only)
	if snapshot.now >= view_start && snapshot.now < view_end {
		nx := x_for_ms(snapshot.now, view_start, view_end, lay.chart_x, lay.chart_w)
		line_v(dc, nx, lay.ruler_y, lay.lanes_bottom - lay.ruler_y, C_RED)
	}

	// Details list + totals
	draw_zoom_bar(snapshot, dc, lay, day_start, day_end)
	draw_list(snapshot, dc, lay)
	draw_totals(snapshot, dc, lay)
	draw_pane_splitters(dc, lay)
}

// fraction of the day, 0..1
day_frac :: proc(ms, day_start, day_end: i64) -> f64 {
	if day_end <= day_start { return 0 }
	f := f64(ms - day_start) / f64(day_end - day_start)
	return min(1.0, max(0.0, f))
}

x_for_ms :: proc(ms, day_start, day_end: i64, x, w: i32) -> i32 {
	return x + i32(day_frac(ms, day_start, day_end) * f64(w))
}

activity_colorref :: proc(a: Activity) -> Colorref {
	c := a.color
	if argb_is_unset(c) {
		index := a.group_id % i64(len(GROUP_COLORS))
		if index < 0 { index = -index } // synthetic unresolved usage identities
		c = GROUP_COLORS[int(index)]
	}
	return argb_to_colorref(c)
}

draw_lane :: proc(snapshot: Day_Snapshot, dc: windows.HDC, lay: Layout, lane: Lane, x, y, w, h: i32, day_start, day_end: i64) {
	fill_rect(dc, x, y, w, h, C_LANE_BG)
	step := zoom_tick_step(day_start, day_end, w)
	local_start := snapshot.day_start
	first_tick := local_start + ((day_start - local_start + step - 1) / step) * step
	for tick := first_tick; tick < day_end; tick += step {
		line_v(dc, x_for_ms(tick, day_start, day_end, x, w), y, h, C_LANE_GRID)
	}
	draw_string(dc, lane_name(lane), x + 10, y + h / 2 - 9, ui.font_normal,
		C_DIM if ui.lane == lane else C_LANE_TXT)

	tl := lane_timeline(lane)
	if tl != 0 {
		draw_lane_bars(snapshot, dc, lane, tl, x, y, w, h, day_start, day_end)
	}

	border := windows.COLORREF(C_BORDER)
	if ui.lane == lane {
		border = C_ACCENT
		border_w := i32(2)
		fill_rect(dc, x, y, w, border_w, C_ACCENT)
		fill_rect(dc, x, y + h - border_w, w, border_w, C_ACCENT)
		fill_rect(dc, x, y, border_w, h, C_ACCENT)
		fill_rect(dc, x + w - border_w, y, border_w, h, C_ACCENT)
	}
	fill_frame(dc, x, y, w, h, border)
}

// Coalesces a left-to-right run of same-height bars without changing pixels:
// a pending bar fully covered by the next one is dropped (it would be painted
// over), and contiguous same-color bars merge. Flush before any other drawing.
Bar_Run :: struct {
	dc: windows.HDC,
	y, h: i32,
	x1, x2: i32,
	color: windows.COLORREF,
	pending: bool,
	fills: int, // painted rectangles, for measurements/tests
}

bar_run_add :: proc(run: ^Bar_Run, x1, w: i32, color: windows.COLORREF) {
	x2 := x1 + w
	if run.pending {
		if x1 <= run.x1 && x2 >= run.x2 {
			run.x1, run.x2, run.color = x1, x2, color
			return
		}
		if color == run.color && x1 >= run.x1 && x1 <= run.x2 {
			run.x2 = max(run.x2, x2)
			return
		}
		bar_run_flush(run)
	}
	run.x1, run.x2, run.color, run.pending = x1, x2, color, true
}

bar_run_flush :: proc(run: ^Bar_Run) {
	if !run.pending { return }
	fill_rect(run.dc, run.x1, run.y, run.x2 - run.x1, run.h, run.color)
	run.fills += 1
	run.pending = false
}

bar_rect_for_lane :: proc(lane: Lane, x, y, w, h: i32) -> windows.RECT {
	return windows.RECT{left = x, top = y, right = x + w, bottom = y + h}
}

draw_lane_bars :: proc(snapshot: Day_Snapshot, dc: windows.HDC, lane: Lane, tl: i64, x, y, w, h: i32, day_start, day_end: i64) {
	br := bar_rect_for_lane(lane, x, y, w, h)
	bar_h := br.bottom - br.top
	bar_y := br.top
	run := Bar_Run{dc = dc, y = bar_y, h = bar_h}

	for row in snapshot.rows {
		a := row.activity
		if a.timeline_id != tl {
			continue
		}
		s := max(row.start_ms, day_start)
		e := min(row.end_ms, day_end)
		if tl == TIMELINE_TAGS && tag_drag_is_edge(tag_drag()) && a.id == tag_ui.id {
			s, e = max(tag_ui.start_ms, day_start), min(tag_ui.end_ms, day_end)
		}
		if e <= s {
			continue
		}
		x1 := x_for_ms(s, day_start, day_end, x, w)
		x2 := x_for_ms(e, day_start, day_end, x, w)
		bw := max(1, x2 - x1)
		color := activity_colorref(a)
		if tl == TIMELINE_COMPUTER && a.group_name == "Active" {
			color = C_GREEN
		}
		if tl == TIMELINE_COMPUTER && a.group_name == "Away" { color = C_ORANGE }
		bar_run_add(&run, x1, bw, color)
		if !row.live && tl != TIMELINE_TAGS { continue }
		// Decorated bars paint over their fill immediately.
		bar_run_flush(&run)
		if row.live { fill_frame(dc, x1, bar_y, bw, bar_h, C_LIVE_FRAME) }
		if tl == TIMELINE_TAGS {
			fill_frame(dc, x1, bar_y, bw, bar_h, C_BORDER)
			draw_string(dc, a.display_name, x1 + 6, bar_y + 8, ui.font_bold, bar_text_color(color), bw - 12)
			line_v(dc, x1 + 2, bar_y + bar_h / 2 - 5, 10, C_PANEL)
			if bw > 6 { line_v(dc, x2 - 3, bar_y + bar_h / 2 - 5, 10, C_PANEL) }
		}
	}
	bar_run_flush(&run)
	if tl == TIMELINE_TAGS && (tag_drag() == .New_Range || (tag_ui.popup != nil && !tag_ui.task_picker)) {
		lay := compute_layout(ui.mem_w, ui.mem_h)
		tag_draw_range(dc, lay, day_start, day_end)
	}

}

// --- Details list (bottom left) ---

ListRow :: struct {
	group_id:   i64,
	name:       string, // points into activity data or temp storage
	start_ms:   i64,
	end_ms:     i64,
	full_start_ms, full_end_ms: i64,
	color:      Argb,
	is_current: bool,
}

TotRow :: struct {
	group_id: i64,
	name:     string,
	color:    Argb,
	ms:       i64,
}

snapshot_filter_matches :: proc(name, filter: string) -> bool {
	if len(filter) == 0 {
		return true
	}
	// Scratch, not heap: every candidate row is lowered on every repaint.
	return strings.contains(strings.to_lower(name, context.temp_allocator), filter)
}

filter_matches :: proc(name: string) -> bool { return snapshot_filter_matches(name, ui.filter) }

// Builds the row list for the selected lane. Allocated with the temp
// allocator: released by the owning native callback's scratch scope.
build_rows :: proc(snapshot: Day_Snapshot, tl: i64, filter: string = "") -> []ListRow {
	if tl == 0 {
		return nil
	}
	rows := make([dynamic]ListRow, 0, 64, context.temp_allocator)
	for row in snapshot.rows {
		a := row.activity
		if a.timeline_id != tl {
			continue
		}
		name := a.display_name
		if tl == TIMELINE_COMPUTER && len(a.group_name) > 0 {
			name = a.group_name
		}
		if !snapshot_filter_matches(name, filter) {
			continue
		}
		append(&rows, ListRow{
			group_id = a.group_id,
			name     = name,
			start_ms = row.start_ms,
			end_ms   = row.end_ms,
			full_start_ms = a.start_ms,
			full_end_ms = a.end_ms,
			color    = a.color,
			is_current = row.live,
		})
	}
	return rows[:]
}

draw_list :: proc(snapshot: Day_Snapshot, dc: windows.HDC, lay: Layout) {
	pane := list_pane_rect(lay)
	x := pane.left
	w := pane.right - pane.left

	fill_rect(dc, x, pane.top, w, pane.bottom - pane.top, C_PANEL)
	rows := build_rows(snapshot, lane_timeline(ui.lane), ui.filter)
	visible := list_rows_visible(lay)
	w -= pane_scroll_update(&ui.list_scroll, i32(len(rows)), visible,
		x + w, list_rows_top(lay), lay.list_bottom)
	skip := ui.list_scroll.pos

	// Header
	fill_rect(dc, x, lay.list_top, w, LIST_HDR, C_HEAD_BG)
	fill_frame(dc, x, lay.list_top, w, LIST_HDR, C_BORDER_SOFT)
	cols := list_columns(x, w)
	draw_string(dc, "Title", x + 8, lay.list_top + 4, ui.font_normal, C_TXT, cols.start - x - 16)
	draw_string(dc, "Start", cols.start + 4, lay.list_top + 4, ui.font_normal, C_DIM, 60)
	draw_string(dc, "End", cols.end + 4, lay.list_top + 4, ui.font_normal, C_DIM, 60)
	draw_string(dc, "Duration", cols.duration + 4, lay.list_top + 4, ui.font_normal, C_DIM, 60)

	tl := lane_timeline(ui.lane)
	if tl == 0 {
		msg := "No tags recorded yet." if ui.lane == .Tags else "No data for this lane."
		draw_string(dc, msg, x + 8, list_rows_top(lay) + 8, ui.font_normal, C_DIM)
		return
	}

	if len(rows) == 0 {
		draw_string(dc, "No activity recorded for this day.", x + 8, list_rows_top(lay) + 8, ui.font_normal, C_DIM)
		return
	}

	n_rows := i32(len(rows))
	for i := skip; i < n_rows && i < skip + visible; i += 1 {
		row := rows[i]
		ry := list_rows_top(lay) + i32(i - skip) * LIST_ROW
		fill_rect(dc, x, ry, w, LIST_ROW, C_ROW_ALT if (i - skip) % 2 == 1 else C_PANEL)
		color := activity_colorref(Activity{group_id = row.group_id, color = row.color})
		fill_rect(dc, x + 2, ry + 4, 4, LIST_ROW - 8, color)
		draw_string(dc, row.name, x + 10, ry + 3, ui.font_normal, C_TXT, cols.start - x - 18)
		draw_string(dc, fmt_snapshot_clock(snapshot, row.start_ms), cols.start + 4, ry + 3, ui.font_normal, C_DIM, 60)
		draw_string(dc, fmt_snapshot_clock(snapshot, row.end_ms), cols.end + 4, ry + 3, ui.font_normal, C_DIM, 60)
		draw_string(dc, fmt_span_hm(row.end_ms - row.start_ms), cols.duration + 4, ry + 3, ui.font_normal, C_DIM, 60)
	}
}

// --- Totals panel (bottom right) ---

build_totals :: proc(snapshot: Day_Snapshot, tl: i64) -> []TotRow {
	if tl == 0 {
		return nil
	}
	m := make(map[i64]TotRow)
	defer delete(m)
	for row in snapshot.rows {
		a := row.activity
		if a.timeline_id != tl {
			continue
		}
		name := a.group_name
		if len(name) == 0 {
			name = a.display_name
		}
		entry, ok := m[a.group_id]
		if !ok {
			entry = TotRow{group_id = a.group_id, name = name, color = a.color}
		}
		entry.ms += row.end_ms - row.start_ms
		m[a.group_id] = entry
	}
	list := make([dynamic]TotRow, 0, len(m))
	for _, v in m {
		append(&list, v)
	}
	slice.sort_by(list[:], proc(a, b: TotRow) -> bool { return a.ms > b.ms })
	return list[:]
}

draw_totals :: proc(snapshot: Day_Snapshot, dc: windows.HDC, lay: Layout) {
	x := lay.sidebar_x
	w := lay.sidebar_w
	total_h := lay.list_bottom - lay.list_top

	fill_rect(dc, x, lay.list_top, w, total_h, C_PANEL)
	fill_frame(dc, x, lay.list_top, w, total_h, C_BORDER_SOFT)

	totals := build_totals(snapshot, lane_timeline(ui.lane))
	defer free_totals_slice(totals)

	total_ms: i64
	for t in totals {
		total_ms += t.ms
	}

	draw_string(dc, "Totals", x + 8, lay.list_top + 6, ui.font_bold, C_TXT)
	draw_totals_mode(dc, lay)
	line_h(dc, x + 1, lay.list_top + 24, w - 2, C_BORDER_SOFT)

	visible := totals_rows_visible(lay)
	tree_rows: []^Totals_Node
	row_count := len(totals)
	if ui.totals_tree {
		tree_rows = totals_tree_rows(totals)
		row_count = len(tree_rows)
	}
	bar_w := pane_scroll_update(&ui.totals_scroll, i32(row_count), visible,
		x + w - 1, totals_rows_top(lay), totals_scroll_bottom(lay))
	row_w := w - bar_w
	skip := ui.totals_scroll.pos

	y := totals_rows_top(lay)
	n_totals := i32(row_count)
	for i := skip; i < n_totals && i < skip + visible; i += 1 {
		if ui.totals_tree {
			draw_totals_tree_row(dc, tree_rows[i], x, y, row_w)
			y += LIST_ROW
			continue
		}
		t := totals[i]
		color := argb_to_colorref(t.color)
		if color == 0 {
			color = activity_colorref(Activity{group_id = t.group_id})
		}
		fill_rect(dc, x + 8, y + 4, 10, 10, color)
		draw_string(dc, t.name, x + 24, y + 2, ui.font_normal, C_TXT, row_w - 90)
		dur := fmt_span_hm(t.ms)
		dw := text_pixel_width(dur, ui.font_normal)
		draw_string(dc, dur, x + row_w - 8 - dw, y + 2, ui.font_normal, C_DIM)
		y += LIST_ROW
	}

	// Total line pinned to the bottom.
	draw_string(dc, "Total:", x + 8, totals_footer_y(lay), ui.font_bold, C_TXT)
	tval := fmt_hms(total_ms)
	tv_w := text_pixel_width(tval, ui.font_bold)
	draw_string(dc, tval, x + w - 8 - tv_w, totals_footer_y(lay), ui.font_bold, C_TXT)
}

// list was made with the default allocator (defer-safe delete).
free_totals_slice :: proc(list: []TotRow) {
	if len(list) > 0 {
		delete(list)
	}
}

// --- Filter row + status bar ---

draw_filter_row :: proc(dc: windows.HDC, w, h: i32) {
	lay := compute_layout(w, h)
	fill_rect(dc, 0, lay.filter_y, w, FILTER_H, C_BG)
	draw_string(dc, "Filter", 12, lay.filter_edit_y + 4, ui.font_normal, C_DIM)
	// The EDIT child control draws itself between x=56 and the right edge.
}

draw_status_bar :: proc(app: ^App, dc: windows.HDC, w, h: i32) {
	lay := compute_layout(w, h)
	fill_rect(dc, 0, lay.status_y, w, STATUS_H, C_PANEL)
	line_h(dc, 0, lay.status_y, w, C_BORDER)

	st: windows.SYSTEMTIME
	GetLocalTime(&st)
	clock := fmt.tprintf("%02d.%02d.%04d %02d:%02d:%02d", st.day, st.month, st.year, st.hour, st.minute, st.second)
	draw_string(dc, clock, 8, lay.status_y + 4, ui.font_normal, C_TXT)

	dot: Colorref = C_GREEN if app.tracker.enabled else C_TRACKER_OFF
	dot_x := 8 + text_pixel_width(clock, ui.font_normal) + 6
	fill_rect(dc, dot_x, lay.status_y + 7, 8, 8, dot)
	status := app_storage_status(app)
	if status != "" {
		fill_rect(dc, dot_x, lay.status_y + 7, 8, 8, C_ORANGE)
		draw_string(dc, status, dot_x + 16, lay.status_y + 4, ui.font_normal, C_TXT, w - dot_x - 24)
	}
}

// --- Hit testing ---

rect_hit :: proc(r: windows.RECT, x, y: i32) -> bool {
	return x >= r.left && x < r.right && y >= r.top && y < r.bottom
}

hit_test :: proc(x, y, w, h: i32) -> Hit {
	if rect_hit(theme_switch_rect(w), x, y) { return .Theme }
	if rect_hit(settings_switch_rect(w), x, y) { return .Settings }
	for tab in Tab {
		if rect_hit(compute_tabs(tab), x, y) {
			return hit_tab(tab)
		}
	}
	// Placeholder tabs draw only the shared tab/theme/settings strip.
	if ui.tab != .Day { return .None }
	lay := compute_layout(w, h)
	if ui.tab == .Day {
		if rect_hit(totals_mode_rect(lay), x, y) { return .Totals_Tree }
		if ui.totals_tree && rect_hit(totals_rows_rect(lay), x, y) { return .Totals_Row }
		_, minus, plus, reset := zoom_rects(lay)
		if rect_hit(minus, x, y) { return .Zoom_Out }
		if rect_hit(plus, x, y) { return .Zoom_In }
		if rect_hit(reset, x, y) { return .Zoom_Reset }
	}
	if lane, in_lane := lane_at(lay, x, y); in_lane { return hit_lane(lane) }
	if rect_hit(lay.btn_prev, x, y) { return .Btn_Prev }
	if rect_hit(lay.btn_next, x, y) { return .Btn_Next }
	if rect_hit(lay.btn_today, x, y) { return .Btn_Today }
	if rect_hit(lay.btn_track, x, y) { return .Btn_Task }
	return .None
}

// --- Tooltip ---

// Lane whose bar rectangle contains the point while a bar tooltip may show
// (ok = false otherwise). Shared by draw_tooltip and hover tracking (hover.odin).
tooltip_lane :: proc(x, y: i32, valid: bool, w, h: i32) -> (lane: Lane, ok: bool) {
	if !valid || ui.tab != .Day || interaction_active() || tag_ui.popup != nil || tag_ui.menu_open { return }
	lay := compute_layout(w, h)
	candidate, in_lane := lane_at(lay, x, y)
	if !in_lane { return }
	br := bar_rect_for_lane(candidate, lay.chart_x, lane_top(lay, candidate), lay.chart_w, lay.lane_h)
	if y < br.top || y >= br.bottom { return }
	return candidate, true
}

tooltip_title :: proc(a: Activity) -> string {
	if a.timeline_id == TIMELINE_COMPUTER && len(a.group_name) > 0 { return a.group_name }
	return a.display_name
}

// Snapshot row index of the bar whose tooltip is shown at the point, or -1
// (no bar, or the filter hides its title).
tooltip_bar_hit :: proc(snapshot: Day_Snapshot, x, y: i32, valid: bool, w, h: i32) -> int {
	lane, in_lane := tooltip_lane(x, y, valid, w, h)
	if !in_lane { return -1 }
	lay := compute_layout(w, h)
	day_start, day_end := zoom_bounds(snapshot.day_start, snapshot.day_end)
	index := snapshot_bar_hit(snapshot, lane_timeline(lane), x, lay.chart_x, lay.chart_w, day_start, day_end)
	if index < 0 || !filter_matches(tooltip_title(snapshot.rows[index].activity)) { return -1 }
	return index
}

draw_tooltip :: proc(snapshot: Day_Snapshot, dc: windows.HDC, w, h: i32) {
	index := tooltip_bar_hit(snapshot, ui.mouse.x, ui.mouse.y, ui.mouse_valid, w, h)
	if index < 0 { return }
	row := snapshot.rows[index]
	a := row.activity
	draw_tooltip_box(dc, w, h,
		a.group_name,
		tooltip_title(a),
		fmt.tprintf("%s - %s  (%s)", fmt_snapshot_clock(snapshot, row.start_ms), fmt_snapshot_clock(snapshot, row.end_ms),
			fmt_span_hm(row.end_ms - row.start_ms)))
}

draw_tooltip_box :: proc(dc: windows.HDC, w, h: i32, line1, line2, line3: string) {
	tw := max(
		max(text_pixel_width(line1, ui.font_normal), text_pixel_width(line2, ui.font_normal) + 40),
		text_pixel_width(line3, ui.font_small)) + TOOLTIP_FOLLOW_W_PAD
	th := TOOLTIP_FOLLOW_H
	tx, ty := tooltip_follow_origin(ui.mouse.x, ui.mouse.y, tw, th, w, h)
	fill_rect(dc, tx, ty, tw, th, C_TIP_BG)
	fill_frame(dc, tx, ty, tw, th, C_TIP_BORDER)
	draw_string(dc, line1, tx + 8, ty + 6, ui.font_normal, C_TXT, tw - 16)
	draw_string(dc, line2, tx + 8, ty + 22, ui.font_normal, C_TXT, tw - 16)
	draw_string(dc, line3, tx + 8, ty + 38, ui.font_small, C_DIM, tw - 16)
}
