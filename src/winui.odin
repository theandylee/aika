package main

import "core:strings"
import "core:fmt"
import "core:sys/windows"

// Native Win32 window layer: message loop, GDI helpers, UI state.
// Replaces the raylib window. All drawing goes through ui.odin into a
// memory DC (double buffering); repaints are on-demand (timer + input).

rgb :: proc "c" (r, g, b: i32) -> windows.COLORREF {
	return windows.COLORREF((u32(b) << 16) | (u32(g) << 8) | u32(r))
}

// Window procs and GDI callbacks run with a non-default calling convention,
// which is contextless in Odin; restore the default context so plain procs
// (allocating text conversions, etc.) can be called from them.
import rt "base:runtime"

// --- UI state ---

PaneScroll :: struct {
	hwnd: windows.HWND,
	pos, rows, page: i32, // row units, not pixels
	wheel_delta: i32,
	visible: bool,
	bounds: windows.RECT,
}

Zoom_Drag :: enum { None, Left, Right, Overview, Timeline }

UiState :: struct {
	dark:         bool,
	hwnd:         windows.HWND,
	tray_hwnd:    windows.HWND,
	tray_menu_open: bool,
	tray_added:   bool,
	taskbar_created: u32,
	edit:         windows.HWND,
	date_picker:  windows.HWND,
	date_popup, date_calendar: windows.HWND,
	mem_dc:       windows.HDC,
	mem_bmp:      windows.HBITMAP,
	mem_bmp_old:  windows.HGDIOBJ,
	mem_w, mem_h: i32,
	mem_valid:    bool,
	main_class, tray_class: bool,

	font_normal: windows.HFONT, // 12px Segoe UI
	font_bold:   windows.HFONT, // 12px bold
	font_small:  windows.HFONT, // 11px
	font_title:  windows.HFONT, // 20px bold (day header)
	font_icons:  windows.HFONT, // standard monochrome sun/moon symbols
	theme_button: Theme_Handle,
	theme_tab:    Theme_Handle,
	pressed_hit:  int,

	mouse:       windows.POINT, // client coords, refreshed each paint
	mouse_valid: bool,
	mouse_tracking: bool,          // TME_LEAVE armed; cleared by WM_MOUSELEAVE
	hover_painted: Hover_Signature, // what the last frame drew for the cursor
	grab_cursor: windows.HCURSOR,

	filter:      string,
	tab:         i32,  // 0 = Day, 1 = Timesheet, 2 = Statistics
	lane:        i32,  // selected timeline lane (0..2)
	list_scroll, totals_scroll: PaneScroll,
	totals_tree: bool,
	totals_expanded: map[string]bool,
	scroll_date: int,
	zoom_start, zoom_end: f64,
	zoom_drag: Zoom_Drag,
	zoom_drag_anchor, zoom_drag_start, zoom_drag_end: f64,
	pane_lane_h, pane_totals_w: i32, // zero = default; retained for this session
	pane_drag: i32, // 1 = timeline height, 2 = list/totals width
	pane_drag_offset: i32,
	pane_saved_lane_h, pane_saved_totals_w: i32,
}

ui: UiState

// Hit target ids for the composite hit test.
HIT_NONE        :: 0
HIT_BTN_PREV    :: 1
HIT_BTN_TODAY   :: 2
HIT_BTN_NEXT    :: 3
HIT_BTN_TASK    :: 4
HIT_ZOOM_OUT    :: 5
HIT_ZOOM_IN     :: 6
HIT_ZOOM_RESET  :: 7
HIT_THEME       :: 8
HIT_TOTALS_TREE :: 9
HIT_TOTALS_ROW  :: 30
HIT_SETTINGS    :: 31
HIT_TAB_BASE    :: 10 // +0..2
HIT_LANE_BASE   :: 20 // +0..3

WNDC_CLASS :: "aika_window_class"
APP_TIMER_ID :: 1
TRAY_MESSAGE :: windows.WM_APP + 1
TRAY_SHOW_MENU :: windows.WM_APP + 2
TRAY_ICON_ID :: 1
TRAY_OPEN :: 1001
TRAY_EXIT :: 1002
TRAY_SETTINGS :: 1003

// Keep the icon available even while the window is visible. Use the legacy
// callback format (uID in wParam, mouse message in lParam).
ui_add_tray :: proc() -> bool {
	if ui.tray_hwnd == nil { return false }
	data := windows.NOTIFYICONDATAW{
		cbSize = size_of(windows.NOTIFYICONDATAW), hWnd = ui.tray_hwnd,
		uID = TRAY_ICON_ID, uFlags = windows.NIF_MESSAGE | windows.NIF_ICON | windows.NIF_TIP,
		uCallbackMessage = TRAY_MESSAGE,
		hIcon = windows.LoadIconW(nil, transmute(cstring16)(u64(32512))), // IDI_APPLICATION (shared)
	}
	copy(data.szTip[:], windows.utf8_to_utf16("aika", context.temp_allocator))
	ui.tray_added = bool(windows.Shell_NotifyIconW(windows.NIM_ADD, &data))
	return ui.tray_added
}

ui_remove_tray :: proc() {
	if !ui.tray_added { return }
	data := windows.NOTIFYICONDATAW{
		cbSize = size_of(windows.NOTIFYICONDATAW), hWnd = ui.tray_hwnd, uID = TRAY_ICON_ID,
	}
	windows.Shell_NotifyIconW(windows.NIM_DELETE, &data)
	ui.tray_added = false
}

ui_restore :: proc() {
	if windows.IsIconic(ui.hwnd) {
		windows.ShowWindow(ui.hwnd, windows.SW_RESTORE)
	} else {
		windows.ShowWindow(ui.hwnd, windows.SW_SHOW)
	}
	windows.SetForegroundWindow(ui.hwnd)
	if tag_ui.popup != nil { windows.SetForegroundWindow(tag_ui.popup) }
	if settings_ui.hwnd != nil { windows.SetForegroundWindow(settings_ui.hwnd) }
	windows.InvalidateRect(ui.hwnd, nil, windows.FALSE)
}

ui_tray_menu :: proc() {
	if ui.tray_menu_open { return }
	ui.tray_menu_open = true
	defer { ui.tray_menu_open = false }
	menu := windows.CreatePopupMenu()
	if menu == nil { return }
	defer windows.DestroyMenu(menu)
	windows.AppendMenuW(menu, 0, TRAY_OPEN, wtext("Open aika"))
	windows.AppendMenuW(menu, 0, TRAY_SETTINGS, wtext("Settings..."))
	windows.AppendMenuW(menu, 0, TRAY_EXIT, wtext("Exit"))
	p: windows.POINT
	windows.GetCursorPos(&p)
	// Keep the visible, enabled app window as the menu owner. Activating the
	// hidden callback window while our main window is active steals activation
	// from it and can cause shell/menu focus handling to dismiss the popup.
	// A modal picker owns its menu instead of its disabled parent; when hidden
	// to the tray the independent callback window remains the fallback owner.
	owner := ui.tray_hwnd
	if windows.IsWindowVisible(ui.hwnd) && windows.IsWindowEnabled(ui.hwnd) { owner = ui.hwnd }
	if tag_ui.popup != nil && windows.IsWindowVisible(tag_ui.popup) { owner = tag_ui.popup }
	if settings_ui.hwnd != nil && windows.IsWindowVisible(settings_ui.hwnd) { owner = settings_ui.hwnd }
	// Drop any in-progress drag before entering the native menu loop.
	if capture := windows.GetCapture(); capture != nil {
		windows.SendMessageW(capture, windows.WM_CANCELMODE, 0, 0)
		windows.ReleaseCapture()
	}
	windows.SetForegroundWindow(owner)
	command := windows.TrackPopupMenu(menu, 0x0102, p.x, p.y, 0, owner, nil)
	windows.PostMessageW(owner, windows.WM_NULL, 0, 0)
	if command != 0 { windows.SendMessageW(ui.hwnd, windows.WM_COMMAND, windows.WPARAM(command), 0) }
}

