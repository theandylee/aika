package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sys/windows"
import rt "base:runtime"

DEFAULT_IDLE_MINUTES :: 1

POMODORO_DEFAULT_MINUTES :: 25
POMODORO_MIN_MINUTES     :: 1
POMODORO_MAX_MINUTES     :: 180

// Pomodoro choices in effect (loaded at startup, written by settings_save_current).
pomodoro_on: bool
pomodoro_minutes: int = POMODORO_DEFAULT_MINUTES

settings_parse_minutes :: proc(text: string) -> (minutes: int, ok: bool) {
	minutes, ok = strconv.parse_int(strings.trim_space(text))
	ok = ok && minutes >= 1 && minutes <= 500
	return
}

// aika-settings.toml lives in the data folder, beside the database:
//
//   [tracking]
//   idle_minutes = 1
//
//   [updates]
//   on_start = true
//   periodic = true
//
//   [appearance]
//   theme = "light"   # or "dark"
//
//   [tag_picker]      # written once the picker has been resized
//   width = 420
//   height = 350
//
//   [layout]          # written once a pane was dragged or the window maximized
//   timeline_height = 0   # 1/1000 of the span; 0 = default
//   totals_width = 0
//   maximized = false
//
//   [pomodoro]        # Start task window: mode toggle and duration
//   enabled = false
//   minutes = 25
//
// Missing or invalid keys keep their defaults. Older versions kept `<db>.settings`
// (first a bare number, later TOML) and `<db>.theme`; settings_migrate_legacy
// folds those into this file once and deletes them.
SETTINGS_FILE_NAME :: "aika-settings.toml"

Settings :: struct {
	idle_minutes:     int,
	updates_on_start: bool,
	updates_periodic: bool,
	dark:             bool,
	picker_w:         int, // tag picker outer size in pixels; 0 = default
	picker_h:         int,
	pomodoro_on:      bool,
	pomodoro_minutes: int, // POMODORO_MIN_MINUTES..POMODORO_MAX_MINUTES
	lane_permille:    int, // timeline height as 1/1000 of the span; 0 = default
	totals_permille:  int, // totals panel width as 1/1000 of the chart width; 0 = default
	maximized:        bool,
}

SETTINGS_DEFAULT :: Settings{idle_minutes = DEFAULT_IDLE_MINUTES, updates_on_start = true, updates_periodic = true,
	pomodoro_minutes = POMODORO_DEFAULT_MINUTES}

// Parses the small TOML subset above: [tables], `key = value` with integers and
// booleans, and # comments. Anything else is ignored.
settings_parse_toml :: proc(text: string) -> (s: Settings) {
	s = SETTINGS_DEFAULT
	if minutes, ok := settings_parse_minutes(text); ok { // legacy: just the number
		s.idle_minutes = minutes
		return
	}
	section := ""
	it := text
	for raw in strings.split_lines_iterator(&it) {
		line, _, _ := strings.partition(raw, "#")
		line = strings.trim_space(line)
		if len(line) == 0 { continue }
		if line[0] == '[' {
			section = strings.trim_space(strings.trim_suffix(line[1:], "]"))
			continue
		}
		key, _, value := strings.partition(line, "=")
		key, value = strings.trim_space(key), strings.trim_space(value)
		switch section {
		case "tracking":
			if key == "idle_minutes" {
				if minutes, ok := settings_parse_minutes(value); ok { s.idle_minutes = minutes }
			}
		case "updates":
			if value == "true" || value == "false" {
				switch key {
				case "on_start": s.updates_on_start = value == "true"
				case "periodic": s.updates_periodic = value == "true"
				}
			}
		case "appearance":
			if key == "theme" { s.dark = strings.trim(value, "\"") == "dark" }
		case "tag_picker":
			if n, ok := strconv.parse_int(value); ok && n >= 100 && n <= 10000 {
				switch key {
				case "width":  s.picker_w = n
				case "height": s.picker_h = n
				}
			}
		case "layout":
			switch key {
			case "timeline_height":
				if n, ok := strconv.parse_int(value); ok && n > 0 && n <= 1000 { s.lane_permille = n }
			case "totals_width":
				if n, ok := strconv.parse_int(value); ok && n > 0 && n <= 1000 { s.totals_permille = n }
			case "maximized":
				if value == "true" || value == "false" { s.maximized = value == "true" }
			}
		case "pomodoro":
			switch key {
			case "enabled":
				if value == "true" || value == "false" { s.pomodoro_on = value == "true" }
			case "minutes":
				if n, ok := strconv.parse_int(value); ok && n >= POMODORO_MIN_MINUTES && n <= POMODORO_MAX_MINUTES {
					s.pomodoro_minutes = n
				}
			}
		}
	}
	return
}

