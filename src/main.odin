package main

import "core:fmt"
import "core:os"
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

main :: proc() {
	args := os.args
	db_path := "data/aika.db"
	import_path := ""
	import_source := ""
	quiet := false

	i := 1
	for i < len(args) {
		switch args[i] {
		case "--quiet", "-q":
			quiet = true
		case "--db":
			if i + 1 >= len(args) || strings.has_prefix(args[i + 1], "--") || args[i + 1] == "" {
				fmt.eprintln("--db requires a path")
				os.exit(2)
			}
			i += 1
			db_path = args[i]
		case "--import":
			if i + 1 >= len(args) || strings.has_prefix(args[i + 1], "--") || args[i + 1] == "" {
				fmt.eprintln("--import requires a path")
				os.exit(2)
			}
			i += 1
			import_path = args[i]
		case "--import-source":
			if i + 1 >= len(args) || strings.has_prefix(args[i + 1], "--") || strings.trim_space(args[i + 1]) == "" {
				fmt.eprintln("--import-source requires a stable source database identifier")
				os.exit(2)
			}
			i += 1
			import_source = args[i]
		case "--help", "-h":
			msg := "aika - a ManicTime-style activity tracker\nusage: aika [--db path] [--import export.json [--import-source database-id]] [--quiet]"
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

	_ = os.make_directory("data")

	db, ok := db_open(db_path)
	if !ok {
		msg := fmt.tprintf("Failed to open database:\n%s", db_path)
		fmt.eprintln(msg)
		if !quiet { message_box(msg, "aika", 0x10) }
		db_close(&db)
		os.exit(1)
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
			if !quiet { message_box(msg, "aika", 0x10) }
			os.exit(1)
		}
		return
	}

	app := App {
		db = db,
		date = today_date_int(),
		db_path = strings.clone(db_path),
	}
	global_app = &app
	// A GUI operation must not sleep for the CLI/import busy timeout. Tracker
	// writes retry on subsequent timer ticks on this same thread.
	sqlite3_busy_timeout(app.db.handle, 0)
	// This date identifies the write-through cache even if the first read fails.
	// load_result still reports that the historical baseline could not be loaded.
	app.loaded_date = app.date
	tracker_init(&app)
	load_day(&app)

	ui_bootstrap()
	defer {
		if !task_stop(&app, now_ms()) {
			message_box("Could not save the final task time. The last saved time is preserved.", "aika", 0x10)
		}
		if !tracker_shutdown(&app) {
			message_box("Tracking writes remain unsaved. Normal Exit should be retried before closing.", "aika", 0x10)
		}
		ui_shutdown()
		free_activities(app.activities)
		db_close(&app.db)
		if len(app.db_path) > 0 {
			delete(app.db_path)
		}
	}

	// Message loop. The 500 ms timer drives the tracker (which samples at
	// 1 Hz internally) and repaints; temp allocations from each message
	// (text conversions, paint structures) are released after dispatch.
	msg: windows.MSG
	for windows.GetMessageW(&msg, nil, 0, 0) > 0 {
		if !settings_key(&msg) && !date_picker_key(&msg) && !tag_picker_key(&msg) {
			windows.TranslateMessage(&msg)
			windows.DispatchMessageW(&msg)
		}
		free_all(context.temp_allocator)
	}
}