// Keep shell callbacks independent of main-window capture and modal pickers.
// Defer menu tracking until after the shell's mouse callback has returned.
tray_wnd_proc :: proc "std" (hwnd: windows.HWND, msg: u32, wp: windows.WPARAM, lp: windows.LPARAM) -> windows.LRESULT {
	context = rt.default_context()
	scratch: Scratch
	context.temp_allocator = scratch_begin(&scratch)
	defer scratch_end(&scratch)
	if ui.taskbar_created != 0 && msg == ui.taskbar_created {
		ui.tray_added = false
		if !ui_add_tray() { ui_restore() }
		return 0
	}
	switch msg {
	case TRAY_MESSAGE:
		if wp != TRAY_ICON_ID { return 0 }
		switch u32(lp) {
		case windows.WM_LBUTTONUP, windows.WM_LBUTTONDBLCLK:
			ui_restore()
		case windows.WM_RBUTTONUP, windows.WM_CONTEXTMENU:
			windows.PostMessageW(hwnd, TRAY_SHOW_MENU, 0, 0)
		}
		return 0
	case TRAY_SHOW_MENU:
		ui_tray_menu()
		return 0
	}
	return windows.DefWindowProcW(hwnd, msg, wp, lp)
}

// --- UTF-8 -> UTF-16 helpers for GDI text calls ---

wtext :: proc(s: string) -> windows.LPCWSTR {
	return windows.utf8_to_wstring(s, context.temp_allocator)
}

text_pixel_width :: proc(s: string, font: windows.HFONT) -> i32 {
	return _measure_text(s, font).cx
}

// --- GDI helpers ---

_fill :: proc(dc: windows.HDC, r: windows.RECT, color: windows.COLORREF) {
	windows.SetDCBrushColor(dc, color)
	rc := r
	windows.FillRect(dc, &rc, windows.HBRUSH(windows.GetStockObject(windows.DC_BRUSH)))
}

fill_rect :: proc(dc: windows.HDC, x, y, w, h: i32, color: windows.COLORREF) {
	if w <= 0 || h <= 0 { return }
	r := windows.RECT{x, y, x + w, y + h}
	_fill(dc, r, color)
}

fill_frame :: proc(dc: windows.HDC, x, y, w, h: i32, color: windows.COLORREF) {
	fill_rect(dc, x, y, w, 1, color)
	fill_rect(dc, x, y + h - 1, w, 1, color)
	fill_rect(dc, x, y, 1, h, color)
	fill_rect(dc, x + w - 1, y, 1, h, color)
}

// 1px line via a filled rect (no pen state juggling).
line_v :: proc(dc: windows.HDC, x, y, h: i32, color: windows.COLORREF) {
	fill_rect(dc, x, y, 1, h, color)
}

line_h :: proc(dc: windows.HDC, x, y, w: i32, color: windows.COLORREF) {
	fill_rect(dc, x, y, w, 1, color)
}

_measure_text :: proc(s: string, font: windows.HFONT) -> (size: windows.SIZE) {
	// The backbuffer is screen-compatible, so its metrics match the window's.
	// Acquiring a window DC per measurement cost ~12x the measurement itself.
	if ui.mem_valid && ui.mem_dc != nil { return measure_text_dc(ui.mem_dc, s, font) }
	dc := windows.GetDC(ui.hwnd)
	defer windows.ReleaseDC(ui.hwnd, dc)
	return measure_text_dc(dc, s, font)
}

measure_text_dc :: proc(dc: windows.HDC, s: string, font: windows.HFONT) -> (size: windows.SIZE) {
	text := windows.utf8_to_utf16(s, context.temp_allocator)
	old := windows.SelectObject(dc, windows.HGDIOBJ(font))
	defer windows.SelectObject(dc, old)
	if len(text) == 0 {
		return size
	}
	windows.GetTextExtentPoint32W(dc, windows.LPCWSTR(raw_data(text)), i32(len(text)), &size)
	return
}

text_size :: proc(s: string, font: windows.HFONT) -> windows.SIZE {
	return _measure_text(s, font)
}

// Draw a single line of UTF-8 text, truncated with an end ellipsis exactly
// like DrawTextW(DT_END_ELLIPSIS) when it does not fit in max_w.
draw_string :: proc(dc: windows.HDC, s: string, x, y: i32, font: windows.HFONT, color: windows.COLORREF, max_w: i32 = 1_000_000) {
	if len(s) == 0 || max_w <= 0 {
		return
	}
	text := windows.utf8_to_utf16(s, context.temp_allocator)
	if len(text) == 0 { return }
	windows.SetTextColor(dc, color)
	dc_font := windows.SelectObject(dc, windows.HGDIOBJ(font))
	defer windows.SelectObject(dc, dc_font)
	// Fast path (measured ~3-7 us vs 15-55 us per call): text that fits is drawn
	// by ExtTextOutW at the same top-left with the same clip rectangle. Glyph
	// placement follows GetTextExtentPoint32W, which layout already uses; DrawTextW
	// applies pair kerning and can place glyphs after a kerned pair 1 px further
	// left. Overflowing text reproduces DrawTextW's kerned end ellipsis exactly
	// (end_ellipsis_layout) or falls back to DrawTextW itself.
	r := windows.RECT{x, y - 2, x + max_w, y + 32}
	size: windows.SIZE
	if windows.GetTextExtentPoint32W(dc, windows.LPCWSTR(raw_data(text)), i32(len(text)), &size) &&
	   size.cy <= r.bottom - r.top {
		if size.cx <= max_w {
			if ExtTextOutW(dc, x, y - 2, ETO_CLIPPED, &r, windows.LPCWSTR(raw_data(text)), u32(len(text)), nil) { return }
		} else if out, dx, ok := end_ellipsis_layout(dc, text, max_w); ok {
			if ExtTextOutW(dc, x, y - 2, ETO_CLIPPED, &r, windows.LPCWSTR(raw_data(out)), u32(len(out)), raw_data(dx)) { return }
		}
	}
	flags := windows.DrawTextFormat.DT_SINGLELINE |
		windows.DrawTextFormat.DT_NOPREFIX |
		windows.DrawTextFormat.DT_END_ELLIPSIS
	windows.DrawTextW(dc, windows.LPCWSTR(raw_data(text)), i32(len(text)), &r, flags)
}

