package main

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sys/windows"
import rt "base:runtime"

Tag_Drag :: enum { None, New_Range, Left_Edge, Right_Edge }

tag_drag_is_edge :: proc(drag: Tag_Drag) -> bool {
	return drag == .Left_Edge || drag == .Right_Edge
}

TagUi :: struct {
	id: i64, // resized block (edge drags) or 0; range below survives for picker
	anchor, start_ms, end_ms: i64,
	down_x: i32,
	view_start, view_end: i64,
	popup, search, list, create: windows.HWND,
	pomo_check, pomo_edit, pomo_spin, pomo_unit: windows.HWND, // Start task picker only
	tags: []Tag,
	visible: [dynamic]int,
	menu_open: bool,
	task_picker: bool,
	multi: bool,              // block pickers select several tags; task pickers one
	selected: [dynamic]i64,   // ticked tag IDs, kept across search filtering
	task_picks: [dynamic]Tag_Pick, // Start task picker: chosen tags (names owned), in order
	control_failed: bool,
}

tag_ui: TagUi
TAG_POPUP_CLASS :: "aika_tag_picker"

// Match the rendered pixel rectangles, including very short and clipped blocks.
// Later activities are painted on top and therefore win the hit test.
tag_block_hit :: proc(app: ^App, x, y: i32, lay: Layout) -> i64 {
	if ui.tab != .Day || !rect_hit(lane_rect(lay, .Tags), x, y) { return 0 }
	snapshot := build_day_snapshot(app, tracker_now(app), tracker_monotonic(app))
	vs, ve := zoom_bounds(snapshot.day_start, snapshot.day_end)
	index := snapshot_bar_hit(snapshot, TIMELINE_TAGS, x, lay.chart_x, lay.chart_w, vs, ve)
	return snapshot.rows[index].activity.id if index >= 0 else 0
}

tag_context_menu :: proc(app: ^App, screen: windows.POINT) {
	if interaction_active() || tag_ui.popup != nil || tag_ui.menu_open { return }
	p := screen
	windows.ScreenToClient(ui.hwnd, &p)
	w, h := client_size(ui.hwnd)
	id := tag_block_hit(app, p.x, p.y, compute_layout(w, h))
	if id == 0 { return }
	if id == app.task.id {
		message_box("Stop the running task before deleting its tag block.", "aika")
		return
	}
	menu := windows.CreatePopupMenu()
	if menu == nil { return }
	defer windows.DestroyMenu(menu)
	if !windows.AppendMenuW(menu, 0, 1, wtext("Delete")) { return }
	ui.lane = .Tags
	tag_ui.menu_open = true
	defer tag_ui.menu_open = false
	windows.InvalidateRect(ui.hwnd, nil, windows.FALSE)
	// The menu runs a nested message loop; retain only the ID, never a pointer
	// into app.activities, because the timer may reload the selected day.
	command := windows.TrackPopupMenu(menu, windows.TPM_RETURNCMD | windows.TPM_RIGHTBUTTON, screen.x, screen.y, 0, ui.hwnd, nil)
	if command == 1 {
		if !db_delete_tag_block(&app.db, id) {
			message_box("Could not delete tag block. Please try again.", "aika", windows.MB_ICONERROR)
		}
		load_day(app)
	}
	windows.InvalidateRect(ui.hwnd, nil, windows.FALSE)
}

tag_ms_for_x :: proc(x: i32, lay: Layout, start, end: i64) -> i64 {
	f := clamp(f64(x - lay.chart_x) / f64(max(1, lay.chart_w)), 0.0, 1.0)
	return start + i64(f * f64(end - start))
}

// Only bounded gaps qualify: do not infer day boundaries as neighboring blocks.
tag_gap_at :: proc(activities: []Activity, point: i64) -> (start, end: i64, found: bool) {
	has_left, has_right := false, false
	for a in activities {
		if a.timeline_id != TIMELINE_TAGS || a.end_ms <= a.start_ms { continue }
		if a.start_ms <= point && point < a.end_ms { return 0, 0, false }
		if a.end_ms <= point && (!has_left || a.end_ms > start) {
			start, has_left = a.end_ms, true
		}
		if a.start_ms > point && (!has_right || a.start_ms < end) {
			end, has_right = a.start_ms, true
		}
	}
	found = has_left && has_right && end > start
	return
}

tag_gap_double_click :: proc(app: ^App, x, y: i32, lay: Layout) -> bool {
	if ui.tab != .Day || tag_ui.popup != nil || tag_ui.menu_open || interaction_active() ||
	   !rect_hit(lane_rect(lay, .Tags), x, y) {
		return false
	}
	if tag_block_hit(app, x, y, lay) != 0 { return false }
	ds, de := day_bounds_ms(app.date)
	vs, ve := zoom_bounds(ds, de)
	start, end, found := tag_gap_at(app.activities, tag_ms_for_x(x, lay, vs, ve))
	if !found { return false }
	ui.lane = .Tags
	ui.list_scroll.pos, ui.totals_scroll.pos = 0, 0
	tag_ui.id = 0
	tag_ui.view_start, tag_ui.view_end = vs, ve
	tag_ui.start_ms, tag_ui.end_ms = start, end
	tag_picker_open()
	windows.InvalidateRect(ui.hwnd, nil, windows.FALSE)
	return true
}

// Edges outside the visible range are not resize handles. Nearest edge wins;
// at a shared boundary, prefer the block under the pointer so both handles are
// reachable from their respective interiors. Topmost wins remaining ties.
tag_edge_hit :: proc(app: ^App, x, y: i32, lay: Layout) -> (id: i64, edge: Tag_Drag) {
	if ui.tab != .Day || x < lay.chart_x || x > lay.chart_x + lay.chart_w ||
	   y < lay.lane_y || y >= lay.lane_y + lay.lane_h { return }
	ds, de := day_bounds_ms(app.date)
	vs, ve := zoom_bounds(ds, de)
	best := dpi_px(EDGE_HIT_PX) + 1
	best_inside := false
	for a in app.activities {
		if a.timeline_id != TIMELINE_TAGS || a.end_ms <= vs || a.start_ms >= ve { continue }
		if a.id == app.task.id { continue }
		left := x_for_ms(max(a.start_ms, vs), vs, ve, lay.chart_x, lay.chart_w)
		right := x_for_ms(min(a.end_ms, ve), vs, ve, lay.chart_x, lay.chart_w)
		inside := x >= left && x < left + max(1, right - left)
		for t, i in ([2]i64{a.start_ms, a.end_ms}) {
			if t < vs || t > ve { continue }
			distance := abs(x - x_for_ms(t, vs, ve, lay.chart_x, lay.chart_w))
			if distance <= dpi_px(EDGE_HIT_PX) && (distance < best || (distance == best && (inside || !best_inside))) {
				id, edge, best = a.id, .Left_Edge if i == 0 else .Right_Edge, distance
				best_inside = inside
			}
		}
	}
	return
}

