package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:sys/windows"
import "core:strings"

TIMELINE_TAGS :: i64(1)
TIMELINE_COMPUTER :: i64(2)
TIMELINE_APPS :: i64(3)
TIMELINE_DOCS :: i64(4)

// Native window app pointer, read by wnd_proc (single-window app).
global_app: ^App

load_day :: proc(app: ^App) -> bool {
	app.last_load_attempt_ms = monotonic_ms()
	activities, result := db_load_activities(&app.db, app.date)
	app.load_result = result
	if result != .Ok {
		// Keep both the old data and its date, never render cached rows as a
		// different selected day after failed navigation.
		if app.loaded_date != 0 {
			app.date = app.loaded_date
		}
		return false
	}
	free_activities(app.activities)
	app.activities = activities
	app.loaded_date = app.date
	app.last_load_ms = monotonic_ms()
	return true
}

// Set by --hidden: the GUI starts in the system tray instead of showing.
start_hidden := false

// Set by --wait-pid (relaunch after an update): previous process to wait for.
wait_pid: u32

main :: proc() {
	scratch: Scratch
	context.temp_allocator = scratch_begin(&scratch)
	defer scratch_end(&scratch)
	args := os.args
	db_path := fmt.tprintf("%s\\%s", datadir_resolve(), DATA_DB_NAME)
	import_path := ""
	import_source := ""
	import_manictime := false
	manictime_path := ""
	quiet := false

	i := 1
	for i < len(args) {
		switch args[i] {
		case "--quiet", "-q":
			quiet = true
		case "--hidden":
			start_hidden = true
		case "--wait-pid": // set by the updater: wait for the old process to exit first
			if i + 1 >= len(args) { fmt.eprintln("--wait-pid requires a process id"); os.exit(2) }
			i += 1
			pid, pid_ok := strconv.parse_int(args[i])
			if !pid_ok || pid <= 0 { fmt.eprintln("--wait-pid requires a process id"); os.exit(2) }
			wait_pid = u32(pid)
		case "--db":
			if i + 1 >= len(args) || strings.has_prefix(args[i + 1], "--") || args[i + 1] == "" {
				fmt.eprintln("--db requires a path")
				os.exit(2)
			}
			i += 1
			db_path = args[i]
			db_path_overridden = true
		case "--import":
			if i + 1 >= len(args) || strings.has_prefix(args[i + 1], "--") || args[i + 1] == "" {
				fmt.eprintln("--import requires a path")
				os.exit(2)
			}
			i += 1
			import_path = args[i]
		case "--import-manictime":
			import_manictime = true
			if i + 1 < len(args) && !strings.has_prefix(args[i + 1], "--") && args[i + 1] != "" {
				i += 1
				manictime_path = args[i]
			}
		case "--import-source":
			if i + 1 >= len(args) || strings.has_prefix(args[i + 1], "--") || strings.trim_space(args[i + 1]) == "" {
				fmt.eprintln("--import-source requires a stable source database identifier")
				os.exit(2)
			}
			i += 1
			import_source = args[i]
		case "--help", "-h":
			msg := "aika - a ManicTime-style activity tracker\nusage: aika [--db path] [--import export.json [--import-source database-id]] [--import-manictime [ManicTime.sdf]] [--quiet] [--hidden]"
			fmt.println(msg)
			if !quiet { message_box(msg, "aika") }
			return
		case:
			fmt.eprintln("unknown argument:", args[i])
			os.exit(2)
		}
		i += 1
	}
	if import_source != "" && import_path == "" {
		fmt.eprintln("--import-source requires --import")
		os.exit(2)
	}

	// Only the GUI is single-instance; CLI imports may run alongside it.
	if import_manictime && import_path != "" {
		fmt.eprintln("--import and --import-manictime are mutually exclusive")
		os.exit(2)
	}
	if wait_pid != 0 { update_wait_for_pid(wait_pid) }
	if import_path == "" && !import_manictime && !acquire_single_instance() {
		activate_existing_instance()
		return
	}
	if import_path == "" && !import_manictime { update_cleanup_old() }

	// Create the database's own directory (not the cwd's "data"): autostart
	// launches with an unrelated working directory and an absolute --db.
	if dir := filepath.dir(db_path); dir != "" && dir != "." {
		_ = datadir_make(datadir_norm(dir))
	}

	db, ok := db_open(db_path)
	if !ok {
		msg := fmt.tprintf("Failed to open database:\n%s", db_path)
		fmt.eprintln(msg)
		if !quiet { message_box(msg, "aika", windows.MB_ICONERROR) }
		db_close(&db)
		os.exit(1)
	}

	if import_manictime {
		path := manictime_path
		if path == "" {
			found: bool
			path, found = manictime_sdf_path()
			if !found {
				db_close(&db)
				fmt.eprintln(import_sdf_message(.Not_Found, path))
				os.exit(1)
			}
		}
		result := import_manictime_sdf(&db, path)
		db_close(&db)
		msg := import_sdf_message(result, path)
		if result == .Ok {
			fmt.println(msg)
		} else {
			fmt.eprintln(msg)
			os.exit(1)
		}
		return
	}

	if import_path != "" {
		ok_import := import_manictime_json(&db, import_path, import_source)
		db_close(&db)
		if ok_import {
			msg := fmt.tprintf("Import complete:\n%s", import_path)
			fmt.println(msg)
			if !quiet { message_box(msg, "aika") }
		} else {
			msg := fmt.tprintf("Import failed:\n%s", import_path)
			fmt.eprintln(msg)
			if !quiet { message_box(msg, "aika", windows.MB_ICONERROR) }
			os.exit(1)
		}
		return
	}

	if !run_gui(db, db_path) { os.exit(1) }
}

