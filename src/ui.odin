package main

import "core:fmt"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"

// Global UI scale: font sizes and layout spacing are multiplied by this.
UI_S :: 1.4

COL_BG :: rl.Color{17, 17, 21, 255}
COL_PANEL :: rl.Color{23, 23, 29, 255}
COL_PANEL_2 :: rl.Color{29, 29, 37, 255}
COL_LINE :: rl.Color{48, 48, 60, 255}
COL_TEXT :: rl.Color{228, 228, 235, 255}
COL_DIM :: rl.Color{146, 146, 160, 255}
COL_ACCENT :: rl.Color{110, 190, 255, 255}
COL_GREEN :: rl.Color{76, 201, 135, 255}
COL_ORANGE :: rl.Color{240, 160, 80, 255}

cstring_temp :: proc(s: string) -> cstring {
	c, _ := strings.clone_to_cstring(s, context.temp_allocator)
	return c
}

// Font sizes passed to these helpers are authored sizes; UI_S is applied here
// so every call site scales consistently.
draw_text :: proc(font: rl.Font, text: string, x, y: f32, size: f32, color: rl.Color) {
	rl.DrawTextEx(font, cstring_temp(text), {x, y}, size * UI_S, 0.3 * UI_S, color)
}

measure_text :: proc(font: rl.Font, text: string, size: f32) -> f32 {
	return rl.MeasureTextEx(font, cstring_temp(text), size * UI_S, 0.3 * UI_S).x
}

draw_text_right :: proc(font: rl.Font, text: string, right, y: f32, size: f32, color: rl.Color) {
	draw_text(font, text, right - measure_text(font, text, size), y, size, color)
}

truncate_to_width :: proc(font: rl.Font, text: string, size, max_w: f32) -> string {
	if measure_text(font, text, size) <= max_w {
		return text
	}
	if max_w <= 12 * UI_S {
		return ""
	}
	ellipsis := "..."
	n := len(text)
	for n > 0 {
		cand := fmt.tprintf("%s%s", text[:n], ellipsis)
		if measure_text(font, cand, size) <= max_w {
			return cand
		}
		n -= 1
	}
	return ellipsis
}

color_from_argb :: proc(c: u32) -> rl.Color {
	a := u8((c >> 24) & 0xFF)
	if a == 0 {
		a = 255
	}
	return {u8((c >> 16) & 0xFF), u8((c >> 8) & 0xFF), u8(c & 0xFF), a}
}

activity_color :: proc(a: Activity) -> rl.Color {
	c := a.color
	if c == 0 {
		c = GROUP_COLORS[int(a.group_id) % len(GROUP_COLORS)]
	}
	col := color_from_argb(c)
	col.a = 235
	return col
}

format_duration :: proc(ms: i64) -> string {
	v := ms
	if v < 0 {
		v = 0
	}
	mins := v / 60000
	if mins < 1 {
		return "<1m"
	}
	if mins < 60 {
		return fmt.tprintf("%dm", mins)
	}
	h := mins / 60
	m := mins % 60
	if m == 0 {
		return fmt.tprintf("%dh", h)
	}
	return fmt.tprintf("%dh %02dm", h, m)
}

format_clock :: proc(ms: i64) -> string {
	st := unix_ms_to_local(ms)
	return fmt.tprintf("%02d:%02d", st.hour, st.minute)
}

time_to_x :: proc(ms, start_ms, end_ms: i64, x, w: f32) -> f32 {
	if end_ms <= start_ms {
		return x
	}
	frac := f32(ms - start_ms) / f32(end_ms - start_ms)
	if frac < 0 { frac = 0 }
	if frac > 1 { frac = 1 }
	return x + frac * w
}

rect_contains :: proc(r: rl.Rectangle, p: rl.Vector2) -> bool {
	return p.x >= r.x && p.x <= r.x + r.width && p.y >= r.y && p.y <= r.y + r.height
}

Agg :: struct {
	group_id: i64,
	name:     string,
	color:    u32,
	ms:       i64,
}

