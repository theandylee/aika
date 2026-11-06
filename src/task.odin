package main

// A task owns one ordinary Tags activity. Persist at 1 Hz; a crash loses at
// most the last second, and graceful exit saves the exact final endpoint.
RunningTask :: struct {
	id, start_ms, end_ms: i64,
	last_wall, last_mono, save_mono: i64,
}

task_start :: proc(app: ^App, group_id: i64, name: string, start: i64) -> bool {
	if app.task.id != 0 { return false }
	if !db_exec(&app.db, "BEGIN IMMEDIATE") { return false }
	if !db_tag_range_free(&app.db, start, start + 1) {
		db_exec(&app.db, "ROLLBACK")
		return false
	}
	tag_id := group_id
	if tag_id == 0 { tag_id = db_ensure_tag(&app.db, name) }
	if tag_id <= 0 {
		db_exec(&app.db, "ROLLBACK")
		return false
	}
	id, result := db_insert_activity(&app.db, TIMELINE_TAGS, name, tag_id, start, start + 1)
	if result != .Ok || !db_exec(&app.db, "COMMIT") {
		db_exec(&app.db, "ROLLBACK")
		return false
	}
	mono := tracker_monotonic(app)
	app.task = RunningTask{id = id, start_ms = start, end_ms = start + 1,
		last_wall = start, last_mono = mono, save_mono = mono}
	return true
}

task_tick :: proc(app: ^App, now: i64, force: bool = false) -> bool {
	task := &app.task
	if task.id == 0 { return true }
	mono := tracker_monotonic(app)
	if abs((now - task.last_wall) - (mono - task.last_mono)) > CLOCK_JUMP_TOLERANCE_MS {
		// A tag cannot be stretched across a wall-clock adjustment safely.
		// Stop at the last acknowledged endpoint; the user can start a new task.
		task^ = RunningTask{}
		return true
	}
	task.last_wall, task.last_mono = now, mono
	if now <= task.end_ms || (!force && mono - task.save_mono < 1000) { return true }
	// Respect future/manual tags, including blocks outside the selected day.
	stmt, ok := db_prepare(&app.db, `SELECT MIN(StartUtcMs) FROM Activity
		WHERE TimelineId = 1 AND ActivityId <> ?1 AND StartUtcMs >= ?2 AND EndUtcMs > StartUtcMs`)
	if !ok { return false }
	bind_i64(stmt, 1, task.id)
	bind_i64(stmt, 2, task.start_ms)
	end := now
	if sqlite3_step(stmt) != SQLITE_ROW {
		sqlite3_finalize(stmt)
		return false
	}
	boundary := col_i64(stmt, 0)
	sqlite3_finalize(stmt)
	if boundary > 0 { end = min(end, boundary) }
	if !db_resize_tag(&app.db, task.id, task.start_ms, end) { return false }
	task.end_ms = end
	task.save_mono = mono
	for &a in app.activities {
		if a.id == task.id { a.end_ms = end }
	}
	if end < now { task^ = RunningTask{} }
	return true
}

task_stop :: proc(app: ^App, now: i64) -> bool {
	if !task_tick(app, now, true) { return false }
	app.task = RunningTask{}
	return true
}
