package main

import "core:fmt"
import "core:sys/windows"
import rt "base:runtime"

// Import runs on the UI thread (it shares the tracker's DB connection), so the
// progress window pumps only its own messages: the main window's timer must not
// fire mid-transaction and write through the same connection.

IMPORT_PROGRESS_W :: 380
IMPORT_PROGRESS_H :: 118

Import_Progress_Ui :: struct {
	hwnd:          windows.HWND,
	stage:         Import_Stage,
	done, total:   int,
	cancelled:     bool,
	last_paint_ms: i64,
}
import_progress_ui: Import_Progress_Ui

// Reading the .sdf is ~20% of the work, writing to SQLite the rest.
import_progress_fraction :: proc() -> f64 {
	p := import_progress_ui
	f := 0.0
	if p.total > 0 { f = min(1.0, f64(p.done) / f64(p.total)) }
	return f * 0.2 if p.stage == .Reading else 0.2 + f * 0.8
}

import_progress_proc :: proc "std" (hwnd: windows.HWND, msg: u32, wp: windows.WPARAM, lp: windows.LPARAM) -> windows.LRESULT {
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
		windows.SetBkMode(dc, windows.BKMODE.TRANSPARENT)
		p := import_progress_ui
		title := "Reading ManicTime database…" if p.stage == .Reading else "Writing activities…"
		if p.cancelled { title = "Cancelling…" }
		margin, bar_y, bar_h := dpi_px(16), dpi_px(40), dpi_px(18)
		draw_string(dc, title, margin, dpi_px(14), ui.font_normal, C_TXT)
		f := import_progress_fraction()
		bar_w := w - 2 * margin
		fill_rect(dc, margin, bar_y, bar_w, bar_h, C_PANEL)
		fill_frame(dc, margin, bar_y, bar_w, bar_h, C_BORDER)
		fill_rect(dc, margin + 1, bar_y + 1, i32(f * f64(bar_w - 2)), bar_h - 2, C_ACCENT)
		percent := fmt.tprintf("%d%%", int(f * 100))
		draw_string(dc, percent, margin, dpi_px(64), ui.font_normal, C_DIM)
		if p.total > 0 {
			x := margin + text_pixel_width(percent, ui.font_normal) + dpi_px(14)
			draw_string(dc, fmt.tprintf("%d of %d activities", min(p.done, p.total), p.total), x, dpi_px(64), ui.font_normal, C_DIM)
		}
		windows.EndPaint(hwnd, &ps)
		return 0
	case windows.WM_DRAWITEM:
		item := transmute(^Draw_Item)(lp)
		if item != nil { draw_settings_button(item); return 1 }
		return 0
	case windows.WM_COMMAND:
		if u32(wp) & 0xFFFF == windows.IDCANCEL {
			import_progress_ui.cancelled = true
			windows.InvalidateRect(hwnd, nil, windows.FALSE)
		}
		return 0
	case windows.WM_CLOSE:
		import_progress_ui.cancelled = true
		return 0
	}
	return windows.DefWindowProcW(hwnd, msg, wp, lp)
}

