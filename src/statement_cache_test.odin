package main

import "core:fmt"
import "core:testing"

// Audit #17: the fixed-slot statement cache (db_lease/db_release).

stmt_test_live_count :: proc(db: ^DB) -> int {
	n := 0
	for s := sqlite3_next_stmt(db.handle, nil); s != nil; s = sqlite3_next_stmt(db.handle, s) { n += 1 }
	return n
}

stmt_test_cached_count :: proc(db: ^DB) -> int {
	n := 0
	for s in db.cache.stmts { if s != nil { n += 1 } }
	return n
}

// No cached statement may be left mid-step (it would hold a read lock).
stmt_test_none_stepping :: proc(db: ^DB) -> bool {
	for s, slot in db.cache.stmts {
		if s != nil && (sqlite3_stmt_busy(s) != 0 || db.cache.busy[slot]) { return false }
	}
	return true
}

stmt_test_path :: proc(name: string) -> string {
	path := fmt.aprintf("%s\\aika-stmtcache-%s.db", test_temp_dir(), name)
	stmt_bench_remove(path)
	return path
}

stmt_test_text :: proc(db: ^DB, sql: string) -> string {
	context.allocator = context.temp_allocator
	stmt, ok := db_prepare(db, sql)
	if !ok { return "" }
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW { return "" }
	return col_text(stmt, 0)
}

@(test)
statement_cache_rebinds_every_parameter :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&db)
	start, _ := day_bounds_ms(20261106)
	ids: [3]i64
	for name, i in ([3]string{"first", "second", "third"}) {
		result: DB_Result
		ids[i], result = db_insert_activity(&db, TIMELINE_APPS, name, i64(i + 1), start + i64(i) * 10_000, start + i64(i) * 10_000 + 5000)
		testing.expect(t, result == .Ok && ids[i] > 0)
	}
	testing.expect(t, db.cache.prepares == 1 && db.cache.reuses == 2, "One prepare, then reuse")
	for id, i in ids {
		testing.expect(t, db_update_activity_end(&db, id, start + i64(i) * 10_000 + 9000 + i64(i) * 1000) == .Ok)
	}
	for id, i in ids {
		end := start + i64(i) * 10_000 + 9000 + i64(i) * 1000
		testing.expect(t, import_test_scalar(&db, fmt.tprintf("SELECT EndUtcMs FROM Activity WHERE ActivityId=%d", id)) == end)
		testing.expect(t, import_test_scalar(&db, fmt.tprintf("SELECT GroupId FROM Activity WHERE ActivityId=%d", id)) == i64(i + 1))
	}
	testing.expect(t, stmt_test_text(&db, "SELECT group_concat(DisplayName) FROM (SELECT DisplayName FROM Activity ORDER BY ActivityId)") == "first,second,third")
	// NULL vs value rebinding on the import writer (GroupId bound NULL only when 0).
	activity := ImportActivity{timelineId = TIMELINE_DOCS, displayName = "A", startUtcMs = start, endUtcMs = start + 1000}
	for group in ([4]i64{0, 7, 0, 9}) {
		id, written := db_import_write_activity(&db, 0, activity, group)
		testing.expect(t, written == .Ok)
		stmt, prepared := db_prepare(&db, "SELECT GroupId FROM Activity WHERE ActivityId=?1")
		testing.expect(t, prepared)
		bind_i64(stmt, 1, id)
		testing.expect(t, sqlite3_step(stmt) == SQLITE_ROW)
		testing.expect(t, col_is_null(stmt, 0) == (group == 0))
		if group != 0 { testing.expect(t, col_i64(stmt, 0) == group) }
		sqlite3_finalize(stmt)
	}
	testing.expect(t, stmt_test_none_stepping(&db))
}