tag_pointer_down :: proc(app: ^App, x, y: i32, lay: Layout) -> bool {
	if ui.tab != .Day || tag_ui.popup != nil || interaction_active() || !rect_hit(lane_rect(lay, .Tags), x, y) {
		return false
	}
	ui.lane = .Tags
	ui.list_scroll.pos, ui.totals_scroll.pos = 0, 0
	ds, de := day_bounds_ms(app.date)
	tag_ui.view_start, tag_ui.view_end = zoom_bounds(ds, de)
	tag_ui.anchor = tag_ms_for_x(x, lay, tag_ui.view_start, tag_ui.view_end)
	tag_ui.start_ms, tag_ui.end_ms = tag_ui.anchor, tag_ui.anchor
	tag_ui.down_x = x
	id, edge := tag_edge_hit(app, x, y, lay)
	tag_ui.id = id
	if tag_ui.id != 0 {
		for a in app.activities {
			if a.id == tag_ui.id { tag_ui.start_ms, tag_ui.end_ms = a.start_ms, a.end_ms; break }
		}
		tag_begin(edge, tag_ui.id)
	} else {
		tag_begin(.New_Range, 0)
	}
	windows.SetFocus(ui.hwnd)
	windows.SetCapture(ui.hwnd)
	return true
}

// Select the first contiguous free interval in the drag direction. Walk out of
// any occupied interval at the anchor (including touching/legacy overlaps),
// then stop at the next block rather than spanning it or creating split blocks.
tag_free_range :: proc(activities: []Activity, anchor, pointer: i64) -> (start, end: i64) {
	forward := pointer >= anchor
	boundary := anchor
	for {
		previous := boundary
		for a in activities {
			if a.timeline_id != TIMELINE_TAGS || a.end_ms <= a.start_ms { continue }
			if forward && a.start_ms <= boundary && a.end_ms > boundary {
				boundary = a.end_ms
			} else if !forward && a.start_ms < boundary && a.end_ms >= boundary {
				boundary = a.start_ms
			}
		}
		if boundary == previous { break }
	}
	if forward {
		start, end = boundary, pointer
		for a in activities {
			if a.timeline_id == TIMELINE_TAGS && a.end_ms > a.start_ms && a.start_ms >= start {
				end = min(end, a.start_ms)
			}
		}
	} else {
		start, end = pointer, boundary
		for a in activities {
			if a.timeline_id == TIMELINE_TAGS && a.end_ms > a.start_ms && a.end_ms <= end {
				start = max(start, a.end_ms)
			}
		}
	}
	if end <= start { return anchor, anchor }
	return
}

tag_pointer_move :: proc(x: i32, lay: Layout, activities: []Activity = nil) {
	t := tag_ms_for_x(x, lay, tag_ui.view_start, tag_ui.view_end)
	switch tag_drag() {
	case .None:
	case .New_Range:
		tag_ui.start_ms, tag_ui.end_ms = tag_free_range(activities, tag_ui.anchor, t)
	case .Left_Edge:
		limit := tag_ui.view_start
		for a in activities {
			if a.timeline_id == TIMELINE_TAGS && a.id != tag_ui.id && a.end_ms <= tag_ui.end_ms {
				limit = max(limit, a.end_ms)
			}
		}
		tag_ui.start_ms = clamp(t, min(limit, tag_ui.end_ms - 1), tag_ui.end_ms - 1)
	case .Right_Edge:
		limit := tag_ui.view_end
		for a in activities {
			if a.timeline_id == TIMELINE_TAGS && a.id != tag_ui.id && a.start_ms >= tag_ui.start_ms {
				limit = min(limit, a.start_ms)
			}
		}
		tag_ui.end_ms = clamp(t, tag_ui.start_ms + 1, max(limit, tag_ui.start_ms + 1))
	}
}

tag_pointer_up :: proc(app: ^App, x: i32, lay: Layout) {
	tag_pointer_move(x, lay, app.activities)
	drag, id := tag_drag(), tag_drag_id()
	interaction_end() // ReleaseCapture sends WM_CAPTURECHANGED synchronously.
	windows.ReleaseCapture()
	if drag == .New_Range {
		if abs(x - tag_ui.down_x) >= dpi_px(CLICK_DRAG_PX) && tag_ui.end_ms > tag_ui.start_ms { tag_picker_open() }
	} else if drag != .None {
		if x != tag_ui.down_x && !db_resize_tag(&app.db, id, tag_ui.start_ms, tag_ui.end_ms) {
			message_box("Could not resize tag. No changes were saved.", "aika", windows.MB_ICONERROR)
		}
		load_day(app)
	}
	windows.InvalidateRect(ui.hwnd, nil, windows.FALSE)
}

tag_draw_range :: proc(dc: windows.HDC, lay: Layout, start, end: i64) {
	if end <= start || tag_ui.end_ms <= tag_ui.start_ms { return }
	x1 := x_for_ms(tag_ui.start_ms, start, end, lay.chart_x, lay.chart_w)
	x2 := x_for_ms(tag_ui.end_ms, start, end, lay.chart_x, lay.chart_w)
	fill_rect(dc, x1, lay.lane_y + 2, max(1, x2 - x1), lay.lane_h - 4, C_TAG_PREVIEW)
	fill_frame(dc, x1, lay.lane_y + 2, max(1, x2 - x1), lay.lane_h - 4, C_ACCENT)
	draw_string(dc, fmt.tprintf("%s - %s", fmt_clock_hm(tag_ui.start_ms), fmt_clock_hm(tag_ui.end_ms)),
		x1 + 6, lay.lane_y + 8, ui.font_bold, C_TXT, x2 - x1 - 12)
}

tag_search_text :: proc() -> string {
	buf: [512]u16
	n := windows.GetWindowTextW(tag_ui.search, &buf[0], len(buf))
	s, _ := windows.utf16_to_utf8(buf[:max(0, n)], context.temp_allocator)
	return strings.trim_space(s)
}

tag_is_selected :: proc(id: i64) -> bool {
	for s in tag_ui.selected { if s == id { return true } }
	return false
}

// Mirrors the listbox's ticks into tag_ui.selected for the visible rows;
// ticks on rows hidden by the search stay selected.
tag_selection_sync :: proc() {
	if !tag_ui.multi || tag_ui.list == nil { return }
	for index, row in tag_ui.visible {
		id := tag_ui.tags[index].id
		ticked := windows.SendMessageW(tag_ui.list, LB_GETSEL, windows.WPARAM(row), 0) > 0
		at := -1
		for s, i in tag_ui.selected { if s == id { at = i; break } }
		if ticked && at < 0 { append(&tag_ui.selected, id) }
		if !ticked && at >= 0 { ordered_remove(&tag_ui.selected, at) }
	}
}

