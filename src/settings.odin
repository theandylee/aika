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

SettingsUi :: struct {
	hwnd, minutes, autostart, import_manictime: windows.HWND,
	folder, folder_browse, folder_default: windows.HWND,
	tracking_labels: [2]windows.HWND, // static labels beside the minutes box
	page: int,                        // index into SETTINGS_PAGES
	control_failed: bool,
}
settings_ui: SettingsUi

SETTINGS_PAGES :: [3]string{"General", "Tracking", "Import"}
SETTINGS_PAGE_GENERAL  :: 0
SETTINGS_PAGE_TRACKING :: 1
SETTINGS_PAGE_IMPORT   :: 2

settings_page_rect :: proc(i: int) -> windows.RECT {
	y := i32(12 + 28 * i)
	return windows.RECT{10, y, 148, y + 26}
}

// Shows one page's controls and hides the other's; the parent repaints the
// section list and group frames.
settings_show_page :: proc(page: int) {
	settings_ui.page = page
	tracking := page == SETTINGS_PAGE_TRACKING
	windows.ShowWindow(settings_ui.minutes, windows.SW_SHOW if tracking else windows.SW_HIDE)
	for label in settings_ui.tracking_labels {
		windows.ShowWindow(label, windows.SW_SHOW if tracking else windows.SW_HIDE)
	}
	general := windows.SW_SHOW if page == SETTINGS_PAGE_GENERAL else windows.SW_HIDE
	windows.ShowWindow(settings_ui.autostart, general)
	windows.ShowWindow(settings_ui.folder, general)
	windows.ShowWindow(settings_ui.folder_browse, general)
	windows.ShowWindow(settings_ui.folder_default, general)
	windows.ShowWindow(settings_ui.import_manictime, windows.SW_SHOW if page == SETTINGS_PAGE_IMPORT else windows.SW_HIDE)
	windows.InvalidateRect(settings_ui.hwnd, nil, windows.TRUE)
}

settings_focus_page :: proc() {
	if settings_ui.page == SETTINGS_PAGE_TRACKING {
		windows.SetFocus(settings_ui.minutes)
		windows.SendMessageW(settings_ui.minutes, windows.EM_SETSEL, 0, -1)
	} else if settings_ui.page == SETTINGS_PAGE_IMPORT {
		windows.SetFocus(settings_ui.import_manictime)
	} else {
		windows.SetFocus(settings_ui.autostart)
	}
}

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
		settings_show_page(SETTINGS_PAGE_TRACKING)
		windows.MessageBoxW(settings_ui.hwnd, wtext("Enter a whole number from 1 to 500 minutes."), wtext("Tracking settings"), windows.MB_ICONWARNING)
		settings_focus_page()
		return
	}
	// Validate the folder before anything is applied, so a bad path changes nothing.
	new_dir, folder_changed, folder_ok := settings_read_folder()
	if !folder_ok {
		settings_show_page(SETTINGS_PAGE_GENERAL)
		windows.MessageBoxW(settings_ui.hwnd, wtext("Enter a full folder path, such as C:\\Users\\you\\aika-data."), wtext("Data folder"), windows.MB_ICONWARNING)
		windows.SetFocus(settings_ui.folder)
		return
	}
	was_autostart := autostart_enabled()
	want_autostart := windows.SendMessageW(settings_ui.autostart, windows.BM_GETCHECK, 0, 0) == windows.BST_CHECKED
	if want_autostart != was_autostart && !autostart_set(want_autostart, global_app.db_path) {
		windows.MessageBoxW(settings_ui.hwnd, wtext("Could not change the Windows startup entry. No changes were applied."), wtext("Settings"), windows.MB_ICONERROR)
		return
	}
	if !settings_save_minutes(global_app.db_path, minutes) {
		if want_autostart != was_autostart { autostart_set(was_autostart, global_app.db_path) }
		windows.MessageBoxW(settings_ui.hwnd, wtext("Could not save settings beside the database. No changes were applied."), wtext("Settings"), windows.MB_ICONERROR)
		return
	}
	global_app.tracker.idle_threshold_ms = i64(minutes) * MS_PER_MINUTE
	if folder_changed && !settings_change_folder(new_dir, minutes) { return }
	settings_close()
}