@(test)
statement_cache_survives_early_returns_and_step_errors :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&db)
	start, _ := day_bounds_ms(20261106)
	id, result := db_insert_activity(&db, TIMELINE_APPS, "ok", 1, start, start + 5000)
	testing.expect(t, result == .Ok)
	// Early returns happen before a lease is taken.
	_, result = db_insert_activity(&db, TIMELINE_APPS, "bad", 1, start + 10, start)
	testing.expect(t, result == .Failed)
	testing.expect(t, db_update_activity_end(&db, 0, start) == .Not_Found)
	// Zero rows changed (end before start) is reported, then the slot is reusable.
	testing.expect(t, db_update_activity_end(&db, id, start - 1) == .Not_Found)
	testing.expect(t, db_update_activity_end(&db, id, start + 8000) == .Ok)
	testing.expect(t, stmt_test_none_stepping(&db))
	// A step error: the cached INSERT aborts, maps to Failed, and then works again.
	testing.expect(t, db_exec(&db, `CREATE TRIGGER deny BEFORE INSERT ON Activity BEGIN SELECT RAISE(ABORT, 'test'); END`))
	_, result = db_insert_activity(&db, TIMELINE_APPS, "denied", 1, start, start + 1000)
	testing.expect(t, result == .Failed)
	testing.expect(t, stmt_test_none_stepping(&db))
	testing.expect(t, db_exec(&db, "DROP TRIGGER deny"))
	_, result = db_insert_activity(&db, TIMELINE_APPS, "after", 2, start + 20_000, start + 21_000)
	testing.expect(t, result == .Ok)
	testing.expect(t, db_count_activities(&db) == 2)
	testing.expect(t, stmt_test_text(&db, "SELECT DisplayName FROM Activity ORDER BY ActivityId DESC LIMIT 1") == "after")
}

@(test)
statement_cache_maps_busy_and_recovers :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := stmt_test_path("busy")
	defer { delete(path); stmt_bench_remove(path) }
	a, ok := db_open(path)
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&a)
	sqlite3_busy_timeout(a.handle, 0)
	b := DB{}
	path_c := fmt.ctprintf("%s", path)
	testing.expect(t, sqlite3_open_v2(path_c, &b.handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
	defer db_close(&b)
	start, _ := day_bounds_ms(20261106)
	id, result := db_insert_activity(&a, TIMELINE_APPS, "seed", 1, start, start + 1000)
	testing.expect(t, result == .Ok)
	testing.expect(t, db_exec(&b, "BEGIN IMMEDIATE"))
	_, result = db_insert_activity(&a, TIMELINE_APPS, "blocked", 1, start + 5000, start + 6000)
	testing.expect(t, result == .Busy, "Busy from step must map exactly as before")
	testing.expect(t, db_update_activity_end(&a, id, start + 2000) == .Busy)
	testing.expect(t, stmt_test_none_stepping(&a))
	testing.expect(t, db_exec(&b, "ROLLBACK"))
	_, result = db_insert_activity(&a, TIMELINE_APPS, "unblocked", 1, start + 5000, start + 6000)
	testing.expect(t, result == .Ok)
	testing.expect(t, db_update_activity_end(&a, id, start + 2000) == .Ok)
	testing.expect(t, db_count_activities(&a) == 2)
}

@(test)
statement_cache_falls_back_when_reentered :: proc(t: ^testing.T) {
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&db)
	first, ok1 := db_lease(&db, .Update_End, "SELECT ?1")
	testing.expect(t, ok1 && first.cache != nil)
	live := stmt_test_live_count(&db)
	second, ok2 := db_lease(&db, .Update_End, "SELECT ?1")
	testing.expect(t, ok2 && second.cache == nil && second.stmt != first.stmt, "Busy slot must not be shared")
	testing.expect(t, stmt_test_live_count(&db) == live + 1)
	bind_i64(first.stmt, 1, 11)
	bind_i64(second.stmt, 1, 22)
	testing.expect(t, sqlite3_step(first.stmt) == SQLITE_ROW && col_i64(first.stmt, 0) == 11)
	testing.expect(t, sqlite3_step(second.stmt) == SQLITE_ROW && col_i64(second.stmt, 0) == 22)
	db_release(&second)
	testing.expect(t, stmt_test_live_count(&db) == live, "One-off statement is finalized")
	testing.expect(t, db.cache.busy[.Update_End], "Releasing the fallback must not free the real slot")
	db_release(&first)
	db_release(&first)
	testing.expect(t, !db.cache.busy[.Update_End] && stmt_test_none_stepping(&db))
	again, ok3 := db_lease(&db, .Update_End, "SELECT ?1")
	testing.expect(t, ok3 && again.cache != nil && again.stmt == db.cache.stmts[.Update_End])
	testing.expect(t, col_is_null_after_step(again.stmt), "Reused statement must come back with cleared bindings")
	db_release(&again)
}