compute_view_range :: proc(app: ^App) -> (view_start, view_end: i64) {
	day_start, day_end := day_bounds_ms(app.date)
	min_ms := i64(1 << 62)
	max_ms := i64(-1 << 62)

	include :: proc(min_ms, max_ms: ^i64, s, e, clamp_s, clamp_e: i64) {
		if e <= clamp_s || s >= clamp_e {
			return
		}
		if s < min_ms^ { min_ms^ = s }
		if e > max_ms^ { max_ms^ = e }
	}

	for a in app.activities {
		include(&min_ms, &max_ms, a.start_ms, a.end_ms, day_start, day_end)
	}
	c := &app.tracker.current
	if c.active && date_int_from_unix_ms(c.start_ms) == app.date {
		include(&min_ms, &max_ms, c.start_ms, now_ms(), day_start, day_end)
	}
	if app.tracker.usage_id > 0 && date_int_from_unix_ms(app.tracker.usage_start_ms) == app.date {
		include(&min_ms, &max_ms, app.tracker.usage_start_ms, now_ms(), day_start, day_end)
	}
	now := now_ms()
	if app.date == today_date_int() && now >= day_start && now <= day_end {
		include(&min_ms, &max_ms, now - 60_000, now + 60_000, day_start, day_end)
	}

	if min_ms > max_ms {
		view_start = day_start + 8 * 3_600_000
		view_end = day_start + 18 * 3_600_000
		return
	}

	pad := i64(15 * 60_000)
	view_start = min_ms - pad
	view_end = max_ms + pad
	if view_end - view_start < 2 * 3_600_000 {
		center := (view_start + view_end) / 2
		view_start = center - 3_600_000
		view_end = center + 3_600_000
	}
	if view_start < day_start { view_start = day_start }
	if view_end > day_end { view_end = day_end }
	return
}