// Folder text from the edit box. `changed` compares against the open database's
// folder; `ok` is false for text that is not a full path.
settings_read_folder :: proc() -> (dir: string, changed, ok: bool) {
	if db_path_overridden { return "", false, true }
	buf: [1024]u16
	n := windows.GetWindowTextW(settings_ui.folder, &buf[0], len(buf))
	text, _ := windows.utf16_to_utf8(buf[:max(0, n)], context.temp_allocator)
	dir = datadir_norm(text)
	if !datadir_is_abs(dir) { return dir, false, false }
	return dir, !strings.equal_fold(dir, datadir_current(global_app)), true
}

// Asks whether to move the data, then switches. Returns false to stay in settings.
settings_change_folder :: proc(new_dir: string, minutes: int) -> bool {
	owner := settings_ui.hwnd
	caption := wtext("Data folder")
	old_dir := datadir_current(global_app)
	answer := windows.MessageBoxW(owner, wtext(fmt.tprintf(
		"Move your existing data to the new folder?\n\nFrom: %s\nTo: %s\n\nYes: copy your data there and remove it from the old folder.\nNo: switch folders without moving. aika uses what is already in the new folder, or starts a new database.\nCancel: keep the current folder.",
		old_dir, new_dir)), caption, windows.MB_YESNOCANCEL | windows.MB_ICONQUESTION)
	if answer != windows.IDYES && answer != windows.IDNO { return false }

	was_autostart := autostart_enabled()
	result := datadir_switch(global_app, new_dir, answer == windows.IDYES)
	text: string
	switch result {
	case .Ok:
		// Settings and the startup entry follow the database.
		settings_save_minutes(global_app.db_path, minutes)
		global_app.tracker.idle_threshold_ms = i64(minutes) * MS_PER_MINUTE
		if was_autostart { autostart_set(true, global_app.db_path) }
		windows.InvalidateRect(ui.hwnd, nil, windows.TRUE)
		return true
	case .Unusable_Folder: text = "aika cannot create or write to that folder. Choose another one."
	case .Has_Data:        text = "That folder already contains an aika database, so it cannot be overwritten. Choose No to use it, or pick another folder."
	case .Pointer_Failed:  text = "Could not remember the new folder. Nothing was changed."
	case .Flush_Failed:    text = "Could not save the activity in progress. Nothing was changed; try again."
	case .Copy_Failed:     text = "Could not copy your data to the new folder. Nothing was moved."
	case .Open_Failed:     text = "Could not open a database in the new folder. Nothing was moved."
	}
	windows.MessageBoxW(owner, wtext(text), caption, windows.MB_ICONERROR)
	return false
}

settings_folder_browse :: proc() {
	buf: [1024]u16
	n := windows.GetWindowTextW(settings_ui.folder, &buf[0], len(buf))
	text, _ := windows.utf16_to_utf8(buf[:max(0, n)], context.temp_allocator)
	if path, ok := datadir_browse(settings_ui.hwnd, datadir_norm(text)); ok {
		windows.SetWindowTextW(settings_ui.folder, wtext(path))
	}
}

