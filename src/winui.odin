package main

import "core:strings"
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

UiState :: struct {
	hwnd:         windows.HWND,
	edit:         windows.HWND,
	mem_dc:       windows.HDC,
	mem_bmp:      windows.HBITMAP,
	mem_bmp_old:  windows.HGDIOBJ,
	mem_w, mem_h: i32,
	mem_valid:    bool,

	font_normal: windows.HFONT, // 12px Segoe UI
	font_bold:   windows.HFONT, // 12px bold
	font_small:  windows.HFONT, // 11px
	font_title:  windows.HFONT, // 20px bold (day header)

	mouse:       windows.POINT, // client coords, refreshed each paint
	mouse_valid: bool,

	filter:      string,
	tab:         i32,  // 0 = Day, 1 = Timesheet, 2 = Statistics
	lane:        i32,  // selected timeline lane (0..2)
	list_scroll: i32,
}

ui: UiState

// Hit target ids for the composite hit test.
HIT_NONE        :: 0
HIT_BTN_PREV    :: 1
HIT_BTN_TODAY   :: 2
HIT_BTN_NEXT    :: 3
HIT_BTN_TRACK   :: 4
HIT_TAB_BASE    :: 10 // +0..2
HIT_LANE_BASE   :: 20 // +0..3

WNDC_CLASS :: "aika_window_class"
APP_TIMER_ID :: 1

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
	c := wtext(s)
	dc := windows.GetDC(ui.hwnd)
	defer windows.ReleaseDC(ui.hwnd, dc)
	old := windows.SelectObject(dc, windows.HGDIOBJ(font))
	defer windows.SelectObject(dc, old)
	if len(s) == 0 {
		return size
	}
	windows.GetTextExtentPoint32W(dc, c, i32(len(s)), &size)
	return
}

text_size :: proc(s: string, font: windows.HFONT) -> windows.SIZE {
	return _measure_text(s, font)
}

// Draw a single line of UTF-8 text, truncated preferentially at word
// boundaries (like DrawText) when narrower than max_w.
draw_string :: proc(dc: windows.HDC, s: string, x, y: i32, font: windows.HFONT, color: windows.COLORREF, max_w: i32 = 1_000_000) {
	if len(s) == 0 || max_w <= 0 {
		return
	}
	c := wtext(s)
	windows.SetTextColor(dc, color)
	dc_font := windows.SelectObject(dc, windows.HGDIOBJ(font))
	defer windows.SelectObject(dc, dc_font)
	r := windows.RECT{x, y - 2, x + max_w, y + 32}
	flags := windows.DrawTextFormat.DT_SINGLELINE |
		windows.DrawTextFormat.DT_NOPREFIX |
		windows.DrawTextFormat.DT_END_ELLIPSIS
	windows.DrawTextW(dc, c, i32(len(s)), &r, flags)
}

// --- Timer tick (2 Hz timer, tracker still samples at 1 Hz internally) ---

app_tick :: proc(app: ^App) {
	now := now_ms()
	if app.tracker.enabled {
		tracker_tick(app, now)
	}
	if app.date != app.loaded_date || now - app.last_load_ms >= 10_000 {
		load_day(app)
	}
	windows.InvalidateRect(ui.hwnd, nil, windows.FALSE)
}

// --- Resize handling ---

recreate_backbuffer :: proc(w, h: i32) {
	if ui.mem_valid {
		windows.SelectObject(ui.mem_dc, ui.mem_bmp_old)
		windows.DeleteObject(windows.HGDIOBJ(ui.mem_bmp))
		windows.DeleteDC(ui.mem_dc)
		ui.mem_valid = false
	}
	if w <= 0 || h <= 0 {
		return
	}
	dc := windows.GetDC(ui.hwnd)
	ui.mem_dc = windows.CreateCompatibleDC(dc)
	ui.mem_bmp = windows.CreateCompatibleBitmap(dc, w, h)
	windows.ReleaseDC(ui.hwnd, dc)
	ui.mem_bmp_old = windows.SelectObject(ui.mem_dc, windows.HGDIOBJ(ui.mem_bmp))
	ui.mem_w = w
	ui.mem_h = h

	// Move the filter edit control to the bottom of the client area.
	if ui_edit_valid() {
		lay := compute_layout(w, h)
		windows.MoveWindow(
			ui.edit,
			lay.filter_edit_x, lay.filter_edit_y,
			lay.filter_edit_w, lay.filter_edit_h,
			windows.TRUE,
		)
	}
	ui.mem_valid = true
}

ui_edit_valid :: proc() -> bool {
	return ui.edit != nil
}

// --- WndProc ---