// DrawTextW (DT_SINGLELINE | DT_END_ELLIPSIS) lays text out with pair kerning.
// If that does not fit it keeps the longest prefix whose own kerned width plus
// the width of "..." fits, and never less than the first character (clipped
// when even that is too wide). This reproduces it with GetCharacterPlacementW,
// whose kerned advances drawn by ExtTextOutW are pixel-identical to DrawTextW,
// but only when every code unit is a simple BMP character that the selected
// font maps to its own glyph, one glyph per unit: GetCharacterPlacementW does
// not follow font linking, mis-measures surrogate pairs and reports ligature
// advances per glyph. Measured ~2.5x cheaper than DrawTextW for tag labels and
// list titles (two GetCharacterPlacementW calls). Returns the units to draw
// with their advances in scratch memory, or ok=false when the caller must
// fall back to DrawTextW.
end_ellipsis_layout :: proc(dc: windows.HDC, text: []u16, max_w: i32) -> (out: []u16, dx: []i32, ok: bool) {
	n := len(text)
	if n == 0 || max_w <= 0 { return }
	for u in text {
		if !end_ellipsis_simple(u) { return }
	}
	glyphs := make([]u16, n, context.temp_allocator)
	if GetGlyphIndicesW(dc, windows.LPCWSTR(raw_data(text)), i32(n), raw_data(glyphs), GGI_MARK_NONEXISTING_GLYPHS) != u32(n) {
		return
	}
	for g in glyphs {
		if g == 0xFFFF { return } // drawn from a linked fallback font
	}
	// Kerned advances, one per unit. A ligature or other substitution makes
	// them per glyph, so require exactly one glyph per unit.
	place :: proc(dc: windows.HDC, units: []u16, dx: []i32, glyphs: []u16) -> (w: i32, ok: bool) {
		res := GCP_RESULTSW{size = size_of(GCP_RESULTSW), dx = raw_data(dx), glyphs = raw_data(glyphs), n_glyphs = u32(len(units))}
		packed := GetCharacterPlacementW(dc, windows.LPCWSTR(raw_data(units)), i32(len(units)), 0, &res, GCP_USEKERNING)
		if packed == 0 || res.n_glyphs != u32(len(units)) { return }
		for d in dx[:len(units)] { w += d }
		// The advances must add up to the reported extent (low word).
		return w, w & 0xFFFF == i32(packed & 0xFFFF)
	}
	buf := make([]u16, n + 3, context.temp_allocator)
	cur := make([]i32, n + 3, context.temp_allocator)
	placed := make([]u16, n + 3, context.temp_allocator)
	copy(buf, text)
	full := place(dc, buf[:n], cur, placed) or_return
	for g, i in glyphs {
		if placed[i] != g { return } // substituted glyph (ligature)
	}
	if full <= max_w { return text, cur[:n], true }

	// DrawTextW keeps the longest prefix (at least one unit) whose kerned width
	// laid out on its own, plus the width of "...", fits. Kerning is per pair,
	// so that width is the line's kerned advances before the last kept unit
	// plus that unit's own advance. Then prefix + "..." is laid out kerned
	// together, as DrawTextW draws it.
	dots_size: windows.SIZE
	dots := [3]u16{'.', '.', '.'}
	if !windows.GetTextExtentPoint32W(dc, windows.LPCWSTR(&dots[0]), 3, &dots_size) { return }
	avail := max_w - dots_size.cx
	pos := make([]i32, n + 1, context.temp_allocator) // kerned advance of text[:i]
	for d, i in cur[:n] { pos[i + 1] = pos[i] + d }
	own_width :: proc(dc: windows.HDC, text: []u16, pos: []i32, k: int) -> (w: i32, ok: bool) {
		own: i32
		if !GetCharWidth32W(dc, u32(text[k - 1]), u32(text[k - 1]), &own) { return }
		return pos[k - 1] + own, true
	}
	// Estimate with the kerning across the cut, then settle on exact widths.
	k := 1
	for k + 1 < n && pos[k + 1] <= avail { k += 1 }
	w := own_width(dc, text, pos, k) or_return
	if w > avail {
		for k > 1 && w > avail {
			k -= 1
			w = own_width(dc, text, pos, k) or_return
		}
	} else {
		for k + 1 < n {
			nw := own_width(dc, text, pos, k + 1) or_return
			if nw > avail { break }
			k += 1
		}
	}
	copy(buf[k:k + 3], dots[:])
	place(dc, buf[:k + 3], cur, placed) or_return
	return buf[:k + 3], cur[:k + 3], true
}

// One glyph per BMP code unit, left to right, with no combining, joining,
// variation, format or surrogate units: kerned GDI placement matches DrawTextW.
end_ellipsis_simple :: proc(u: u16) -> bool {
	switch u {
	case 0x20 ..= 0x7E, 0xA0 ..= 0xAC, 0xAE ..= 0x2FF, // Latin (no soft hyphen; combining marks start at U+0300)
	     0x370 ..= 0x482, 0x48A ..= 0x52F, // Greek, Cyrillic without combining marks
	     0x1E00 ..= 0x1FFF, // Latin/Greek extended
	     0x2000 ..= 0x200A, 0x2010 ..= 0x2027, 0x202F ..= 0x205F, 0x2070 ..= 0x20CF, // spaces, punctuation, currency
	     0x2100 ..= 0x2BFF, // letterlike, arrows, math, shapes, symbols
	     0x2E80 ..= 0x3029, 0x3030 ..= 0x3098, 0x309B ..= 0x30FF, // CJK radicals, punctuation, kana
	     0x3400 ..= 0x4DBF, 0x4E00 ..= 0x9FFF, 0xAC00 ..= 0xD7A3, 0xF900 ..= 0xFAFF, // ideographs, Hangul
	     0xFF01 ..= 0xFFEF: // half/full width forms
		return true
	}
	return false
}

// Button captions use the actual font metrics rather than a fixed baseline.
draw_button_text :: proc(dc: windows.HDC, label: string, bounds: windows.RECT, centered: bool = true) {
	if len(label) == 0 { return }
	r := bounds
	old := windows.SelectObject(dc, windows.HGDIOBJ(ui.font_normal))
	defer windows.SelectObject(dc, old)
	windows.SetBkMode(dc, windows.BKMODE.TRANSPARENT)
	windows.SetTextColor(dc, C_TXT)
	flags := windows.DrawTextFormat.DT_SINGLELINE | windows.DrawTextFormat.DT_VCENTER |
		windows.DrawTextFormat.DT_NOPREFIX | windows.DrawTextFormat.DT_END_ELLIPSIS
	if centered { flags |= windows.DrawTextFormat.DT_CENTER }
	windows.DrawTextW(dc, wtext(label), -1, &r, flags)
}

// --- Timer tick (2 Hz timer, tracker still samples at 1 Hz internally) ---

app_tick :: proc(app: ^App) {
	now := now_ms()
	tracker_tick(app, now) // also retries pending writes while sampling is paused
	if !task_tick(app, now) {
		task_clear(&app.task)
		message_box("Task tracking stopped because its tag block could not be updated. The last saved time is preserved.", "aika", 0x10)
	}
	mono := monotonic_ms()
	if (app.date != app.loaded_date || app.load_result != .Ok || mono - app.last_load_ms >= 10_000) &&
	   mono - app.last_load_attempt_ms >= 1000 {
		load_day(app)
		sync_date_picker(app)
	}
	ui_storage_title(app)
	windows.InvalidateRect(ui.hwnd, nil, windows.FALSE)
}

ui_storage_title :: proc(app: ^App) {
	status := app_storage_status(app)
	title := "aika" if status == "" else fmt.tprintf("aika - %s", status)
	windows.SetWindowTextW(ui.hwnd, wtext(title))
}

ui_request_exit :: proc(app: ^App) -> bool {
	// Do not destroy the window/message loop while it owns unsaved intervals.
	// A failed Exit stays visible and retries; a later Exit can then succeed.
	if !task_stop(app, now_ms()) {
		message_box("Could not save the final task time. Exit cancelled; please try again.", "aika", 0x10)
		return false
	}
	if !tracker_shutdown(app) {
		tracker_resume(app)
		ui_restore()
		ui_storage_title(app)
		message_box("Tracking writes remain unsaved. Exit cancelled; aika will retry. Please try Exit again after the save error clears.", "aika", 0x10)
		return false
	}
	return true
}