tag_picker_filter :: proc() {
	query := strings.to_lower(tag_search_text(), context.temp_allocator)
	clear(&tag_ui.visible)
	windows.SendMessageW(tag_ui.list, LB_RESETCONTENT, 0, 0)
	exact := false
	for tag, i in tag_ui.tags {
		lower := strings.to_lower(tag.name, context.temp_allocator)
		if lower == query { exact = true }
		if tag_ui.task_picker && tag_task_has_id(tag.id) { continue } // already in the chosen list
		if strings.contains(lower, query) {
			row := len(tag_ui.visible)
			append(&tag_ui.visible, i)
			windows.SendMessageW(tag_ui.list, LB_ADDSTRING, 0, transmute(windows.LPARAM)(wtext(tag.name)))
			if tag_ui.multi && tag_is_selected(tag.id) { windows.SendMessageW(tag_ui.list, LB_SETSEL, 1, windows.LPARAM(row)) }
		}
	}
	if len(tag_ui.visible) > 0 {
		if tag_ui.multi { windows.SendMessageW(tag_ui.list, LB_SETCARETINDEX, 0, 0) } else { windows.SendMessageW(tag_ui.list, LB_SETCURSEL, 0, 0) }
	}
	// Creating is offered whenever the typed name is new; in multi mode it adds to the ticked tags.
	// The Start task picker's Create also accepts an existing name (it just adds that tag).
	windows.EnableWindow(tag_ui.create, windows.TRUE if query != "" && (!exact || tag_ui.task_picker) else windows.FALSE)
	if tag_ui.task_picker { tag_task_update_start() }
}

// Start is available with chosen tags, or else with a highlighted list row,
// which Ctrl+Enter then starts as the single tag.
tag_task_update_start :: proc() {
	if tag_ui.popup == nil { return }
	can := len(tag_ui.task_picks) > 0 || (tag_ui.list != nil && len(tag_ui.visible) > 0 &&
		windows.SendMessageW(tag_ui.list, LB_GETCURSEL, 0, 0) >= 0)
	windows.EnableWindow(windows.GetDlgItem(tag_ui.popup, i32(TAG_ID_START)), windows.TRUE if can else windows.FALSE)
}

// --- Start task picker: chosen-tag list ---

TAG_MAX_PICKS :: 32
TAG_CHIP_H    :: 22
TAG_CHIP_GAP  :: 6
TAG_CHIP_X    :: 12
TAG_CHIP_TOP  :: 36
TAG_CHIP_CROSS_W :: 22

Tag_Chip :: struct { box, cross: windows.RECT }

tag_task_has_id :: proc(id: i64) -> bool {
	if id == 0 { return false }
	for p in tag_ui.task_picks { if p.id == id { return true } }
	return false
}

tag_task_has_name :: proc(name: string) -> bool {
	for p in tag_ui.task_picks { if strings.equal_fold(p.name, name) { return true } }
	return false
}

// Flows the chosen tags as wrapping chips (name + cross). Returns how many
// chips were placed and the height of the whole area (one line when empty).
tag_chip_layout :: proc(client_w: i32, chips: ^[TAG_MAX_PICKS]Tag_Chip) -> (count: int, height: i32) {
	x, y := i32(TAG_CHIP_X), i32(TAG_CHIP_TOP)
	limit := client_w - TAG_CHIP_X
	for p, i in tag_ui.task_picks {
		if i >= TAG_MAX_PICKS { break }
		wd := min(text_size(p.name, ui.font_normal).cx + 8 + 6 + TAG_CHIP_CROSS_W, limit - TAG_CHIP_X)
		if x > TAG_CHIP_X && x + wd > limit { x = TAG_CHIP_X; y += TAG_CHIP_H + TAG_CHIP_GAP }
		box := windows.RECT{x, y, x + wd, y + TAG_CHIP_H}
		chips[i] = Tag_Chip{box = box, cross = {box.right - TAG_CHIP_CROSS_W, box.top, box.right, box.bottom}}
		count += 1
		x += wd + TAG_CHIP_GAP
	}
	return count, (y + TAG_CHIP_H) - TAG_CHIP_TOP
}

// Top of the search field: below the chip area in the Start task picker.
tag_search_y :: proc(client_w: i32) -> i32 {
	if !tag_ui.task_picker { return 58 }
	chips: [TAG_MAX_PICKS]Tag_Chip
	_, h := tag_chip_layout(client_w, &chips)
	return TAG_CHIP_TOP + h + 10
}

tag_draw_chips :: proc(dc: windows.HDC, client_w: i32) {
	chips: [TAG_MAX_PICKS]Tag_Chip
	count, _ := tag_chip_layout(client_w, &chips)
	th := text_size("Ag", ui.font_normal).cy
	if count == 0 {
		draw_string(dc, "No tags selected yet", TAG_CHIP_X, TAG_CHIP_TOP + (TAG_CHIP_H - th) / 2 + 2, ui.font_normal, C_DIM)
		return
	}
	for i in 0 ..< count {
		c := chips[i]
		fill_rect(dc, c.box.left, c.box.top, c.box.right - c.box.left, c.box.bottom - c.box.top, C_BTN_FACE)
		fill_frame(dc, c.box.left, c.box.top, c.box.right - c.box.left, c.box.bottom - c.box.top, C_BTN_BORDER)
		ty := c.box.top + (TAG_CHIP_H - th) / 2 + 2 // draw_string draws 2 px above the y it is given
		draw_string(dc, tag_ui.task_picks[i].name, c.box.left + 8, ty, ui.font_normal, C_TXT, c.cross.left - c.box.left - 10)
		cw := text_size("×", ui.font_normal).cx
		draw_string(dc, "×", c.cross.left + (TAG_CHIP_CROSS_W - cw) / 2, ty, ui.font_normal, C_DIM)
	}
}

// Re-lays out and repaints after the chosen list or the search text changed.
tag_task_refresh :: proc() {
	if tag_ui.popup == nil { return }
	tag_picker_layout(tag_ui.popup)
	if tag_ui.list != nil { tag_picker_filter() } // also refreshes the Start button
	windows.InvalidateRect(tag_ui.popup, nil, true)
}

tag_task_add_pick :: proc(id: i64, name: string) {
	if len(tag_ui.task_picks) < TAG_MAX_PICKS && !tag_task_has_id(id) && !tag_task_has_name(name) {
		append(&tag_ui.task_picks, Tag_Pick{id, strings.clone(name)})
	}
	windows.SetWindowTextW(tag_ui.search, wtext("")) // fires EN_CHANGE -> refilter
	tag_task_refresh()
	windows.SetFocus(tag_ui.search)
}

// Enter: add the highlighted list row.
tag_task_add_selected :: proc() {
	index := int(windows.SendMessageW(tag_ui.list, LB_GETCURSEL, 0, 0))
	if index < 0 && len(tag_ui.visible) > 0 { index = 0 }
	if index < 0 || index >= len(tag_ui.visible) { return }
	tag := tag_ui.tags[tag_ui.visible[index]]
	tag_task_add_pick(tag.id, tag.name)
}

