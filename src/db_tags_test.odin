package main

import "core:testing"

tag_test_expect_times :: proc(t: ^testing.T, db: ^DB, id, start, end: i64) {
	stmt, prepared := db_prepare(db, `SELECT StartLocalDate, StartLocalTime, StartUtcTime, StartUtcMs,
		EndLocalDate, EndLocalTime, EndUtcTime, EndUtcMs FROM Activity WHERE ActivityId=?1`)
	testing.expect(t, prepared)
	if !prepared { return }
	defer sqlite3_finalize(stmt)
	testing.expect(t, bind_i64(stmt, 1, id) == SQLITE_OK && sqlite3_step(stmt) == SQLITE_ROW)
	for ms, i in ([2]i64{start, end}) {
		col := i * 4
		local_text, utc_text := col_text(stmt, col + 1), col_text(stmt, col + 2)
		testing.expect(t, col_i64(stmt, col) == manic_date_from_date_int(date_int_from_unix_ms(ms)))
		testing.expect(t, local_text == format_systemtime(unix_ms_to_local(ms)))
		testing.expect(t, utc_text == format_systemtime(unix_ms_to_utc(ms)) && col_i64(stmt, col + 3) == ms)
		delete(local_text)
		delete(utc_text)
	}
}

@(test)
repository_time_bindings_match_all_activity_sql_layouts :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&db)
	_, midnight := day_bounds_ms(20261106)
	start, end := midnight - 2500, midnight + 1500
	group, _, ensured := db_ensure_group(&db, TIMELINE_APPS, "time-layout", "Editor", "")
	testing.expect(t, ensured == .Ok)
	id, result := db_insert_activity(&db, TIMELINE_APPS, "Title", group, start, end)
	testing.expect(t, result == .Ok)
	tag_test_expect_times(t, &db, id, start, end)
	testing.expect(t, db_update_activity_end(&db, id, end + 1000) == .Ok)
	tag_test_expect_times(t, &db, id, start, end + 1000)
	block, created := db_create_tag_block(&db, 0, "Work", start, end)
	testing.expect(t, created == .Ok)
	testing.expect(t, db_resize_tag(&db, block.id, start - 1000, end + 2000))
	tag_test_expect_times(t, &db, block.id, start - 1000, end + 2000)
	activity := ImportActivity{timelineId = TIMELINE_DOCS, displayName = "Imported", startUtcMs = start, endUtcMs = end}
	imported, written := db_import_write_activity(&db, 0, activity, 0)
	testing.expect(t, written == .Ok)
	tag_test_expect_times(t, &db, imported, start, end)
	activity.startUtcMs -= 1000
	activity.endUtcMs += 3000
	_, written = db_import_write_activity(&db, imported, activity, 0)
	testing.expect(t, written == .Ok)
	tag_test_expect_times(t, &db, imported, activity.startUtcMs, activity.endUtcMs)
	stmt, prepared := db_prepare(&db, "SELECT ?1,?2,?3,?4")
	testing.expect(t, prepared)
	if !prepared { return }
	defer sqlite3_finalize(stmt)
	testing.expect(t, db_bind_time(stmt, start, DB_Time_Columns{1, 2, 3, 99}) == .Failed,
		"A timestamp binding error must be propagated before executing a write")
}

@(test)
repository_tag_operations_report_writer_contention :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	first, second: DB
	// SQLite's named shared in-memory DB allows real independent connections and
	// lock contention without touching a file or depending on a machine temp path.
	uri: cstring = "file:aika-tag-contention?mode=memory&cache=shared"
	flags :: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | 0x40 // SQLITE_OPEN_URI
	rc := sqlite3_open_v2(uri, &first.handle, flags, nil)
	defer db_close(&first)
	testing.expect(t, rc == SQLITE_OK)
	if rc != SQLITE_OK { return }
	testing.expect(t, db_init_schema(&first))
	rc = sqlite3_open_v2(uri, &second.handle, flags, nil)
	defer db_close(&second)
	testing.expect(t, rc == SQLITE_OK)
	if rc != SQLITE_OK { return }
	sqlite3_busy_timeout(second.handle, 0)
	start, _ := day_bounds_ms(20261106)
	live, created := db_start_task(&first, 0, "Work", start)
	testing.expect(t, created == .Ok)
	testing.expect(t, db_exec(&first, "BEGIN IMMEDIATE"))
	block, result := db_create_tag_block(&second, 0, "Blocked", start + 10_000, start + 20_000)
	testing.expect(t, result == .Busy && block.id == 0)
	end, stopped, extended := db_extend_task_until_boundary(&second, live.id, start, start + 1000)
	testing.expect(t, extended == .Busy && end == 0 && !stopped)
	testing.expect(t, db_exec(&first, "ROLLBACK"))
	_, _, extended = db_extend_task_until_boundary(&second, live.id, start, start + 1000)
	testing.expect(t, extended == .Ok)
}