// --- Resize handling ---

Backbuffer_IO :: struct {
	create_dc: type_of(windows.CreateCompatibleDC),
	create_bitmap: type_of(windows.CreateCompatibleBitmap),
	select_object: type_of(windows.SelectObject),
}

release_backbuffer :: proc(s: ^UiState) {
	if s.mem_dc != nil && s.mem_bmp_old != nil { windows.SelectObject(s.mem_dc, s.mem_bmp_old) }
	if s.mem_bmp != nil { windows.DeleteObject(windows.HGDIOBJ(s.mem_bmp)) }
	if s.mem_dc != nil { windows.DeleteDC(s.mem_dc) }
	s.mem_dc, s.mem_bmp, s.mem_bmp_old = nil, nil, nil
	s.mem_valid = false
	s.mem_w, s.mem_h = 0, 0
}

// Build off to the side: failure preserves the previous valid buffer, and
// releases every partially acquired resource. The caller never blits a stale size.
create_backbuffer :: proc(s: ^UiState, dc: windows.HDC, w, h: i32, io := Backbuffer_IO{}) -> bool {
	if dc == nil || w <= 0 || h <= 0 { return false }
	ops := io
	if ops.create_dc == nil { ops.create_dc = windows.CreateCompatibleDC }
	if ops.create_bitmap == nil { ops.create_bitmap = windows.CreateCompatibleBitmap }
	if ops.select_object == nil { ops.select_object = windows.SelectObject }
	next: UiState
	defer release_backbuffer(&next)
	next.mem_dc = ops.create_dc(dc)
	if next.mem_dc == nil { return false }
	next.mem_bmp = ops.create_bitmap(dc, w, h)
	if next.mem_bmp == nil { return false }
	next.mem_bmp_old = ops.select_object(next.mem_dc, windows.HGDIOBJ(next.mem_bmp))
	if next.mem_bmp_old == nil || uintptr(next.mem_bmp_old) == ~uintptr(0) {
		next.mem_bmp_old = nil
		return false
	}
	release_backbuffer(s)
	s.mem_dc, s.mem_bmp, s.mem_bmp_old = next.mem_dc, next.mem_bmp, next.mem_bmp_old
	s.mem_w, s.mem_h, s.mem_valid = w, h, true
	next.mem_dc, next.mem_bmp, next.mem_bmp_old = nil, nil, nil
	return true
}

recreate_backbuffer :: proc(w, h: i32) -> bool {
	if w <= 0 || h <= 0 { release_backbuffer(&ui); return true }
	dc := windows.GetDC(ui.hwnd)
	if dc == nil { return false }
	defer windows.ReleaseDC(ui.hwnd, dc)
	ok := create_backbuffer(&ui, dc, w, h)

	// Move the filter edit control to the bottom of the client area.
	if ui.edit != nil {
		lay := compute_layout(w, h)
		windows.MoveWindow(
			ui.edit,
			lay.filter_edit_x, lay.filter_edit_y,
			lay.filter_edit_w, lay.filter_edit_h,
			windows.TRUE,
		)
	}
	ui_resize_date_picker(w, h)
	return ok
}

ui_edit_valid :: proc() -> bool {
	return ui.edit != nil
}

// Keep the date picker aligned with the toolbar layout on resize.
ui_resize_date_picker :: proc(w, h: i32) {
	if ui.date_picker == nil {
		return
	}
	lay := compute_layout(w, h)
	r := lay.date_pick
	windows.MoveWindow(ui.date_picker, r.left, r.top, r.right - r.left, r.bottom - r.top, windows.TRUE)
}

// Keep the date button label and calendar selection synchronized.
sync_date_picker :: proc(app: ^App) {
	if ui.date_picker == nil {
		return
	}
	st := date_systemtime(app.date)
	windows.SetWindowTextW(ui.date_picker, wtext(date_label(app.date)))
	if ui.date_calendar != nil {
		windows.SendMessageW(ui.date_calendar, 0x1002, 0, windows.LPARAM(uintptr(&st))) // MCM_SETCURSEL
	}
	windows.InvalidateRect(ui.date_picker, nil, windows.TRUE)
}

// --- WndProc ---

pane_scroll_show :: proc(s: ^PaneScroll, show: bool) {
	if s.hwnd != nil && s.visible != show {
		s.visible = show
		windows.ShowWindow(s.hwnd, windows.SW_SHOW if show else windows.SW_HIDE)
	}
}

// A native scrollbar sits beside the rows, leaving headers and totals fixed.
// Returns the width reserved for the scrollbar (zero when all rows fit).
pane_scroll_update :: proc(s: ^PaneScroll, rows, page: i32, right, top, bottom: i32) -> i32 {
	s.rows = rows
	s.page = max(1, page)
	s.pos = clamp(s.pos, 0, max(0, rows - s.page))
	show := ui.tab == 0 && rows > s.page && bottom > top
	width := i32(windows.GetSystemMetrics(windows.SM_CXVSCROLL))
	if show {
		r := windows.RECT{right - width, top, right, bottom}
		if s.bounds != r {
			s.bounds = r
			windows.MoveWindow(s.hwnd, r.left, r.top, width, bottom - top, windows.TRUE)
		}
	}
	info := Scroll_Info{cbSize = size_of(Scroll_Info), fMask = 7, // SIF_RANGE | SIF_PAGE | SIF_POS
		nMax = max(0, rows - 1), nPage = u32(s.page), nPos = s.pos}
	SetScrollInfo(s.hwnd, 2, &info, windows.TRUE) // SB_CTL
	pane_scroll_show(s, show)
	return width if show else 0
}

pane_scroll_message :: proc(s: ^PaneScroll, command: i32) {
	switch command {
	case 0: s.pos -= 1 // SB_LINEUP
	case 1: s.pos += 1 // SB_LINEDOWN
	case 2: s.pos -= s.page
	case 3: s.pos += s.page
	case 4, 5: // SB_THUMBPOSITION / SB_THUMBTRACK; query the full 32-bit position.
		info := Scroll_Info{cbSize = size_of(Scroll_Info), fMask = 0x10}
		if GetScrollInfo(s.hwnd, 2, &info) { s.pos = info.nTrackPos }
	case 6: s.pos = 0
	case 7: s.pos = s.rows - s.page
	}
	s.pos = clamp(s.pos, 0, max(0, s.rows - s.page))
}

pane_scroll_wheel :: proc(s: ^PaneScroll, delta: i32) {
	s.wheel_delta += delta
	steps := s.wheel_delta / 120
	s.wheel_delta %= 120
	s.pos = clamp(s.pos - steps * 3, 0, max(0, s.rows - s.page))
}

ui_close_themes :: proc() {
	if ui.theme_button != nil { CloseThemeData(ui.theme_button) }
	if ui.theme_tab != nil { CloseThemeData(ui.theme_tab) }
	ui.theme_button = nil
	ui.theme_tab = nil
}

ui_open_themes :: proc() {
	ui_close_themes()
	ui.theme_button = OpenThemeData(ui.hwnd, wtext("Button"))
	ui.theme_tab = OpenThemeData(ui.hwnd, wtext("Tab"))
}