// Takes ownership of db, even when bootstrap fails. Return before os.exit so
// partial-startup cleanup actually runs (os.exit does not execute defers).
run_gui :: proc(db: DB, db_path: string) -> bool {
	app := App {
		db = db,
		date = today_date_int(),
		db_path = strings.clone(db_path),
	}
	global_app = &app
	defer { global_app = nil }
	defer {
		ui_shutdown()
		tracker_release(&app.tracker)
		task_clear(&app.task)
		free_activities(app.activities)
		db_close(&app.db)
		delete(app.db_path)
	}
	// A GUI operation must not sleep for the CLI/import busy timeout. Tracker
	// writes retry on subsequent timer ticks on this same thread.
	sqlite3_busy_timeout(app.db.handle, 0)
	// This date identifies the write-through cache even if the first read fails.
	// load_result still reports that the historical baseline could not be loaded.
	app.loaded_date = app.date
	settings_migrate_legacy(app.db_path) // before anything reads settings or theme
	loaded := settings_load(app.db_path)
	day_shift_hours = loaded.day_shift // day boundaries: before the first date/day load
	app.date = today_date_int()
	app.loaded_date = app.date
	tracker_init(&app)
	update_set_policy(loaded.updates_on_start, loaded.updates_periodic)
	tag_picker_size = {i32(loaded.picker_w), i32(loaded.picker_h)}
	pomodoro_on, pomodoro_minutes = loaded.pomodoro_on, loaded.pomodoro_minutes
	ui.pane_lane_frac, ui.pane_totals_frac = f32(loaded.lane_permille) / 1000, f32(loaded.totals_permille) / 1000
	ui.maximized = loaded.maximized
	load_day(&app)

	app_identity_register() // notification header reads "aika", not "aika.exe"
	if !ui_bootstrap() {
		message_box("Could not initialize the native window. aika will exit.", "aika", windows.MB_ICONERROR)
		tracker_shutdown(&app)
		return false
	}
	defer {
		if !task_stop(&app, now_ms()) {
			message_box("Could not save the final task time. The last saved time is preserved.", "aika", windows.MB_ICONERROR)
		}
		if !tracker_shutdown(&app) {
			message_box("Tracking writes remain unsaved. Normal Exit should be retried before closing.", "aika", windows.MB_ICONERROR)
		}
	}

	// Message loop. The 500 ms timer drives the tracker (which samples at
	// 1 Hz internally) and repaints. Key routing owns scratch too, independently
	// of callback scratch entered by DispatchMessage and native modal loops.
	msg: windows.MSG
	for {
		result := windows.GetMessageW(&msg, nil, 0, 0)
		if result <= 0 { return result == 0 }
		dispatch_app_message(&msg)
	}
}