// Shift+Enter: the typed name becomes a new tag; an existing tag of that name is simply added.
tag_task_create :: proc() {
	name := tag_search_text()
	if name == "" { return }
	for tag in tag_ui.tags {
		if strings.equal_fold(tag.name, name) { tag_task_add_pick(tag.id, tag.name); return }
	}
	tag_task_add_pick(0, name)
}

tag_task_remove :: proc(index: int) {
	if index < 0 || index >= len(tag_ui.task_picks) { return }
	delete(tag_ui.task_picks[index].name)
	ordered_remove(&tag_ui.task_picks, index)
	tag_task_refresh()
}

tag_task_free_picks :: proc() {
	for p in tag_ui.task_picks { delete(p.name) }
	delete(tag_ui.task_picks)
	tag_ui.task_picks = nil
}

// --- Start task picker: pomodoro mode ---

// Applies the checkbox to the visible controls, remembers it and saves the settings.
tag_pomo_sync :: proc() {
	if tag_ui.pomo_check == nil { return }
	on := windows.SendMessageW(tag_ui.pomo_check, windows.BM_GETCHECK, 0, 0) == windows.BST_CHECKED
	cmd := windows.SW_SHOW if on else windows.SW_HIDE
	for ctl in ([]windows.HWND{tag_ui.pomo_edit, tag_ui.pomo_spin, tag_ui.pomo_unit}) {
		if ctl != nil { windows.ShowWindow(ctl, cmd) }
	}
	if on != pomodoro_on {
		pomodoro_on = on
		settings_save_current(global_app.db_path, settings_load(global_app.db_path).idle_minutes)
	}
}

// Ctrl+P: flips the checkbox; switching on moves focus to the duration.
tag_pomo_toggle :: proc() {
	if tag_ui.pomo_check == nil { return }
	on := windows.SendMessageW(tag_ui.pomo_check, windows.BM_GETCHECK, 0, 0) == windows.BST_CHECKED
	windows.SendMessageW(tag_ui.pomo_check, windows.BM_SETCHECK, windows.WPARAM(windows.BST_UNCHECKED if on else windows.BST_CHECKED), 0)
	tag_pomo_sync()
	if !on && tag_ui.pomo_edit != nil {
		windows.SetFocus(tag_ui.pomo_edit)
		windows.SendMessageW(tag_ui.pomo_edit, EM_SETSEL, 0, -1)
	}
}

// Reads the duration field (invalid text keeps the saved value), clamps it into
// range, shows the clamped number and, if it changed, saves it to the settings file.
tag_pomo_commit :: proc() {
	if tag_ui.pomo_edit == nil { return }
	buf: [16]u16
	n := int(windows.GetWindowTextW(tag_ui.pomo_edit, &buf[0], len(buf)))
	minutes := pomodoro_minutes
	if text, err := windows.utf16_to_utf8(buf[:n], context.temp_allocator); err == nil {
		if parsed, ok := strconv.parse_int(strings.trim_space(text)); ok { minutes = parsed }
	}
	minutes = clamp(minutes, POMODORO_MIN_MINUTES, POMODORO_MAX_MINUTES)
	windows.SetWindowTextW(tag_ui.pomo_edit, wtext(fmt.tprintf("%d", minutes)))
	if minutes != pomodoro_minutes {
		pomodoro_minutes = minutes
		settings_save_current(global_app.db_path, settings_load(global_app.db_path).idle_minutes)
	}
}

// Ctrl+Enter: the only way to start the task.
tag_task_start :: proc() {
	if len(tag_ui.task_picks) == 0 {
		// Nothing added yet: start with the highlighted tag, if any.
		index := int(windows.SendMessageW(tag_ui.list, LB_GETCURSEL, 0, 0))
		if index < 0 || index >= len(tag_ui.visible) { return }
		tag := tag_ui.tags[tag_ui.visible[index]]
		append(&tag_ui.task_picks, Tag_Pick{tag.id, strings.clone(tag.name)})
	}
	app := global_app
	tag_pomo_commit()
	pomo_ms := i64(pomodoro_minutes) * MS_PER_MINUTE if pomodoro_on else 0
	if !task_start_picks(app, tag_ui.task_picks[:], now_ms(), pomo_ms) {
		message_box("Could not start task. The current time may already be tagged. Please select free time or try again.", "aika", windows.MB_ICONERROR)
		return
	}
	tag_picker_close()
	app.date = today_date_int()
	ui.lane = .Tags
	ui.list_scroll.pos, ui.totals_scroll.pos = 0, 0
	load_day(app)
	sync_date_picker(app)
}

tag_picker_icon: windows.HICON // title-bar icon of the Start task picker

tag_picker_close :: proc() {
	tag_pomo_commit() // keeps a changed duration even when the picker is cancelled
	hwnd := tag_ui.popup
	tag_ui.popup = nil
	tag_ui.search, tag_ui.list, tag_ui.create = nil, nil, nil
	tag_ui.pomo_check, tag_ui.pomo_edit, tag_ui.pomo_spin, tag_ui.pomo_unit = nil, nil, nil, nil
	tag_ui.task_picker = false
	tag_ui.multi = false
	delete(tag_ui.selected)
	tag_ui.selected = nil
	tag_task_free_picks()
	windows.EnableWindow(ui.hwnd, windows.TRUE)
	if hwnd != nil { windows.DestroyWindow(hwnd) }
	if tag_picker_icon != nil { windows.DestroyIcon(tag_picker_icon); tag_picker_icon = nil }
	free_tags(tag_ui.tags)
	tag_ui.tags = nil
	delete(tag_ui.visible)
	tag_ui.visible = nil
	windows.SetFocus(ui.hwnd)
	windows.InvalidateRect(ui.hwnd, nil, windows.FALSE)
}

tag_picker_accept :: proc(create: bool) {
	app := global_app
	name := tag_search_text()
	id: i64
	picks := make([dynamic]Tag_Pick, context.temp_allocator)
	if tag_ui.multi {
		tag_selection_sync()
		if !create && len(tag_ui.selected) == 0 {
			// Nothing ticked: use the highlighted row.
			row := int(windows.SendMessageW(tag_ui.list, LB_GETCARETINDEX, 0, 0))
			if row >= 0 && row < len(tag_ui.visible) { append(&tag_ui.selected, tag_ui.tags[tag_ui.visible[row]].id) }
		}
		for tag in tag_ui.tags {
			if tag_is_selected(tag.id) { append(&picks, Tag_Pick{tag.id, tag.name}) }
		}
		if create {
			if name == "" { return }
			append(&picks, Tag_Pick{0, name})
		}
		if len(picks) == 0 { return }
	} else if !create {
		index := int(windows.SendMessageW(tag_ui.list, LB_GETCURSEL, 0, 0))
		if index < 0 || index >= len(tag_ui.visible) { return }
		tag := tag_ui.tags[tag_ui.visible[index]]
		id, name = tag.id, tag.name
	} else if name == "" { return }
	if !tag_ui.multi { append(&picks, Tag_Pick{id, name}) }
	_, result := db_create_tag_block_multi(&app.db, picks[:], tag_ui.start_ms, tag_ui.end_ms)
	if result == .Overlap {
		message_box("This time range is already tagged. Please select free time.", "aika", windows.MB_ICONERROR)
		tag_picker_close()
		load_day(app)
		return
	}
	if result != .Ok {
		message_box("Could not save tag. Please try again.", "aika", windows.MB_ICONERROR)
		return
	}
	tag_picker_close()
	load_day(app)
}

