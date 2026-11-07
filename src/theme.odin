package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/windows"

// Keep preferences beside the selected database, including isolated test DBs.
theme_path :: proc() -> string {
	return fmt.tprintf("%s.theme", global_app.db_path)
}

theme_switch_rect :: proc(w: i32) -> windows.RECT {
	return windows.RECT{w - 36, 2, w - 8, TAB_H - 2}
}

draw_theme_switch :: proc(dc: windows.HDC, w: i32) {
	r := theme_switch_rect(w)
	draw_button(dc, r, "", .Theme)
	old := windows.SelectObject(dc, windows.HGDIOBJ(ui.font_icons))
	defer windows.SelectObject(dc, old)
	windows.SetTextColor(dc, C_TXT)
	flags := windows.DrawTextFormat.DT_SINGLELINE | windows.DrawTextFormat.DT_CENTER |
		windows.DrawTextFormat.DT_VCENTER | windows.DrawTextFormat.DT_NOPREFIX
	// Standard monochrome sun/moon symbols from Windows' symbol font.
	windows.DrawTextW(dc, wtext("☀" if ui.dark else "☾"), -1, &r, flags)
}

draw_theme_tooltip :: proc(dc: windows.HDC, w: i32) {
	if !ui.mouse_valid || press_hit() != .None ||
	   !rect_hit(theme_switch_rect(w), ui.mouse.x, ui.mouse.y) { return }
	label := "Switch to light theme" if ui.dark else "Switch to dark theme"
	width := text_pixel_width(label, ui.font_normal) + 16
	draw_single_line_tooltip(dc, tab_tooltip_rect(w - 8, width), label)
}

theme_set_palette :: proc(dark: bool) {
	ui.dark = dark
	palette_apply(PALETTE_DARK if dark else PALETTE_LIGHT)
}

theme_load :: proc() {
	data, err := os.read_entire_file(theme_path(), context.temp_allocator)
	theme_set_palette(err == nil && strings.trim_space(string(data)) == "dark")
}

theme_control_colors :: proc(wp: windows.WPARAM) -> windows.LRESULT {
	dc := windows.HDC(wp)
	windows.SetTextColor(dc, C_TXT)
	windows.SetBkColor(dc, C_PANEL)
	windows.SetDCBrushColor(dc, C_PANEL)
	return windows.LRESULT(uintptr(windows.GetStockObject(windows.DC_BRUSH)))
}

theme_apply_native :: proc() {
	dark := windows.BOOL(ui.dark)
	// Supported on Windows 10 20H1+; older systems ignore this attribute.
	DwmSetWindowAttribute(ui.hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, size_of(dark))
	if ui.date_picker != nil {
		theme_date_calendar()
		windows.InvalidateRect(ui.date_picker, nil, windows.TRUE)
	}
	for hwnd in ([3]windows.HWND{ui.edit, ui.list_scroll.hwnd, ui.totals_scroll.hwnd}) {
		if hwnd != nil {
			SetWindowTheme(hwnd, wtext("DarkMode_Explorer") if ui.dark else nil, nil)
			windows.InvalidateRect(hwnd, nil, windows.TRUE)
		}
	}
	windows.InvalidateRect(ui.hwnd, nil, windows.TRUE)
}

// The custom date button opens a native month calendar with palette colors.
theme_date_calendar :: proc() {
	// utf8_to_wstring("") returns nil, which RESETS styling instead of disabling
	// it. Pass an actual non-null, NUL-terminated empty string to UxTheme.
	empty: [1]u16
	no_theme := cstring16(&empty[0])
	calendar := ui.date_calendar
	if calendar != nil {
		SetWindowTheme(calendar, no_theme if ui.dark else nil, no_theme if ui.dark else nil)
	}
	// MCSC_BACKGROUND, TEXT, TITLEBK, TITLETEXT, MONTHBK, TRAILINGTEXT.
	for color, i in ([6]windows.COLORREF{C_BG, C_TXT, C_HEAD_BG, C_TXT, C_PANEL, C_DIM}) {
		if calendar != nil {
			windows.SendMessageW(calendar, MCM_SETCOLOR, windows.WPARAM(i), windows.LPARAM(color))
		}
	}
	if calendar != nil { windows.InvalidateRect(calendar, nil, windows.TRUE) }
}

theme_toggle :: proc() {
	theme_set_palette(!ui.dark)
	theme_apply_native()
	value := "dark" if ui.dark else "light"
	if err := os.write_entire_file(theme_path(), transmute([]u8)value); err != nil {
		message_box("Theme changed, but the preference could not be saved beside the database.", "aika", windows.MB_ICONWARNING)
	}
}