draw_timeline :: proc(app: ^App, bounds: rl.Rectangle) {
	font := app.font
	start_ms, end_ms := day_bounds_ms(app.date)
	view_start, view_end := compute_view_range(app)
	now := now_ms()

	rl.DrawRectangleRec(bounds, COL_PANEL)
	rl.DrawRectangleLinesEx(bounds, 1, COL_LINE)

	draw_text(font, "Activity timeline", bounds.x + 16 * UI_S, bounds.y + 12 * UI_S, 22, COL_TEXT)
	draw_text(font, date_label(app.date), bounds.x + 190 * UI_S, bounds.y + 16 * UI_S, 16, COL_DIM)

	gutter: f32 = 96 * UI_S
	chart_x := bounds.x + gutter
	chart_w := bounds.width - gutter - 18 * UI_S
	ruler_y := bounds.y + 58 * UI_S
	chart_bottom := bounds.y + bounds.height - 18 * UI_S

	apps_y := ruler_y + 34 * UI_S
	apps_h: f32 = 300 * UI_S
	if bounds.height < 450 * UI_S {
		apps_h = bounds.height * 0.55
	}
	usage_y := apps_y + 34 * UI_S + apps_h
	usage_h: f32 = 54 * UI_S
	if usage_y + usage_h > chart_bottom {
		usage_h = max(28 * UI_S, chart_bottom - usage_y)
	}

	// Ruler and grid (adaptive to the visible range)
	span_h := f32(view_end - view_start) / 3_600_000.0
	step_min: i64 = 180
	if span_h <= 2.0 {
		step_min = 15
	} else if span_h <= 4.0 {
		step_min = 30
	} else if span_h <= 8.0 {
		step_min = 60
	} else if span_h <= 14.0 {
		step_min = 120
	}
	step_ms := step_min * 60_000
	tick := ((view_start + step_ms - 1) / step_ms) * step_ms
	for tick <= view_end {
		x := time_to_x(tick, view_start, view_end, chart_x, chart_w)
		rl.DrawLineEx({x, ruler_y}, {x, chart_bottom}, 1, COL_LINE)
		label := format_clock(tick)
		label_w := measure_text(font, label, 13)
		draw_text(font, label, x - label_w / 2, ruler_y - 20 * UI_S, 13, COL_DIM)
		tick += step_ms
	}

	// Lane backgrounds
	rl.DrawRectangleRec({chart_x, apps_y, chart_w, apps_h}, {20, 20, 26, 255})
	rl.DrawRectangleRec({chart_x, usage_y, chart_w, usage_h}, {20, 20, 26, 255})
	rl.DrawRectangleLinesEx({chart_x, apps_y, chart_w, apps_h}, 1, {38, 38, 48, 255})
	rl.DrawRectangleLinesEx({chart_x, usage_y, chart_w, usage_h}, 1, {38, 38, 48, 255})

	draw_text(font, "Applications", bounds.x + 14 * UI_S, apps_y + 8 * UI_S, 16, COL_DIM)
	draw_text(font, "Computer usage", bounds.x + 14 * UI_S, usage_y + 16 * UI_S, 16, COL_DIM)

	hovered: ^Activity = nil
	mouse := rl.GetMousePosition()

	// Application bars
	bar_y := apps_y + 10 * UI_S
	bar_h: f32 = 30 * UI_S
	for i in 0 ..< len(app.activities) {
		a := &app.activities[i]
		if a.timeline_id != TIMELINE_APPS {
			continue
		}
		s := max(a.start_ms, start_ms)
		e := min(a.end_ms, end_ms)
		if e <= s {
			continue
		}
		x1 := time_to_x(s, view_start, view_end, chart_x, chart_w)
		x2 := time_to_x(e, view_start, view_end, chart_x, chart_w)
		w := max(1.5, x2 - x1 - 1)
		col := activity_color(a^)
		rl.DrawRectangleRec({x1, bar_y, w, bar_h}, col)
		rl.DrawRectangleLinesEx({x1, bar_y, w, bar_h}, 1, {0, 0, 0, 120})

		if rect_contains({x1, bar_y, w, bar_h}, mouse) {
			hovered = a
		}
	}

	// Current application overlay (grows in real time)
	if app.tracker.current.active && date_int_from_unix_ms(app.tracker.current.start_ms) == app.date {
		c := &app.tracker.current
		s := max(c.start_ms, start_ms)
		e := min(now, end_ms)
		if e > s {
			x1 := time_to_x(s, view_start, view_end, chart_x, chart_w)
			x2 := time_to_x(e, view_start, view_end, chart_x, chart_w)
			w := max(1.5, x2 - x1 - 1)
			col := color_from_argb(c.group_color)
			col.a = 255
			rl.DrawRectangleRec({x1, bar_y, w, bar_h}, col)
			rl.DrawRectangleLinesEx({x1, bar_y, w, bar_h}, 1.5, {255, 255, 255, 190})
		}
	}

	// Computer usage bars
	u_y := usage_y + 12 * UI_S
	u_h: f32 = 28 * UI_S
	for i in 0 ..< len(app.activities) {
		a := &app.activities[i]
		if a.timeline_id != TIMELINE_COMPUTER {
			continue
		}
		s := max(a.start_ms, start_ms)
		e := min(a.end_ms, end_ms)
		if e <= s {
			continue
		}
		x1 := time_to_x(s, view_start, view_end, chart_x, chart_w)
		x2 := time_to_x(e, view_start, view_end, chart_x, chart_w)
		w := max(1.5, x2 - x1 - 1)
		col := activity_color(a^)
		if a.group_id == 1 || a.group_name == "Active" {
			col = {34, 70, 56, 255}
		}
		rl.DrawRectangleRec({x1, u_y, w, u_h}, col)
		rl.DrawRectangleLinesEx({x1, u_y, w, u_h}, 1, {0, 0, 0, 100})
	}

	if app.tracker.usage_id > 0 && date_int_from_unix_ms(app.tracker.usage_start_ms) == app.date {
		s := max(app.tracker.usage_start_ms, start_ms)
		e := min(now, end_ms)
		if e > s {
			x1 := time_to_x(s, view_start, view_end, chart_x, chart_w)
			x2 := time_to_x(e, view_start, view_end, chart_x, chart_w)
			w := max(1.5, x2 - x1 - 1)
			col := COL_GREEN if app.tracker.usage_kind == .Active else COL_ORANGE
			col.a = 235
			rl.DrawRectangleRec({x1, u_y, w, u_h}, col)
			rl.DrawRectangleLinesEx({x1, u_y, w, u_h}, 1, {255, 255, 255, 120})
		}
	}

	// Now line
	if app.date == today_date_int() {
		x := time_to_x(now, view_start, view_end, chart_x, chart_w)
		rl.DrawLineEx({x, ruler_y - 8 * UI_S}, {x, chart_bottom}, 1.5 * UI_S, {255, 90, 90, 220})
		draw_text(font, "now", x + 5 * UI_S, ruler_y - 20 * UI_S, 12, {255, 130, 130, 255})
	}

	// Tooltip
	if hovered != nil {
		a := hovered
		lines := []string{
			a.group_name,
			truncate_to_width(font, a.display_name, 15, 420 * UI_S),
			fmt.tprintf("%s – %s  (%s)", format_clock(a.start_ms), format_clock(a.end_ms), format_duration(a.end_ms - a.start_ms)),
		}
		max_w: f32 = 0
		for line in lines {
			max_w = max(max_w, measure_text(font, line, 15))
		}
		tip_w := max_w + 20 * UI_S
		tip_h: f32 = 72 * UI_S
		tx := mouse.x + 14 * UI_S
		ty := mouse.y + 14 * UI_S
		if tx + tip_w > f32(rl.GetScreenWidth()) - 8 {
			tx = mouse.x - tip_w - 14 * UI_S
		}
		if ty + tip_h > f32(rl.GetScreenHeight()) - 8 {
			ty = mouse.y - tip_h - 14 * UI_S
		}
		rl.DrawRectangleRec({tx, ty, tip_w, tip_h}, {14, 14, 18, 245})
		rl.DrawRectangleLinesEx({tx, ty, tip_w, tip_h}, 1, COL_LINE)
		draw_text(font, lines[0], tx + 10 * UI_S, ty + 8 * UI_S, 15, COL_ACCENT)
		draw_text(font, lines[1], tx + 10 * UI_S, ty + 28 * UI_S, 15, COL_TEXT)
		draw_text(font, lines[2], tx + 10 * UI_S, ty + 48 * UI_S, 13, COL_DIM)
	}
}