@(test)
repository_tag_creation_validates_and_reuses_identity :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&db)
	start, _ := day_bounds_ms(20261106)
	first, result := db_create_tag_block(&db, 0, "Work", start, start + 1000)
	testing.expect(t, result == .Ok && first.id > 0 && first.group_id > 0 && first.color != 0)
	second: DB_Tag_Block
	second, result = db_create_tag_block(&db, 0, "work", start + 1000, start + 2000)
	testing.expect(t, result == .Ok && second.group_id == first.group_id)
	testing.expect(t, first.id != second.id && first.color == second.color)
	_, result = db_create_tag_block(&db, first.group_id, "Work", start + 500, start + 1500)
	testing.expect(t, result == .Overlap)
	_, result = db_create_tag_block(&db, 0, "Do not create", start + 100, start + 200)
	testing.expect(t, result == .Overlap && import_test_scalar(&db, `SELECT count(*) FROM "Group" WHERE TimelineId=1`) == 1)
	_, result = db_create_tag_block(&db, 0, "", start + 2000, start + 3000)
	testing.expect(t, result == .Invalid)
	_, result = db_create_tag_block(&db, first.group_id, "Work", start + 3000, start + 2000)
	testing.expect(t, result == .Invalid)
	_, result = db_create_tag_block(&db, 999999, "Missing", start + 2000, start + 3000)
	testing.expect(t, result == .Not_Found)
	app_group, _, ensured := db_ensure_group(&db, TIMELINE_APPS, "application", "App", "")
	testing.expect(t, ensured == .Ok)
	_, result = db_create_tag_block(&db, app_group, "Not a tag", start + 2000, start + 3000)
	testing.expect(t, result == .Not_Found && db_count_activities(&db) == 2)
}

@(test)
repository_tag_creation_rolls_back_writes_and_commit_failures :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&db)
	start, _ := day_bounds_ms(20261106)
	for scenario in 0 ..< 3 {
		switch scenario {
		case 0:
			testing.expect(t, db_exec(&db, `CREATE TRIGGER deny_tag BEFORE INSERT ON Activity BEGIN SELECT RAISE(ABORT, 'test failure'); END`))
		case 1:
			testing.expect(t, db_exec(&db, `CREATE TRIGGER deny_tag BEFORE INSERT ON Activity BEGIN SELECT RAISE(IGNORE); END`))
		case 2:
			testing.expect(t, db_exec(&db, `CREATE TABLE TagCommitGuard(ref INTEGER REFERENCES Timeline(TimelineId) DEFERRABLE INITIALLY DEFERRED);
				CREATE TRIGGER deny_tag AFTER INSERT ON Activity BEGIN INSERT INTO TagCommitGuard VALUES(999); END`))
		}
		block, result := db_create_tag_block(&db, 0, "New tag", start, start + 1000)
		testing.expect(t, result == .Failed && block.id == 0 && block.group_id == 0)
		app := App{db = db, date = 20261106, loaded_date = 20261106}
		testing.expect(t, !task_start(&app, 0, "Failed task", start))
		testing.expect(t, app.task.id == 0 && app.task.name == "" && app.activities == nil,
			"Failed creation must not publish task ownership or cached rows")
		testing.expect(t, db_count_activities(&db) == 0 && import_test_scalar(&db, `SELECT count(*) FROM "Group" WHERE TimelineId=1`) == 0)
		testing.expect(t, db_exec(&db, "DROP TRIGGER deny_tag"))
		testing.expect(t, db_exec(&db, "BEGIN IMMEDIATE"), "Failure must leave no repository transaction open")
		testing.expect(t, db_exec(&db, "ROLLBACK"))
	}
	_, result := db_start_task(&db, 0, "Recovered", start)
	testing.expect(t, result == .Ok)
}