col_is_null_after_step :: proc(stmt: ^sqlite3_stmt) -> bool {
	return sqlite3_step(stmt) == SQLITE_ROW && col_is_null(stmt, 0)
}

@(test)
statement_cache_survives_rollback_and_import_failure :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&db)
	start, _ := day_bounds_ms(20261106)
	testing.expect(t, db_exec(&db, "BEGIN"))
	_, result := db_insert_activity(&db, TIMELINE_APPS, "rolled back", 1, start, start + 1000)
	testing.expect(t, result == .Ok)
	testing.expect(t, db_exec(&db, "ROLLBACK"))
	testing.expect(t, db_count_activities(&db) == 0 && stmt_test_none_stepping(&db))
	_, result = db_insert_activity(&db, TIMELINE_APPS, "kept", 1, start, start + 1000)
	testing.expect(t, result == .Ok && db_count_activities(&db) == 1)

	imp := stmt_test_import(3, 6, 0)
	testing.expect(t, db_exec(&db, `CREATE TRIGGER deny BEFORE INSERT ON Activity WHEN NEW.DisplayName='Window 3' BEGIN SELECT RAISE(ABORT, 'test'); END`))
	testing.expect(t, !import_test_apply(&db, imp), "Import must fail on the trigger")
	testing.expect(t, db_count_activities(&db) == 1 && import_test_scalar(&db, "SELECT count(*) FROM ImportActivityMap") == 0)
	testing.expect(t, stmt_test_none_stepping(&db))
	testing.expect(t, db_exec(&db, "DROP TRIGGER deny"))
	testing.expect(t, import_test_apply(&db, imp))
	testing.expect(t, db_count_activities(&db) == 7 && import_test_scalar(&db, "SELECT count(*) FROM ImportActivityMap") == 6)
	testing.expect(t, db_exec(&db, "BEGIN IMMEDIATE") && db_exec(&db, "ROLLBACK"), "No statement may hold a lock")
}

@(test)
statement_cache_close_reopen_and_double_close :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := stmt_test_path("reopen")
	defer { delete(path); stmt_bench_remove(path) }
	start, _ := day_bounds_ms(20261106)
	db, ok := db_open(path)
	testing.expect(t, ok)
	if !ok { return }
	_, result := db_insert_activity(&db, TIMELINE_APPS, "one", 1, start, start + 1000)
	testing.expect(t, result == .Ok && stmt_test_cached_count(&db) == 1)
	db_close(&db)
	testing.expect(t, db.handle == nil && db.cache == nil && db.path == "")
	db_close(&db)
	db, ok = db_open(path)
	testing.expect(t, ok && db.cache != nil && stmt_test_cached_count(&db) == 0, "Fresh connection, fresh cache")
	if !ok { return }
	defer db_close(&db)
	_, result = db_insert_activity(&db, TIMELINE_APPS, "two", 1, start + 5000, start + 6000)
	testing.expect(t, result == .Ok && db_count_activities(&db) == 2)
}