// Outer size the user last resized the picker to (persisted in the settings
// file); zero means the default size.
tag_picker_size: [2]i32

tag_picker_remember_size :: proc(hwnd: windows.HWND) {
	r: windows.RECT
	windows.GetWindowRect(hwnd, &r)
	w, h := r.right - r.left, r.bottom - r.top
	size := [2]i32{w, h}
	min_w, min_h := tag_picker_min_size()
	if w < min_w || h < min_h || size == tag_picker_size { return }
	tag_picker_size = size
	settings_save_current(global_app.db_path, settings_load(global_app.db_path).idle_minutes)
}

// The search field is a self-drawn frame (border + magnifier) with a borderless
// EDIT inside it, so the icon sits within the field like a typical search box.
TAG_SEARCH_H   :: 26
TAG_ICON_PX    :: 16
TAG_ICON_SS    :: 8                      // supersampling factor for the icon
TAG_SEARCH_X   :: 12 + 1 + 8 + TAG_ICON_PX + 6 // EDIT left edge: frame, padding, icon, gap
TAG_SEARCH_PAD :: 8                      // gap between the EDIT and the frame's right edge
TAG_EDIT_H     :: 18

// Draws the field frame and an anti-aliased magnifier. The glyph is rendered at
// TAG_ICON_SS x size into a DIB (white on black), box-filtered down, and the
// coverage is blended between the panel and dim text colours.
tag_picker_draw_search :: proc(dc: windows.HDC, client_w: i32) {
	sy := tag_search_y(client_w)
	frame := windows.RECT{12, sy, client_w - 12, sy + TAG_SEARCH_H}
	fill_rect(dc, frame.left, frame.top, frame.right - frame.left, frame.bottom - frame.top, C_BORDER)
	fill_rect(dc, frame.left + 1, frame.top + 1, frame.right - frame.left - 2, frame.bottom - frame.top - 2, C_PANEL)

	big :: TAG_ICON_PX * TAG_ICON_SS
	bmi := windows.BITMAPINFO{bmiHeader = {
		biSize = size_of(windows.BITMAPINFOHEADER), biWidth = big, biHeight = -big,
		biPlanes = 1, biBitCount = 32, biCompression = windows.BI_RGB}}
	mem := windows.CreateCompatibleDC(dc)
	if mem == nil { return }
	defer windows.DeleteDC(mem)
	bits: rawptr
	dib := windows.CreateDIBSection(mem, &bmi, windows.DIB_RGB_COLORS, &bits, nil, 0)
	if dib == nil || bits == nil { return }
	defer windows.DeleteObject(windows.HGDIOBJ(dib))
	old_bmp := windows.SelectObject(mem, windows.HGDIOBJ(dib))
	defer windows.SelectObject(mem, old_bmp)

	hi := ([^]u32)(bits)[:big * big]
	for &p in hi { p = 0 }
	s :: TAG_ICON_SS
	white := windows.COLORREF(0xFFFFFF)
	// Lens: ring centred at (6.5, 6.5), radius 4.4 (px in icon space).
	px :: proc(tenths: i32) -> i32 { return tenths * TAG_ICON_SS / 10 } // tenths of an icon pixel -> supersampled
	ring := windows.CreatePen(windows.PS_SOLID, px(17), white)
	old_pen := windows.SelectObject(mem, windows.HGDIOBJ(ring))
	old_brush := windows.SelectObject(mem, windows.GetStockObject(windows.NULL_BRUSH))
	windows.Ellipse(mem, px(21), px(21), px(109), px(109))
	windows.SelectObject(mem, old_brush)
	windows.SelectObject(mem, old_pen)
	windows.DeleteObject(windows.HGDIOBJ(ring))
	// Handle: thicker stroke from the lens edge towards the bottom right.
	handle := windows.CreatePen(windows.PS_SOLID, px(22), white)
	old_pen = windows.SelectObject(mem, windows.HGDIOBJ(handle))
	windows.MoveToEx(mem, px(102), px(102), nil)
	windows.LineTo(mem, px(142), px(142))
	windows.SelectObject(mem, old_pen)
	windows.DeleteObject(windows.HGDIOBJ(handle))

	out: [TAG_ICON_PX * TAG_ICON_PX]u32
	bg_r, bg_g, bg_b := u32(C_PANEL) & 0xFF, (u32(C_PANEL) >> 8) & 0xFF, (u32(C_PANEL) >> 16) & 0xFF
	fg_r, fg_g, fg_b := u32(C_DIM) & 0xFF, (u32(C_DIM) >> 8) & 0xFF, (u32(C_DIM) >> 16) & 0xFF
	for y in 0 ..< TAG_ICON_PX {
		for x in 0 ..< TAG_ICON_PX {
			sum: u32
			for sy in 0 ..< s {
				for sx in 0 ..< s { sum += hi[(y * s + sy) * big + x * s + sx] & 0xFF }
			}
			a := sum / (s * s) // 0..255 coverage
			r := (bg_r * (255 - a) + fg_r * a) / 255
			g := (bg_g * (255 - a) + fg_g * a) / 255
			b := (bg_b * (255 - a) + fg_b * a) / 255
			out[y * TAG_ICON_PX + x] = (r << 16) | (g << 8) | b
		}
	}
	small := windows.BITMAPINFO{bmiHeader = {
		biSize = size_of(windows.BITMAPINFOHEADER), biWidth = TAG_ICON_PX, biHeight = -TAG_ICON_PX,
		biPlanes = 1, biBitCount = 32, biCompression = windows.BI_RGB}}
	windows.StretchDIBits(dc, frame.left + 1 + 8, frame.top + (TAG_SEARCH_H - TAG_ICON_PX) / 2, TAG_ICON_PX, TAG_ICON_PX,
		0, 0, TAG_ICON_PX, TAG_ICON_PX, &out[0], &small, windows.DIB_RGB_COLORS, windows.SRCCOPY)
}