settings_format_toml :: proc(s: Settings) -> string {
	text := fmt.tprintf("[tracking]\nidle_minutes = %d\n\n[updates]\non_start = %v\nperiodic = %v\n\n[appearance]\ntheme = \"%s\"\n",
		s.idle_minutes, s.updates_on_start, s.updates_periodic, "dark" if s.dark else "light")
	if s.picker_w > 0 && s.picker_h > 0 {
		text = fmt.tprintf("%s\n[tag_picker]\nwidth = %d\nheight = %d\n", text, s.picker_w, s.picker_h)
	}
	if s.lane_permille > 0 || s.totals_permille > 0 || s.maximized {
		text = fmt.tprintf("%s\n[layout]\ntimeline_height = %d\ntotals_width = %d\nmaximized = %v\n",
			text, s.lane_permille, s.totals_permille, s.maximized)
	}
	if s.pomodoro_minutes >= POMODORO_MIN_MINUTES && s.pomodoro_minutes <= POMODORO_MAX_MINUTES {
		text = fmt.tprintf("%s\n[pomodoro]\nenabled = %v\nminutes = %d\n", text, s.pomodoro_on, s.pomodoro_minutes)
	}
	return text
}

// The settings file for a database: in the same folder, so a custom data folder
// (or --db) keeps its own preferences.
settings_path :: proc(db_path: string) -> string {
	context.allocator = context.temp_allocator // filepath.dir allocates
	dir := filepath.dir(db_path)
	if dir == "" || dir == "." { return SETTINGS_FILE_NAME }
	return fmt.tprintf("%s\\%s", dir, SETTINGS_FILE_NAME)
}

// One-time upgrade from `<db>.settings` + `<db>.theme`; no-op once the new file exists.
settings_migrate_legacy :: proc(db_path: string) {
	if db_path == "" || datadir_exists(settings_path(db_path)) { return }
	legacy_settings, legacy_theme := fmt.tprintf("%s.settings", db_path), fmt.tprintf("%s.theme", db_path)
	have_settings, have_theme := datadir_exists(legacy_settings), datadir_exists(legacy_theme)
	if !have_settings && !have_theme { return }
	s := SETTINGS_DEFAULT
	if data, err := os.read_entire_file(legacy_settings, context.temp_allocator); err == nil {
		s = settings_parse_toml(string(data))
	}
	if data, err := os.read_entire_file(legacy_theme, context.temp_allocator); err == nil {
		s.dark = strings.trim_space(string(data)) == "dark"
	}
	if settings_save(db_path, s) {
		os.remove(legacy_settings)
		os.remove(legacy_theme)
	}
}

settings_load :: proc(db_path: string) -> Settings {
	if db_path == "" { return SETTINGS_DEFAULT }
	data, err := os.read_entire_file(settings_path(db_path), context.temp_allocator)
	if err != nil { return SETTINGS_DEFAULT }
	return settings_parse_toml(string(data))
}

settings_save :: proc(db_path: string, s: Settings) -> bool {
	if s.idle_minutes < 1 || s.idle_minutes > 500 { return false }
	return os.write_entire_file(settings_path(db_path), transmute([]u8)settings_format_toml(s)) == nil
}

settings_load_minutes :: proc(db_path: string) -> int { return settings_load(db_path).idle_minutes }

// Saves everything: the given idle minutes plus the update policy and theme in effect.
settings_save_current :: proc(db_path: string, minutes: int) -> bool {
	on_start, periodic := update_policy()
	return settings_save(db_path, Settings{idle_minutes = minutes, updates_on_start = on_start,
		updates_periodic = periodic, dark = ui.dark, picker_w = int(tag_picker_size.x), picker_h = int(tag_picker_size.y),
		pomodoro_on = pomodoro_on, pomodoro_minutes = pomodoro_minutes,
		lane_permille = int(ui.pane_lane_frac * 1000 + 0.5), totals_permille = int(ui.pane_totals_frac * 1000 + 0.5),
		maximized = ui.maximized})
}

