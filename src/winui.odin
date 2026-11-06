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

PaneScroll :: struct {
	hwnd: windows.HWND,
	pos, rows, page: i32, // row units, not pixels
	wheel_delta: i32,
	visible: bool,
	bounds: windows.RECT,
}

UiState :: struct {
	hwnd:         windows.HWND,
	edit:         windows.HWND,
	date_picker:  windows.HWND,
	mem_dc:       windows.HDC,
	mem_bmp:      windows.HBITMAP,
	mem_bmp_old:  windows.HGDIOBJ,
	mem_w, mem_h: i32,
	mem_valid:    bool,

	font_normal: windows.HFONT, // 12px Segoe UI
	font_bold:   windows.HFONT, // 12px bold
	font_small:  windows.HFONT, // 11px
	font_title:  windows.HFONT, // 20px bold (day header)
	theme_button: Theme_Handle,
	theme_tab:    Theme_Handle,
	pressed_hit:  int,

	mouse:       windows.POINT, // client coords, refreshed each paint
	mouse_valid: bool,

	filter:      string,
	tab:         i32,  // 0 = Day, 1 = Timesheet, 2 = Statistics
	lane:        i32,  // selected timeline lane (0..2)
	list_scroll, totals_scroll: PaneScroll,
	scroll_date: int,
	zoom_start, zoom_end: f64,
	zoom_drag: i32, // 0 = idle, 1/2 = resize edges, 3 = pan
	zoom_drag_anchor, zoom_drag_start, zoom_drag_end: f64,
}

ui: UiState

// Hit target ids for the composite hit test.
HIT_NONE        :: 0
HIT_BTN_PREV    :: 1
HIT_BTN_TODAY   :: 2
HIT_BTN_NEXT    :: 3
HIT_BTN_TRACK   :: 4
HIT_ZOOM_OUT    :: 5
HIT_ZOOM_IN     :: 6
HIT_ZOOM_RESET  :: 7
HIT_TAB_BASE    :: 10 // +0..2
HIT_LANE_BASE   :: 20 // +0..3

// Native date picker (SysDateTimePick32) values missing from core:sys/windows.
DTM_FIRST          :: 0x1000
DTM_SETSYSTEMTIME  :: DTM_FIRST + 2
DTM_GETSYSTEMTIME  :: DTM_FIRST + 3
DTN_FIRST2         :: ~windows.DWORD(753 - 1)
DTN_DATETIMECHANGE :: DTN_FIRST2 - 6 // -759, per WinSDK CommCtrl.h
GDT_VALID          :: 0

// tagNMDATETIMECHANGE: payload of DTN_DATETIMECHANGE (same process, in-proc).
NMDATETIMECHANGE :: struct {
	nmhdr:   windows.NMHDR,
	dwFlags: windows.DWORD, // GDT_VALID in this app (no DTS_SHOWNONE)
	st:      windows.SYSTEMTIME,
}

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
	ui.mem_valid = true
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

