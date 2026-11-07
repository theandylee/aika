package main

import "core:sys/windows"
import "core:testing"

// Audit #24: central DPI scaling. Design constants are 96-DPI pixels;
// dpi_px is the identity at 96 DPI (so existing layout tests are unchanged)
// and scales proportionally above it.
dpi_scaling_behavior :: proc(t: ^testing.T) {
	old := ui
	defer ui = old

	dpi_set(96)
	testing.expect(t, dpi_current() == 96)
	testing.expect(t, dpi_px(26) == 26)
	testing.expect(t, dpi_px(0) == 0)
	// Rounding to nearest: 1px at 150% -> 2px, 3px drag threshold -> 5px.
	dpi_set(144)
	testing.expect(t, dpi_px(1) == 2)
	testing.expect(t, dpi_px(96) == 144)
	testing.expect(t, dpi_px(26) == 39)
	// 200%: exact doubling.
	dpi_set(192)
	testing.expect(t, dpi_px(26) == 52)
	testing.expect(t, dpi_px(11) == 22)
	// Zero DPI can never happen from Windows; dpi_set guards it to 96.
	dpi_set(0)
	testing.expect(t, dpi_current() == 96)

	// Layout scales with DPI: same client size yields proportional geometry.
	dpi_set(96)
	lay96 := compute_layout(1320, 860)
	dpi_set(192)
	lay192 := compute_layout(1320, 860)
	testing.expect(t, lay192.toolbar_y == 2*lay96.toolbar_y)
	testing.expect(t, lay192.ruler_y == 2*lay96.ruler_y)
	testing.expect(t, lay192.chart_x == 2*lay96.chart_x)
	testing.expect(t, lay192.lane_y == lay96.lane_y*2 || abs(lay192.lane_y - lay96.lane_y*2) <= 2)
	testing.expect(t, lay192.list_top > lay96.list_top)
	testing.expect(t, lay192.sidebar_w == 2*lay96.sidebar_w)

	// Stored pane sizes rescale across a DPI change instead of staying small.
	dpi_set(96)
	ui.pane_lane_h, ui.pane_totals_w = 100, 320
	ui_apply_dpi(192)
	testing.expect(t, ui.pane_lane_h == 200 && ui.pane_totals_w == 640)
	// Defaults (zero) stay zero so they recompute from scaled constants.
	ui.pane_lane_h, ui.pane_totals_w = 0, 0
	ui_apply_dpi(96)
	testing.expect(t, ui.pane_lane_h == 0 && ui.pane_totals_w == 0)

	// ui_apply_dpi rebuilds real GDI fonts; drop them so the test leaks nothing.
	for f in ([5]windows.HFONT{ui.font_normal, ui.font_bold, ui.font_small, ui.font_title, ui.font_icons}) {
		if f != nil {
			windows.DeleteObject(windows.HGDIOBJ(f))
		}
	}
	ui.font_normal, ui.font_bold, ui.font_small, ui.font_title, ui.font_icons = nil, nil, nil, nil, nil

	dpi_set(96)
}
