package main

CLOCK_JUMP_TOLERANCE_MS :: 2000

// Per-tracker overrides for deterministic lifecycle tests. Nil callbacks use
// the production Win32/SQLite implementation; no process-wide test state is used.
// Foreground strings are borrowed for the duration of a sample, as in Win32.
Tracker_IO :: struct {
	data: rawptr,
	now: proc(data: rawptr) -> i64,
	monotonic: proc(data: rawptr) -> i64,
	idle: proc(data: rawptr) -> i64,
	foreground: proc(data: rawptr) -> (WindowInfo, bool),
	insert: proc(data: rawptr, db: ^DB, timeline: i64, title: string, group: i64, start, end: i64) -> (i64, DB_Result),
	update_end: proc(data: rawptr, db: ^DB, id, end: i64) -> DB_Result,
}

monotonic_ms :: proc() -> i64 { return i64(GetTickCount64()) }

tracker_monotonic :: proc(app: ^App) -> i64 {
	io := &app.tracker.io
	if io.monotonic != nil { return io.monotonic(io.data) }
	return monotonic_ms()
}

tracker_now :: proc(app: ^App) -> i64 {
	io := &app.tracker.io
	if io.now != nil { return io.now(io.data) }
	return now_ms()
}

tracker_idle :: proc(app: ^App) -> i64 {
	io := &app.tracker.io
	if io.idle != nil { return io.idle(io.data) }
	return idle_ms()
}

tracker_foreground :: proc(app: ^App) -> (WindowInfo, bool) {
	io := &app.tracker.io
	if io.foreground != nil { return io.foreground(io.data) }
	return get_foreground_window_info()
}

tracker_insert :: proc(app: ^App, timeline: i64, title: string, group: i64, start, end: i64, spell: u64 = 0) -> (i64, DB_Result) {
	io := &app.tracker.io
	id: i64
	result: DB_Result
	if io.insert != nil {
		id, result = io.insert(io.data, &app.db, timeline, title, group, start, end)
	} else {
		id, result = db_insert_activity(&app.db, timeline, title, group, start, end)
	}
	if result == .Ok && timeline == TIMELINE_APPS && (spell == 0 || spell == app.tracker.spell) {
		append(&app.tracker.spell_rows, id)
	}
	return id, result
}

tracker_update_end :: proc(app: ^App, id, end: i64) -> DB_Result {
	io := &app.tracker.io
	if io.update_end != nil {
		return io.update_end(io.data, &app.db, id, end)
	} else {
		return db_update_activity_end(&app.db, id, end)
	}
}