wnd_proc :: proc "std" (hwnd: windows.HWND, msg: u32, wparam: windows.WPARAM, lparam: windows.LPARAM) -> windows.LRESULT {
	context = rt.default_context()
	app := global_app
	switch msg {
	case windows.WM_ERASEBKGND:
		return 1 // no flicker: everything is drawn in WM_PAINT
	case windows.WM_PAINT:
		ps: windows.PAINTSTRUCT
		dc := windows.BeginPaint(hwnd, &ps)
		defer windows.EndPaint(hwnd, &ps)
		w, h := client_size(hwnd)
		if !ui.mem_valid || ui.mem_w != w || ui.mem_h != h {
			recreate_backbuffer(w, h)
		}
		if ui.mem_valid {
			// Keep the cursor position current even without mouse-move spam.
			_update_mouse_client()
			dc_buffer := ui.mem_dc
			draw_frame(app, dc_buffer, w, h)
			windows.BitBlt(dc, 0, 0, w, h, dc_buffer, 0, 0, windows.SRCCOPY)
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
		if ui.mouse.x != win_x || ui.mouse.y != win_y {
			ui.mouse.x = win_x
			ui.mouse.y = win_y
			ui.mouse_valid = true
			windows.InvalidateRect(hwnd, nil, windows.FALSE)
		}
		return 0
	case windows.WM_MOUSELEAVE:
		ui.mouse_valid = false
		return 0
	case windows.WM_MOUSEWHEEL:
		delta := i16((u32(wparam) >> 16) & 0xFFFF)
		ui.list_scroll -= i32(delta) / 6
		windows.InvalidateRect(hwnd, nil, windows.FALSE)
		return 0
	case windows.WM_LBUTTONDOWN:
		win_x := i32(i16(u32(lparam) & 0xFFFF))
		win_y := i32(i16((u32(lparam) >> 16) & 0xFFFF))
		handle_click(app, win_x, win_y)
		return 0
	case windows.WM_COMMAND:
		// Filter edit: HIWORD notification = EN_CHANGE, LOWORD = control id.
		hi := i32((u32(wparam) >> 16) & 0xFFFF)
		if hi == windows.EN_CHANGE {
			read_filter()
			windows.InvalidateRect(hwnd, nil, windows.FALSE)
		}
		return 0
	case windows.WM_GETMINMAXINFO:
		mmi := transmute(^windows.MINMAXINFO)(lparam)
		mmi.ptMinTrackSize = windows.POINT{x = 720, y = 480}
		return 0
	case windows.WM_DESTROY:
		windows.KillTimer(hwnd, windows.UINT_PTR(APP_TIMER_ID))
		windows.PostQuitMessage(0)
		return 0
	}
	return windows.DefWindowProcW(hwnd, msg, wparam, lparam)
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

read_filter :: proc() {
	buf: [512]u16
	n := windows.GetWindowTextW(ui.edit, &buf[0], 512)
	if n < 0 { n = 0 }
	s := ""
	if n > 0 {
		s, _ = windows.utf16_to_utf8(buf[:n], context.allocator)
	}
	if len(ui.filter) > 0 {
		delete(ui.filter)
	}
	ui.filter = strings.to_lower(s)
}

handle_click :: proc(app: ^App, x, y: i32) {
	w, h := client_size(ui.hwnd)
	id := hit_test(x, y, w, h)
	switch {
	case id == HIT_BTN_PREV:
		app.date = add_days(app.date, -1)
		load_day(app)
	case id == HIT_BTN_NEXT:
		app.date = add_days(app.date, 1)
		load_day(app)
	case id == HIT_BTN_TODAY:
		app.date = today_date_int()
		load_day(app)
	case id == HIT_BTN_TRACK:
		if app.tracker.enabled {
			tracker_pause(app)
		} else {
			tracker_resume(app)
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
			ui.list_scroll = 0
		}
	}
	windows.InvalidateRect(ui.hwnd, nil, windows.FALSE)
}

// --- Fonts ---

// Height is the em height in pixels (negative height in CreateFontW means
// "cell height", here expressed directly). Same face for everything.
ui_make_font :: proc(h_px, weight: i32) -> windows.HFONT {
	return windows.CreateFontW(
		-h_px, 0, 0, 0, windows.INT(weight),
		0, 0, 0, // not italic / underlined / struck out
		windows.DEFAULT_CHARSET,
		0, 0, // OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS
		windows.CLEARTYPE_QUALITY,
		0, // DEFAULT_PITCH | FF_DONTCARE
		windows.LPCWSTR(windows.utf8_to_wstring("Segoe UI", context.temp_allocator)),
	)
}

ui_create_fonts :: proc() {
	ui.font_normal = ui_make_font(12, 400)
	ui.font_bold   = ui_make_font(12, windows.FW_BOLD)
	ui.font_small  = ui_make_font(11, 400)
	ui.font_title  = ui_make_font(20, windows.FW_BOLD)
}

// --- Window bootstrap ---

ui_bootstrap :: proc() -> bool {
	hinstance := windows.GetModuleHandleW(nil)
	class_name := windows.utf8_to_wstring(WNDC_CLASS, context.temp_allocator)

	wc: windows.WNDCLASSEXW
	wc.cbSize = windows.UINT(size_of(windows.WNDCLASSEXW))
	wc.lpfnWndProc = wnd_proc
	wc.hInstance = windows.HINSTANCE(hinstance)
	wc.hCursor = windows.LoadCursorW(nil, transmute(cstring16)(u64(32512))) // IDC_ARROW
	wc.lpszClassName = class_name
	if windows.RegisterClassExW(&wc) == 0 {
		return false
	}

	ui_create_fonts()

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
	if ui.font_normal != nil {
		windows.SendMessageW(ui.edit, windows.WM_SETFONT, windows.WPARAM(ui.font_normal), 0)
	}

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

	windows.ShowWindow(ui.hwnd, windows.SW_SHOW)
	windows.SetTimer(ui.hwnd, windows.UINT_PTR(APP_TIMER_ID), 500, nil)
	return true
}

ui_shutdown :: proc() {
	if ui.mem_valid {
		windows.SelectObject(ui.mem_dc, ui.mem_bmp_old)
		windows.DeleteObject(windows.HGDIOBJ(ui.mem_bmp))
		windows.DeleteDC(ui.mem_dc)
		ui.mem_valid = false
	}
	if ui.font_normal != nil { windows.DeleteObject(windows.HGDIOBJ(ui.font_normal)) }
	if ui.font_bold != nil { windows.DeleteObject(windows.HGDIOBJ(ui.font_bold)) }
	if ui.font_small != nil { windows.DeleteObject(windows.HGDIOBJ(ui.font_small)) }
	if ui.font_title != nil { windows.DeleteObject(windows.HGDIOBJ(ui.font_title)) }
	if ui.filter != "" {
		delete(ui.filter)
		ui.filter = ""
	}
}
