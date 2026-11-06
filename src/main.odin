package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import rl "vendor:raylib"

TIMELINE_TAGS :: i64(1)
TIMELINE_COMPUTER :: i64(2)
TIMELINE_APPS :: i64(3)
TIMELINE_DOCS :: i64(4)

load_day :: proc(app: ^App) {
	if app.activities != nil {
		free_activities(app.activities)
		app.activities = nil
	}
	app.activities = db_load_activities(&app.db, app.date, app.tracker.current.persisted_id)
	app.loaded_date = app.date
	app.last_load_ms = now_ms()
}

load_ui_font :: proc() -> rl.Font {
	default_font := rl.GetFontDefault()
	path := "C:/Windows/Fonts/segoeui.ttf"
	if !os.exists(path) {
		return default_font
	}
	cpath := strings.clone_to_cstring(path, context.temp_allocator)

	codepoints := make([]rune, 0x500 - 32)
	defer delete(codepoints)
	for cp in 32 ..< 0x500 {
		codepoints[cp - 32] = rune(cp)
	}
	// Load at a larger base size so text drawn at scaled UI sizes stays sharp.
	font := rl.LoadFontEx(cpath, 48, raw_data(codepoints), c.int(len(codepoints)))
	if font.texture.id == 0 {
		return default_font
	}
	rl.SetTextureFilter(font.texture, .BILINEAR)
	return font
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
	tracker_init(&app)
	load_day(&app)

	rl.SetConfigFlags({.WINDOW_RESIZABLE, .MSAA_4X_HINT})
	rl.InitWindow(1320, 860, "aika вЂ” activity timeline")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	app.default_font = rl.GetFontDefault()
	app.font = load_ui_font()

	for !rl.WindowShouldClose() {
		now := now_ms()
		if app.tracker.enabled {
			tracker_tick(&app, now)
		}
		if app.date != app.loaded_date || now - app.last_load_ms >= 10_000 {
			load_day(&app)
		}

		draw_frame(&app)
		free_all(context.temp_allocator)
	}

	tracker_shutdown(&app)
	if app.font.texture.id != 0 && app.font.texture.id != app.default_font.texture.id {
		rl.UnloadFont(app.font)
	}
	free_activities(app.activities)
	db_close(&app.db)
	if len(app.db_path) > 0 {
		delete(app.db_path)
	}
}












