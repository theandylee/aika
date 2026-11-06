package main

tracker_owns_row :: proc(app: ^App, id: i64) -> bool {
	for owned in app.tracker.spell_rows {
		if owned == id { return true }
	}
	return false
}

// Pause/Exit can arrive before a timer detects a clock adjustment. In that case
// close at the last observed instant, not across an unobserved clock jump.
tracker_safe_endpoint :: proc(app: ^App) -> i64 {
	t := &app.tracker
	now := tracker_now(app)
	if t.clock_ready && abs((now - t.last_wall_ms) - (tracker_monotonic(app) - t.last_wall_mono)) > CLOCK_JUMP_TOLERANCE_MS {
		return t.last_wall_ms
	}
	return now
}

// The pending queue is chronological. Mutate an unsaved predecessor in place;
// otherwise retain any failed extension as a normal owned queued write.
tracker_merge_short :: proc(app: ^App, end: i64) {
	c := &app.tracker.current
	t := &app.tracker
	for i := t.pending_count - 1; i >= 0; i -= 1 {
		p := &t.pending[i]
		if p.timeline != TIMELINE_APPS { continue }
		if p.end_ms == c.start_ms && p.spell == t.spell {
			p.end_ms = end
			return
		}
		break
	}
	last, result := db_last_activity(&app.db, TIMELINE_APPS)
	if result == .Not_Found { return }
	if result != .Ok {
		// A failed lookup is not proof that there is no predecessor. Retain
		// this short sample under its own identity rather than silently lose it.
		write := Pending_Activity{timeline = TIMELINE_APPS, group = c.group_id,
			title = c.title, start_ms = c.start_ms, end_ms = end}
		result = tracker_write(app, &write)
		if result != .Ok { tracker_queue(app, write, result) }
		return
	}
	defer delete(last.display_name)
	if last.end_ms != c.start_ms || !tracker_owns_row(app, last.id) { return }
	write := Pending_Activity{id = last.id, timeline = TIMELINE_APPS,
		group = last.group_id, title = last.display_name, start_ms = last.start_ms, end_ms = end}
	result = tracker_write(app, &write)
	if result != .Ok { tracker_queue(app, write, result) }
}

// Freeze the transition on failure. Neither live state nor queued IDs are
// acknowledged until COMMIT: a rollback must be retryable without stale row IDs.
tracker_reconcile_idle :: proc(app: ^App) -> bool {
	t := &app.tracker
	if !t.idle_pending { return true }
	t.idle_result = tracker_idle_transaction(app)
	if t.idle_result != .Ok { return false }
	for i in 0 ..< t.pending_count { delete(t.pending[i].title) }
	t.pending = {}
	t.pending_count = 0
	t.pending_result, t.current_result, t.usage_result = .Ok, .Ok, .Ok
	delete(t.spell_rows)
	t.spell_rows = nil
	clear_current(&t.current)
	t.usage_active = true
	t.usage_kind = .Away
	t.usage_start_ms = t.idle_cutoff
	t.usage_last_db_update = t.idle_observed
	t.usage_save_mono = tracker_monotonic(app)
	t.idle_pending = false
	return true
}

tracker_idle_transaction :: proc(app: ^App) -> DB_Result {
	t := &app.tracker
	if !db_exec(&app.db, "BEGIN IMMEDIATE") { return db_failure(&app.db) }
	committed := false
	owned_count := len(t.spell_rows)
	defer if !committed {
		db_exec(&app.db, "ROLLBACK")
		resize(&t.spell_rows, owned_count)
	}
	// Pending endpoints may precede this active spell. Persist them first, using
	// copies so tentative insert IDs never escape a rolled-back transaction.
	for p in t.pending[:t.pending_count] {
		write := p
		result := tracker_write(app, &write)
		if result != .Ok { return result }
	}
	c := &t.current
	if c.active && c.start_ms < t.idle_cutoff {
		write := Pending_Activity{id = c.persisted_id, timeline = TIMELINE_APPS,
			group = c.group_id, title = c.title, start_ms = c.start_ms, end_ms = t.idle_cutoff}
		result := tracker_write(app, &write)
		if result != .Ok { return result }
	}
	result := db_reconcile_idle_apps(&app.db, t.spell_rows[:], t.usage_start_ms, t.idle_cutoff, t.idle_observed)
	if result != .Ok { return result }
	active := Pending_Activity{id = t.usage_id, timeline = TIMELINE_COMPUTER,
		start_ms = t.usage_start_ms, end_ms = t.idle_cutoff,
		title = "Active", usage_kind = .Active}
	result = tracker_write(app, &active)
	if result != .Ok { return result }
	away := Pending_Activity{timeline = TIMELINE_COMPUTER, start_ms = t.idle_cutoff,
		end_ms = t.idle_observed, title = "Away", usage_kind = .Away}
	result = tracker_write(app, &away)
	if result != .Ok { return result }
	if !db_exec(&app.db, "COMMIT") { return db_failure(&app.db) }
	committed = true
	t.usage_id = away.id
	return .Ok
}

// Only the current Active spell is reconciled, not previous sessions or future
// history. Fail on unexpected future-spanning rows rather than destroying their
// tail. All selected rows and all timestamp representations change atomically.
db_reconcile_idle_apps :: proc(db: ^DB, owned_ids: []i64, spell_start, cutoff, observed: i64) -> DB_Result {
	owned := make(map[i64]bool, context.temp_allocator)
	for id in owned_ids { owned[id] = true }
	stmt, ok := db_prepare(db, `SELECT ActivityId, StartUtcMs, EndUtcMs FROM Activity
		WHERE TimelineId=3 AND StartUtcMs>=?1 AND StartUtcMs<?3 AND EndUtcMs>?2`)
	if !ok { return db_failure(db) }
	defer sqlite3_finalize(stmt)
	bound := db_bind_result(bind_i64(stmt, 1, spell_start), bind_i64(stmt, 2, cutoff), bind_i64(stmt, 3, observed))
	if bound != .Ok { return bound }
	ids := make([dynamic]i64, context.temp_allocator)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE { break }
		if rc != SQLITE_ROW { return db_result(rc) }
		if !owned[col_i64(stmt, 0)] { continue }
		if col_i64(stmt, 2) > observed { return .Failed }
		id := col_i64(stmt, 0)
		if col_i64(stmt, 1) >= cutoff { id = -id }
		append(&ids, id)
	}
	for id in ids {
		if id > 0 {
			result := db_update_activity_end(db, id, cutoff)
			if result != .Ok { return result }
		} else {
			del, prepared := db_prepare(db, "DELETE FROM Activity WHERE ActivityId=?1")
			if !prepared { return db_failure(db) }
			result := db_result(bind_i64(del, 1, -id))
			if result == .Ok { result = db_result(sqlite3_step(del)) }
			sqlite3_finalize(del)
			if result != .Ok { return result }
			if sqlite3_changes(db.handle) != 1 { return .Failed }
		}
	}
	return .Ok
}