// Return false when visual styles are unavailable so callers can use GDI.
draw_themed_control :: proc(dc: windows.HDC, theme: Theme_Handle, part, state: i32, r: windows.RECT, label: string) -> bool {
	if ui.dark || theme == nil { return false }
	rc := r
	if DrawThemeBackground(theme, dc, part, state, &rc, nil) < 0 { return false }
	old := windows.SelectObject(dc, windows.HGDIOBJ(ui.font_normal))
	defer windows.SelectObject(dc, old)
	flags := windows.DrawTextFormat.DT_SINGLELINE | windows.DrawTextFormat.DT_CENTER |
		windows.DrawTextFormat.DT_VCENTER | windows.DrawTextFormat.DT_NOPREFIX
	text := wtext(label)
	DrawThemeText(theme, dc, part, state, text, -1, u32(flags), 0, &rc)
	return true
}

wnd_proc :: proc "std" (hwnd: windows.HWND, msg: u32, wparam: windows.WPARAM, lparam: windows.LPARAM) -> windows.LRESULT {
	context = rt.default_context()
	scratch: Scratch
	context.temp_allocator = scratch_begin(&scratch)
	defer scratch_end(&scratch)
	app := global_app
	switch msg {
	case windows.WM_CLOSE:
		// Never hide if the shell cannot provide a way to reopen/exit.
		if ui.tray_added || ui_add_tray() {
			windows.ShowWindow(hwnd, windows.SW_HIDE)
		} else {
			message_box("Could not create the system tray icon. aika will stay open.", "aika", 0x30)
		}
		return 0
	case TRAY_MESSAGE:
		windows.PostMessageW(ui.tray_hwnd, msg, wparam, lparam)
		return 0
	case 0x031A: // WM_THEMECHANGED: cached theme handles are no longer valid.
		ui_open_themes()
		windows.InvalidateRect(hwnd, nil, windows.FALSE)
		return 0
	case windows.WM_ERASEBKGND:
		return 1 // no flicker: everything is drawn in WM_PAINT
	case windows.WM_CTLCOLOREDIT, windows.WM_CTLCOLORSTATIC, windows.WM_CTLCOLORLISTBOX:
		return theme_control_colors(wparam)
	case windows.WM_PAINT:
		ps: windows.PAINTSTRUCT
		dc := windows.BeginPaint(hwnd, &ps)
		defer windows.EndPaint(hwnd, &ps)
		w, h := client_size(hwnd)
		if !ui.mem_valid || ui.mem_w != w || ui.mem_h != h {
			recreate_backbuffer(w, h)
		}
		if ui.mem_valid && ui.mem_w == w && ui.mem_h == h {
			// Keep the cursor position current even without mouse-move spam.
			_update_mouse_client()
			dc_buffer := ui.mem_dc
			draw_frame(app, dc_buffer, w, h)
			windows.BitBlt(dc, 0, 0, w, h, dc_buffer, 0, 0, windows.SRCCOPY)
		} else {
			fill_rect(dc, 0, 0, w, h, C_BG)
			draw_string(dc, "Unable to allocate drawing buffer. Resize to retry.", 16, 40, ui.font_normal, C_TXT)
			ui.hover_painted = {} // nothing hover-dependent is drawn
		}
		return 0
	case windows.WM_TIMER:
		if int(wparam) == APP_TIMER_ID {
			app_tick(app)
		}
		return 0
	case windows.WM_SIZE:
		u32l := u32(lparam)
		w := i32(u32l & 0xFFFF)
		h := i32((u32l >> 16) & 0xFFFF)
		recreate_backbuffer(w, h)
		return 0
	case windows.WM_MOUSEMOVE:
		win_x := i32(i16(u32(lparam) & 0xFFFF))
		win_y := i32(i16((u32(lparam) >> 16) & 0xFFFF))
		if ui.pane_drag != 0 {
			w, h := client_size(hwnd)
			pane_pointer_move(win_x, win_y, compute_layout(w, h))
			windows.InvalidateRect(hwnd, nil, windows.FALSE)
			return 0
		}
		if tag_ui.drag != 0 {
			w, h := client_size(hwnd)
			tag_pointer_move(win_x, compute_layout(w, h), app.activities)
			windows.InvalidateRect(hwnd, nil, windows.FALSE)
		}
		if ui.zoom_drag != .None {
			w, h := client_size(hwnd)
			zoom_pointer_move(win_x, compute_layout(w, h))
			windows.InvalidateRect(hwnd, nil, windows.FALSE)
		}
		hover_track_leave(hwnd)
		if ui.mouse.x != win_x || ui.mouse.y != win_y || !ui.mouse_valid {
			ui.mouse.x = win_x
			ui.mouse.y = win_y
			ui.mouse_valid = true
			// Repaint only if the frame drawn for this position would differ.
			w, h := client_size(hwnd)
			if hover_needs_repaint(ui.hover_painted, hover_signature_for_app(app, win_x, win_y, w, h)) {
				windows.InvalidateRect(hwnd, nil, windows.FALSE)
			}
		}
		return 0
	case windows.WM_MOUSELEAVE:
		ui.mouse_tracking = false
		ui.mouse_valid = false
		if ui.hover_painted != {} { windows.InvalidateRect(hwnd, nil, windows.FALSE) }
		return 0
	case windows.WM_SETCURSOR:
		if ui.tab == 0 && (u32(lparam) & 0xFFFF) == 1 { // HTCLIENT
			if ui.zoom_drag == .Timeline {
				windows.SetCursor(ui_grab_cursor())
				return 1
			}
			_update_mouse_client()
			w, h := client_size(hwnd)
			split := ui.pane_drag
			if split == 0 { split = pane_split_hit(ui.mouse.x, ui.mouse.y, compute_layout(w, h)) }
			if split != 0 {
				cursor := u64(32645) if split == 1 else u64(32644) // IDC_SIZENS / IDC_SIZEWE
				windows.SetCursor(windows.LoadCursorW(nil, transmute(cstring16)(cursor)))
				return 1
			}
			_, edge := tag_edge_hit(app, ui.mouse.x, ui.mouse.y, compute_layout(w, h))
			if edge != 0 || tag_ui.drag >= 2 {
				windows.SetCursor(windows.LoadCursorW(nil, transmute(cstring16)(u64(32644))))
				return 1
			}
			bar, _, _, _ := zoom_rects(compute_layout(w, h))
			if rect_hit(bar, ui.mouse.x, ui.mouse.y) {
				width := f64(bar.right - bar.left)
				left := bar.left + i32(ui.zoom_start * width)
				right := bar.left + i32(ui.zoom_end * width)
				cursor := u64(32649) // IDC_HAND (pan)
				if abs(ui.mouse.x - left) <= 6 || abs(ui.mouse.x - right) <= 6 {
					cursor = 32644 // IDC_SIZEWE (resize)
				}
				windows.SetCursor(windows.LoadCursorW(nil, transmute(cstring16)(cursor)))
				return 1
			}
		}
	case windows.WM_MOUSEWHEEL:
		if ui.tab != 0 || tag_ui.drag != 0 || ui.pane_drag != 0 || ui.zoom_drag != .None { return 0 }
		delta := i32(i16((u32(wparam) >> 16) & 0xFFFF))
		// WM_MOUSEWHEEL coordinates are screen-relative, including on other monitors.
		p := windows.POINT{i32(i16(u32(lparam) & 0xFFFF)), i32(i16((u32(lparam) >> 16) & 0xFFFF))}
		windows.ScreenToClient(hwnd, &p)
		w, h := client_size(hwnd)
		lay := compute_layout(w, h)
		if p.x >= lay.chart_x && p.x < lay.chart_x + lay.chart_w &&
		   p.y >= lay.ruler_y && p.y < lay.list_top {
			if delta != 0 {
				zoom_scale(0.8 if delta > 0 else 1.25,
					clamp(f64(p.x - lay.chart_x) / f64(lay.chart_w), 0.0, 1.0))
			}
		}
		if p.y >= lay.list_top && p.y < lay.list_bottom {
			if p.x >= lay.chart_x && p.x < lay.sidebar_x - 8 {
				pane_scroll_wheel(&ui.list_scroll, delta)
			} else if p.x >= lay.sidebar_x && p.x < lay.sidebar_x + lay.sidebar_w {
				pane_scroll_wheel(&ui.totals_scroll, delta)
			}
		}
		windows.InvalidateRect(hwnd, nil, windows.FALSE)
		return 0
	case windows.WM_VSCROLL:
		source := windows.HWND(uintptr(lparam))
		command := i32(u32(wparam) & 0xFFFF)
		if source == ui.list_scroll.hwnd {
			pane_scroll_message(&ui.list_scroll, command)
		} else if source == ui.totals_scroll.hwnd {
			pane_scroll_message(&ui.totals_scroll, command)
		}
		windows.InvalidateRect(hwnd, nil, windows.FALSE)
		return 0
	case windows.WM_CONTEXTMENU:
		if windows.HWND(wparam) == hwnd {
			p := windows.POINT{i32(i16(u32(lparam) & 0xFFFF)), i32(i16((u32(lparam) >> 16) & 0xFFFF))}
			if p.x == -1 && p.y == -1 { windows.GetCursorPos(&p) }
			tag_context_menu(app, p)
			return 0
		}
	case windows.WM_MBUTTONDOWN:
		x := i32(i16(u32(lparam) & 0xFFFF))
		y := i32(i16((u32(lparam) >> 16) & 0xFFFF))
		w, h := client_size(hwnd)
		if zoom_pan_down(x, y, compute_layout(w, h)) {
			windows.SetCapture(hwnd)
			windows.SetCursor(ui_grab_cursor())
		}
		return 0
	case windows.WM_MBUTTONUP:
		if ui.zoom_drag == .Timeline {
			w, h := client_size(hwnd)
			x := i32(i16(u32(lparam) & 0xFFFF))
			zoom_pointer_move(x, compute_layout(w, h))
			ui.zoom_drag = .None
			windows.ReleaseCapture()
			windows.InvalidateRect(hwnd, nil, windows.FALSE)
		}
		return 0
	case windows.WM_LBUTTONDOWN, windows.WM_LBUTTONDBLCLK:
		if ui.zoom_drag == .Timeline { return 0 }
		win_x := i32(i16(u32(lparam) & 0xFFFF))
		win_y := i32(i16((u32(lparam) >> 16) & 0xFFFF))
		w, h := client_size(hwnd)
		if pane_pointer_down(win_x, win_y, compute_layout(w, h)) { return 0 }
		if msg == windows.WM_LBUTTONDBLCLK && tag_gap_double_click(app, win_x, win_y, compute_layout(w, h)) {
			return 0
		}
		if tag_pointer_down(app, win_x, win_y, compute_layout(w, h)) {
			windows.InvalidateRect(hwnd, nil, windows.FALSE)
			return 0
		}
		if zoom_pointer_down(win_x, win_y, compute_layout(w, h)) {
			windows.InvalidateRect(hwnd, nil, windows.FALSE)
			return 0
		}
		id := hit_test(win_x, win_y, w, h)
		if (id >= HIT_BTN_PREV && id <= HIT_TOTALS_TREE) || id == HIT_SETTINGS {
			ui.pressed_hit = id
			windows.SetCapture(hwnd)
			windows.InvalidateRect(hwnd, nil, windows.FALSE)
		} else {
			handle_click(app, win_x, win_y)
		}
		return 0
	case windows.WM_LBUTTONUP:
		if ui.zoom_drag == .Timeline { return 0 }
		if ui.pane_drag != 0 {
			w, h := client_size(hwnd)
			x := i32(i16(u32(lparam) & 0xFFFF))
			y := i32(i16((u32(lparam) >> 16) & 0xFFFF))
			pane_pointer_move(x, y, compute_layout(w, h))
			ui.pane_drag = 0
			windows.ReleaseCapture()
			windows.InvalidateRect(hwnd, nil, windows.FALSE)
			return 0
		}
		if tag_ui.drag != 0 {
			w, h := client_size(hwnd)
			x := i32(i16(u32(lparam) & 0xFFFF))
			tag_pointer_up(app, x, compute_layout(w, h))
			return 0
		}
		if ui.zoom_drag != .None {
			ui.zoom_drag = .None
			windows.ReleaseCapture()
			windows.InvalidateRect(hwnd, nil, windows.FALSE)
			return 0
		}
		pressed := ui.pressed_hit
		ui.pressed_hit = HIT_NONE
		if pressed != HIT_NONE {
			windows.ReleaseCapture()
			x := i32(i16(u32(lparam) & 0xFFFF))
			y := i32(i16((u32(lparam) >> 16) & 0xFFFF))
			w, h := client_size(hwnd)
			if hit_test(x, y, w, h) == pressed { handle_click(app, x, y) }
			windows.InvalidateRect(hwnd, nil, windows.FALSE)
		}
		return 0
	case windows.WM_CANCELMODE:
		ui_cancel_interaction()
		if windows.GetCapture() == hwnd { windows.ReleaseCapture() }
		windows.InvalidateRect(hwnd, nil, windows.FALSE)
		// Let DefWindowProc dismiss any active native menu as well.
		return windows.DefWindowProcW(hwnd, msg, wparam, lparam)
	case windows.WM_CAPTURECHANGED:
		ui_cancel_interaction()
		windows.InvalidateRect(hwnd, nil, windows.FALSE)
		return 0
	case windows.WM_KEYDOWN:
		if wparam == 0x1B {
			ui_cancel_interaction()
			if windows.GetCapture() == hwnd { windows.ReleaseCapture() }
			windows.InvalidateRect(hwnd, nil, windows.FALSE)
			return 0
		}
	case windows.WM_COMMAND:
		if ui.date_picker != nil && windows.HWND(uintptr(lparam)) == ui.date_picker && (u32(wparam) >> 16) == 0 {
			if ui.tab == 0 { date_calendar_open() }
			return 0
		}
		if lparam == 0 && (u32(wparam) >> 16) == 0 {
			switch u32(wparam) & 0xFFFF {
			case TRAY_OPEN: ui_restore(); return 0
			case TRAY_SETTINGS: ui_restore(); settings_open(); return 0
			case TRAY_EXIT:
				if !ui_request_exit(app) { return 0 }
				settings_close()
				if tag_ui.popup != nil { tag_picker_close() }
				windows.DestroyWindow(hwnd)
				return 0
			}
		}
		// Filter edit: HIWORD notification = EN_CHANGE, LOWORD = control id.
		hi := i32((u32(wparam) >> 16) & 0xFFFF)
		if hi == windows.EN_CHANGE {
			read_filter()
			windows.InvalidateRect(hwnd, nil, windows.FALSE)
		}
		return 0
	case windows.WM_DRAWITEM:
		item := transmute(^Draw_Item)(lparam)
		if item != nil && item.hwndItem == ui.date_picker {
			draw_date_button(item)
			return 1
		}
		return 0
	case windows.WM_GETMINMAXINFO:
		mmi := transmute(^windows.MINMAXINFO)(lparam)
		mmi.ptMinTrackSize = windows.POINT{x = 720, y = 480}
		return 0
	case windows.WM_DESTROY:
		ui_remove_tray()
		windows.KillTimer(hwnd, windows.UINT_PTR(APP_TIMER_ID))
		windows.PostQuitMessage(0)
		if ui.hwnd == hwnd { ui.hwnd = nil }
		return 0
	}
	return windows.DefWindowProcW(hwnd, msg, wparam, lparam)
}

