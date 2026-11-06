package main

import "core:sys/windows"
import rt "base:runtime"

date_popup_closing: bool

draw_date_button :: proc(item: ^Draw_Item) {
	dc, r := item.hDC, item.rcItem
	bg := C_BTN_FACE
	if item.itemState & 1 != 0 { bg = C_BORDER_SOFT } // ODS_SELECTED
	fill_rect(dc, r.left, r.top, r.right - r.left, r.bottom - r.top, bg)
	fill_frame(dc, r.left, r.top, r.right - r.left, r.bottom - r.top, C_BTN_BORDER)
	windows.SetBkMode(dc, windows.BKMODE.TRANSPARENT)
	// Small calendar outline, drawn in GDI so no optional icon font is needed.
	x, y := r.left + 10, r.top + (r.bottom - r.top - 12) / 2
	fill_frame(dc, x, y, 14, 12, C_TXT)
	line_h(dc, x + 1, y + 4, 12, C_TXT)
	line_v(dc, x + 3, y - 2, 4, C_TXT)
	line_v(dc, x + 10, y - 2, 4, C_TXT)
	fill_rect(dc, x + 4, y + 7, 2, 2, C_TXT)
	fill_rect(dc, x + 8, y + 7, 2, 2, C_TXT)
	text_rect := windows.RECT{r.left + 32, r.top, r.right - 8, r.bottom}
	draw_button_text(dc, date_label(global_app.date), text_rect, false)
	if item.itemState & 0x10 != 0 { // ODS_FOCUS
		focus := windows.RECT{r.left + 3, r.top + 3, r.right - 3, r.bottom - 3}
		DrawFocusRect(dc, &focus)
	}
}

date_calendar_close :: proc(restore_focus: bool) {
	if ui.date_popup == nil || date_popup_closing { return }
	date_popup_closing = true
	defer { date_popup_closing = false }
	windows.ShowWindow(ui.date_popup, windows.SW_HIDE)
	if restore_focus {
		windows.SetForegroundWindow(ui.hwnd)
		windows.SetFocus(ui.date_picker)
	}
}

date_calendar_accept :: proc() {
	st: windows.SYSTEMTIME
	if windows.SendMessageW(ui.date_calendar, 0x1001, 0, windows.LPARAM(uintptr(&st))) != 0 {
		global_app.date = date_int_from_systemtime(st)
		sync_date_picker(global_app)
		load_day(global_app)
		windows.InvalidateRect(ui.hwnd, nil, windows.FALSE)
	}
	date_calendar_close(true)
}

date_popup_proc :: proc "std" (hwnd: windows.HWND, msg: u32, wp: windows.WPARAM, lp: windows.LPARAM) -> windows.LRESULT {
	context = rt.default_context()
	switch msg {
	case windows.WM_ACTIVATE:
		if u32(wp) & 0xFFFF == 0 { date_calendar_close(false) }
		return 0
	case windows.WM_CLOSE:
		date_calendar_close(true)
		return 0
	case windows.WM_NOTIFY:
		nm := transmute(^windows.NMHDR)(lp)
		if nm != nil && nm.hwndFrom == ui.date_calendar && nm.code == ~u32(745) { // MCN_SELECT (-746)
			date_calendar_accept()
		}
		return 0
	}
	return windows.DefWindowProcW(hwnd, msg, wp, lp)
}

date_calendar_open :: proc() {
	if ui.date_popup == nil {
		hi := windows.HINSTANCE(windows.GetModuleHandleW(nil))
		wc := windows.WNDCLASSEXW{cbSize = size_of(windows.WNDCLASSEXW),
			lpfnWndProc = date_popup_proc, hInstance = hi,
			hCursor = windows.LoadCursorW(nil, transmute(cstring16)(u64(32512))),
			lpszClassName = wtext("aika_date_popup")}
		windows.RegisterClassExW(&wc)
		ui.date_popup = windows.CreateWindowExW(0x80, wc.lpszClassName, wtext("Choose date"),
			windows.WS_POPUP | windows.WS_BORDER, 0, 0, 240, 200, ui.hwnd, nil, hi, nil)
		if ui.date_popup == nil { return }
		ui.date_calendar = windows.CreateWindowExW(0, wtext("SysMonthCal32"), nil,
			windows.WS_CHILD | windows.WS_VISIBLE | windows.WS_TABSTOP, 0, 0, 240, 200,
			ui.date_popup, nil, hi, nil)
	}
	if ui.date_calendar == nil { return }
	theme_date_calendar()
	sync_date_picker(global_app)
	minimum: windows.RECT
	windows.SendMessageW(ui.date_calendar, 0x1009, 0, windows.LPARAM(uintptr(&minimum))) // MCM_GETMINREQRECT
	w, h := minimum.right - minimum.left, minimum.bottom - minimum.top
	if w <= 0 || h <= 0 { return }
	windows.MoveWindow(ui.date_calendar, 0, 0, w, h, windows.TRUE)
	button: windows.RECT
	windows.GetWindowRect(ui.date_picker, &button)
	outer := windows.RECT{0, 0, w, h}
	windows.AdjustWindowRectEx(&outer, windows.WS_POPUP | windows.WS_BORDER, windows.FALSE, 0x80)
	pw, ph := outer.right - outer.left, outer.bottom - outer.top
	x, y := button.left, button.bottom
	monitor := Monitor_Info{cbSize = size_of(Monitor_Info)}
	if GetMonitorInfoW(MonitorFromWindow(ui.date_picker, 2), &monitor) {
		x = clamp(x, monitor.rcWork.left, max(monitor.rcWork.left, monitor.rcWork.right - pw))
		if y + ph > monitor.rcWork.bottom { y = button.top - ph }
		y = clamp(y, monitor.rcWork.top, max(monitor.rcWork.top, monitor.rcWork.bottom - ph))
	}
	windows.MoveWindow(ui.date_popup, x, y, pw, ph, windows.TRUE)
	windows.ShowWindow(ui.date_popup, windows.SW_SHOW)
	windows.SetForegroundWindow(ui.date_popup)
	windows.SetFocus(ui.date_calendar)
}

date_picker_key :: proc(msg: ^windows.MSG) -> bool {
	if ui.date_popup == nil || !windows.IsWindowVisible(ui.date_popup) { return false }
	if msg.message == windows.WM_KEYDOWN {
		switch msg.wParam {
		case 0x1B: date_calendar_close(true); return true
		case 0x0D: date_calendar_accept(); return true
		}
	}
	return false
}
