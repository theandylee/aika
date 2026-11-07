package main

import "core:sys/windows"

// Central DPI policy (audit #24): Per-Monitor V2.
//
// All design constants (TAB_H, LIST_ROW, ...) are expressed in 96-DPI pixels.
// dpi_px converts them to physical pixels for the current monitor. At 96 DPI
// it is the identity, so existing layout tests keep passing.
//
// Keyboard policy (same audit item, minimal native only): Tab cycles the
// native controls (filter EDIT, date picker button, scrollbars, dialogs).
// The custom-painted canvas (tabs, toolbar buttons, zoom bar, lanes, lists)
// stays mouse-only by design; Escape cancels the active interaction.

DPI_BASE :: 96

// Effective DPI for the main window; initialized before fonts are created
// (system DPI) and refreshed once the window exists (window DPI) and on
// WM_DPICHANGED. Tests set it directly.
dpi_set :: proc(dpi: u32) {
	if dpi == 0 {
		ui.dpi = DPI_BASE
		return
	}
	ui.dpi = dpi
}

dpi_current :: proc() -> u32 {
	if ui.dpi == 0 {
		return DPI_BASE
	}
	return ui.dpi
}

// Scale a 96-DPI design pixel to a physical pixel, rounding to nearest.
dpi_px :: proc(base: i32) -> i32 {
	dpi := i32(dpi_current())
	return (base*dpi + DPI_BASE/2) / DPI_BASE
}

dpi_px_u32 :: proc(base: u32) -> u32 {
	dpi := dpi_current()
	if dpi == 0 {
		return base
	}
	return (base*dpi + DPI_BASE/2) / DPI_BASE
}

// System DPI before any window exists; falls back to 96.
dpi_system :: proc() -> u32 {
	d := u32(windows.GetDpiForSystem())
	if d == 0 {
		return DPI_BASE
	}
	return d
}

// Window DPI with system/96 fallbacks (GetDpiForWindow returns 0 on failure).
dpi_for_window :: proc(hwnd: windows.HWND) -> u32 {
	if hwnd == nil {
		return dpi_system()
	}
	d := u32(windows.GetDpiForWindow(hwnd))
	if d == 0 {
		d = dpi_system()
	}
	if d == 0 {
		d = DPI_BASE
	}
	return d
}

// Rescale a stored physical-pixel size across a DPI change.
dpi_rescale :: proc(value: i32, old_dpi, new_dpi: u32) -> i32 {
	if value == 0 || old_dpi == 0 || new_dpi == 0 || old_dpi == new_dpi {
		return value
	}
	return (value*i32(new_dpi) + i32(old_dpi)/2) / i32(old_dpi)
}