tag_picker_layout :: proc(hwnd: windows.HWND) {
	w, h := client_size(hwnd)
	place :: proc(hwnd: windows.HWND, id: uintptr, x, y, w, h: i32) {
		c := windows.GetDlgItem(hwnd, i32(id))
		if c != nil { windows.MoveWindow(c, x, y, max(w, 0), max(h, 0), true) }
	}
	inner := w - 24
	sy := tag_search_y(w)
	list_y := sy + TAG_SEARCH_H + 6
	place(hwnd, TAG_ID_DESC, 12, 12, inner, 20)
	place(hwnd, TAG_ID_HINT, 12, 36, inner, 20)
	place(hwnd, TAG_ID_SEARCH, TAG_SEARCH_X, sy + (TAG_SEARCH_H - TAG_EDIT_H) / 2,
		inner - (TAG_SEARCH_X - 12) - TAG_SEARCH_PAD, TAG_EDIT_H)
	list_bottom := i32(52)
	if tag_ui.task_picker { list_bottom += 32 } // pomodoro row above the buttons
	place(hwnd, TAG_ID_LIST, 12, list_y, inner, h - list_y - list_bottom)
	if tag_ui.task_picker {
		// Pomodoro row: [x] Pomodoro mode [Ctrl+P]   [ 25 ^v] min
		row_y := h - 76
		check_w := text_size(TAG_LABEL_POMO, ui.font_normal).cx + 28
		place(hwnd, TAG_ID_POMO, 12, row_y, check_w, 24)
		ex := 12 + check_w + 12
		place(hwnd, TAG_ID_POMO_MIN, ex, row_y, 64, 24)
		if tag_ui.pomo_spin != nil && tag_ui.pomo_edit != nil { // re-attach so the arrows follow the moved EDIT
			windows.SendMessageW(tag_ui.pomo_spin, windows.UDM_SETBUDDY, windows.WPARAM(uintptr(tag_ui.pomo_edit)), 0)
		}
		place(hwnd, TAG_ID_POMO_UNIT, ex + 64 + 6, row_y + 4, 40, 20)
		// Buttons sized to their "Title [Keys]" labels: Add/Create left, Start/Cancel right.
		bw :: proc(label: string) -> i32 { return text_size(label, ui.font_normal).cx + 28 }
		aw, nw, sw, cw := bw(TAG_LABEL_ADD), bw(TAG_LABEL_CREATE), bw(TAG_LABEL_START), bw(TAG_LABEL_CANCEL)
		place(hwnd, TAG_ID_USE, 12, h - 40, aw, 28)
		place(hwnd, TAG_ID_CREATE, 12 + aw + 8, h - 40, nw, 28)
		place(hwnd, TAG_ID_CANCEL, w - 12 - cw, h - 40, cw, 28)
		place(hwnd, TAG_ID_START, w - 12 - cw - 8 - sw, h - 40, sw, 28)
		return
	}
	place(hwnd, TAG_ID_USE, 12, h - 40, 100, 28)
	place(hwnd, TAG_ID_CREATE, 120, h - 40, 140, 28)
	place(hwnd, TAG_ID_CANCEL, w - 12 - 120, h - 40, 120, 28)
}

// Start task picker button labels: "Title [Keymap]".
TAG_LABEL_ADD    :: "Add tag [Enter]"
TAG_LABEL_CREATE :: "Create tag [Shift+Enter]"
TAG_LABEL_START  :: "Start task [Ctrl+Enter]"
TAG_LABEL_CANCEL :: "Cancel [Esc]"
TAG_LABEL_POMO   :: "Pomodoro mode [Ctrl+P]"

tag_picker_min_size :: proc() -> (w, h: i32) {
	if tag_ui.task_picker { return TAG_TASK_POPUP_W, TAG_TASK_POPUP_H }
	return TAG_POPUP_W, TAG_POPUP_H
}

tag_picker_proc :: proc "std" (hwnd: windows.HWND, msg: u32, wp: windows.WPARAM, lp: windows.LPARAM) -> windows.LRESULT {
	context = rt.default_context()
	scratch: Scratch
	context.temp_allocator = scratch_begin(&scratch)
	defer scratch_end(&scratch)
	switch msg {
	case windows.WM_SIZE:
		tag_picker_layout(hwnd)
		windows.InvalidateRect(hwnd, nil, true)
		return 0
	case windows.WM_EXITSIZEMOVE:
		tag_picker_remember_size(hwnd)
		return 0
	case windows.WM_GETMINMAXINFO:
		mmi := transmute(^windows.MINMAXINFO)(lp)
		min_w, min_h := tag_picker_min_size()
		mmi.ptMinTrackSize = {min_w, min_h}
		return 0
	case windows.WM_LBUTTONDOWN:
		if tag_ui.task_picker {
			x, y := i32(i16(lp & 0xFFFF)), i32(i16((lp >> 16) & 0xFFFF))
			w, _ := client_size(hwnd)
			chips: [TAG_MAX_PICKS]Tag_Chip
			count, _ := tag_chip_layout(w, &chips)
			for i in 0 ..< count {
				if rect_hit(chips[i].cross, x, y) { tag_task_remove(i); break }
			}
		}
		return 0
	case windows.WM_ERASEBKGND:
		w, h := client_size(hwnd)
		fill_rect(windows.HDC(wp), 0, 0, w, h, C_PANEL)
		return 1
	case windows.WM_PAINT:
		ps: windows.PAINTSTRUCT
		dc := windows.BeginPaint(hwnd, &ps)
		w, _ := client_size(hwnd)
		windows.SetBkMode(dc, .TRANSPARENT)
		if tag_ui.task_picker { tag_draw_chips(dc, w) }
		tag_picker_draw_search(dc, w)
		windows.EndPaint(hwnd, &ps)
		return 0
	case windows.WM_CTLCOLOREDIT, windows.WM_CTLCOLORSTATIC, windows.WM_CTLCOLORLISTBOX:
		return theme_control_colors(wp)
	case windows.WM_CLOSE:
		tag_picker_close()
		return 0
	case windows.WM_COMMAND:
		id, code := u32(wp) & 0xFFFF, (u32(wp) >> 16) & 0xFFFF
		if id == TAG_ID_SEARCH && code == windows.EN_CHANGE && tag_ui.list != nil { tag_picker_filter() }
		if id == TAG_ID_LIST && code == LBN_SELCHANGE { tag_selection_sync() }
		if tag_ui.task_picker {
			if id == TAG_ID_LIST && code == LBN_DBLCLK { tag_task_add_selected() }
			switch id {
			case TAG_ID_POMO:   if code == windows.BN_CLICKED { tag_pomo_sync() }
			case TAG_ID_USE:    tag_task_add_selected()
			case TAG_ID_CREATE: tag_task_create()
			case TAG_ID_START:  tag_task_start()
			case TAG_ID_CANCEL: tag_picker_close()
			}
			return 0
		}
		if id == TAG_ID_LIST && code == LBN_DBLCLK {
			if tag_ui.multi {
				// The double click toggled the row twice; keep it ticked and accept.
				row := int(windows.SendMessageW(tag_ui.list, LB_GETCARETINDEX, 0, 0))
				if row >= 0 { windows.SendMessageW(tag_ui.list, LB_SETSEL, 1, windows.LPARAM(row)) }
			}
			tag_picker_accept(false)
		}
		if id == TAG_ID_USE { tag_picker_accept(false) }
		if id == TAG_ID_CREATE { tag_picker_accept(true) }
		if id == TAG_ID_CANCEL { tag_picker_close() }
		return 0
	}
	return windows.DefWindowProcW(hwnd, msg, wp, lp)
}