draw_summary :: proc(app: ^App, bounds: rl.Rectangle) {
	font := app.font
	start_ms, end_ms := day_bounds_ms(app.date)

	rl.DrawRectangleRec(bounds, COL_PANEL)
	rl.DrawRectangleLinesEx(bounds, 1, COL_LINE)

	draw_text(font, "Summary", bounds.x + 16 * UI_S, bounds.y + 12 * UI_S, 22, COL_TEXT)
	draw_text(font, "selected day", bounds.x + 120 * UI_S, bounds.y + 16 * UI_S, 14, COL_DIM)

	aggs: map[i64]Agg
	defer delete(aggs)

	for a in app.activities {
		if a.timeline_id != TIMELINE_APPS {
			continue
		}
		s := max(a.start_ms, start_ms)
		e := min(a.end_ms, end_ms)
		if e <= s {
			continue
		}
		entry, exists := aggs[a.group_id]
		if !exists {
			name := a.group_name
			if name == "" {
				name = a.display_name
			}
			entry = Agg{group_id = a.group_id, name = name, color = a.color}
		}
		entry.ms += e - s
		aggs[a.group_id] = entry
	}

	// Include the unpersisted current activity.
	c := &app.tracker.current
	if c.active && c.persisted_id == 0 && date_int_from_unix_ms(c.start_ms) == app.date {
		s := max(c.start_ms, start_ms)
		e := min(now_ms(), end_ms)
		if e > s {
			entry, exists := aggs[c.group_id]
			if !exists {
				entry = Agg{group_id = c.group_id, name = c.app_name, color = c.group_color}
			}
			entry.ms += e - s
			aggs[c.group_id] = entry
		}
	}

	list := make([dynamic]Agg, 0, len(aggs))
	defer delete(list[:])
	total: i64 = 0
	for _, a in aggs {
		append(&list, a)
		total += a.ms
	}
	slice.sort_by(list[:], proc(a, b: Agg) -> bool { return a.ms > b.ms })

	draw_text(font, "Tracked", bounds.x + 16 * UI_S, bounds.y + 54 * UI_S, 14, COL_DIM)
	draw_text(font, format_duration(total), bounds.x + 16 * UI_S, bounds.y + 72 * UI_S, 30, COL_TEXT)

	y := bounds.y + 124 * UI_S
	draw_text(font, "Applications", bounds.x + 16 * UI_S, y, 14, COL_DIM)
	y += 26 * UI_S

	limit := min(10, len(list))
	for i in 0 ..< limit {
		a := list[i]
		col := color_from_argb(a.color)
		if a.color == 0 {
			col = color_from_argb(GROUP_COLORS[int(a.group_id) % len(GROUP_COLORS)])
		}
		rl.DrawRectangleRec({bounds.x + 16 * UI_S, y + 3 * UI_S, 11 * UI_S, 11 * UI_S}, col)
		name := truncate_to_width(font, a.name, 15, bounds.width - 120 * UI_S)
		draw_text(font, name, bounds.x + 34 * UI_S, y, 15, COL_TEXT)
		draw_text_right(font, format_duration(a.ms), bounds.x + bounds.width - 16 * UI_S, y, 14, COL_DIM)
		y += 23 * UI_S
	}
	if limit == 0 {
		draw_text(font, "No activity recorded for this day.", bounds.x + 16 * UI_S, y + 4 * UI_S, 14, COL_DIM)
	}

	// Current focus
	y = bounds.y + bounds.height - 82 * UI_S
	rl.DrawLineEx({bounds.x + 16 * UI_S, y - 10 * UI_S}, {bounds.x + bounds.width - 16 * UI_S, y - 10 * UI_S}, 1, COL_LINE)
	draw_text(font, "Current window", bounds.x + 16 * UI_S, y, 13, COL_DIM)
	if c.active {
		draw_text(font, truncate_to_width(font, c.app_name, 16, bounds.width - 32 * UI_S), bounds.x + 16 * UI_S, y + 18 * UI_S, 16, COL_ACCENT)
		draw_text(font, truncate_to_width(font, c.title, 13, bounds.width - 32 * UI_S), bounds.x + 16 * UI_S, y + 38 * UI_S, 13, COL_DIM)
	} else {
		draw_text(font, "not tracking", bounds.x + 16 * UI_S, y + 18 * UI_S, 15, COL_DIM)
	}
}

