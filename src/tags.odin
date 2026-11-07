package main

import "core:fmt"
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
	tags: []Tag,
	visible: [dynamic]int,
	menu_open: bool,
	task_picker: bool,
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
	best := EDGE_HIT_PX + 1
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
			if distance <= EDGE_HIT_PX && (distance < best || (distance == best && (inside || !best_inside))) {
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
		if abs(x - tag_ui.down_x) >= CLICK_DRAG_PX && tag_ui.end_ms > tag_ui.start_ms { tag_picker_open() }
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

tag_picker_filter :: proc() {
	query := strings.to_lower(tag_search_text(), context.temp_allocator)
	clear(&tag_ui.visible)
	windows.SendMessageW(tag_ui.list, LB_RESETCONTENT, 0, 0)
	exact := false
	for tag, i in tag_ui.tags {
		lower := strings.to_lower(tag.name, context.temp_allocator)
		if lower == query { exact = true }
		if strings.contains(lower, query) {
			append(&tag_ui.visible, i)
			windows.SendMessageW(tag_ui.list, LB_ADDSTRING, 0, transmute(windows.LPARAM)(wtext(tag.name)))
		}
	}
	if len(tag_ui.visible) > 0 { windows.SendMessageW(tag_ui.list, LB_SETCURSEL, 0, 0) }
	windows.EnableWindow(tag_ui.create, windows.TRUE if query != "" && !exact else windows.FALSE)
}

tag_picker_close :: proc() {
	hwnd := tag_ui.popup
	tag_ui.popup = nil
	tag_ui.search, tag_ui.list, tag_ui.create = nil, nil, nil
	tag_ui.task_picker = false
	windows.EnableWindow(ui.hwnd, windows.TRUE)
	if hwnd != nil { windows.DestroyWindow(hwnd) }
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
	if !create {
		index := int(windows.SendMessageW(tag_ui.list, LB_GETCURSEL, 0, 0))
		if index < 0 || index >= len(tag_ui.visible) { return }
		tag := tag_ui.tags[tag_ui.visible[index]]
		id, name = tag.id, tag.name
	} else if name == "" { return }
	if tag_ui.task_picker {
		if !task_start(app, id, name, now_ms()) {
			message_box("Could not start task. The current time may already be tagged. Please select free time or try again.", "aika", windows.MB_ICONERROR)
			return
		}
		tag_picker_close()
		app.date = today_date_int()
		ui.lane = .Tags
		ui.list_scroll.pos, ui.totals_scroll.pos = 0, 0
		load_day(app)
		sync_date_picker(app)
		return
	}
	_, result := db_create_tag_block(&app.db, id, name, tag_ui.start_ms, tag_ui.end_ms)
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

tag_picker_proc :: proc "std" (hwnd: windows.HWND, msg: u32, wp: windows.WPARAM, lp: windows.LPARAM) -> windows.LRESULT {
	context = rt.default_context()
	scratch: Scratch
	context.temp_allocator = scratch_begin(&scratch)
	defer scratch_end(&scratch)
	switch msg {
	case windows.WM_ERASEBKGND:
		w, h := client_size(hwnd)
		fill_rect(windows.HDC(wp), 0, 0, w, h, C_PANEL)
		return 1
	case windows.WM_CTLCOLOREDIT, windows.WM_CTLCOLORSTATIC, windows.WM_CTLCOLORLISTBOX:
		return theme_control_colors(wp)
	case windows.WM_CLOSE:
		tag_picker_close()
		return 0
	case windows.WM_COMMAND:
		id, code := u32(wp) & 0xFFFF, (u32(wp) >> 16) & 0xFFFF
		if id == TAG_ID_SEARCH && code == windows.EN_CHANGE && tag_ui.list != nil { tag_picker_filter() }
		if id == TAG_ID_LIST && code == LBN_DBLCLK { tag_picker_accept(false) }
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
	hi := windows.HINSTANCE(windows.GetModuleHandleW(nil))
	wc := windows.WNDCLASSEXW{cbSize = size_of(windows.WNDCLASSEXW), lpfnWndProc = tag_picker_proc,
		hInstance = hi, hCursor = system_cursor(IDC_ARROW),
		hbrBackground = windows.HBRUSH(uintptr(16)), lpszClassName = wtext(TAG_POPUP_CLASS)}
	windows.RegisterClassExW(&wc)
	r: windows.RECT
	windows.GetWindowRect(ui.hwnd, &r)
	title := "Start task" if tag_ui.task_picker else "Tag selected time"
	tag_ui.popup = windows.CreateWindowExW(0, wtext(TAG_POPUP_CLASS), wtext(title),
		windows.WS_CAPTION | windows.WS_SYSMENU | windows.WS_CLIPCHILDREN,
		r.left + 80, r.top + 100, 420, 350, ui.hwnd, nil, hi, nil)
	if tag_ui.popup == nil { tag_ui.task_picker = false; return }
	tag_ui.list = nil
	description := "Choose a tag to track from now." if tag_ui.task_picker else fmt.tprintf("%s - %s", fmt_clock_hm(tag_ui.start_ms), fmt_clock_hm(tag_ui.end_ms))
	tag_picker_control("STATIC", description, 0, 12, 12, 380, 20, 0)
	tag_picker_control("STATIC", "Search tags or enter a new tag name:", 0, 12, 36, 380, 20, 0)
	tag_ui.search = tag_picker_control("EDIT", "", windows.WS_BORDER | windows.WS_TABSTOP | windows.ES_AUTOHSCROLL, 12, 58, 380, 24, TAG_ID_SEARCH)
	tag_ui.list = tag_picker_control("LISTBOX", "", windows.WS_BORDER | windows.WS_TABSTOP | windows.WS_VSCROLL | LBS_NOTIFY, 12, 90, 380, 162, TAG_ID_LIST)
	tag_picker_control("BUTTON", "Use tag", windows.WS_TABSTOP | windows.BS_DEFPUSHBUTTON, 12, 268, 100, 28, TAG_ID_USE)
	tag_ui.create = tag_picker_control("BUTTON", "Create tag", windows.WS_TABSTOP, 120, 268, 140, 28, TAG_ID_CREATE)
	tag_picker_control("BUTTON", "Cancel", windows.WS_TABSTOP, 272, 268, 120, 28, TAG_ID_CANCEL)
	if tag_ui.control_failed { tag_picker_close(); return }
	tags, result := db_load_tags(&global_app.db)
	if result != .Ok {
		tag_picker_close()
		message_box("Could not load tags. Please try again.", "aika", windows.MB_ICONERROR)
		return
	}
	tag_ui.tags = tags
	tag_picker_filter()
	windows.EnableWindow(ui.hwnd, windows.FALSE)
	windows.ShowWindow(tag_ui.popup, windows.SW_SHOW)
	windows.SetFocus(tag_ui.search)
}

// Called before TranslateMessage so EDIT/LISTBOX keystrokes reach the picker.
tag_picker_key :: proc(msg: ^windows.MSG) -> bool {
	if tag_ui.popup == nil { return false }
	if msg.message == windows.WM_KEYDOWN {
		switch msg.wParam {
		case windows.VK_ESCAPE: tag_picker_close(); return true
		case windows.VK_RETURN:
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