// OK/Cancel are owner-drawn with the same flat face/border as the date button,
// so they match the palette in both themes.
draw_settings_button :: proc(item: ^Draw_Item) {
	dc, r := item.hDC, item.rcItem
	bg := C_BTN_FACE
	if item.itemState & ODS_SELECTED != 0 { bg = C_BORDER_SOFT }
	fill_rect(dc, r.left, r.top, r.right - r.left, r.bottom - r.top, bg)
	fill_frame(dc, r.left, r.top, r.right - r.left, r.bottom - r.top, C_BTN_BORDER)
	windows.SetBkMode(dc, windows.BKMODE.TRANSPARENT)
	buf: [32]u16
	n := windows.GetWindowTextW(item.hwndItem, &buf[0], len(buf))
	label, _ := windows.utf16_to_utf8(buf[:max(0, n)], context.temp_allocator)
	draw_button_text(dc, label, r)
	if item.itemState & ODS_FOCUS != 0 {
		focus := windows.RECT{r.left + 3, r.top + 3, r.right - 3, r.bottom - 3}
		DrawFocusRect(dc, &focus)
	}
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
		windows.SetBkMode(dc, windows.BKMODE.TRANSPARENT)
		pages := SETTINGS_PAGES
		for name, i in pages {
			r := settings_page_rect(i)
			if i == settings_ui.page { fill_rect(dc, r.left, r.top, r.right - r.left, r.bottom - r.top, C_SECTION_HEAD) }
			draw_string(dc, name, 18, r.top + 6, ui.font_normal, C_TXT)
		}
		if settings_ui.page == SETTINGS_PAGE_GENERAL {
			fill_frame(dc, 164, 22, 370, 82, C_BORDER)
			fill_rect(dc, 172, 14, 62, 18, C_BG)
			draw_string(dc, "Startup", 176, 16, ui.font_normal, C_TXT)
			draw_string(dc, "Runs from this folder; toggle again if you move aika.", 176, 76, ui.font_normal, C_DIM)
			fill_frame(dc, 164, 124, 370, 118, C_BORDER)
			fill_rect(dc, 172, 116, 92, 18, C_BG)
			draw_string(dc, "Data folder", 176, 118, ui.font_normal, C_TXT)
			note := "Set by --db for this run; it cannot be changed here." if db_path_overridden else "Your database and settings are kept here."
			draw_string(dc, note, 176, 214, ui.font_normal, C_DIM)
		} else if settings_ui.page == SETTINGS_PAGE_IMPORT {
			fill_frame(dc, 164, 22, 370, 110, C_BORDER)
			fill_rect(dc, 172, 14, 90, 18, C_BG)
			draw_string(dc, "ManicTime", 176, 16, ui.font_normal, C_TXT)
			draw_string(dc, "Imports all history from the ManicTime on this PC.", 176, 84, ui.font_normal, C_DIM)
			draw_string(dc, "Safe to repeat; existing entries are updated.", 176, 102, ui.font_normal, C_DIM)
		} else {
			fill_frame(dc, 164, 22, 370, 100, C_BORDER)
			fill_rect(dc, 172, 14, 180, 18, C_BG)
			draw_string(dc, "Time is marked as Away when", 176, 16, ui.font_normal, C_TXT)
			draw_string(dc, "No keyboard or mouse input.", 176, 148, ui.font_normal, C_DIM)
		}
		windows.EndPaint(hwnd, &ps)
		return 0
	case windows.WM_CTLCOLOREDIT, windows.WM_CTLCOLORSTATIC, windows.WM_CTLCOLORBTN:
		return theme_control_colors(wp)
	case windows.WM_DRAWITEM:
		item := transmute(^Draw_Item)(lp)
		if item != nil && (item.CtlID == SETTINGS_ID_OK || item.CtlID == SETTINGS_ID_CANCEL ||
		   item.CtlID == SETTINGS_ID_IMPORT_MANICTIME || item.CtlID == SETTINGS_ID_FOLDER_BROWSE ||
		   item.CtlID == SETTINGS_ID_FOLDER_DEFAULT) {
			draw_settings_button(item)
			return 1
		}
		return 0
	case windows.WM_LBUTTONDOWN:
		x, y := i32(i16(lp & 0xFFFF)), i32(i16((lp >> 16) & 0xFFFF))
		for i in 0 ..< len(SETTINGS_PAGES) {
			if rect_hit(settings_page_rect(i), x, y) {
				if i != settings_ui.page { settings_show_page(i); settings_focus_page() }
				break
			}
		}
		return 0
	case windows.WM_CLOSE:
		settings_close()
		return 0
	case windows.WM_COMMAND:
		switch u32(wp) & 0xFFFF {
		case SETTINGS_ID_OK: settings_accept()
		case SETTINGS_ID_CANCEL: settings_close()
		case SETTINGS_ID_IMPORT_MANICTIME: settings_import_manictime()
		case SETTINGS_ID_FOLDER_BROWSE: settings_folder_browse()
		case SETTINGS_ID_FOLDER_DEFAULT:
			windows.SetWindowTextW(settings_ui.folder, wtext(datadir_default()))
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
	settings_ui.tracking_labels[0] = settings_control("STATIC", "Computer is not used for", 0, 176, 58, 146, 22, 0)
	settings_ui.minutes = settings_control("EDIT", fmt.tprintf("%d", global_app.tracker.idle_threshold_ms / MS_PER_MINUTE),
		windows.WS_BORDER | windows.WS_TABSTOP | windows.ES_NUMBER, 326, 54, 54, 24, SETTINGS_ID_MINUTES)
	windows.SendMessageW(settings_ui.minutes, windows.EM_SETLIMITTEXT, 3, 0)
	settings_ui.tracking_labels[1] = settings_control("STATIC", "minutes (1–500)", 0, 388, 58, 136, 22, 0)
	settings_ui.autostart = settings_control("BUTTON", "Start aika when I sign in to Windows",
		windows.WS_TABSTOP | windows.BS_AUTOCHECKBOX, 176, 44, 340, 24, SETTINGS_ID_AUTOSTART)
	if settings_ui.autostart != nil && autostart_enabled() {
		windows.SendMessageW(settings_ui.autostart, windows.BM_SETCHECK, windows.WPARAM(windows.BST_CHECKED), 0)
	}
	settings_ui.import_manictime = settings_control("BUTTON", "Import data from ManicTime",
		windows.WS_TABSTOP | windows.BS_OWNERDRAW, 176, 44, 220, 28, SETTINGS_ID_IMPORT_MANICTIME)
	settings_ui.folder = settings_control("EDIT", datadir_current(global_app),
		windows.WS_BORDER | windows.WS_TABSTOP | windows.ES_AUTOHSCROLL, 176, 148, 348, 24, SETTINGS_ID_FOLDER)
	settings_ui.folder_browse = settings_control("BUTTON", "Browse…",
		windows.WS_TABSTOP | windows.BS_OWNERDRAW, 176, 180, 96, 28, SETTINGS_ID_FOLDER_BROWSE)
	settings_ui.folder_default = settings_control("BUTTON", "Use default",
		windows.WS_TABSTOP | windows.BS_OWNERDRAW, 280, 180, 110, 28, SETTINGS_ID_FOLDER_DEFAULT)
	if db_path_overridden {
		windows.EnableWindow(settings_ui.folder, windows.FALSE)
		windows.EnableWindow(settings_ui.folder_browse, windows.FALSE)
		windows.EnableWindow(settings_ui.folder_default, windows.FALSE)
	}
	settings_control("BUTTON", "OK", windows.WS_TABSTOP | windows.BS_OWNERDRAW, 334, 394, 96, 28, SETTINGS_ID_OK)
	settings_control("BUTTON", "Cancel", windows.WS_TABSTOP | windows.BS_OWNERDRAW, 438, 394, 96, 28, SETTINGS_ID_CANCEL)
	if settings_ui.control_failed { settings_close(); return }
	dark := windows.BOOL(ui.dark)
	DwmSetWindowAttribute(settings_ui.hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, size_of(dark))
	SetWindowTheme(settings_ui.minutes, wtext("DarkMode_Explorer") if ui.dark else nil, nil)
	SetWindowTheme(settings_ui.autostart, wtext("DarkMode_Explorer") if ui.dark else nil, nil)
	SetWindowTheme(settings_ui.folder, wtext("DarkMode_Explorer") if ui.dark else nil, nil)
	windows.EnableWindow(ui.hwnd, windows.FALSE)
	settings_show_page(SETTINGS_PAGE_GENERAL)
	windows.ShowWindow(settings_ui.hwnd, windows.SW_SHOW)
	windows.SetForegroundWindow(settings_ui.hwnd)
	settings_focus_page()
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
