package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/windows"
import rt "base:runtime"

DEFAULT_IDLE_MINUTES :: 1

settings_parse_minutes :: proc(text: string) -> (minutes: int, ok: bool) {
	minutes, ok = strconv.parse_int(strings.trim_space(text))
	ok = ok && minutes >= 1 && minutes <= 500
	return
}

settings_load_minutes :: proc(db_path: string) -> int {
	if db_path == "" { return DEFAULT_IDLE_MINUTES }
	data, err := os.read_entire_file(fmt.tprintf("%s.settings", db_path), context.temp_allocator)
	if err == nil {
		if minutes, ok := settings_parse_minutes(string(data)); ok { return minutes }
	}
	return DEFAULT_IDLE_MINUTES
}

settings_save_minutes :: proc(db_path: string, minutes: int) -> bool {
	if minutes < 1 || minutes > 500 { return false }
	return os.write_entire_file(fmt.tprintf("%s.settings", db_path),
		transmute([]u8)fmt.tprintf("%d\n", minutes)) == nil
}

SettingsUi :: struct { hwnd, minutes: windows.HWND, control_failed: bool }
settings_ui: SettingsUi

// The settings window exists only while open (settings_close destroys it),
// so a non-nil handle means it owns the cursor.
settings_popup_open :: proc() -> bool {
	return settings_ui.hwnd != nil
}

settings_switch_rect :: proc(w: i32) -> windows.RECT {
	return windows.RECT{w - dpi_px(70), dpi_px(2), w - dpi_px(42), dpi_px(TAB_H) - dpi_px(2)}
}

draw_settings_switch :: proc(dc: windows.HDC, w: i32) {
	r := settings_switch_rect(w)
	draw_button(dc, r, "", .Settings)
	old := windows.SelectObject(dc, windows.HGDIOBJ(ui.font_icons))
	defer windows.SelectObject(dc, old)
	windows.SetTextColor(dc, C_TXT)
	flags := windows.DrawTextFormat.DT_SINGLELINE | windows.DrawTextFormat.DT_CENTER |
		windows.DrawTextFormat.DT_VCENTER | windows.DrawTextFormat.DT_NOPREFIX
	windows.DrawTextW(dc, wtext("⚙"), -1, &r, flags)
}

draw_settings_tooltip :: proc(dc: windows.HDC, w: i32) {
	if !ui.mouse_valid || press_hit() != .None ||
	   !rect_hit(settings_switch_rect(w), ui.mouse.x, ui.mouse.y) { return }
	width := text_pixel_width("Settings", ui.font_normal) + 16
	draw_single_line_tooltip(dc, tab_tooltip_rect(w - dpi_px(42), width), "Settings")
}

settings_close :: proc() {
	if settings_ui.hwnd == nil { return }
	hwnd := settings_ui.hwnd
	settings_ui = {}
	windows.EnableWindow(ui.hwnd, windows.TRUE)
	windows.DestroyWindow(hwnd)
	windows.SetForegroundWindow(ui.hwnd)
}

settings_accept :: proc() {
	buf: [64]u16
	n := windows.GetWindowTextW(settings_ui.minutes, &buf[0], len(buf))
	text, _ := windows.utf16_to_utf8(buf[:max(0, n)], context.temp_allocator)
	minutes, ok := settings_parse_minutes(text)
	if !ok {
		windows.MessageBoxW(settings_ui.hwnd, wtext("Enter a whole number from 1 to 500 minutes."), wtext("Tracking settings"), windows.MB_ICONWARNING)
		windows.SetFocus(settings_ui.minutes)
		windows.SendMessageW(settings_ui.minutes, windows.EM_SETSEL, 0, -1)
		return
	}
	if !settings_save_minutes(global_app.db_path, minutes) {
		windows.MessageBoxW(settings_ui.hwnd, wtext("Could not save settings beside the database. No changes were applied."), wtext("Settings"), windows.MB_ICONERROR)
		return
	}
	global_app.tracker.idle_threshold_ms = i64(minutes) * MS_PER_MINUTE
	settings_close()
}

settings_proc :: proc "std" (hwnd: windows.HWND, msg: u32, wp: windows.WPARAM, lp: windows.LPARAM) -> windows.LRESULT {
	context = rt.default_context()
	scratch: Scratch
	context.temp_allocator = scratch_begin(&scratch)
	defer scratch_end(&scratch)
	switch msg {
	case windows.WM_ERASEBKGND:
		return 1
	case windows.WM_PAINT:
		ps: windows.PAINTSTRUCT
		dc := windows.BeginPaint(hwnd, &ps)
		w, h := client_size(hwnd)
		fill_rect(dc, 0, 0, w, h, C_BG)
		fill_rect(dc, 8, 8, 142, h - 56, C_PANEL)
		fill_frame(dc, 8, 8, 142, h - 56, C_BORDER)
		fill_rect(dc, 10, 12, 138, 26, C_SECTION_HEAD)
		windows.SetBkMode(dc, windows.BKMODE.TRANSPARENT)
		draw_string(dc, "Tracking", 18, 18, ui.font_normal, C_TXT)
		fill_frame(dc, 164, 22, 370, 100, C_BORDER)
		fill_rect(dc, 172, 14, 180, 18, C_BG)
		draw_string(dc, "Time is marked as Away when", 176, 16, ui.font_normal, C_TXT)
		draw_string(dc, "No keyboard or mouse input.", 176, 148, ui.font_normal, C_DIM)
		draw_string(dc, "Changes apply when you click OK.", 176, 170, ui.font_normal, C_DIM)
		windows.EndPaint(hwnd, &ps)
		return 0
	case windows.WM_CTLCOLOREDIT, windows.WM_CTLCOLORSTATIC:
		return theme_control_colors(wp)
	case windows.WM_CLOSE:
		settings_close()
		return 0
	case windows.WM_COMMAND:
		switch u32(wp) & 0xFFFF {
		case SETTINGS_ID_OK: settings_accept()
		case SETTINGS_ID_CANCEL: settings_close()
		}
		return 0
	}
	return windows.DefWindowProcW(hwnd, msg, wp, lp)
}

