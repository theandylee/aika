package main

import "core:fmt"
import "core:strings"
import "core:sys/windows"

// Version shown at the right end of the status bar; clicking it opens the
// GitHub releases page. Set at build time: -define:AIKA_VERSION=1.2.3 (build.bat
// forwards the AIKA_VERSION environment variable; CI derives it from the tag).
AIKA_VERSION :: #config(AIKA_VERSION, "dev")
RELEASES_URL :: "https://github.com/theandylee/aika/releases"

VERSION_PAD :: i32(8) // gap from the window's right edge and around the label

foreign import aika_shell_open "system:shell32.lib"

@(default_calling_convention = "system")
foreign aika_shell_open {
	ShellExecuteW :: proc(hwnd: windows.HWND, op, file, params, dir: windows.LPCWSTR, show: i32) -> windows.HINSTANCE ---
}

version_label :: proc() -> string {
	if AIKA_VERSION == "dev" { return "dev build" }
	return fmt.tprintf("v%s", strings.trim_prefix(AIKA_VERSION, "v"))
}

// Clickable label area at the right end of the status bar (full bar height).
version_rect :: proc(w, h: i32) -> windows.RECT {
	lay := compute_layout(w, h)
	label_w := text_pixel_width(version_label(), ui.font_normal)
	right := w - dpi_px(VERSION_PAD)
	return windows.RECT{right - label_w - dpi_px(VERSION_PAD), lay.status_y, right + dpi_px(VERSION_PAD), lay.status_y + dpi_px(STATUS_H)}
}

// Left edge of everything the status bar's right side occupies (update label + badge).
status_right_limit :: proc(w, h: i32) -> i32 {
	if r := update_rect(w, h); !rect_empty(r) { return r.left }
	return version_rect(w, h).left
}

draw_version :: proc(dc: windows.HDC, w, h: i32) {
	r := version_rect(w, h)
	hovered := ui.mouse_valid && rect_hit(r, ui.mouse.x, ui.mouse.y)
	color: Colorref = C_TXT if hovered else C_DIM
	draw_string(dc, version_label(), r.left + dpi_px(VERSION_PAD), status_text_y(r.top, ui.font_normal), ui.font_normal, color)
}

open_releases_page :: proc() {
	ShellExecuteW(ui.hwnd, wtext("open"), wtext(RELEASES_URL), nil, nil, windows.SW_SHOWNORMAL)
}
