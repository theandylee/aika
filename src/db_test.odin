package main

import "core:testing"

@(test)
db_results_distinguish_missing_empty_and_failed :: proc(t: ^testing.T) {
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&db)
	last, found := db_last_activity(&db, TIMELINE_APPS)
	testing.expect(t, found == .Not_Found && last.id == 0)
	rows, loaded := db_load_activities(&db, 20261106)
	testing.expect(t, loaded == .Ok && len(rows) == 0)
	free_activities(rows)
	testing.expect(t, db_update_activity_end(&db, 12345, 1000) == .Not_Found)
	tags, tags_loaded := db_load_tags(&db) // before Activity is dropped: tag recency reads it
	testing.expect(t, tags_loaded == .Ok && len(tags) == 0)
	free_tags(tags)
	testing.expect(t, db_exec(&db, "DROP TABLE Activity"))
	rows, loaded = db_load_activities(&db, 20261106)
	testing.expect(t, loaded == .Failed && rows == nil)
	last, found = db_last_activity(&db, TIMELINE_APPS)
	testing.expect(t, found == .Failed && last.id == 0)
	testing.expect(t, db_exec(&db, `DROP TABLE "Group"`))
	tags, tags_loaded = db_load_tags(&db)
	testing.expect(t, tags_loaded == .Failed && tags == nil)
	id, _, ensured := db_ensure_group(&db, TIMELINE_APPS, "key", "name", "")
	testing.expect(t, id == 0 && ensured == .Failed)
	testing.expect(t, db_result(SQLITE_BUSY) == .Busy && db_result(SQLITE_LOCKED) == .Busy)
}

@(test)
db_failed_writes_are_not_acknowledged :: proc(t: ^testing.T) {
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&db)
	start, _ := day_bounds_ms(20261106)
	group := db_ensure_tag(&db, "Test")
	id, inserted := db_insert_activity(&db, TIMELINE_TAGS, "Test", group, start, start + 5000)
	testing.expect(t, inserted == .Ok)
	testing.expect(t, db_exec(&db, `CREATE TRIGGER deny_update BEFORE UPDATE ON Activity BEGIN SELECT RAISE(ABORT, 'test failure'); END`))
	testing.expect(t, db_update_activity_end(&db, id, start + 6000) == .Failed)
	last, result := db_last_activity(&db, TIMELINE_TAGS)
	testing.expect(t, result == .Ok && last.end_ms == start + 5000)
	delete(last.display_name)
	testing.expect(t, db_exec(&db, "DROP TRIGGER deny_update"))
	testing.expect(t, db_exec(&db, `CREATE TRIGGER ignore_update BEFORE UPDATE ON Activity BEGIN SELECT RAISE(IGNORE); END`))
	testing.expect(t, db_update_activity_end(&db, id, start + 6000) == .Not_Found,
		"SQLITE_DONE without an affected row is not success")
	testing.expect(t, db_exec(&db, "DROP TRIGGER ignore_update"))
	testing.expect(t, db_update_activity_end(&db, id, start + 6000) == .Ok)
	testing.expect(t, db_exec(&db, `CREATE TRIGGER deny_insert BEFORE INSERT ON Activity BEGIN SELECT RAISE(ABORT, 'test failure'); END`))
	failed_id, failed := db_insert_activity(&db, TIMELINE_TAGS, "Test", group, start, start + 5000)
	testing.expect(t, failed_id == 0 && failed == .Failed)
	testing.expect(t, db_exec(&db, "DROP TRIGGER deny_insert"))
	testing.expect(t, db_exec(&db, `CREATE TRIGGER ignore_insert BEFORE INSERT ON Activity BEGIN SELECT RAISE(IGNORE); END`))
	failed_id, failed = db_insert_activity(&db, TIMELINE_TAGS, "Test", group, start, start + 5000)
	testing.expect(t, failed_id == 0 && failed == .Failed, "An ignored insert cannot return a previous row's ID")
}

DB_Test_Progress :: struct { steps, fail_after: int }

db_test_progress :: proc "c" (data: rawptr) -> i32 {
	p := (^DB_Test_Progress)(data)
	p.steps += 1
	return 1 if p.fail_after > 0 && p.steps >= p.fail_after else 0
}

@(test)
db_partial_day_read_is_discarded :: proc(t: ^testing.T) {
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&db)
	start, _ := day_bounds_ms(20261106)
	group := db_ensure_tag(&db, "History")
	for i in 0 ..< 20 {
		_, result := db_insert_activity(&db, TIMELINE_TAGS, "History", group, start + i64(i) * 1000, start + i64(i + 1) * 1000)
		testing.expect(t, result == .Ok)
	}
	progress: DB_Test_Progress
	sqlite3_progress_handler(db.handle, 1, db_test_progress, &progress)
	defer sqlite3_progress_handler(db.handle, 0, nil, nil)
	// Calibrate against this SQLite build/query plan: interrupt after at least
	// the first row was available, rather than only testing prepare failures.
	stmt, prepared := db_prepare(&db, LOAD_ACTIVITIES_SQL)
	testing.expect(t, prepared)
	if !prepared { return }
	bind_i64(stmt, 1, manic_date_from_date_int(20261106))
	_, end := day_bounds_ms(20261106)
	bind_i64(stmt, 2, start)
	bind_i64(stmt, 3, end)
	testing.expect(t, sqlite3_step(stmt) == SQLITE_ROW)
	first_row_steps := progress.steps
	sqlite3_finalize(stmt)
	progress = DB_Test_Progress{fail_after = first_row_steps + 1}
	rows, result := db_load_activities(&db, 20261106)
	testing.expect(t, result == .Failed && rows == nil, "Never publish a partial day")
	testing.expect(t, progress.steps > first_row_steps)
	progress.fail_after = 0
	rows, result = db_load_activities(&db, 20261106)
	testing.expect(t, result == .Ok && len(rows) == 20)
	free_activities(rows)
}

@(test)
day_cache_replaced_only_after_successful_read :: proc(t: ^testing.T) {
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	app := App{db = db, date = 20261106}
	defer db_close(&app.db)
	defer free_activities(app.activities)
	start, _ := day_bounds_ms(app.date)
	group := db_ensure_tag(&app.db, "Cached")
	_, inserted := db_insert_activity(&app.db, TIMELINE_TAGS, "Cached", group, start, start + 5000)
	testing.expect(t, inserted == .Ok && load_day(&app))
	old := raw_data(app.activities)
	last_load := app.last_load_ms
	testing.expect(t, db_exec(&app.db, "ALTER TABLE Activity RENAME TO HiddenActivity"))
	app.date = 20261107
	testing.expect(t, !load_day(&app))
	testing.expect(t, raw_data(app.activities) == old && len(app.activities) == 1)
	testing.expect(t, app.activities[0].display_name == "Cached")
	testing.expect(t, app.date == 20261106 && app.loaded_date == 20261106 && app.last_load_ms == last_load)
	testing.expect(t, app.load_result == .Failed && app_storage_status(&app) != "")
	testing.expect(t, db_exec(&app.db, "ALTER TABLE HiddenActivity RENAME TO Activity"))
	app.date = 20261107
	testing.expect(t, load_day(&app))
	testing.expect(t, app.load_result == .Ok && len(app.activities) == 0 && app.loaded_date == 20261107)
	testing.expect(t, app_storage_status(&app) == "")
}