@(test)
statement_cache_has_no_leaked_statements :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&db)
	testing.expect(t, stmt_test_live_count(&db) == 0)
	testing.expect(t, import_test_apply(&db, stmt_test_import(5, 40, 0)))
	testing.expect(t, import_test_apply(&db, stmt_test_import(5, 40, 7)))
	cached := stmt_test_cached_count(&db)
	testing.expect(t, cached > 0 && cached <= len(Stmt_Slot))
	testing.expect(t, stmt_test_live_count(&db) == cached, "Only cached slots may be live")
	testing.expect(t, stmt_test_none_stepping(&db))
	db_stmt_cache_flush(&db)
	testing.expect(t, stmt_test_live_count(&db) == 0 && stmt_test_cached_count(&db) == 0)
	// Schema re-run drops slots and later calls re-prepare lazily.
	start, _ := day_bounds_ms(20261106)
	_, result := db_insert_activity(&db, TIMELINE_APPS, "x", 1, start, start + 1000)
	testing.expect(t, result == .Ok && db.cache.stmts[.Insert_Activity] != nil)
	testing.expect(t, db_init_schema(&db))
	testing.expect(t, stmt_test_live_count(&db) == 0 && db.cache.stmts[.Insert_Activity] == nil)
	_, result = db_insert_activity(&db, TIMELINE_APPS, "y", 1, start + 5000, start + 6000)
	testing.expect(t, result == .Ok && db_count_activities(&db) == 42)
}