tag_picker_control :: proc(class, label: string, style: u32, x, y, w, h: i32, id: uintptr) -> windows.HWND {
	hwnd := windows.CreateWindowExW(0, wtext(class), wtext(label),
		windows.WS_CHILD | windows.WS_VISIBLE | style, x, y, w, h,
		tag_ui.popup, windows.HMENU(id), windows.HINSTANCE(windows.GetModuleHandleW(nil)), nil)
	if hwnd == nil { tag_ui.control_failed = true; return nil }
	windows.SendMessageW(hwnd, windows.WM_SETFONT, windows.WPARAM(ui.font_normal), 0)
	return hwnd
}

tag_picker_open :: proc() {
	if tag_ui.popup != nil { windows.SetForegroundWindow(tag_ui.popup); return }
	tag_ui.control_failed = false
	tag_ui.multi = !tag_ui.task_picker
	delete(tag_ui.selected)
	tag_ui.selected = nil
	hi := windows.HINSTANCE(windows.GetModuleHandleW(nil))
	wc := windows.WNDCLASSEXW{cbSize = size_of(windows.WNDCLASSEXW), lpfnWndProc = tag_picker_proc,
		hInstance = hi, hCursor = system_cursor(IDC_ARROW),
		hbrBackground = windows.HBRUSH(uintptr(16)), lpszClassName = wtext(TAG_POPUP_CLASS)}
	windows.RegisterClassExW(&wc)
	r: windows.RECT
	windows.GetWindowRect(ui.hwnd, &r)
	title := "Start task" if tag_ui.task_picker else "Tag selected time"
	min_w, min_h := tag_picker_min_size()
	pw, ph := max(tag_picker_size.x, min_w), max(tag_picker_size.y, min_h)
	tag_ui.popup = windows.CreateWindowExW(0, wtext(TAG_POPUP_CLASS), wtext(title),
		windows.WS_CAPTION | windows.WS_SYSMENU | windows.WS_THICKFRAME | windows.WS_CLIPCHILDREN,
		r.left + ((r.right - r.left) - pw) / 2, r.top + ((r.bottom - r.top) - ph) / 2,
		pw, ph, ui.hwnd, nil, hi, nil)
	if tag_ui.popup == nil { tag_ui.task_picker = false; return }
	if tag_ui.task_picker {
		tag_picker_icon = make_glyph_icon("▶")
		if tag_picker_icon != nil {
			windows.SendMessageW(tag_ui.popup, windows.WM_SETICON, 0, windows.LPARAM(uintptr(tag_picker_icon))) // ICON_SMALL
		}
	}
	tag_ui.list = nil
	description := "Add one or more tags to track from now." if tag_ui.task_picker else fmt.tprintf("%s - %s", fmt_clock_hm(tag_ui.start_ms), fmt_clock_hm(tag_ui.end_ms))
	tag_picker_control("STATIC", description, 0, 12, 12, 380, 20, TAG_ID_DESC)
	if !tag_ui.task_picker { // the task picker's chosen-tag chips take this spot
		hint := "Search tags or enter a new tag name:"
		if tag_ui.multi { hint = "Tick one or more tags, or type a new one:" }
		tag_picker_control("STATIC", hint, 0, 12, 36, 380, 20, TAG_ID_HINT)
	}
	// Final positions are set by tag_picker_layout below.
	tag_ui.search = tag_picker_control("EDIT", "", windows.WS_TABSTOP | windows.ES_AUTOHSCROLL, 0, 0, 100, TAG_EDIT_H, TAG_ID_SEARCH)
	edit_enable_word_delete(tag_ui.search)
	list_style := u32(windows.WS_BORDER | windows.WS_TABSTOP | windows.WS_VSCROLL | LBS_NOTIFY)
	if tag_ui.multi { list_style |= LBS_MULTIPLESEL }
	tag_ui.list = tag_picker_control("LISTBOX", "", list_style, 0, 0, 100, 100, TAG_ID_LIST)
	if tag_ui.task_picker {
		tag_picker_control("BUTTON", TAG_LABEL_ADD, windows.WS_TABSTOP | windows.BS_DEFPUSHBUTTON, 0, 0, 100, 28, TAG_ID_USE)
		tag_ui.create = tag_picker_control("BUTTON", TAG_LABEL_CREATE, windows.WS_TABSTOP, 0, 0, 100, 28, TAG_ID_CREATE)
		tag_picker_control("BUTTON", TAG_LABEL_START, windows.WS_TABSTOP | windows.WS_DISABLED, 0, 0, 100, 28, TAG_ID_START)
		tag_picker_control("BUTTON", TAG_LABEL_CANCEL, windows.WS_TABSTOP, 0, 0, 100, 28, TAG_ID_CANCEL)
		tag_ui.pomo_check = tag_picker_control("BUTTON", TAG_LABEL_POMO, windows.WS_TABSTOP | windows.BS_AUTOCHECKBOX, 0, 0, 200, 24, TAG_ID_POMO)
		tag_ui.pomo_edit = tag_picker_control("EDIT", fmt.tprintf("%d", pomodoro_minutes),
			windows.WS_TABSTOP | windows.WS_BORDER | windows.ES_NUMBER | windows.ES_AUTOHSCROLL, 0, 0, 64, 24, TAG_ID_POMO_MIN)
		tag_ui.pomo_spin = tag_picker_control(windows.UPDOWN_CLASS, "",
			windows.UDS_SETBUDDYINT | windows.UDS_ALIGNRIGHT | windows.UDS_ARROWKEYS | windows.UDS_NOTHOUSANDS,
			0, 0, 16, 24, TAG_ID_POMO_SPIN)
		tag_ui.pomo_unit = tag_picker_control("STATIC", "min", 0, 0, 0, 40, 20, TAG_ID_POMO_UNIT)
		if tag_ui.pomo_edit != nil && tag_ui.pomo_spin != nil {
			windows.SendMessageW(tag_ui.pomo_edit, EM_LIMITTEXT, 3, 0)
			windows.SendMessageW(tag_ui.pomo_spin, windows.UDM_SETBUDDY, windows.WPARAM(uintptr(tag_ui.pomo_edit)), 0)
			windows.SendMessageW(tag_ui.pomo_spin, windows.UDM_SETRANGE32, POMODORO_MIN_MINUTES, POMODORO_MAX_MINUTES)
			windows.SendMessageW(tag_ui.pomo_spin, windows.UDM_SETPOS32, 0, windows.LPARAM(pomodoro_minutes))
		}
		if tag_ui.pomo_check != nil && pomodoro_on {
			windows.SendMessageW(tag_ui.pomo_check, windows.BM_SETCHECK, windows.WPARAM(windows.BST_CHECKED), 0)
		}
	} else {
		tag_picker_control("BUTTON", "Use tags" if tag_ui.multi else "Use tag", windows.WS_TABSTOP | windows.BS_DEFPUSHBUTTON, 0, 0, 100, 28, TAG_ID_USE)
		tag_ui.create = tag_picker_control("BUTTON", "Add new tag" if tag_ui.multi else "Create tag", windows.WS_TABSTOP, 0, 0, 140, 28, TAG_ID_CREATE)
		tag_picker_control("BUTTON", "Cancel", windows.WS_TABSTOP, 0, 0, 120, 28, TAG_ID_CANCEL)
	}
	if tag_ui.control_failed { tag_picker_close(); return }
	tag_picker_layout(tag_ui.popup)
	tag_pomo_sync() // show or hide the duration for the remembered state
	tags, result := db_load_tags(&global_app.db)
	if result != .Ok {
		tag_picker_close()
		message_box("Could not load tags. Please try again.", "aika", windows.MB_ICONERROR)
		return
	}
	tag_ui.tags = tags
	tag_picker_filter()
	dark := windows.BOOL(ui.dark)
	DwmSetWindowAttribute(tag_ui.popup, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, size_of(dark))
	for ctl in ([]windows.HWND{tag_ui.search, tag_ui.list, tag_ui.create,
		windows.GetDlgItem(tag_ui.popup, i32(TAG_ID_USE)), windows.GetDlgItem(tag_ui.popup, i32(TAG_ID_START)),
		windows.GetDlgItem(tag_ui.popup, i32(TAG_ID_CANCEL)), tag_ui.pomo_check, tag_ui.pomo_edit, tag_ui.pomo_spin}) {
		if ctl != nil { SetWindowTheme(ctl, wtext("DarkMode_Explorer") if ui.dark else nil, nil) }
	}
	windows.EnableWindow(ui.hwnd, windows.FALSE)
	windows.ShowWindow(tag_ui.popup, windows.SW_SHOW)
	windows.SetFocus(tag_ui.search)
}

