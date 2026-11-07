package main

import "core:mem"
import "core:strings"
import "core:sys/windows"
import "core:testing"

@(test)
scratch_nested_scopes_preserve_outer_storage :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	outer: Scratch
	context.temp_allocator = scratch_begin(&outer)
	text := strings.clone("outer callback remains live", context.temp_allocator)
	for _ in 0 ..< 1000 {
		inner: Scratch
		allocator := scratch_begin(&inner)
		_ = make([]byte, 48 * 1024, allocator)
		_ = make([]byte, 3, allocator)
		index := make(map[i64]int, allocator)
		index[123] = 456
		testing.expect(t, index[123] == 456)
		scratch_end(&inner)
		testing.expect(t, text == "outer callback remains live")
	}
	scratch_end(&outer)
	testing.expect(t, len(track.allocation_map) == 0)
}

@(test)
db_failed_open_releases_owned_path_and_handle :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	scratch: Scratch
	context.temp_allocator = scratch_begin(&scratch)
	defer scratch_end(&scratch)
	// Not a filesystem path: SQLite rejects the name without touching history.
	db, ok := db_open(":/invalid/aika.db")
	testing.expect(t, !ok && db.handle == nil && db.path == "")
	db_close(&db)
	db_close(&db)
	db, ok = db_open(":memory:", proc(db: ^DB) -> bool { return false })
	testing.expect(t, !ok && db.handle == nil && db.path == "")
	// Scratch is still alive; only the persistent clone must have disappeared.
	scratch_end(&scratch)
	testing.expect(t, len(track.allocation_map) == 0)
}

fail_buffer_dc :: proc "std" (dc: windows.HDC) -> windows.HDC { return nil }
fail_buffer_bitmap :: proc "std" (dc: windows.HDC, w, h: windows.INT) -> windows.HBITMAP { return nil }
fail_buffer_select :: proc "std" (dc: windows.HDC, obj: windows.HGDIOBJ) -> windows.HGDIOBJ { return nil }

@(test)
backbuffer_failures_are_transactional :: proc(t: ^testing.T) {
	dc := windows.GetDC(nil)
	testing.expect(t, dc != nil)
	if dc == nil { return }
	defer windows.ReleaseDC(nil, dc)
	s: UiState
	defer release_backbuffer(&s)
	testing.expect(t, create_backbuffer(&s, dc, 32, 32))
	original := s.mem_bmp
	for io in ([3]Backbuffer_IO{
		{create_dc = fail_buffer_dc}, {create_bitmap = fail_buffer_bitmap}, {select_object = fail_buffer_select},
	}) {
		for _ in 0 ..< 50 {
			testing.expect(t, !create_backbuffer(&s, dc, 64, 64, io))
			testing.expect(t, s.mem_valid && s.mem_bmp == original && s.mem_w == 32)
		}
	}
	testing.expect(t, !create_backbuffer(&s, nil, 64, 64))
	testing.expect(t, create_backbuffer(&s, dc, 64, 64))
	release_backbuffer(&s)
	release_backbuffer(&s)
	testing.expect(t, s.mem_dc == nil && s.mem_bmp == nil && !s.mem_valid)
}

@(test)
tracker_teardown_releases_unacknowledged_metadata :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	tracker: Tracker
	tracker.current.title = strings.clone("current")
	tracker.current.app_name = strings.clone("app")
	tracker.current.exe_path = strings.clone("exe")
	tracker.pending_count = 1
	tracker.pending[0].title = strings.clone("pending")
	tracker.pending[0].group_name = strings.clone("group")
	append(&tracker.spell_rows, 1)
	tracker_release(&tracker)
	tracker_release(&tracker)
	testing.expect(t, len(track.allocation_map) == 0)
}

// Serialized with the other tests of shared native UI state in zoom_behavior.
ui_startup_unwinds_every_stage :: proc(t: ^testing.T) {
	old, old_app := ui, global_app
	defer { ui = old; global_app = old_app }
	app := App{date = today_date_int(), db_path = ":memory:"}
	global_app = &app
	for stage in Ui_Startup_Stage {
		ui = {}
		scratch: Scratch
		context.temp_allocator = scratch_begin(&scratch)
		defer scratch_end(&scratch)
		fail := struct{stage: Ui_Startup_Stage, reached: bool}{stage = stage}
		context.user_ptr = &fail
		ok := ui_bootstrap(proc(stage: Ui_Startup_Stage) -> bool {
			state := cast(^struct{stage: Ui_Startup_Stage, reached: bool})context.user_ptr
			if stage == state.stage { state.reached = true; return false }
			return true
		})
		testing.expect(t, !ok && fail.reached)
		testing.expect(t, ui.hwnd == nil && ui.tray_hwnd == nil && ui.edit == nil && ui.date_picker == nil)
		testing.expect(t, ui.font_normal == nil && ui.font_icons == nil && ui.mem_dc == nil && ui.mem_bmp == nil)
		testing.expect(t, !ui.main_class && !ui.tray_class && !ui.tray_added)
		ui_shutdown() // Repeatable after every partial initialization.
	}
}

ui_visibility_and_cancellation :: proc(t: ^testing.T) {
	old, old_tag := ui, tag_ui
	defer { ui = old; tag_ui = old_tag }
	ui = {}
	lay := compute_layout(1320, 860)
	for tab in ([2]Tab{.Timesheet, .Statistics}) {
		ui.tab = tab
		for y := i32(TAB_H); y < 860; y += 4 {
			for x := i32(0); x < 1320; x += 4 {
				testing.expect(t, hit_test(x, y, 1320, 860) == .None)
			}
		}
		testing.expect(t, !zoom_pointer_down(lay.chart_x + 100, lay.zoom_y + 10, lay))
	}
	for drag in ([4]Zoom_Drag{.Left, .Right, .Overview, .Timeline}) {
		ui.zoom_start, ui.zoom_end = 0.1, 0.8
		zoom_begin(drag, 0.5)
		ui.zoom_start, ui.zoom_end = 0.4, 0.5
		ui_cancel_interaction()
		ui_cancel_interaction()
		testing.expect(t, zoom_drag() == .None && ui.zoom_start == 0.1 && ui.zoom_end == 0.8)
		tag_begin(.New_Range, 0)
		ui_cancel_interaction()
		testing.expect(t, tag_drag() == .None)
		press_begin(.Settings)
		ui_cancel_interaction()
		ui_cancel_interaction()
		testing.expect(t, press_hit() == .None)
	}
	ui.tab = .Day
	ui.zoom_start, ui.zoom_end = 0.1, 0.3
	bar, _, _, _ := zoom_rects(lay)
	x := bar.left + (bar.right - bar.left) * 3 / 4
	testing.expect(t, zoom_pointer_down(x, bar.top + 10, lay))
	centered := ui.zoom_start
	zoom_pointer_move(x, lay)
	testing.expect(t, abs(ui.zoom_start - centered) < 0.000001)
	ui_cancel_interaction()
	testing.expect(t, ui.zoom_start == 0.1 && ui.zoom_end == 0.3)
}