// Idempotent cancellation shared by Escape, native modal transitions and
// capture loss. Successful releases clear their state before ReleaseCapture.
ui_cancel_interaction :: proc() {
	pane_drag_cancel()
	if ui.zoom_drag != .None {
		ui.zoom_start, ui.zoom_end = ui.zoom_drag_start, ui.zoom_drag_end
	}
	ui.zoom_drag = .None
	tag_ui.drag = 0
	ui.pressed_hit = HIT_NONE
}

client_size :: proc(hwnd: windows.HWND) -> (w, h: i32) {
	rc: windows.RECT
	windows.GetClientRect(hwnd, &rc)
	return rc.right - rc.left, rc.bottom - rc.top
}

_update_mouse_client :: proc() {
	screen: windows.POINT
	if windows.GetCursorPos(&screen) {
		windows.ScreenToClient(ui.hwnd, &screen)
		ui.mouse = screen
		ui.mouse_valid = true
		rc: windows.RECT
		windows.GetClientRect(ui.hwnd, &rc)
		if screen.x < 0 || screen.y < 0 || screen.x >= rc.right || screen.y >= rc.bottom {
			ui.mouse_valid = false
		}
	}
}

// The caller owns the lowercase result; the conversion never escapes.
filter_from_utf16 :: proc(text: []u16) -> string {
	s, _ := windows.utf16_to_utf8(text, context.allocator)
	defer delete(s)
	return strings.to_lower(s)
}