// Called before TranslateMessage so EDIT/LISTBOX keystrokes reach the picker.
tag_picker_key :: proc(msg: ^windows.MSG) -> bool {
	if tag_ui.popup == nil { return false }
	if msg.message == windows.WM_KEYDOWN && windows.GetFocus() == tag_ui.list && tag_ui.search != nil {
		// Typing while the list has focus must edit the search, not jump through
		// the list (type-ahead): move focus back and redirect the key there.
		vk := u32(msg.wParam)
		ctrl := windows.GetKeyState(windows.VK_CONTROL) < 0
		alt := windows.GetKeyState(windows.VK_MENU) < 0
		typing := (vk >= 0x30 && vk <= 0x5A) || (vk >= 0x60 && vk <= 0x6F) || (vk >= 0xBA && vk <= 0xE2) ||
			vk == u32(windows.VK_BACK) || vk == u32(windows.VK_DELETE) ||
			(vk == u32(windows.VK_SPACE) && !tag_ui.multi) // Space ticks rows in the multi list
		if typing && !alt && (!ctrl || vk == u32(windows.VK_BACK)) {
			windows.SetFocus(tag_ui.search)
			// Focusing a single-line EDIT selects its text; keep it and append instead.
			end := windows.GetWindowTextLengthW(tag_ui.search)
			windows.SendMessageW(tag_ui.search, EM_SETSEL, windows.WPARAM(end), windows.LPARAM(end))
			msg.hwnd = tag_ui.search
		}
	}
	if msg.message == windows.WM_KEYDOWN && tag_ui.pomo_edit != nil && windows.GetFocus() == tag_ui.pomo_edit && tag_ui.search != nil {
		// The duration only takes digits, and its ES_NUMBER EDIT would flash a
		// warning balloon on anything else. Letters, punctuation and Space instead
		// silently continue in the search field.
		vk := u32(msg.wParam)
		ctrl := windows.GetKeyState(windows.VK_CONTROL) < 0
		alt := windows.GetKeyState(windows.VK_MENU) < 0
		non_digit := (vk >= 0x41 && vk <= 0x5A) || (vk >= 0x6A && vk <= 0x6F) || (vk >= 0xBA && vk <= 0xE2) ||
			vk == u32(windows.VK_SPACE)
		if non_digit && !ctrl && !alt {
			tag_pomo_commit() // the duration is done; clamp and save what was typed
			windows.SetFocus(tag_ui.search)
			end := windows.GetWindowTextLengthW(tag_ui.search)
			windows.SendMessageW(tag_ui.search, EM_SETSEL, windows.WPARAM(end), windows.LPARAM(end))
			msg.hwnd = tag_ui.search
		}
	}
	if msg.message == windows.WM_KEYDOWN {
		if tag_ui.task_picker && msg.wParam == 'P' && windows.GetKeyState(windows.VK_CONTROL) < 0 &&
		   windows.GetKeyState(windows.VK_MENU) >= 0 {
			tag_pomo_toggle()
			return true
		}
		switch msg.wParam {
		case windows.VK_ESCAPE: tag_picker_close(); return true
		case windows.VK_RETURN:
			if tag_ui.task_picker {
				focus := windows.GetFocus()
				if focus == tag_ui.pomo_edit && windows.GetKeyState(windows.VK_CONTROL) >= 0 {
					tag_pomo_commit() // Enter in the duration just accepts it
					windows.SetFocus(tag_ui.search)
					return true
				}
				if windows.GetKeyState(windows.VK_CONTROL) < 0 { tag_task_start(); return true }
				if windows.GetKeyState(windows.VK_SHIFT) < 0 { tag_task_create(); return true }
				if focus == tag_ui.search || focus == tag_ui.list { tag_task_add_selected(); return true }
				break // a focused button activates through the dialog handling below
			}
			focus := windows.GetFocus()
			if focus == tag_ui.create { tag_picker_accept(true) } else {
				if focus != tag_ui.search && focus != tag_ui.list { break }
				tag_picker_accept(len(tag_ui.visible) == 0)
			}
			return true
		case windows.VK_DOWN:
			if windows.GetFocus() == tag_ui.search { windows.SetFocus(tag_ui.list); return true }
		}
	}
	return bool(windows.IsDialogMessageW(tag_ui.popup, msg))
}