@(test)
statement_cache_is_safe_across_db_copies :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&db)
	other, ok_other := db_open(":memory:")
	testing.expect(t, ok_other)
	if !ok_other { return }
	defer db_close(&other)
	start, _ := day_bounds_ms(20261106)
	// A copy (App{db = db}) shares the cache: statements and in-use flags agree.
	copy := db
	_, result := db_insert_activity(&copy, TIMELINE_APPS, "via copy", 1, start, start + 1000)
	testing.expect(t, result == .Ok)
	_, result = db_insert_activity(&db, TIMELINE_APPS, "via original", 1, start + 5000, start + 6000)
	testing.expect(t, result == .Ok && db_count_activities(&copy) == 2 && db.cache.prepares == 1 && db.cache.reuses == 1)
	held, held_ok := db_lease(&db, .Update_End, "SELECT ?1")
	testing.expect(t, held_ok)
	dup, dup_ok := db_lease(&copy, .Update_End, "SELECT ?1")
	testing.expect(t, dup_ok && dup.cache == nil && dup.stmt != held.stmt)
	db_release(&dup)
	db_release(&held)
	// A DB value whose cache belongs to another connection never uses it.
	mismatched := DB{handle = other.handle, cache = db.cache}
	prepares, reuses := db.cache.prepares, db.cache.reuses
	_, result = db_insert_activity(&mismatched, TIMELINE_APPS, "other connection", 1, start, start + 1000)
	testing.expect(t, result == .Ok && db_count_activities(&other) == 1 && db_count_activities(&db) == 2)
	testing.expect(t, db.cache.prepares == prepares && db.cache.reuses == reuses)
	// The swap pattern used by focus_cache_test.
	old := db
	db = other
	_, result = db_insert_activity(&db, TIMELINE_APPS, "swapped", 1, start + 9000, start + 9500)
	testing.expect(t, result == .Ok && db_count_activities(&other) == 2)
	other = db
	db = old
	_, result = db_insert_activity(&db, TIMELINE_APPS, "restored", 1, start + 9000, start + 9500)
	testing.expect(t, result == .Ok && db_count_activities(&db) == 3)
	// No cache at all (raw handle) still works with one-off statements.
	raw := DB{}
	testing.expect(t, sqlite3_open_v2(":memory:", &raw.handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
	defer db_close(&raw)
	testing.expect(t, db_init_schema(&raw))
	_, result = db_insert_activity(&raw, TIMELINE_APPS, "raw", 1, start, start + 1000)
	testing.expect(t, result == .Ok && db_count_activities(&raw) == 1 && raw.cache == nil)
}

stmt_test_import :: proc(groups, activities: int, revision: int) -> ImportFile {
	base, _ := day_bounds_ms(20261106)
	imp := ImportFile{source = "ManicTime", sourceId = "stmt-cache"}
	imp.groups = make([]ImportGroup, groups, context.temp_allocator)
	imp.activities = make([]ImportActivity, activities, context.temp_allocator)
	for i in 0 ..< groups {
		imp.groups[i] = ImportGroup{groupId = i64(i + 1), timelineId = TIMELINE_APPS,
			displayName = fmt.tprintf("App %d", i), color = 0xFF000000 + i64(i), key = fmt.tprintf("key-%d", i), textData = "meta"}
	}
	for i in 0 ..< activities {
		a := ImportActivity{activityId = i64(i + 1), timelineId = TIMELINE_APPS, displayName = fmt.tprintf("Window %d", i),
			startUtcMs = base + i64(i) * 10_000, endUtcMs = base + i64(i) * 10_000 + 8000, textData = "text"}
		if i % 4 != 3 { a.groupId = i64(i % groups + 1) } // some rows have no group (NULL)
		if revision > 0 && i % 3 == 0 {
			a.displayName = fmt.tprintf("Window %d rev %d", i, revision)
			a.endUtcMs += i64(revision) * 500
		}
		imp.activities[i] = a
	}
	return imp
}

stmt_test_dump :: proc(db: ^DB) -> string {
	return fmt.tprintf("%s\n--\n%s\n--\n%s",
		stmt_test_text(db, `SELECT group_concat(r, char(10)) FROM (SELECT ActivityId||'|'||TimelineId||'|'||ifnull(DisplayName,'~')||'|'||ifnull(GroupId,'~')||'|'||ifnull(GroupListId,'~')||'|'||
			StartLocalDate||'|'||StartLocalTime||'|'||StartUtcTime||'|'||EndLocalDate||'|'||EndLocalTime||'|'||EndUtcTime||'|'||
			StartUtcMs||'|'||EndUtcMs||'|'||ifnull(TextData,'~') AS r FROM Activity ORDER BY ActivityId)`),
		stmt_test_text(db, `SELECT group_concat(r, char(10)) FROM (SELECT GroupId||'|'||TimelineId||'|'||ifnull(DisplayName,'~')||'|'||Color||'|'||Key||'|'||ifnull(TextData,'~') AS r FROM "Group" ORDER BY GroupId)`),
		stmt_test_text(db, `SELECT group_concat(r, char(10)) FROM (SELECT SourceId||'|'||SourceActivityId||'|'||SourceTimelineId||'|'||SourceStartUtcMs||'|'||
			ifnull(LocalActivityId,'~')||'|'||SourceFingerprint||'|'||LocalFingerprint AS r FROM ImportActivityMap ORDER BY SourceActivityId)`))
}

@(test)
statement_cache_import_matches_one_off_path :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	cached, ok1 := db_open(":memory:")
	plain, ok2 := db_open(":memory:")
	testing.expect(t, ok1 && ok2)
	if !ok1 || !ok2 { return }
	defer db_close(&cached)
	defer db_close(&plain)
	db_set_stmt_cache(&plain, false)
	// Fresh import, unchanged re-import, changed re-import (update paths), repeat.
	for revision in ([5]int{0, 0, 1, 2, 2}) {
		imp := stmt_test_import(7, 60, revision)
		testing.expect(t, import_test_apply(&cached, imp))
		testing.expect(t, import_test_apply(&plain, imp))
		a, b := stmt_test_dump(&cached), stmt_test_dump(&plain)
		testing.expectf(t, len(a) > 100 && a == b, "revision %d: databases differ", revision)
	}
	testing.expect(t, import_test_scalar(&cached, "SELECT count(*) FROM Activity WHERE GroupId IS NULL") == 15)
	testing.expect(t, cached.cache.reuses > 200 && cached.cache.prepares <= len(Stmt_Slot))
	testing.expect(t, plain.cache.prepares == 0 && plain.cache.reuses == 0)
	testing.expect(t, stmt_test_none_stepping(&cached))
}