@(test)
repository_task_extension_obeys_boundaries_and_ownership :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&db)
	_, midnight := day_bounds_ms(20261106)
	start := midnight - 2000
	_, scheduled := db_create_tag_block(&db, 0, "Scheduled", midnight + 3000, midnight + 9000)
	testing.expect(t, scheduled == .Ok)
	live, result := db_start_task(&db, 0, "Live", start)
	testing.expect(t, result == .Ok)
	end: i64
	stopped: bool
	end, stopped, result = db_extend_task_until_boundary(&db, live.id, start, midnight + 2000)
	testing.expect(t, result == .Ok && !stopped && end == midnight + 2000)
	end, stopped, result = db_extend_task_until_boundary(&db, live.id, start, midnight + 3000)
	testing.expect(t, result == .Ok && !stopped && end == midnight + 3000, "Exact-boundary acknowledgement preserves the current lifecycle contract")
	end, stopped, result = db_extend_task_until_boundary(&db, live.id, start, midnight + 4000)
	testing.expect(t, result == .Ok && stopped && end == midnight + 3000)
	_, _, result = db_extend_task_until_boundary(&db, live.id, start + 1, midnight + 4000)
	testing.expect(t, result == .Invalid, "Stale owners must not rewrite a manually changed start")
	_, _, result = db_extend_task_until_boundary(&db, live.id, start, start)
	testing.expect(t, result == .Invalid)
	_, _, result = db_extend_task_until_boundary(&db, 999999, start, midnight + 4000)
	testing.expect(t, result == .Not_Found)
	app_id, inserted := db_insert_activity(&db, TIMELINE_APPS, "Not a task", live.group_id, start, midnight)
	testing.expect(t, inserted == .Ok)
	_, _, result = db_extend_task_until_boundary(&db, app_id, start, midnight + 4000)
	testing.expect(t, result == .Not_Found)
	_, inserted = db_insert_activity(&db, TIMELINE_TAGS, "Legacy overlap", live.group_id, start - 1000, start + 1000)
	testing.expect(t, inserted == .Ok)
	_, _, result = db_extend_task_until_boundary(&db, live.id, start, midnight + 4000)
	testing.expect(t, result == .Overlap)
	tag_test_expect_times(t, &db, live.id, start, midnight + 3000)
}

@(test)
repository_task_extension_failure_does_not_acknowledge_or_update_cache :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	input: Tracker_Test_Input
	app, ok := tracker_test_app(&input)
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&app.db)
	defer { free_activities(app.activities) }
	defer task_clear(&app.task)
	start := input.now
	app.date = date_int_from_unix_ms(start)
	testing.expect(t, load_day(&app))
	testing.expect(t, task_start(&app, 0, "Work", start))
	id, acknowledged := app.task.id, app.task.end_ms
	for scenario in 0 ..< 3 {
		switch scenario {
		case 0:
			testing.expect(t, db_exec(&app.db, `CREATE TRIGGER deny_extension BEFORE UPDATE ON Activity BEGIN SELECT RAISE(ABORT, 'test failure'); END`))
		case 1:
			testing.expect(t, db_exec(&app.db, `CREATE TRIGGER deny_extension BEFORE UPDATE ON Activity BEGIN SELECT RAISE(IGNORE); END`))
		case 2:
			testing.expect(t, db_exec(&app.db, `CREATE TABLE TaskCommitGuard(ref INTEGER REFERENCES Timeline(TimelineId) DEFERRABLE INITIALLY DEFERRED);
				CREATE TRIGGER deny_extension AFTER UPDATE ON Activity BEGIN INSERT INTO TaskCommitGuard VALUES(999); END`))
		}
		input.now += 1000
		testing.expect(t, !task_tick(&app, input.now))
		testing.expect(t, app.task.id == id && app.task.end_ms == acknowledged)
		testing.expect(t, len(app.activities) == 1 && app.activities[0].end_ms == acknowledged)
		testing.expect(t, import_test_scalar(&app.db, "SELECT EndUtcMs FROM Activity") == acknowledged)
		testing.expect(t, db_exec(&app.db, "DROP TRIGGER deny_extension"))
	}
	input.now += 1000
	testing.expect(t, task_tick(&app, input.now) && app.task.end_ms == input.now)
}

@(test)
repository_tag_storage_errors_are_not_overlap_conflicts :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&db)
	start, _ := day_bounds_ms(20261106)
	testing.expect(t, db_exec(&db, "DROP TABLE Activity"))
	block, result := db_create_tag_block(&db, 0, "Work", start, start + 1000)
	testing.expect(t, result == .Failed && block.id == 0)
	testing.expect(t, db_exec(&db, "BEGIN IMMEDIATE"))
	testing.expect(t, db_exec(&db, "ROLLBACK"))
}