settings_control :: proc(class, label: string, style: u32, x, y, w, h: i32, id: uintptr) -> windows.HWND {
	hwnd := windows.CreateWindowExW(0, wtext(class), wtext(label),
		windows.WS_CHILD | windows.WS_VISIBLE | style, x, y, w, h,
		settings_ui.hwnd, windows.HMENU(id), windows.HINSTANCE(windows.GetModuleHandleW(nil)), nil)
	if hwnd == nil { settings_ui.control_failed = true; return nil }
	windows.SendMessageW(hwnd, windows.WM_SETFONT, windows.WPARAM(ui.font_normal), 0)
	return hwnd
}

settings_open :: proc() {
	if settings_ui.hwnd != nil { windows.SetForegroundWindow(settings_ui.hwnd); return }
	if tag_ui.popup != nil { windows.SetForegroundWindow(tag_ui.popup); return }
	date_calendar_close(false)
	hi := windows.HINSTANCE(windows.GetModuleHandleW(nil))
	wc := windows.WNDCLASSEXW{cbSize = size_of(windows.WNDCLASSEXW), lpfnWndProc = settings_proc,
		hInstance = hi, hCursor = system_cursor(IDC_ARROW),
		lpszClassName = wtext("aika_settings")}
	windows.RegisterClassExW(&wc)
	style := u32(windows.WS_CAPTION | windows.WS_SYSMENU | windows.WS_CLIPCHILDREN)
	r := windows.RECT{0, 0, 546, 430}
	windows.AdjustWindowRectEx(&r, style, windows.FALSE, 0)
	parent: windows.RECT
	windows.GetWindowRect(ui.hwnd, &parent)
	width, height := r.right - r.left, r.bottom - r.top
	x := parent.left + (parent.right - parent.left - width) / 2
	y := parent.top + (parent.bottom - parent.top - height) / 2
	settings_ui.hwnd = windows.CreateWindowExW(0, wc.lpszClassName, wtext("Settings"), style,
		x, y, width, height, ui.hwnd, nil, hi, nil)
	if settings_ui.hwnd == nil { return }
	settings_control("STATIC", "Computer is not used for", 0, 176, 58, 146, 22, 0)
	settings_ui.minutes = settings_control("EDIT", fmt.tprintf("%d", global_app.tracker.idle_threshold_ms / MS_PER_MINUTE),
		windows.WS_BORDER | windows.WS_TABSTOP | windows.ES_NUMBER, 326, 54, 54, 24, SETTINGS_ID_MINUTES)
	windows.SendMessageW(settings_ui.minutes, windows.EM_SETLIMITTEXT, 3, 0)
	settings_control("STATIC", "minutes (1–500)", 0, 388, 58, 136, 22, 0)
	settings_control("BUTTON", "OK", windows.WS_TABSTOP | windows.BS_DEFPUSHBUTTON, 334, 394, 96, 28, SETTINGS_ID_OK)
	settings_control("BUTTON", "Cancel", windows.WS_TABSTOP, 438, 394, 96, 28, SETTINGS_ID_CANCEL)
	if settings_ui.control_failed { settings_close(); return }
	dark := windows.BOOL(ui.dark)
	DwmSetWindowAttribute(settings_ui.hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, size_of(dark))
	SetWindowTheme(settings_ui.minutes, wtext("DarkMode_Explorer") if ui.dark else nil, nil)
	windows.EnableWindow(ui.hwnd, windows.FALSE)
	windows.ShowWindow(settings_ui.hwnd, windows.SW_SHOW)
	windows.SetForegroundWindow(settings_ui.hwnd)
	windows.SetFocus(settings_ui.minutes)
	windows.SendMessageW(settings_ui.minutes, windows.EM_SETSEL, 0, -1)
}

settings_key :: proc(msg: ^windows.MSG) -> bool {
	if settings_ui.hwnd == nil { return false }
	if msg.message == windows.WM_KEYDOWN {
		switch msg.wParam {
		case windows.VK_ESCAPE: settings_close(); return true
		case windows.VK_RETURN:
			if windows.GetDlgCtrlID(windows.GetFocus()) == SETTINGS_ID_CANCEL { settings_close() } else { settings_accept() }
			return true
		}
	}
	return bool(windows.IsDialogMessageW(settings_ui.hwnd, msg))
}