dispatch_app_message :: proc(msg: ^windows.MSG) {
	scratch: Scratch
	context.temp_allocator = scratch_begin(&scratch)
	defer scratch_end(&scratch)
	if !settings_key(msg) && !date_picker_key(msg) && !tag_picker_key(msg) {
		// Escape in the filter clears it and hands focus back to the main window.
		if msg.message == windows.WM_KEYDOWN && msg.wParam == windows.VK_ESCAPE && ui.edit != nil && msg.hwnd == ui.edit {
			windows.SetWindowTextW(ui.edit, wtext("")) // EN_CHANGE re-reads the filter
			windows.SetFocus(ui.hwnd)
			return
		}
		// "/" jumps to the filter box from anywhere in the main window.
		// Matched on WM_KEYDOWN: IsDialogMessage below would swallow the WM_CHAR.
		if msg.message == windows.WM_KEYDOWN && (msg.wParam == windows.VK_OEM_2 || msg.wParam == windows.VK_DIVIDE) &&
		   windows.GetKeyState(windows.VK_SHIFT) >= 0 && windows.GetKeyState(windows.VK_CONTROL) >= 0 &&
		   windows.GetKeyState(windows.VK_MENU) >= 0 && ui.edit != nil &&
		   (msg.hwnd == ui.hwnd || windows.IsChild(ui.hwnd, msg.hwnd)) &&
		   msg.hwnd != ui.edit && windows.IsWindowVisible(ui.edit) && windows.IsWindowEnabled(ui.edit) {
			windows.SetFocus(ui.edit)
			return
		}
		// Alt+Enter toggles maximize. Alt makes this a WM_SYSKEYDOWN.
		if msg.message == windows.WM_SYSKEYDOWN && msg.wParam == windows.VK_RETURN &&
		   windows.GetKeyState(windows.VK_CONTROL) >= 0 && windows.GetKeyState(windows.VK_SHIFT) >= 0 &&
		   (msg.hwnd == ui.hwnd || windows.IsChild(ui.hwnd, msg.hwnd)) {
			windows.ShowWindow(ui.hwnd, windows.SW_RESTORE if windows.IsZoomed(ui.hwnd) else windows.SW_MAXIMIZE)
			return
		}
		// Ctrl+Enter = the Start/Stop task button (Day view, where the button is shown).
		if msg.message == windows.WM_KEYDOWN && msg.wParam == windows.VK_RETURN &&
		   windows.GetKeyState(windows.VK_CONTROL) < 0 && windows.GetKeyState(windows.VK_SHIFT) >= 0 &&
		   windows.GetKeyState(windows.VK_MENU) >= 0 && ui.tab == .Day &&
		   (msg.hwnd == ui.hwnd || windows.IsChild(ui.hwnd, msg.hwnd)) {
			task_button_activate(global_app)
			windows.InvalidateRect(ui.hwnd, nil, windows.FALSE)
			return
		}
		// Ctrl+, opens Settings from anywhere in the main window (including the filter box).
		if msg.message == windows.WM_KEYDOWN && msg.wParam == windows.VK_OEM_COMMA &&
		   windows.GetKeyState(windows.VK_CONTROL) < 0 && windows.GetKeyState(windows.VK_SHIFT) >= 0 &&
		   windows.GetKeyState(windows.VK_MENU) >= 0 &&
		   (msg.hwnd == ui.hwnd || windows.IsChild(ui.hwnd, msg.hwnd)) {
			settings_open()
			return
		}
		// F12 toggles the light/dark theme from anywhere in the main window.
		if msg.message == windows.WM_KEYDOWN && msg.wParam == windows.VK_F12 &&
		   windows.GetKeyState(windows.VK_CONTROL) >= 0 && windows.GetKeyState(windows.VK_SHIFT) >= 0 &&
		   windows.GetKeyState(windows.VK_MENU) >= 0 &&
		   (msg.hwnd == ui.hwnd || windows.IsChild(ui.hwnd, msg.hwnd)) {
			theme_toggle()
			windows.InvalidateRect(ui.hwnd, nil, windows.FALSE)
			return
		}
		// - / + zoom the Day timeline (main window focused; "+" is Shift+"=" so Shift is allowed).
		if msg.message == windows.WM_KEYDOWN && ui.tab == .Day && msg.hwnd == ui.hwnd && !interaction_active() &&
		   (msg.wParam == windows.VK_OEM_MINUS || msg.wParam == windows.VK_SUBTRACT ||
		    msg.wParam == windows.VK_OEM_PLUS || msg.wParam == windows.VK_ADD) &&
		   windows.GetKeyState(windows.VK_CONTROL) >= 0 && windows.GetKeyState(windows.VK_MENU) >= 0 {
			if msg.wParam == windows.VK_OEM_MINUS || msg.wParam == windows.VK_SUBTRACT {
				zoom_scale(1.5, 0.5)
			} else {
				zoom_scale(1.0 / 1.5, 0.5)
			}
			windows.InvalidateRect(ui.hwnd, nil, windows.FALSE)
			return
		}
		// Q / E / T = previous / next day / today (only with the main window itself
		// focused, so typing in the filter box is unaffected).
		if msg.message == windows.WM_KEYDOWN && (msg.wParam == 'Q' || msg.wParam == 'E' || msg.wParam == 'T') &&
		   msg.hwnd == ui.hwnd && global_app != nil &&
		   windows.GetKeyState(windows.VK_SHIFT) >= 0 && windows.GetKeyState(windows.VK_CONTROL) >= 0 &&
		   windows.GetKeyState(windows.VK_MENU) >= 0 {
			if msg.wParam == 'T' {
				global_app.date = today_date_int()
				load_day(global_app)
				sync_date_picker(global_app)
			} else {
				shift_day(global_app, -1 if msg.wParam == 'Q' else 1)
			}
			windows.InvalidateRect(ui.hwnd, nil, windows.FALSE)
			return
		}
		// Native Tab order for the main window (filter EDIT <-> date picker
		// button <-> scrollbars). Custom canvas controls stay mouse-only.
		if ui.hwnd != nil && bool(windows.IsDialogMessageW(ui.hwnd, msg)) {
			return
		}
		windows.TranslateMessage(msg)
		windows.DispatchMessageW(msg)
	}
}
