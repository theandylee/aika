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

load_day :: proc(app: ^App) {
	if app.activities != nil {
		free_activities(app.activities)
		app.activities = nil
	}
	app.activities = db_load_activities(&app.db, app.date, app.tracker.current.persisted_id)
	app.loaded_date = app.date
	app.last_load_ms = now_ms()
}

main :: proc() {
	args := os.args
	db_path := "data/aika.db"
	import_path := ""
	quiet := false

	i := 1
	for i < len(args) {
		switch args[i] {
		case "--quiet", "-q":
			quiet = true
		case "--db":
			if i + 1 < len(args) {
				i += 1
				db_path = args[i]
			}
		case "--import":
			if i + 1 < len(args) {
				i += 1
				import_path = args[i]
			}
		case "--help", "-h":
			msg := "aika - a ManicTime-style activity tracker\nusage: aika [--db path] [--import export.json]"
			fmt.println(msg)
			message_box(msg, "aika")
			return
		}
		i += 1
	}

	_ = os.make_directory("data")

	db, ok := db_open(db_path)
	if !ok {
		msg := fmt.tprintf("Failed to open database:\n%s", db_path)
		fmt.eprintln(msg)
		if !quiet { message_box(msg, "aika", 0x10) }
		return
	}

	if import_path != "" {
		ok_import := import_manictime_json(&db, import_path)
		db_close(&db)
		if ok_import {
			msg := fmt.tprintf("Import complete:\n%s", import_path)
			fmt.println(msg)
			if !quiet { message_box(msg, "aika") }
		} else {
			msg := fmt.tprintf("Import failed:\n%s", import_path)
			fmt.eprintln(msg)
			if !quiet { message_box(msg, "aika", 0x10) }
		}
		return
	}

	app := App {
		db = db,
		date = today_date_int(),
		db_path = strings.clone(db_path),
	}
	global_app = &app
	tracker_init(&app)
	load_day(&app)

	ui_bootstrap()
	defer {
		if !task_stop(&app, now_ms()) {
			message_box("Could not save the final task time. The last saved time is preserved.", "aika", 0x10)
		}
		tracker_shutdown(&app)
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
		if !tag_picker_key(&msg) {
			windows.TranslateMessage(&msg)
			windows.DispatchMessageW(&msg)
		}
		free_all(context.temp_allocator)
	}
}
