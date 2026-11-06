package main

// Per-tracker overrides for deterministic lifecycle tests. Nil callbacks use
// the production Win32/SQLite implementation; no process-wide test state is used.
// Foreground strings are borrowed for the duration of a sample, as in Win32.
// Write signatures deliberately match today's repository contract. Explicit
// update results and pending-write ownership are a separate reliability change.
Tracker_IO :: struct {
	data: rawptr,
	now: proc(data: rawptr) -> i64,
	idle: proc(data: rawptr) -> i64,
	foreground: proc(data: rawptr) -> (WindowInfo, bool),
	insert: proc(data: rawptr, db: ^DB, timeline: i64, title: string, group: i64, start, end: i64) -> i64,
	update_end: proc(data: rawptr, db: ^DB, id, end: i64),
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

tracker_insert :: proc(app: ^App, timeline: i64, title: string, group: i64, start, end: i64) -> i64 {
	io := &app.tracker.io
	if io.insert != nil { return io.insert(io.data, &app.db, timeline, title, group, start, end) }
	return db_insert_activity(&app.db, timeline, title, group, start, end)
}

tracker_update_end :: proc(app: ^App, id, end: i64) {
	io := &app.tracker.io
	if io.update_end != nil {
		io.update_end(io.data, &app.db, id, end)
	} else {
		db_update_activity_end(&app.db, id, end)
	}
}