// Persists pane proportions / maximize state, keeping the other saved values.
settings_save_layout :: proc() {
	if global_app == nil { return }
	settings_save_current(global_app.db_path, settings_load(global_app.db_path).idle_minutes)
}

SettingsUi :: struct {
	hwnd, minutes, autostart, updates_start, updates_periodic, import_manictime: windows.HWND,
	folder, folder_browse, folder_default, folder_open: windows.HWND,
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
	windows.ShowWindow(settings_ui.updates_start, general)
	windows.ShowWindow(settings_ui.updates_periodic, general)
	windows.ShowWindow(settings_ui.folder, general)
	windows.ShowWindow(settings_ui.folder_browse, general)
	windows.ShowWindow(settings_ui.folder_default, general)
	windows.ShowWindow(settings_ui.folder_open, general)
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

settings_gear_icon: windows.HICON

// Render the gear glyph into a small per-pixel-alpha icon for the title bar.
// The glyph is drawn white-on-black into a DIB; its luminance becomes alpha.
make_gear_icon :: proc() -> windows.HICON { return make_glyph_icon("⚙") }

make_glyph_icon :: proc(glyph: string) -> windows.HICON {
	size := windows.GetSystemMetrics(windows.SM_CXSMICON)
	if size <= 0 { size = 16 }
	bmi := windows.BITMAPINFO{bmiHeader = {
		biSize = size_of(windows.BITMAPINFOHEADER), biWidth = size, biHeight = -size,
		biPlanes = 1, biBitCount = 32, biCompression = windows.BI_RGB}}
	screen := windows.GetDC(nil)
	defer windows.ReleaseDC(nil, screen)
	dc := windows.CreateCompatibleDC(screen)
	if dc == nil { return nil }
	defer windows.DeleteDC(dc)
	bits: rawptr
	color := windows.CreateDIBSection(dc, &bmi, windows.DIB_RGB_COLORS, &bits, nil, 0)
	if color == nil || bits == nil { return nil }
	defer windows.DeleteObject(windows.HGDIOBJ(color))
	old_bmp := windows.SelectObject(dc, windows.HGDIOBJ(color))
	defer windows.SelectObject(dc, old_bmp)

	px := ([^]u32)(bits)[:size * size]
	for &p in px { p = 0 }
	font := windows.CreateFontW(-size, 0, 0, 0, 400, 0, 0, 0, windows.DEFAULT_CHARSET,
		0, 0, windows.ANTIALIASED_QUALITY, 0, wtext("Segoe UI Symbol"))
	if font == nil { return nil }
	defer windows.DeleteObject(windows.HGDIOBJ(font))
	old_font := windows.SelectObject(dc, windows.HGDIOBJ(font))
	defer windows.SelectObject(dc, old_font)
	windows.SetBkMode(dc, .TRANSPARENT)
	windows.SetTextColor(dc, windows.COLORREF(0xFFFFFF))
	r := windows.RECT{0, 0, size, size}
	windows.DrawTextW(dc, wtext(glyph), -1, &r, windows.DrawTextFormat.DT_SINGLELINE |
		windows.DrawTextFormat.DT_CENTER | windows.DrawTextFormat.DT_VCENTER | windows.DrawTextFormat.DT_NOPREFIX)

	// Tint with the theme text colour (COLORREF is 0x00BBGGRR) using premultiplied alpha.
	tr, tg, tb := u32(C_TXT) & 0xFF, (u32(C_TXT) >> 8) & 0xFF, (u32(C_TXT) >> 16) & 0xFF
	for &p in px {
		a := max((p >> 16) & 0xFF, max((p >> 8) & 0xFF, p & 0xFF))
		p = (a << 24) | ((tr * a / 255) << 16) | ((tg * a / 255) << 8) | (tb * a / 255)
	}
	mask := windows.CreateBitmap(size, size, 1, 1, nil)
	if mask == nil { return nil }
	defer windows.DeleteObject(windows.HGDIOBJ(mask))
	info := windows.ICONINFO{fIcon = windows.TRUE, hbmMask = mask, hbmColor = color}
	return windows.CreateIconIndirect(&info)
}

settings_close :: proc() {
	if settings_ui.hwnd == nil { return }
	hwnd := settings_ui.hwnd
	settings_ui = {}
	windows.EnableWindow(ui.hwnd, windows.TRUE)
	windows.DestroyWindow(hwnd)
	if settings_gear_icon != nil {
		windows.DestroyIcon(settings_gear_icon)
		settings_gear_icon = nil
	}
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
	was_start, was_periodic := update_policy()
	want_start := windows.SendMessageW(settings_ui.updates_start, windows.BM_GETCHECK, 0, 0) == windows.BST_CHECKED
	want_periodic := windows.SendMessageW(settings_ui.updates_periodic, windows.BM_GETCHECK, 0, 0) == windows.BST_CHECKED
	update_set_policy(want_start, want_periodic) // settings_save_current writes the policy in effect
	if !settings_save_current(global_app.db_path, minutes) {
		update_set_policy(was_start, was_periodic)
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
		settings_save_current(global_app.db_path, minutes)
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
			fill_frame(dc, 164, 262, 370, 108, C_BORDER)
			fill_rect(dc, 172, 254, 70, 18, C_BG)
			draw_string(dc, "Updates", 176, 256, ui.font_normal, C_TXT)
			draw_string(dc, "Asks GitHub for the latest release; nothing else is sent.", 176, 342, ui.font_normal, C_DIM)
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
		   item.CtlID == SETTINGS_ID_FOLDER_DEFAULT || item.CtlID == SETTINGS_ID_FOLDER_OPEN) {
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
		case SETTINGS_ID_FOLDER_OPEN:
			// The folder in use now, not whatever is typed in the box.
			ShellExecuteW(settings_ui.hwnd, wtext("open"), wtext(datadir_current(global_app)), nil, nil, windows.SW_SHOWNORMAL)
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
	settings_gear_icon = make_gear_icon()
	if settings_gear_icon != nil {
		windows.SendMessageW(settings_ui.hwnd, windows.WM_SETICON, 0, windows.LPARAM(uintptr(settings_gear_icon))) // ICON_SMALL
	}
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
	on_start, periodic := update_policy()
	settings_ui.updates_start = settings_control("BUTTON", "Check for updates on start",
		windows.WS_TABSTOP | windows.BS_AUTOCHECKBOX, 176, 284, 340, 24, SETTINGS_ID_UPDATES_START)
	settings_ui.updates_periodic = settings_control("BUTTON", "Check for updates every 6 hours while running",
		windows.WS_TABSTOP | windows.BS_AUTOCHECKBOX, 176, 312, 340, 24, SETTINGS_ID_UPDATES_PERIODIC)
	if settings_ui.updates_start != nil && on_start {
		windows.SendMessageW(settings_ui.updates_start, windows.BM_SETCHECK, windows.WPARAM(windows.BST_CHECKED), 0)
	}
	if settings_ui.updates_periodic != nil && periodic {
		windows.SendMessageW(settings_ui.updates_periodic, windows.BM_SETCHECK, windows.WPARAM(windows.BST_CHECKED), 0)
	}
	settings_ui.import_manictime = settings_control("BUTTON", "Import data from ManicTime",
		windows.WS_TABSTOP | windows.BS_OWNERDRAW, 176, 44, 220, 28, SETTINGS_ID_IMPORT_MANICTIME)
	settings_ui.folder = settings_control("EDIT", datadir_current(global_app),
		windows.WS_BORDER | windows.WS_TABSTOP | windows.ES_AUTOHSCROLL, 176, 148, 348, 24, SETTINGS_ID_FOLDER)
	settings_ui.folder_browse = settings_control("BUTTON", "Browse…",
		windows.WS_TABSTOP | windows.BS_OWNERDRAW, 176, 180, 96, 28, SETTINGS_ID_FOLDER_BROWSE)
	settings_ui.folder_default = settings_control("BUTTON", "Use default",
		windows.WS_TABSTOP | windows.BS_OWNERDRAW, 280, 180, 110, 28, SETTINGS_ID_FOLDER_DEFAULT)
	settings_ui.folder_open = settings_control("BUTTON", "Open folder",
		windows.WS_TABSTOP | windows.BS_OWNERDRAW, 398, 180, 110, 28, SETTINGS_ID_FOLDER_OPEN)
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
	SetWindowTheme(settings_ui.updates_start, wtext("DarkMode_Explorer") if ui.dark else nil, nil)
	SetWindowTheme(settings_ui.updates_periodic, wtext("DarkMode_Explorer") if ui.dark else nil, nil)
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
