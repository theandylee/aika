package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:sys/windows"
import "core:testing"
import "core:time"

// Opt-in (AIKA_VIEW_BENCHMARK=1), no thresholds. Measures one repaint's
// derived-view work separately from the full GDI frame on a synthetic busy day.
// Mutates the global ui state: run alone with ODIN_TEST_THREADS=1.

View_Bench_Phase :: enum { Snapshot, Derived, Derived_Filter, Derived_Tree, Frame, Frame_Filter, Frame_Tree, Frame_Clustered }

view_bench_derived :: proc(app: ^App) -> int {
	snapshot := build_day_snapshot(app, tracker_now(app), tracker_monotonic(app))
	tl := lane_timeline(ui.lane)
	rows := build_rows(snapshot, tl, ui.filter)
	totals := build_totals(snapshot, tl)
	defer free_totals_slice(totals)
	n := len(rows) + len(totals)
	if ui.totals_tree { n += len(totals_tree_rows(totals)) }
	min_ms, max_ms := day_span(snapshot)
	n += int(max_ms > min_ms)
	n += snapshot_bar_hit(snapshot, tl, ui.mouse.x, 8, 1303, snapshot.day_start, snapshot.day_end)
	return n
}

@(test)
view_paint_measurement :: proc(t: ^testing.T) {
	flag := os.get_env("AIKA_VIEW_BENCHMARK", context.allocator)
	defer delete(flag)
	if flag != "1" { return }
	old := ui
	defer ui = old

	data_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&data_arena)
	defer mem.dynamic_arena_destroy(&data_arena)
	data := mem.dynamic_arena_allocator(&data_arena)

	// 900 app switches across 60 groups, 24 hierarchical tags, 2 usage rows.
	app := App{date = today_date_int()}
	app.loaded_date = app.date
	ds, de := day_bounds_ms(app.date)
	rows := make([dynamic]Activity, data)
	apps := [6]string{"Visual Studio Code", "Firefox", "Windows Terminal", "Explorer", "Slack", "Outlook"}
	for i in 0 ..< 900 {
		step := (de - ds) / 900
		g := i % 60
		app_name := fmt.aprintf("%s %d", apps[g % 6], g, allocator = data)
		append(&rows, Activity{id = i64(i + 1), timeline_id = TIMELINE_APPS, group_id = i64(g + 10),
			display_name = fmt.aprintf("src/file_%d.odin - aika - %s", i % 137, app_name, allocator = data),
			group_name = app_name, start_ms = ds + i64(i) * step, end_ms = ds + i64(i + 1) * step,
			start_date = app.date})
	}
	for i in 0 ..< 24 {
		step := (de - ds) / 24
		name := fmt.aprintf("Work/Project %d/Task %d", i % 4, i % 7, allocator = data)
		append(&rows, Activity{id = i64(2000 + i), timeline_id = TIMELINE_TAGS, group_id = i64(100 + i % 12),
			display_name = name, group_name = name, color = 0xFF3080C0,
			start_ms = ds + i64(i) * step, end_ms = ds + i64(i + 1) * step - 1000, start_date = app.date})
	}
	append(&rows, Activity{id = 3000, timeline_id = TIMELINE_COMPUTER, group_id = 1, group_name = "Active",
		start_ms = ds, end_ms = ds + (de - ds) / 2, start_date = app.date})
	append(&rows, Activity{id = 3001, timeline_id = TIMELINE_COMPUTER, group_id = 2, group_name = "Away",
		start_ms = ds + (de - ds) / 2, end_ms = de, start_date = app.date})
	app.activities = rows[:]
	// Same rows, with the 900 app switches packed into 09:00-18:00.
	clustered := make([]Activity, len(rows), data)
	copy(clustered, rows[:])
	for &a, i in clustered[:900] {
		step := i64(9 * 3_600_000 / 900)
		a.start_ms = ds + 9 * 3_600_000 + i64(i) * step
		a.end_ms = a.start_ms + step
	}

	ui = {}
	ui.lane = .Apps
	ui.zoom_start, ui.zoom_end = 0, 1
	ui.mouse = {660, 0}
	ui.mouse_valid = true
	ui.font_normal = ui_make_font(12, 400)
	ui.font_bold = ui_make_font(12, windows.FW_BOLD)
	ui.font_small = ui_make_font(11, 400)
	ui.font_title = ui_make_font(20, windows.FW_BOLD)
	ui.font_icons = ui_make_font(16, 400, "Segoe UI Symbol")
	defer for f in ([5]windows.HFONT{ui.font_normal, ui.font_bold, ui.font_small, ui.font_title, ui.font_icons}) {
		windows.DeleteObject(windows.HGDIOBJ(f))
	}
	ui.totals_expanded = make(map[string]bool)
	defer delete(ui.totals_expanded)
	for key in ([5]string{"0:/Work", "0:/Work/Project 0", "0:/Work/Project 1", "0:/Work/Project 2", "0:/Work/Project 3"}) {
		ui.totals_expanded[key] = true
	}
	W, H :: 1320, 860
	screen := windows.GetDC(nil)
	testing.expect(t, screen != nil)
	if screen == nil { return }
	defer windows.ReleaseDC(nil, screen)
	testing.expect(t, create_backbuffer(&ui, screen, W, H))
	defer release_backbuffer(&ui)
	// Hover a mid-day application bar so the tooltip path is exercised.
	lay := compute_layout(W, H)
	ui.mouse.y = lay.lane_y + 2 * (lay.lane_h + LANE_GAP) + lay.lane_h / 2

	// Primitive costs: 1,000 calls each, median of 21 batches, microseconds per call.
	{
		// Draw_String_Clipped, Tag_Label and Tag_Tiny overflow max_w (ellipsis
		// path); DrawText_Ellipsis is the DrawTextW call they replace.
		Prim :: enum { Fill_1px, Fill_Frame, Measure_Text, Measure_On_DC, Draw_String, Draw_String_Clipped,
			Draw_String_Tag_Label, Draw_String_Tag_Tiny, DrawText_Ellipsis,
			DrawText_Plain, ExtTextOut_Short, ExtTextOut_Long_Clipped, Format_Clock }
		short := windows.utf8_to_utf16("12:00", context.allocator)
		long := windows.utf8_to_utf16("src/file_12.odin - aika - Visual Studio Code 12", context.allocator)
		tag := windows.utf8_to_utf16("Work/Project 1/Task 3", context.allocator)
		defer { delete(short); delete(long); delete(tag) }
		samples: [Prim][21]f64
		dc := ui.mem_dc
		for b in 0 ..< 21 {
			for prim in Prim {
				scratch: Scratch
				context.temp_allocator = scratch_begin(&scratch)
				start := time.tick_now()
				for i in 0 ..< 1000 {
					x := i32(i % 1000)
					switch prim {
					case .Fill_1px: fill_rect(dc, x, 100, 1, 40, C_GREEN)
					case .Fill_Frame: fill_frame(dc, x, 100, 20, 40, C_BORDER)
					case .Measure_Text: _ = text_pixel_width("12:00", ui.font_small)
					case .Draw_String: draw_string(dc, "12:00", x, 100, ui.font_small, C_TXT)
					case .Draw_String_Clipped:
						draw_string(dc, "src/file_12.odin - aika - Visual Studio Code 12", x, 100, ui.font_normal, C_TXT, 120)
					case .Draw_String_Tag_Label:
						draw_string(dc, "Work/Project 1/Task 3", x, 100, ui.font_bold, C_TXT, 60)
					case .Draw_String_Tag_Tiny:
						draw_string(dc, "Work/Project 1/Task 3", x, 100, ui.font_bold, C_TXT, 5)
					case .DrawText_Ellipsis:
						old_font := windows.SelectObject(dc, windows.HGDIOBJ(ui.font_bold))
						r := windows.RECT{x, 98, x + 60, 132}
						windows.DrawTextW(dc, windows.LPCWSTR(raw_data(tag)), i32(len(tag)), &r,
							windows.DrawTextFormat.DT_SINGLELINE | windows.DrawTextFormat.DT_NOPREFIX |
							windows.DrawTextFormat.DT_END_ELLIPSIS)
						windows.SelectObject(dc, old_font)
					case .Format_Clock: _ = fmt_clock_hm(ds + i64(i) * 60_000)
					case .Measure_On_DC: _ = measure_text_dc(dc, "12:00", ui.font_small)
					case .DrawText_Plain:
						old_font := windows.SelectObject(dc, windows.HGDIOBJ(ui.font_small))
						r := windows.RECT{x, 98, x + 200, 132}
						windows.DrawTextW(dc, windows.LPCWSTR(raw_data(short)), i32(len(short)), &r,
							windows.DrawTextFormat.DT_SINGLELINE | windows.DrawTextFormat.DT_NOPREFIX)
						windows.SelectObject(dc, old_font)
					case .ExtTextOut_Short:
						old_font := windows.SelectObject(dc, windows.HGDIOBJ(ui.font_small))
						ExtTextOutW(dc, x, 100, 0, nil, windows.LPCWSTR(raw_data(short)), u32(len(short)), nil)
						windows.SelectObject(dc, old_font)
					case .ExtTextOut_Long_Clipped:
						old_font := windows.SelectObject(dc, windows.HGDIOBJ(ui.font_normal))
						r := windows.RECT{x, 98, x + 120, 132}
						ExtTextOutW(dc, x, 100, 4, &r, windows.LPCWSTR(raw_data(long)), u32(len(long)), nil) // ETO_CLIPPED
						windows.SelectObject(dc, old_font)
					}
				}
				samples[prim][b] = time.duration_microseconds(time.tick_since(start)) / 1000
				scratch_end(&scratch)
			}
		}
		for &s, prim in samples {
			slice.sort(s[:])
			fmt.printf("view primitive %-19v median=%6.2f us/call\n", prim, s[10])
		}
	}

	// Per-component breakdown of one Day frame (default view, no filter/tree).
	{
		Part :: enum { Snapshot, Background, Tabs, Toolbar, Ruler_Lanes, Zoom_Bar, List, Totals, Filter_Status, Tooltip }
		samples: [Part][101]f64
		for i in 0 ..< 101 {
			scratch: Scratch
			context.temp_allocator = scratch_begin(&scratch)
			dc := ui.mem_dc
			tick := time.tick_now()
			mark :: proc(tick: ^time.Tick) -> f64 {
				d := time.duration_microseconds(time.tick_since(tick^))
				tick^ = time.tick_now()
				return d
			}
			snapshot := build_day_snapshot(&app, tracker_now(&app), tracker_monotonic(&app))
			samples[.Snapshot][i] = mark(&tick)
			fill_rect(dc, 0, 0, W, H, C_BG)
			samples[.Background][i] = mark(&tick)
			draw_tabs(dc)
			samples[.Tabs][i] = mark(&tick)
			draw_toolbar(&app, snapshot, dc, lay)
			samples[.Toolbar][i] = mark(&tick)
			vs, ve := zoom_bounds(snapshot.day_start, snapshot.day_end)
			for lane in Lane {
				draw_lane(snapshot, dc, lay, lane, lay.chart_x, lane_top(lay, lane), lay.chart_w, lay.lane_h, vs, ve)
			}
			samples[.Ruler_Lanes][i] = mark(&tick)
			draw_zoom_bar(snapshot, dc, lay, snapshot.day_start, snapshot.day_end)
			samples[.Zoom_Bar][i] = mark(&tick)
			draw_list(snapshot, dc, lay)
			samples[.List][i] = mark(&tick)
			draw_totals(snapshot, dc, lay)
			samples[.Totals][i] = mark(&tick)
			draw_filter_row(dc, W, H)
			draw_status_bar(&app, dc, W, H)
			samples[.Filter_Status][i] = mark(&tick)
			draw_tooltip(snapshot, dc, W, H)
			samples[.Tooltip][i] = mark(&tick)
			scratch_end(&scratch)
		}
		for &s, part in samples {
			slice.sort(s[:])
			fmt.printf("view breakdown %-13v median=%8.1f us\n", part, s[50])
		}
	}

	for phase in View_Bench_Phase {
		ui.filter = "code" if phase == .Derived_Filter || phase == .Frame_Filter else ""
		ui.totals_tree = phase == .Derived_Tree || phase == .Frame_Tree
		ui.lane = .Tags if ui.totals_tree else .Apps
		app.activities = clustered if phase == .Frame_Clustered else rows[:]
		samples: [201]f64
		blocks, out_band: int
		for &sample in samples {
			scratch: Scratch
			context.temp_allocator = scratch_begin(&scratch)
			start := time.tick_now()
			switch phase {
			case .Snapshot:
				s := build_day_snapshot(&app, tracker_now(&app), tracker_monotonic(&app))
				testing.expect(t, len(s.rows) == len(rows))
			case .Derived, .Derived_Filter, .Derived_Tree:
				testing.expect(t, view_bench_derived(&app) > 0)
			case .Frame, .Frame_Filter, .Frame_Tree, .Frame_Clustered:
				draw_frame(&app, ui.mem_dc, W, H)
			}
			sample = time.duration_microseconds(time.tick_since(start))
			// 16 KiB arena blocks (including the current one) plus large out-of-band requests.
			blocks = len(scratch.used_blocks) + 1
			out_band = len(scratch.out_band_allocations)
			scratch_end(&scratch)
		}
		slice.sort(samples[:])
		fmt.printf("view benchmark %-15v median=%8.1f us p95=%8.1f us scratch=%d x 16 KiB blocks + %d large\n",
			phase, samples[100], samples[190], blocks, out_band)
	}
}
