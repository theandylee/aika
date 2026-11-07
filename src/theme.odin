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
	draw_button(dc, r, "", HIT_THEME)
	old := windows.SelectObject(dc, windows.HGDIOBJ(ui.font_icons))
	defer windows.SelectObject(dc, old)
	windows.SetTextColor(dc, C_TXT)
	flags := windows.DrawTextFormat.DT_SINGLELINE | windows.DrawTextFormat.DT_CENTER |
		windows.DrawTextFormat.DT_VCENTER | windows.DrawTextFormat.DT_NOPREFIX
	// Standard monochrome sun/moon symbols from Windows' symbol font.
	windows.DrawTextW(dc, wtext("☀" if ui.dark else "☾"), -1, &r, flags)
}

draw_theme_tooltip :: proc(dc: windows.HDC, w: i32) {
	if !ui.mouse_valid || ui.pressed_hit != HIT_NONE ||
	   !rect_hit(theme_switch_rect(w), ui.mouse.x, ui.mouse.y) { return }
	label := "Switch to light theme" if ui.dark else "Switch to dark theme"
	width := text_pixel_width(label, ui.font_normal) + 16
	x := w - 8 - width
	fill_rect(dc, x, TAB_H + 4, width, 24, C_TIP_BG)
	fill_frame(dc, x, TAB_H + 4, width, 24, C_TIP_BORDER)
	draw_string(dc, label, x + 8, TAB_H + 10, ui.font_normal, C_TXT)
}

theme_set_palette :: proc(dark: bool) {
	ui.dark = dark
	colors := [?]^windows.COLORREF{&C_BG, &C_PANEL, &C_BORDER, &C_BORDER_SOFT,
		&C_LANE_BG, &C_LANE_GRID, &C_LANE_TXT, &C_TXT, &C_DIM,
		&C_TAB_BG, &C_TAB_ACTIVE, &C_BTN_FACE, &C_BTN_BORDER, &C_BTN_HOVER,
		&C_HEAD_BG, &C_ROW_ALT, &C_TIP_BG, &C_TIP_BORDER}
	light := [?]windows.COLORREF{0xFAF7F5, 0xFFFFFF, 0xC0AF9C, 0xE2D8CD,
		0xF4ECE2, 0xE4D8CB, 0x746658, 0x28221E, 0x908478,
		0xF5EFE8, 0xFFFFFF, 0xFFFFFF, 0xEAB47E, 0xFCE0E4,
		0xF8F4EF, 0xFCF9F6, 0xE1FFFF, 0x8C8278}
	dim := [?]windows.COLORREF{0x201B18, 0x282320, 0x6B594B, 0x4C4036,
		0x302820, 0x40362D, 0xB8A99A, 0xF0E8E0, 0xB8A99A,
		0x201B18, 0x282320, 0x382F28, 0x907050, 0x504030,
		0x342C25, 0x2E2722, 0x382F28, 0x907050}
	for p, i in colors { p^ = dim[i] if dark else light[i] }
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
	DwmSetWindowAttribute(ui.hwnd, 20, &dark, size_of(dark))
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
			windows.SendMessageW(calendar, 0x100A, windows.WPARAM(i), windows.LPARAM(color)) // MCM_SETCOLOR
		}
	}
	if calendar != nil { windows.InvalidateRect(calendar, nil, windows.TRUE) }
}

theme_toggle :: proc() {
	theme_set_palette(!ui.dark)
	theme_apply_native()
	value := "dark" if ui.dark else "light"
	if err := os.write_entire_file(theme_path(), transmute([]u8)value); err != nil {
		message_box("Theme changed, but the preference could not be saved beside the database.", "aika", 0x30)
	}
}

// Tag fills retain their stored colors; choose readable text independently.
bar_text_color :: proc(color: windows.COLORREF) -> windows.COLORREF {
	r, g, b := u32(color) & 255, (u32(color) >> 8) & 255, (u32(color) >> 16) & 255
	return 0x0028221E if r * 299 + g * 587 + b * 114 >= 140000 else 0x00FFFFFF
}