draw_header :: proc(app: ^App, width: f32) {
	font := app.font
	h: f32 = 72 * UI_S
	rl.DrawRectangleRec({0, 0, width, h}, COL_PANEL_2)
	rl.DrawLineEx({0, h}, {width, h}, 1, COL_LINE)

	btn_h: f32 = 32 * UI_S
	btn_y: f32 = 20 * UI_S
	// Buttons are anchored to the left; widths follow the scaled font.
	btn_x: f32 = 24 * UI_S
	if rl.GuiButton({btn_x, btn_y, 38 * UI_S, btn_h}, "<") {
		app.date = add_days(app.date, -1)
		load_day(app)
	}
	if rl.GuiButton({btn_x + 44 * UI_S, btn_y, 78 * UI_S, btn_h}, "Today") {
		app.date = today_date_int()
		load_day(app)
	}
	if rl.GuiButton({btn_x + 128 * UI_S, btn_y, 38 * UI_S, btn_h}, ">") {
		app.date = add_days(app.date, 1)
		load_day(app)
	}

	label := "Tracking: ON" if app.tracker.enabled else "Tracking: OFF"
	if rl.GuiButton({btn_x + 188 * UI_S, btn_y, 150 * UI_S, btn_h}, cstring_temp(label)) {
		if app.tracker.enabled {
			tracker_pause(app)
		} else {
			tracker_resume(app)
		}
		load_day(app)
	}

	draw_text(font, date_label(app.date), (btn_x + 188 * UI_S + 150 * UI_S + 40 * UI_S), 27 * UI_S, 18, COL_DIM)

	if app.tracker.current.active {
		x: f32 = 820 * UI_S
		max_w := width - x - 24 * UI_S
		if max_w > 0 {
			line := fmt.tprintf("%s  —  %s", app.tracker.current.app_name, app.tracker.current.title)
			draw_text(font, truncate_to_width(font, line, 15, max_w), x, 20 * UI_S, 15, COL_TEXT)
			draw_text(font, "recording", x, 42 * UI_S, 12, COL_GREEN)
		}
	}
}

draw_footer :: proc(app: ^App, width, height: f32) {
	font := app.font
	y := height - 30 * UI_S
	rl.DrawLineEx({0, y - 8 * UI_S}, {width, y - 8 * UI_S}, 1, COL_LINE)
	info := fmt.tprintf("db: %s    activities: %d    idle: %s", app.db_path, len(app.activities), format_duration(idle_ms()))
	draw_text(font, info, 24 * UI_S, y, 13, COL_DIM)
}

draw_frame :: proc(app: ^App) {
	width := f32(rl.GetScreenWidth())
	height := f32(rl.GetScreenHeight())

	rl.BeginDrawing()
	rl.ClearBackground(COL_BG)

	draw_header(app, width)
	draw_footer(app, width, height)

	panel_top := f32(92 * UI_S)
	panel_bottom := height - 48 * UI_S
	panel_h := panel_bottom - panel_top
	right_w: f32 = 320 * UI_S
	timeline_w := width - 48 * UI_S - right_w - 16 * UI_S

	timeline_bounds := rl.Rectangle{24 * UI_S, panel_top, timeline_w, panel_h}
	summary_bounds := rl.Rectangle{24 * UI_S + timeline_w + 16 * UI_S, panel_top, right_w, panel_h}

	draw_timeline(app, timeline_bounds)
	draw_summary(app, summary_bounds)

	rl.EndDrawing()
}
