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
// and is released by the free_all(context.temp_allocator) call after each
// message in main; nothing is cached between frames.

// --- Palette (COLORREF = 0x00BBGGRR; comments show rgb(R,G,B)) ---

C_BG:          windows.COLORREF = 0x00FAF7F5
C_PANEL:       windows.COLORREF = 0x00FFFFFF
C_BORDER:      windows.COLORREF = 0x00C0AF9C
C_BORDER_SOFT: windows.COLORREF = 0x00E2D8CD
C_LANE_BG:     windows.COLORREF = 0x00F4ECE2
C_LANE_GRID:   windows.COLORREF = 0x00E4D8CB
C_LANE_TXT:    windows.COLORREF = 0x00746658
C_TXT:         windows.COLORREF = 0x0028221E
C_DIM:         windows.COLORREF = 0x00908478
C_ACCENT      :: 0x0030A0F0 // rgb(240,160,48) - selected lane, ManicTime orange
C_GREEN       :: 0x0087C94C // rgb(76,201,135)
C_ORANGE      :: 0x0050A0F0 // rgb(240,160,80)
C_RED         :: 0x005A5ADE // rgb(222,90,90)
C_TAB_BG:      windows.COLORREF = 0x00F5EFE8
C_TAB_ACTIVE:  windows.COLORREF = 0x00FFFFFF
C_BTN_FACE:    windows.COLORREF = 0x00FFFFFF
C_BTN_BORDER:  windows.COLORREF = 0x00EAB47E
C_BTN_HOVER:   windows.COLORREF = 0x00FCE0E4
C_HEAD_BG:     windows.COLORREF = 0x00F8F4EF
C_ROW_ALT:     windows.COLORREF = 0x00FCF9F6
C_TIP_BG:      windows.COLORREF = 0x00E1FFFF
C_TIP_BORDER:  windows.COLORREF = 0x008C8278

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
		2 * LANE_GAP - 4 - ZOOM_H - SPLITTER_W - MIN_LOWER_H) / 3)
	lay.lane_h = clamp(wanted_lane_h, MIN_LANE_H, max_lane_h)
	lay.lane_y = lay.ruler_y + RULER_H
	lay.lanes_bottom = lay.lane_y + 3 * lay.lane_h + 2 * LANE_GAP
	lay.zoom_y = lay.lanes_bottom + 4
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

	bh := i32(26)
	by := lay.toolbar_y + 12
	lay.btn_prev = windows.RECT{left = MARGIN, top = by, right = MARGIN + 26, bottom = by + bh}
	lay.btn_today = windows.RECT{left = MARGIN + 30, top = by, right = MARGIN + 98, bottom = by + bh}
	lay.btn_next = windows.RECT{left = MARGIN + 102, top = by, right = MARGIN + 128, bottom = by + bh}
	lay.date_pick = windows.RECT{left = MARGIN + 140, top = by, right = MARGIN + 140 + DATE_PICK_W, bottom = by + bh}
	lay.btn_track = windows.RECT{left = MARGIN + 148 + DATE_PICK_W, top = by, right = MARGIN + 280 + DATE_PICK_W, bottom = by + bh}

	// Day start / day end / duration boxes anchored to the right.
	bw := min(i32(108), (w - lay.btn_track.right - 24) / 3 - 4)
	bh2 := i32(36)
	by2 := lay.toolbar_y + 8
	bx := w - MARGIN - bw
	for i := 2; i >= 0; i -= 1 {
		lay.day_boxes[i] = windows.RECT{left = bx, top = by2, right = bx + bw, bottom = by2 + bh2}
		bx -= bw + 4
	}
	return lay
}

compute_tabs :: proc(i: i32) -> windows.RECT {
	txs := [3]i32{2, 58, 148}
	tws := [3]i32{54, 88, 92}
	return windows.RECT{left = txs[i], top = 0, right = txs[i] + tws[i], bottom = TAB_H}
}

tab_name :: proc(i: i32) -> string {
	switch i {
	case 1: return "Timesheet"
	case 2: return "Statistics"
	}
	return "Day"
}