import_progress_open :: proc() -> bool {
	hi := windows.HINSTANCE(windows.GetModuleHandleW(nil))
	wc := windows.WNDCLASSEXW{cbSize = size_of(windows.WNDCLASSEXW), lpfnWndProc = import_progress_proc,
		hInstance = hi, hCursor = system_cursor(IDC_ARROW), lpszClassName = wtext("aika_import_progress")}
	windows.RegisterClassExW(&wc)
	style := u32(windows.WS_CAPTION | windows.WS_SYSMENU | windows.WS_CLIPCHILDREN)
	client_w, client_h := dpi_px(IMPORT_PROGRESS_W), dpi_px(IMPORT_PROGRESS_H)
	r := windows.RECT{0, 0, client_w, client_h}
	windows.AdjustWindowRectExForDpi(&r, style, windows.FALSE, 0, dpi_current())
	parent: windows.RECT
	windows.GetWindowRect(settings_ui.hwnd, &parent)
	width, height := r.right - r.left, r.bottom - r.top
	x := parent.left + (parent.right - parent.left - width) / 2
	y := parent.top + (parent.bottom - parent.top - height) / 2
	import_progress_ui = {}
	hwnd := windows.CreateWindowExW(0, wc.lpszClassName, wtext("Import data from ManicTime"), style,
		x, y, width, height, settings_ui.hwnd, nil, hi, nil)
	if hwnd == nil { return false }
	import_progress_ui.hwnd = hwnd
	windows.CreateWindowExW(0, wtext("BUTTON"), wtext("Cancel"),
		windows.WS_CHILD | windows.WS_VISIBLE | windows.WS_TABSTOP | windows.BS_OWNERDRAW,
		client_w - dpi_px(106), dpi_px(80), dpi_px(90), dpi_px(28), hwnd, windows.HMENU(uintptr(windows.IDCANCEL)), hi, nil)
	dark := windows.BOOL(ui.dark)
	DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, size_of(dark))
	windows.EnableWindow(settings_ui.hwnd, windows.FALSE)
	windows.ShowWindow(hwnd, windows.SW_SHOW)
	windows.UpdateWindow(hwnd)
	return true
}

import_progress_close :: proc() {
	if import_progress_ui.hwnd == nil { return }
	windows.EnableWindow(settings_ui.hwnd, windows.TRUE)
	windows.DestroyWindow(import_progress_ui.hwnd)
	import_progress_ui = {}
	windows.SetForegroundWindow(settings_ui.hwnd)
}

// Import callback: repaint and handle only the progress window's messages.
import_progress_cb :: proc(stage: Import_Stage, done, total: int, data: rawptr) -> bool {
	p := &import_progress_ui
	p.stage, p.done, p.total = stage, done, total
	if now := monotonic_ms(); now - p.last_paint_ms >= 40 {
		p.last_paint_ms = now
		windows.InvalidateRect(p.hwnd, nil, windows.FALSE)
		windows.UpdateWindow(p.hwnd)
		msg: windows.MSG
		for windows.PeekMessageW(&msg, p.hwnd, 0, 0, windows.PM_REMOVE) {
			if !bool(windows.IsDialogMessageW(p.hwnd, &msg)) {
				windows.TranslateMessage(&msg)
				windows.DispatchMessageW(&msg)
			}
		}
	}
	return !p.cancelled
}

// Imports history straight from the local ManicTime database (see sdf.odin).
settings_import_manictime :: proc() {
	owner := settings_ui.hwnd
	caption := wtext("Import data from ManicTime")
	path, found := manictime_sdf_path()
	if !found {
		windows.MessageBoxW(owner, wtext(import_sdf_message(.Not_Found, path)), caption, windows.MB_ICONERROR)
		return
	}
	if windows.MessageBoxW(owner,
		wtext(fmt.tprintf("Import all history from:\n%s\n\nThis can take a while. For the most consistent result, close ManicTime first. Re-importing is safe: existing data is updated, not duplicated.", path)),
		caption, windows.MB_OKCANCEL | windows.MB_ICONQUESTION) != windows.IDOK { return }

	progress := import_progress_cb
	if !import_progress_open() { progress = nil }
	result := import_manictime_sdf(&global_app.db, path, progress)
	import_progress_close()

	if result != .Ok {
		icon: u32 = windows.MB_ICONERROR
		if result == .Cancelled { icon = windows.MB_ICONINFORMATION }
		windows.MessageBoxW(owner, wtext(import_sdf_message(result, path)), caption, icon)
		return
	}
	load_day(global_app)
	windows.InvalidateRect(ui.hwnd, nil, windows.TRUE)
	windows.MessageBoxW(owner, wtext(import_sdf_message(result, path)), caption, windows.MB_ICONINFORMATION)
}