read_filter :: proc() {
	buf: [512]u16
	n := windows.GetWindowTextW(ui.edit, &buf[0], 512)
	if n < 0 { n = 0 }
	if len(ui.filter) > 0 {
		delete(ui.filter)
	}
	ui.filter = filter_from_utf16(buf[:n])
	ui.list_scroll.pos = 0
}

handle_click :: proc(app: ^App, x, y: i32) {
	w, h := client_size(ui.hwnd)
	id := hit_test(x, y, w, h)
	switch {
	case id == HIT_TOTALS_TREE:
		ui.totals_tree = !ui.totals_tree
		ui.totals_scroll.pos = 0
	case id == HIT_TOTALS_ROW:
		totals_tree_click(app, y, compute_layout(w, h))
	case id == HIT_THEME:
		theme_toggle()
	case id == HIT_SETTINGS:
		settings_open()
	case id == HIT_ZOOM_OUT:
		zoom_scale(1.5, 0.5)
	case id == HIT_ZOOM_IN:
		zoom_scale(1.0 / 1.5, 0.5)
	case id == HIT_ZOOM_RESET:
		ui.zoom_start, ui.zoom_end = 0, 1
	case id == HIT_BTN_PREV:
		app.date = add_days(app.date, -1)
		load_day(app)
		sync_date_picker(app)
	case id == HIT_BTN_NEXT:
		app.date = add_days(app.date, 1)
		load_day(app)
		sync_date_picker(app)
	case id == HIT_BTN_TODAY:
		app.date = today_date_int()
		load_day(app)
		sync_date_picker(app)
	case id == HIT_BTN_TASK:
		if app.task.id != 0 {
			if !task_stop(app, now_ms()) {
				message_box("Could not stop task. Please try again.", "aika", 0x10)
			}
		} else {
			tag_ui.task_picker = true
			tag_picker_open()
		}
		load_day(app)
	case id == HIT_TAB_BASE:
		ui.tab = 0
	case id == HIT_TAB_BASE + 1:
		ui.tab = 1
	case id == HIT_TAB_BASE + 2:
		ui.tab = 2
	case id >= HIT_LANE_BASE && id < HIT_LANE_BASE + 3:
		if ui.lane != i32(id - HIT_LANE_BASE) {
			ui.lane = i32(id - HIT_LANE_BASE)
			ui.list_scroll.pos = 0
			ui.totals_scroll.pos = 0
		}
	}
	ui_sync_day_controls()
	windows.InvalidateRect(ui.hwnd, nil, windows.FALSE)
}

ui_sync_day_controls :: proc() {
	show := ui.tab == 0
	if !show { date_calendar_close(false) }
	if ui.date_picker != nil && bool(windows.IsWindowVisible(ui.date_picker)) != show {
		windows.ShowWindow(ui.date_picker, windows.SW_SHOW if show else windows.SW_HIDE)
	}
}

// --- Fonts ---

// Height is the em height in pixels (negative height in CreateFontW means
// "cell height", here expressed directly). Same face for everything.
ui_make_font :: proc(h_px, weight: i32, face: string = "Segoe UI") -> windows.HFONT {
	return windows.CreateFontW(
		-h_px, 0, 0, 0, windows.INT(weight),
		0, 0, 0, // not italic / underlined / struck out
		windows.DEFAULT_CHARSET,
		0, 0, // OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS
		windows.CLEARTYPE_QUALITY,
		0, // DEFAULT_PITCH | FF_DONTCARE
		windows.LPCWSTR(windows.utf8_to_wstring(face, context.temp_allocator)),
	)
}

ui_create_fonts :: proc() {
	ui.font_normal = ui_make_font(12, 400)
	ui.font_bold   = ui_make_font(12, windows.FW_BOLD)
	ui.font_small  = ui_make_font(11, 400)
	ui.font_title  = ui_make_font(20, windows.FW_BOLD)
	ui.font_icons  = ui_make_font(16, 400, "Segoe UI Symbol")
}

// --- Window bootstrap ---

Ui_Startup_Stage :: enum { Class, Fonts, Window, Tray, Scrollbars, Filter, Date, Buffer, Timer }