lane_name :: proc(i: i32) -> string {
	switch i {
	case 0: return "Tags"
	case 1: return "Computer Usage"
	case 2: return "Applications"
	}
	return ""
}

lane_timeline :: proc(i: i32) -> i64 {
	switch i {
	case 0: return TIMELINE_TAGS
	case 1: return TIMELINE_COMPUTER
	case 2: return TIMELINE_APPS
	}
	return 0
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
	windows.SetBkMode(dc, windows.BKMODE.TRANSPARENT)
	if ui.scroll_date != app.date {
		ui.scroll_date = app.date
		ui.list_scroll.pos = 0
		ui.totals_scroll.pos = 0
	}
	if ui.tab != 0 {
		pane_scroll_show(&ui.list_scroll, false)
		pane_scroll_show(&ui.totals_scroll, false)
	}
	fill_rect(dc, 0, 0, w, h, C_BG)
	switch ui.tab {
	case 0:
		draw_day(app, dc, w, h)
	case 1:
		draw_placeholder(dc, w, h, "Timesheet", "Timesheets are not implemented yet (see docs/ROADMAP.md).")
	case 2:
		draw_placeholder(dc, w, h, "Statistics", "Statistics are not implemented yet (see docs/ROADMAP.md).")
	}
	draw_filter_row(dc, w, h)
	draw_status_bar(app, dc, w, h)
	if ui.tab == 0 {
		draw_tooltip(app, dc, w, h)
	}
	draw_theme_tooltip(dc, w)
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
	for i := i32(0); i < 3; i += 1 {
		t := compute_tabs(i32(i))
		active := ui.tab == i
		state := i32(3) if active else i32(1) // TIS_SELECTED / TIS_NORMAL
		if !active && ui.mouse_valid && rect_hit(t, ui.mouse.x, ui.mouse.y) {
			state = 2 // TIS_HOT
		}
		if draw_themed_control(dc, ui.theme_tab, 1, state, t, tab_name(i)) {
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
		tw := text_pixel_width(tab_name(i32(i)), ui.font_normal)
		draw_string(dc, tab_name(i32(i)),
			t.left + (t.right - t.left - tw) / 2, t.top + 6,
			ui.font_normal, C_TXT if active else C_DIM)
	}
}

// --- Toolbar (date navigation + day start/end/duration) ---

draw_toolbar :: proc(app: ^App, dc: windows.HDC, lay: Layout) {
	draw_toolbar_background_rect(dc, 0, lay.toolbar_y, lay.w, TOOLBAR_H)
	draw_button(dc, lay.btn_prev, "<", HIT_BTN_PREV)
	draw_button(dc, lay.btn_next, ">", HIT_BTN_NEXT)
	draw_button(dc, lay.btn_today, "Today", HIT_BTN_TODAY)

	label := "Start task"
	if app.task.id != 0 { label = fmt.tprintf("Stop task  %s", fmt_hms(now_ms() - app.task.start_ms)) }
	draw_button(dc, lay.btn_track, label, HIT_BTN_TASK)

	// Day start / day end / duration, ManicTime-style.
	day_start, day_end := day_bounds_ms(app.date)
	min_ms, max_ms := day_span(app, day_start, day_end)
	captions := [3]string{"Day start", "Day end", "Duration"}
	values := [3]string{fmt_hm(min_ms), fmt_hm(max_ms), fmt_span_hm(max_ms - min_ms)}
	if max_ms <= min_ms {
		values = [3]string{"-:--", "-:--", "0:00"}
	}
	for i := 0; i < 3; i += 1 {
		b := lay.day_boxes[i]
		bw := b.right - b.left
		bhh := b.bottom - b.top
		fill_rect(dc, b.left + 1, b.top + 1, bw - 2, bhh - 2, C_PANEL)
		fill_frame(dc, b.left, b.top, bw, bhh, C_BTN_BORDER)
		draw_string(dc, captions[i], b.left + 8, b.top + 3, ui.font_small, C_DIM)
		draw_string(dc, values[i], b.left + 8, b.top + 18, ui.font_bold, C_TXT)
	}
}

// Day span across both tracked lanes, clamped to the selected date.
day_span :: proc(app: ^App, day_start, day_end: i64) -> (min_ms, max_ms: i64) {
	min_ms = day_end
	max_ms = day_start
	for a in app.activities {
		if a.timeline_id != TIMELINE_COMPUTER && a.timeline_id != TIMELINE_APPS {
			continue
		}
		if a.start_ms < min_ms && a.end_ms > day_start { min_ms = max(a.start_ms, day_start) }
		if a.end_ms > max_ms && a.start_ms < day_end { max_ms = min(a.end_ms, day_end) }
	}
	if min_ms > max_ms {
		min_ms, max_ms = day_end, day_start
	}
	return
}

draw_button :: proc(dc: windows.HDC, r: windows.RECT, label: string, hit: int) {
	hot := ui.mouse_valid && rect_hit(r, ui.mouse.x, ui.mouse.y)
	state := i32(1) // PBS_NORMAL
	if hot {
		state = 3 if ui.pressed_hit == hit else 2 // PBS_PRESSED / PBS_HOT
	}
	if draw_themed_control(dc, ui.theme_button, 1, state, r, label) { return }
	w := r.right - r.left
	h := r.bottom - r.top
	bg: windows.COLORREF = C_BTN_FACE
	if ui.mouse_valid && rect_hit(r, ui.mouse.x, ui.mouse.y) {
		bg = C_BORDER_SOFT if ui.pressed_hit == hit else C_BTN_HOVER
	}
	fill_rect(dc, r.left + 1, r.top + 1, w - 2, h - 2, bg)
	fill_frame(dc, r.left, r.top, w, h, C_BTN_BORDER)
	draw_button_text(dc, label, r)
}

// --- Day view ---

draw_day :: proc(app: ^App, dc: windows.HDC, w, h: i32) {
	lay := compute_layout(w, h)
	draw_tabs(dc)
	draw_toolbar(app, dc, lay)

	day_start, day_end := day_bounds_ms(app.date)
	view_start, view_end := zoom_bounds(day_start, day_end)

	// Ruler
	draw_toolbar_background_rect(dc, lay.chart_x, lay.ruler_y, lay.chart_w, RULER_H)
	step := zoom_tick_step(view_start, view_end, lay.chart_w)
	first_tick := day_start + ((view_start - day_start + step - 1) / step) * step
	for tick := first_tick; tick <= view_end + 1; tick += step {
		x := x_for_ms(tick, view_start, view_end, lay.chart_x, lay.chart_w)
		s := fmt_clock_hm(tick)
		if tick >= day_end { s = "24:00" }
		tw := text_pixel_width(s, ui.font_small)
		draw_string(dc, s, clamp(x - tw / 2, lay.chart_x, lay.chart_x + lay.chart_w - tw),
			lay.ruler_y + 6, ui.font_small, C_DIM)
	}

	// Lanes
	for i := 0; i < 3; i += 1 {
		ly := lay.lane_y + i32(i) * (lay.lane_h + LANE_GAP)
		draw_lane(app, dc, lay, i32(i), lay.chart_x, ly, lay.chart_w, lay.lane_h, view_start, view_end)
	}

	// Now marker (today only)
	if app.date == today_date_int() && now_ms() >= view_start && now_ms() < view_end {
		nx := x_for_ms(now_ms(), view_start, view_end, lay.chart_x, lay.chart_w)
		line_v(dc, nx, lay.ruler_y, lay.lanes_bottom - lay.ruler_y, C_RED)
	}

	// Details list + totals
	draw_zoom_bar(app, dc, lay, day_start, day_end)
	draw_list(app, dc, lay, day_start, day_end)
	draw_totals(app, dc, lay, day_start, day_end)
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

argb_to_colorref :: proc(c: u32) -> windows.COLORREF {
	if c == 0 { return 0 }
	return rgb(i32((c >> 16) & 0xFF), i32((c >> 8) & 0xFF), i32(c & 0xFF))
}

activity_colorref :: proc(a: Activity) -> windows.COLORREF {
	c := a.color
	if c == 0 {
		c = GROUP_COLORS[int(a.group_id) % len(GROUP_COLORS)]
	}
	return argb_to_colorref(c)
}

draw_lane :: proc(app: ^App, dc: windows.HDC, lay: Layout, idx, x, y, w, h: i32, day_start, day_end: i64) {
	fill_rect(dc, x, y, w, h, C_LANE_BG)
	step := zoom_tick_step(day_start, day_end, w)
	local_start, _ := day_bounds_ms(app.date)
	first_tick := local_start + ((day_start - local_start + step - 1) / step) * step
	for tick := first_tick; tick < day_end; tick += step {
		line_v(dc, x_for_ms(tick, day_start, day_end, x, w), y, h, C_LANE_GRID)
	}
	draw_string(dc, lane_name(idx), x + 10, y + h / 2 - 9, ui.font_normal,
		C_DIM if ui.lane == idx else C_LANE_TXT)

	tl := lane_timeline(idx)
	if tl != 0 {
		draw_lane_bars(app, dc, idx, tl, x, y, w, h, day_start, day_end)
	}

	border := windows.COLORREF(C_BORDER)
	if ui.lane == idx {
		border = C_ACCENT
		border_w := i32(2)
		fill_rect(dc, x, y, w, border_w, C_ACCENT)
		fill_rect(dc, x, y + h - border_w, w, border_w, C_ACCENT)
		fill_rect(dc, x, y, border_w, h, C_ACCENT)
		fill_rect(dc, x + w - border_w, y, border_w, h, C_ACCENT)
	}
	fill_frame(dc, x, y, w, h, border)
}

bar_rect_for_lane :: proc(idx: i32, x, y, w, h: i32) -> windows.RECT {
	return windows.RECT{left = x, top = y, right = x + w, bottom = y + h}
}

draw_lane_bars :: proc(app: ^App, dc: windows.HDC, lane_idx: i32, tl: i64, x, y, w, h: i32, day_start, day_end: i64) {
	br := bar_rect_for_lane(lane_idx, x, y, w, h)
	bar_h := br.bottom - br.top
	bar_y := br.top

	for a in app.activities {
		if a.timeline_id != tl {
			continue
		}
		s := max(a.start_ms, day_start)
		e := min(a.end_ms, day_end)
		if tl == TIMELINE_TAGS && tag_ui.drag >= 2 && a.id == tag_ui.id {
			s, e = max(tag_ui.start_ms, day_start), min(tag_ui.end_ms, day_end)
		}
		if e <= s {
			continue
		}
		x1 := x_for_ms(s, day_start, day_end, x, w)
		x2 := x_for_ms(e, day_start, day_end, x, w)
		bw := max(1, x2 - x1)
		color := activity_colorref(a)
		if tl == TIMELINE_COMPUTER && (a.group_id == 1 || a.group_name == "Active") {
			color = C_GREEN
		}
		fill_rect(dc, x1, bar_y, bw, bar_h, color)
		if tl == TIMELINE_TAGS {
			fill_frame(dc, x1, bar_y, bw, bar_h, C_BORDER)
			draw_string(dc, a.display_name, x1 + 6, bar_y + 8, ui.font_bold, bar_text_color(color), bw - 12)
			line_v(dc, x1 + 2, bar_y + bar_h / 2 - 5, 10, C_PANEL)
			if bw > 6 { line_v(dc, x2 - 3, bar_y + bar_h / 2 - 5, 10, C_PANEL) }
		}
	}
	if tl == TIMELINE_TAGS && (tag_ui.drag == 1 || (tag_ui.popup != nil && !tag_ui.task_picker)) {
		lay := compute_layout(ui.mem_w, ui.mem_h)
		tag_draw_range(dc, lay, day_start, day_end)
	}

	// Current (possibly unpersisted) activity grows live.
	if tl == TIMELINE_APPS && app.tracker.current.active &&
	   date_int_from_unix_ms(app.tracker.current.start_ms) == app.date {
		c := &app.tracker.current
		s := max(c.start_ms, day_start)
		e := min(now_ms(), day_end)
		if e > s {
			x1 := x_for_ms(s, day_start, day_end, x, w)
			x2 := x_for_ms(e, day_start, day_end, x, w)
			bw := max(1, x2 - x1)
			color := activity_colorref(Activity{group_id = c.group_id, color = c.group_color})
			fill_rect(dc, x1, bar_y, bw, bar_h, color)
			fill_frame(dc, x1, bar_y, bw, bar_h, rgb(255, 255, 255))
		}
	}
	if tl == TIMELINE_COMPUTER && app.tracker.usage_id > 0 &&
	   date_int_from_unix_ms(app.tracker.usage_start_ms) == app.date {
		s := max(app.tracker.usage_start_ms, day_start)
		e := min(now_ms(), day_end)
		if e > s {
			x1 := x_for_ms(s, day_start, day_end, x, w)
			x2 := x_for_ms(e, day_start, day_end, x, w)
			bw := max(1, x2 - x1)
			color: windows.COLORREF = C_GREEN if app.tracker.usage_kind == .Active else C_ORANGE
			fill_rect(dc, x1, bar_y, bw, bar_h, color)
			fill_frame(dc, x1, bar_y, bw, bar_h, rgb(255, 255, 255))
		}
	}
}

// --- Details list (bottom left) ---

ListRow :: struct {
	group_id:   i64,
	name:       string, // points into activity data or temp storage
	start_ms:   i64,
	end_ms:     i64,
	color:      u32,
	is_current: bool,
}

TotRow :: struct {
	group_id: i64,
	name:     string,
	color:    u32,
	ms:       i64,
}

filter_matches :: proc(name: string) -> bool {
	if len(ui.filter) == 0 {
		return true
	}
	l := strings.to_lower(name)
	defer delete(l)
	return strings.contains(l, ui.filter)
}

// Builds the row list for the selected lane. Allocated with the temp
// allocator: released by the post-message free_all in main.
build_rows :: proc(app: ^App, day_start, day_end: i64) -> []ListRow {
	tl := lane_timeline(i32(ui.lane))
	if tl == 0 {
		return nil
	}
	rows := make([dynamic]ListRow, 0, 64, context.temp_allocator)
	for a in app.activities {
		if a.timeline_id != tl {
			continue
		}
		s := max(a.start_ms, day_start)
		e := min(a.end_ms, day_end)
		if e <= s {
			continue
		}
		name := a.display_name
		if tl == TIMELINE_COMPUTER && len(a.group_name) > 0 {
			name = a.group_name
		}
		if !filter_matches(name) {
			continue
		}
		append(&rows, ListRow{
			group_id = a.group_id,
			name     = name,
			start_ms = a.start_ms,
			end_ms   = a.end_ms,
			color    = a.color,
		})
	}
	c := &app.tracker.current
	if tl == TIMELINE_APPS && c.active && c.persisted_id == 0 &&
	   date_int_from_unix_ms(c.start_ms) == app.date {
		s := max(c.start_ms, day_start)
		e := min(now_ms(), day_end)
		if e > s && filter_matches(c.title) {
			append(&rows, ListRow{
				group_id   = c.group_id,
				name       = c.title,
				start_ms   = c.start_ms,
				end_ms     = e,
				color      = c.group_color,
				is_current = true,
			})
		}
	}
	return rows[:]
}

draw_list :: proc(app: ^App, dc: windows.HDC, lay: Layout, day_start, day_end: i64) {
	x := lay.chart_x
	w := lay.sidebar_x - lay.chart_x - 8

	fill_rect(dc, x, lay.list_top, w, lay.list_bottom - lay.list_top, C_PANEL)
	rows := build_rows(app, day_start, day_end)
	rows_view_h := max(0, lay.list_bottom - lay.list_top - LIST_HDR)
	visible := max(1, rows_view_h / LIST_ROW)
	w -= pane_scroll_update(&ui.list_scroll, i32(len(rows)), visible,
		x + w, lay.list_top + LIST_HDR, lay.list_bottom)
	skip := ui.list_scroll.pos

	// Header
	fill_rect(dc, x, lay.list_top, w, LIST_HDR, C_HEAD_BG)
	fill_frame(dc, x, lay.list_top, w, LIST_HDR, C_BORDER_SOFT)
	col_start := x + w - 64 // duration column left edge
	col_end := x + w - 128
	col_dur := x + w - 186
	draw_string(dc, "Title", x + 8, lay.list_top + 4, ui.font_normal, C_TXT, col_dur - x - 16)
	draw_string(dc, "Start", col_dur + 4, lay.list_top + 4, ui.font_normal, C_DIM, 60)
	draw_string(dc, "End", col_end + 4, lay.list_top + 4, ui.font_normal, C_DIM, 60)
	draw_string(dc, "Duration", col_start + 4, lay.list_top + 4, ui.font_normal, C_DIM, 60)

	tl := lane_timeline(i32(ui.lane))
	if tl == 0 {
		msg := "No tags recorded yet." if ui.lane == 0 else "No data for this lane."
		draw_string(dc, msg, x + 8, lay.list_top + LIST_HDR + 8, ui.font_normal, C_DIM)
		return
	}

	if len(rows) == 0 {
		draw_string(dc, "No activity recorded for this day.", x + 8, lay.list_top + LIST_HDR + 8, ui.font_normal, C_DIM)
		return
	}

	n_rows := i32(len(rows))
	for i := skip; i < n_rows && i < skip + visible; i += 1 {
		row := rows[i]
		ry := lay.list_top + LIST_HDR + i32(i - skip) * LIST_ROW
		fill_rect(dc, x, ry, w, LIST_ROW, C_ROW_ALT if (i - skip) % 2 == 1 else C_PANEL)
		color := activity_colorref(Activity{group_id = row.group_id, color = row.color})
		fill_rect(dc, x + 2, ry + 4, 4, LIST_ROW - 8, color)
		draw_string(dc, row.name, x + 10, ry + 3, ui.font_normal, C_TXT, col_dur - x - 18)
		draw_string(dc, fmt_clock_hm(row.start_ms), col_dur + 4, ry + 3, ui.font_normal, C_DIM, 60)
		draw_string(dc, fmt_clock_hm(row.end_ms), col_end + 4, ry + 3, ui.font_normal, C_DIM, 60)
		draw_string(dc, fmt_span_hm(row.end_ms - row.start_ms), col_start + 4, ry + 3, ui.font_normal, C_DIM, 60)
	}
}

// --- Totals panel (bottom right) ---

build_totals :: proc(app: ^App, day_start, day_end: i64) -> []TotRow {
	tl := lane_timeline(i32(ui.lane))
	if tl == 0 {
		return nil
	}
	m := make(map[i64]TotRow)
	defer delete(m)
	for a in app.activities {
		if a.timeline_id != tl {
			continue
		}
		s := max(a.start_ms, day_start)
		e := min(a.end_ms, day_end)
		if e <= s {
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
		entry.ms += e - s
		m[a.group_id] = entry
	}
	c := &app.tracker.current
	if tl == TIMELINE_APPS && c.active && c.persisted_id == 0 && date_int_from_unix_ms(c.start_ms) == app.date {
		s := max(c.start_ms, day_start)
		e := min(now_ms(), day_end)
		if e > s {
			entry, ok := m[c.group_id]
			if !ok {
				entry = TotRow{group_id = c.group_id, name = c.app_name, color = c.group_color}
			}
			entry.ms += e - s
			m[c.group_id] = entry
		}
	}
	list := make([dynamic]TotRow, 0, len(m))
	for _, v in m {
		append(&list, v)
	}
	slice.sort_by(list[:], proc(a, b: TotRow) -> bool { return a.ms > b.ms })
	return list[:]
}

draw_totals :: proc(app: ^App, dc: windows.HDC, lay: Layout, day_start, day_end: i64) {
	x := lay.sidebar_x
	w := lay.sidebar_w
	total_h := lay.list_bottom - lay.list_top

	fill_rect(dc, x, lay.list_top, w, total_h, C_PANEL)
	fill_frame(dc, x, lay.list_top, w, total_h, C_BORDER_SOFT)

	totals := build_totals(app, day_start, day_end)
	defer free_totals_slice(totals)

	total_ms: i64
	for t in totals {
		total_ms += t.ms
	}

	draw_string(dc, "Totals", x + 8, lay.list_top + 6, ui.font_bold, C_TXT)
	line_h(dc, x + 1, lay.list_top + 24, w - 2, C_BORDER_SOFT)

	view_h := max(0, total_h - 52)
	visible := max(1, view_h / LIST_ROW)
	bar_w := pane_scroll_update(&ui.totals_scroll, i32(len(totals)), visible,
		x + w - 1, lay.list_top + 32, lay.list_bottom - 20)
	row_w := w - bar_w
	skip := ui.totals_scroll.pos

	y := lay.list_top + 32
	n_totals := i32(len(totals))
	for i := skip; i < n_totals && i < skip + visible; i += 1 {		t := totals[i]
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
	draw_string(dc, "Total:", x + 8, lay.list_bottom - 20, ui.font_bold, C_TXT)
	tval := fmt_hms(total_ms)
	tv_w := text_pixel_width(tval, ui.font_bold)
	draw_string(dc, tval, x + w - 8 - tv_w, lay.list_bottom - 20, ui.font_bold, C_TXT)
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

	dot := C_GREEN if app.tracker.enabled else rgb(200, 204, 208)
	dot_x := 8 + text_pixel_width(clock, ui.font_normal) + 6
	fill_rect(dc, dot_x, lay.status_y + 7, 8, 8, dot)

	version := "aika (native ui)"
	tw := text_pixel_width(version, ui.font_normal)
	draw_string(dc, version, w - 8 - tw, lay.status_y + 4, ui.font_normal, C_DIM)
}

// --- Hit testing ---

rect_hit :: proc(r: windows.RECT, x, y: i32) -> bool {
	return x >= r.left && x < r.right && y >= r.top && y < r.bottom
}

hit_test :: proc(x, y, w, h: i32) -> int {
	if rect_hit(theme_switch_rect(w), x, y) { return HIT_THEME }
	for i := 0; i < 3; i += 1 {
		if rect_hit(compute_tabs(i32(i)), x, y) {
			return HIT_TAB_BASE + i
		}
	}
	lay := compute_layout(w, h)
	if ui.tab == 0 {
		_, minus, plus, reset := zoom_rects(lay)
		if rect_hit(minus, x, y) { return HIT_ZOOM_OUT }
		if rect_hit(plus, x, y) { return HIT_ZOOM_IN }
		if rect_hit(reset, x, y) { return HIT_ZOOM_RESET }
	}
	if y >= lay.ruler_y && x >= lay.chart_x && x < lay.chart_x + lay.chart_w {
		for i := 0; i < 3; i += 1 {
			ly := lay.lane_y + i32(i) * (lay.lane_h + LANE_GAP)
			if y >= ly && y < ly + lay.lane_h {
				return HIT_LANE_BASE + i
			}
		}
	}
	if rect_hit(lay.btn_prev, x, y) { return HIT_BTN_PREV }
	if rect_hit(lay.btn_next, x, y) { return HIT_BTN_NEXT }
	if rect_hit(lay.btn_today, x, y) { return HIT_BTN_TODAY }
	if rect_hit(lay.btn_track, x, y) { return HIT_BTN_TASK }
	return HIT_NONE
}

// --- Tooltip ---

draw_tooltip :: proc(app: ^App, dc: windows.HDC, w, h: i32) {
	if !ui.mouse_valid || ui.tab != 0 || ui.pane_drag != 0 || tag_ui.drag != 0 || tag_ui.popup != nil || tag_ui.menu_open { return }
	mx, my := ui.mouse.x, ui.mouse.y
	lay := compute_layout(w, h)
	if mx < lay.chart_x || mx >= lay.chart_x + lay.chart_w { return }

	found: ^Activity = nil
	full_start, full_end := day_bounds_ms(app.date)
	day_start, day_end := zoom_bounds(full_start, full_end)

	for lane_i := 0; lane_i <= 2; lane_i += 1 {
		ly := lay.lane_y + i32(lane_i) * (lay.lane_h + LANE_GAP)
		if my < ly || my >= ly + lay.lane_h { continue }
		br := bar_rect_for_lane(i32(lane_i), lay.chart_x, ly, lay.chart_w, lay.lane_h)
		if my < br.top || my >= br.bottom { return }
		tl := lane_timeline(i32(lane_i))

		// The live (possibly unpersisted) current activity first.
		if c := &app.tracker.current; tl == TIMELINE_APPS && c.active &&
		   date_int_from_unix_ms(c.start_ms) == app.date {
			s := max(c.start_ms, day_start)
			e := min(now_ms(), day_end)
			if e > s {
				x1 := x_for_ms(s, day_start, day_end, lay.chart_x, lay.chart_w)
				x2 := x_for_ms(e, day_start, day_end, lay.chart_x, lay.chart_w)
				if mx >= x1 && mx <= x2 {
					if !filter_matches(c.title) { return }
					draw_tooltip_box(dc, w, h, c.app_name, c.title,
						fmt.tprintf("%s - %s", fmt_clock_hm(c.start_ms), fmt_clock_hm(e)))
					return
				}
			}
		}

		// Innermost matching bar wins (activities can visually overlap).
		best_w := lay.chart_w + 1
		for a, ai in app.activities {
			if a.timeline_id != tl { continue }
			s := max(a.start_ms, day_start)
			e := min(a.end_ms, day_end)
			if e <= s { continue }
			x1 := x_for_ms(s, day_start, day_end, lay.chart_x, lay.chart_w)
			x2 := x_for_ms(e, day_start, day_end, lay.chart_x, lay.chart_w)
			if mx >= x1 && mx <= x2 && x2 - x1 < best_w {
				if len(a.display_name) > 0 && !filter_matches(a.display_name) {
					continue
				}
				best_w = x2 - x1
				found = &app.activities[ai]
			}
		}
		if found != nil {
			a := found
			title := a.display_name
			if tl == TIMELINE_COMPUTER && len(a.group_name) > 0 {
				title = a.group_name
			}
			draw_tooltip_box(dc, w, h,
				a.group_name,
				title,
				fmt.tprintf("%s - %s  (%s)", fmt_clock_hm(a.start_ms), fmt_clock_hm(a.end_ms),
					fmt_span_hm(a.end_ms - a.start_ms)))
		}
		return
	}
}

draw_tooltip_box :: proc(dc: windows.HDC, w, h: i32, line1, line2, line3: string) {
	tw := max(
		max(text_pixel_width(line1, ui.font_normal), text_pixel_width(line2, ui.font_normal) + 40),
		text_pixel_width(line3, ui.font_small)) + 20
	th := i32(58)
	tx := ui.mouse.x + 14
	ty := ui.mouse.y + 14
	if tx + tw > w - 8 { tx = ui.mouse.x - tw - 14 }
	if ty + th > h - 8 { ty = ui.mouse.y - th - 14 }
	if tx < 0 { tx = 0 }
	if ty < 0 { ty = 0 }
	fill_rect(dc, tx, ty, tw, th, C_TIP_BG)
	fill_frame(dc, tx, ty, tw, th, C_TIP_BORDER)
	draw_string(dc, line1, tx + 8, ty + 6, ui.font_normal, C_TXT, tw - 16)
	draw_string(dc, line2, tx + 8, ty + 22, ui.font_normal, C_TXT, tw - 16)
	draw_string(dc, line3, tx + 8, ty + 38, ui.font_small, C_DIM, tw - 16)
}