// Push app.date into the native picker (used when date changes via buttons).
sync_date_picker :: proc(app: ^App) {
	if ui.date_picker == nil {
		return
	}
	st := date_systemtime(app.date)
	windows.SendMessageW(ui.date_picker, DTM_SETSYSTEMTIME, GDT_VALID, windows.LPARAM(uintptr(&st)))
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
	if theme == nil { return false }
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
	app := global_app
	switch msg {
	case 0x031A: // WM_THEMECHANGED: cached theme handles are no longer valid.
		ui_open_themes()
		windows.InvalidateRect(hwnd, nil, windows.FALSE)
		return 0
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
		if ui.zoom_drag != 0 {
			w, h := client_size(hwnd)
			zoom_pointer_move(win_x, compute_layout(w, h))
			windows.InvalidateRect(hwnd, nil, windows.FALSE)
		}
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
	case windows.WM_SETCURSOR:
		if ui.tab == 0 && (u32(lparam) & 0xFFFF) == 1 { // HTCLIENT
			_update_mouse_client()
			w, h := client_size(hwnd)
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
		if ui.tab != 0 { return 0 }
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
	case windows.WM_LBUTTONDOWN:
		win_x := i32(i16(u32(lparam) & 0xFFFF))
		win_y := i32(i16((u32(lparam) >> 16) & 0xFFFF))
		w, h := client_size(hwnd)
		if zoom_pointer_down(win_x, win_y, compute_layout(w, h)) {
			windows.InvalidateRect(hwnd, nil, windows.FALSE)
			return 0
		}
		id := hit_test(win_x, win_y, w, h)
		if id >= HIT_BTN_PREV && id <= HIT_ZOOM_RESET {
			ui.pressed_hit = id
			windows.SetCapture(hwnd)
			windows.InvalidateRect(hwnd, nil, windows.FALSE)
		} else {
			handle_click(app, win_x, win_y)
		}
		return 0
	case windows.WM_LBUTTONUP:
		if ui.zoom_drag != 0 {
			ui.zoom_drag = 0
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
	case windows.WM_CAPTURECHANGED:
		ui.pressed_hit = HIT_NONE
		ui.zoom_drag = 0
		windows.InvalidateRect(hwnd, nil, windows.FALSE)
		return 0
	case windows.WM_COMMAND:
		// Filter edit: HIWORD notification = EN_CHANGE, LOWORD = control id.
		hi := i32((u32(wparam) >> 16) & 0xFFFF)
		if hi == windows.EN_CHANGE {
			read_filter()
			windows.InvalidateRect(hwnd, nil, windows.FALSE)
		}
		return 0
	case windows.WM_NOTIFY:
		// Date picker change: DTN_DATETIMECHANGE carries the new date itself
		// (re-querying DTM_GETSYSTEMTIME mid-change can be transiently
		// invalid), so trust the notification payload.
		nm := transmute(^windows.NMHDR)(lparam)
		if nm != nil && nm.hwndFrom == ui.date_picker && nm.code == DTN_DATETIMECHANGE {
			ch := transmute(^NMDATETIMECHANGE)(lparam)
			if ch.dwFlags == GDT_VALID {
				d := date_int_from_systemtime(ch.st)
				if d != app.date {
					app.date = d
					load_day(app)
				}
			}
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
	ui.list_scroll.pos = 0
}

handle_click :: proc(app: ^App, x, y: i32) {
	w, h := client_size(ui.hwnd)
	id := hit_test(x, y, w, h)
	switch {
	case id == HIT_ZOOM_OUT:
		zoom_scale(1.5, 0.5)
	case id == HIT_ZOOM_IN:
		zoom_scale(1.0 / 1.5, 0.5)
	case id == HIT_ZOOM_RESET:
		ui.zoom_start, ui.zoom_end = 0, 1
	case id == HIT_BTN_PREV:
		app.date = add_days(app.date, -1)
		sync_date_picker(app)
		load_day(app)
	case id == HIT_BTN_NEXT:
		app.date = add_days(app.date, 1)
		sync_date_picker(app)
		load_day(app)
	case id == HIT_BTN_TODAY:
		app.date = today_date_int()
		sync_date_picker(app)
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
			ui.list_scroll.pos = 0
			ui.totals_scroll.pos = 0
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
	ui.zoom_end = 1
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

	// Common controls (ICC_DATE_CLASSES) for the native date picker.
	icc := windows.INITCOMMONCONTROLSEX{
		dwSize = windows.DWORD(size_of(windows.INITCOMMONCONTROLSEX)),
		dwICC  = windows.ICC_DATE_CLASSES,
	}
	windows.InitCommonControlsEx(&icc)

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
	ui_open_themes()

	// Independent native scrollbars, initially hidden until row counts are known.
	for s in ([2]^PaneScroll{&ui.list_scroll, &ui.totals_scroll}) {
		s.hwnd = windows.CreateWindowExW(0, wtext("SCROLLBAR"), nil,
			windows.WS_CHILD | windows.WS_TABSTOP | 1, // SBS_VERT
			0, 0, 0, 0, ui.hwnd, nil, windows.HINSTANCE(hinstance), nil)
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

	// Native date picker in the toolbar. DTN_DATETIMECHANGE (handled in
	// wnd_proc) navigates to the chosen day; button navigation writes back
	// from sync_date_picker.
	ui.date_picker = windows.CreateWindowExW(
		windows.DWORD(0),
		windows.LPCWSTR(windows.utf8_to_wstring(windows.DATETIMEPICK_CLASS, context.temp_allocator)),
		nil,
		windows.WS_CHILD | windows.WS_VISIBLE,
		0, 0, 120, 26,
		ui.hwnd, nil, windows.HINSTANCE(hinstance), nil,
	)
	if ui.date_picker != nil {
		if ui.font_normal != nil {
			windows.SendMessageW(ui.date_picker, windows.WM_SETFONT, windows.WPARAM(ui.font_normal), 0)
		}
		if global_app != nil {
			sync_date_picker(global_app)
		}
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
	ui_resize_date_picker(cw, ch)

	windows.ShowWindow(ui.hwnd, windows.SW_SHOW)
	windows.SetTimer(ui.hwnd, windows.UINT_PTR(APP_TIMER_ID), 500, nil)
	return true
}

ui_shutdown :: proc() {
	ui_close_themes()
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