// Optional checkpoint permits deterministic unwinding tests after each owned
// resource stage; production passes nil and checks the native API results.
ui_bootstrap :: proc(checkpoint: proc(stage: Ui_Startup_Stage) -> bool = nil) -> bool {
	ready := false
	defer if !ready { ui_shutdown() }
	theme_load()
	ui.zoom_end = 1
	hinstance := windows.GetModuleHandleW(nil)
	class_name := windows.utf8_to_wstring(WNDC_CLASS, context.temp_allocator)

	wc: windows.WNDCLASSEXW
	wc.cbSize = windows.UINT(size_of(windows.WNDCLASSEXW))
	wc.style = windows.CS_DBLCLKS
	wc.lpfnWndProc = wnd_proc
	wc.hInstance = windows.HINSTANCE(hinstance)
	wc.hCursor = windows.LoadCursorW(nil, transmute(cstring16)(u64(32512))) // IDC_ARROW
	wc.lpszClassName = class_name
	if windows.RegisterClassExW(&wc) == 0 {
		return false
	}
	ui.main_class = true
	if checkpoint != nil && !checkpoint(.Class) { return false }

	ui_create_fonts()
	if ui.font_normal == nil || ui.font_bold == nil || ui.font_small == nil || ui.font_title == nil || ui.font_icons == nil { return false }
	if checkpoint != nil && !checkpoint(.Fonts) { return false }

	// Common controls (ICC_DATE_CLASSES) for the native month calendar.
	icc := windows.INITCOMMONCONTROLSEX{
		dwSize = windows.DWORD(size_of(windows.INITCOMMONCONTROLSEX)),
		dwICC  = windows.ICC_DATE_CLASSES,
	}
	if !windows.InitCommonControlsEx(&icc) { return false }

	title := windows.utf8_to_wstring("aika", context.temp_allocator)
	// WS_CLIPCHILDREN keeps our BitBlt from painting over the filter EDIT.
	style := windows.WS_OVERLAPPEDWINDOW | windows.WS_CLIPCHILDREN
	ex_style := windows.DWORD(0)
	client := windows.RECT{left = 0, top = 0, right = 1320, bottom = 860}
	windows.AdjustWindowRectEx(&client, windows.WS_OVERLAPPEDWINDOW, windows.FALSE, ex_style)
	outer_w := client.right - client.left
	outer_h := client.bottom - client.top

	ui.hwnd = windows.CreateWindowExW(
		ex_style,
		class_name,
		title,
		style,
		100, 60, outer_w, outer_h,
		nil, nil, windows.HINSTANCE(hinstance), nil,
	)
	if ui.hwnd == nil {
		return false
	}
	if checkpoint != nil && !checkpoint(.Window) { return false }
	ui_open_themes()
	tray_class := windows.WNDCLASSEXW{cbSize = size_of(windows.WNDCLASSEXW),
		lpfnWndProc = tray_wnd_proc, hInstance = windows.HINSTANCE(hinstance),
		lpszClassName = wtext("aika_tray_window_class")}
	if windows.RegisterClassExW(&tray_class) == 0 { return false }
	ui.tray_class = true
	ui.tray_hwnd = windows.CreateWindowExW(0, tray_class.lpszClassName, wtext("aika tray"),
		windows.WS_POPUP, 0, 0, 0, 0, nil, nil, windows.HINSTANCE(hinstance), nil)
	if ui.tray_hwnd == nil { return false }
	ui.taskbar_created = windows.RegisterWindowMessageW(wtext("TaskbarCreated"))
	ui_add_tray()
	if checkpoint != nil && !checkpoint(.Tray) { return false }

	// Independent native scrollbars, initially hidden until row counts are known.
	for s in ([2]^PaneScroll{&ui.list_scroll, &ui.totals_scroll}) {
		s.hwnd = windows.CreateWindowExW(0, wtext("SCROLLBAR"), nil,
			windows.WS_CHILD | windows.WS_TABSTOP | 1, // SBS_VERT
			0, 0, 0, 0, ui.hwnd, nil, windows.HINSTANCE(hinstance), nil)
		if s.hwnd == nil { return false }
	}
	if checkpoint != nil && !checkpoint(.Scrollbars) { return false }

	// Start with the Applications lane selected, like a fresh ManicTime day.
	ui.lane = 2

	// Filter edit control. Its WM_COMMAND EN_CHANGE keeps ui.filter current.
	ui.edit = windows.CreateWindowExW(
		windows.DWORD(0),
		windows.LPCWSTR(windows.utf8_to_wstring("EDIT", context.temp_allocator)),
		nil,
		windows.WS_CHILD | windows.WS_VISIBLE | windows.WS_BORDER,
		0, 0, 100, 24,
		ui.hwnd, nil, windows.HINSTANCE(hinstance), nil,
	)
	if ui.edit == nil { return false }
	if ui.font_normal != nil {
		windows.SendMessageW(ui.edit, windows.WM_SETFONT, windows.WPARAM(ui.font_normal), 0)
	}
	if ui.edit != nil {
		previous := windows.SetWindowLongPtrW(ui.edit, -4, transmute(windows.LONG_PTR)(windows.WNDPROC(filter_edit_proc))) // GWLP_WNDPROC
		filter_edit_original = transmute(windows.WNDPROC)(previous)
		if previous == 0 { return false }
	}
	if checkpoint != nil && !checkpoint(.Filter) { return false }

	// Native owner-drawn button keeps keyboard activation and accessibility,
	// while allowing the face to use the same palette as the rest of the UI.
	ui.date_picker = windows.CreateWindowExW(
		windows.DWORD(0),
		wtext("BUTTON"),
		nil,
		windows.WS_CHILD | windows.WS_VISIBLE | windows.WS_TABSTOP | 0xB, // BS_OWNERDRAW
		0, 0, 120, 26,
		ui.hwnd, nil, windows.HINSTANCE(hinstance), nil,
	)
	if ui.date_picker == nil { return false }
	if ui.date_picker != nil {
		if ui.font_normal != nil {
			windows.SendMessageW(ui.date_picker, windows.WM_SETFONT, windows.WPARAM(ui.font_normal), 0)
		}
		if global_app != nil {
			sync_date_picker(global_app)
		}
	}
	if checkpoint != nil && !checkpoint(.Date) { return false }

	// Position the filter edit explicitly: the first WM_SIZE can arrive before
	// the control exists.
	cw, ch := client_size(ui.hwnd)
	lay := compute_layout(cw, ch)
	windows.MoveWindow(
		ui.edit,
		lay.filter_edit_x, lay.filter_edit_y,
		lay.filter_edit_w, lay.filter_edit_h,
		windows.TRUE,
	)
	ui_resize_date_picker(cw, ch)
	if !recreate_backbuffer(cw, ch) { return false }
	if checkpoint != nil && !checkpoint(.Buffer) { return false }

	theme_apply_native()
	if windows.SetTimer(ui.hwnd, windows.UINT_PTR(APP_TIMER_ID), 500, nil) == 0 { return false }
	if checkpoint != nil && !checkpoint(.Timer) { return false }
	windows.ShowWindow(ui.hwnd, windows.SW_SHOW)
	ready = true
	return true
}

ui_shutdown :: proc() {
	settings_close()
	if tag_ui.popup != nil { tag_picker_close() }
	if ui.date_popup != nil { windows.DestroyWindow(ui.date_popup); ui.date_popup = nil; ui.date_calendar = nil }
	if ui.hwnd != nil {
		windows.DestroyWindow(ui.hwnd)
		ui.hwnd = nil
	}
	ui.edit, ui.date_picker, ui.list_scroll.hwnd, ui.totals_scroll.hwnd = nil, nil, nil, nil
	if ui.grab_cursor != nil { windows.DestroyCursor(ui.grab_cursor); ui.grab_cursor = nil }
	totals_tree_shutdown()
	ui_remove_tray()
	if ui.tray_hwnd != nil { windows.DestroyWindow(ui.tray_hwnd); ui.tray_hwnd = nil }
	ui_close_themes()
	release_backbuffer(&ui)
	if ui.font_normal != nil { windows.DeleteObject(windows.HGDIOBJ(ui.font_normal)) }
	if ui.font_bold != nil { windows.DeleteObject(windows.HGDIOBJ(ui.font_bold)) }
	if ui.font_small != nil { windows.DeleteObject(windows.HGDIOBJ(ui.font_small)) }
	if ui.font_title != nil { windows.DeleteObject(windows.HGDIOBJ(ui.font_title)) }
	if ui.font_icons != nil { windows.DeleteObject(windows.HGDIOBJ(ui.font_icons)) }
	ui.font_normal, ui.font_bold, ui.font_small, ui.font_title, ui.font_icons = nil, nil, nil, nil, nil
	hi := windows.HINSTANCE(windows.GetModuleHandleW(nil))
	if ui.tray_class { windows.UnregisterClassW(wtext("aika_tray_window_class"), hi); ui.tray_class = false }
	if ui.main_class { windows.UnregisterClassW(wtext(WNDC_CLASS), hi); ui.main_class = false }
	if ui.filter != "" {
		delete(ui.filter)
		ui.filter = ""
	}
}
