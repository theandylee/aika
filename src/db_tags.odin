package main

import "core:strings"

// Keep business conflicts separate from storage failures: the picker may dismiss
// an overlapping range, but must remain available after a failed write/read.
DB_Tag_Result :: enum { Ok, Overlap, Invalid, Not_Found, Busy, Failed }

DB_Tag_Block :: struct {
	id, group_id: i64,
	color: Argb,
}

db_tag_result :: proc(result: DB_Result) -> DB_Tag_Result {
	switch result {
	case .Ok: return .Ok
	case .Not_Found: return .Not_Found
	case .Busy: return .Busy
	case .Failed: return .Failed
	}
	return .Failed
}

// Owns the transaction. group_id==0 means create/reuse by name; a supplied ID
// must belong to Tags. Return metadata/IDs only after all writes have committed.
db_create_tag_block :: proc(db: ^DB, group_id: i64, name: string, start, end: i64) -> (DB_Tag_Block, DB_Tag_Result) {
	if group_id < 0 || end <= start || (group_id == 0 && strings.trim_space(name) == "") {
		return {}, .Invalid
	}
	if !db_exec(db, "BEGIN IMMEDIATE") { return {}, db_tag_result(db_failure(db)) }
	committed := false
	defer if !committed { db_exec(db, "ROLLBACK") }
	free, checked := db_tag_range_check(db, start, end)
	if checked != .Ok { return {}, db_tag_result(checked) }
	if !free { return {}, .Overlap }
	tag := group_id
	if tag == 0 {
		id, ensured := db_ensure_tag_result(db, name)
		if ensured != .Ok { return {}, db_tag_result(ensured) }
		tag = id
	}
	color, loaded := db_tag_color(db, tag)
	if loaded != .Ok { return {}, db_tag_result(loaded) }
	id, inserted := db_insert_activity(db, TIMELINE_TAGS, name, tag, start, end)
	if inserted != .Ok { return {}, db_tag_result(inserted) }
	if !db_exec(db, "COMMIT") { return {}, db_tag_result(db_failure(db)) }
	committed = true
	return DB_Tag_Block{id = id, group_id = tag, color = color}, .Ok
}

db_start_task :: proc(db: ^DB, group_id: i64, name: string, start: i64) -> (DB_Tag_Block, DB_Tag_Result) {
	if start == 0x7FFF_FFFF_FFFF_FFFF { return {}, .Invalid }
	return db_create_tag_block(db, group_id, name, start, start + 1)
}

db_tag_color :: proc(db: ^DB, id: i64) -> (Argb, DB_Result) {
	stmt, ok := db_prepare(db, `SELECT Color FROM "Group" WHERE GroupId=?1 AND TimelineId=1`)
	if !ok { return 0, db_failure(db) }
	defer sqlite3_finalize(stmt)
	bound := db_result(bind_i64(stmt, 1, id))
	if bound != .Ok { return 0, bound }
	rc := sqlite3_step(stmt)
	if rc == SQLITE_ROW { return Argb(col_i64(stmt, 0)), .Ok }
	if rc == SQLITE_DONE { return 0, .Not_Found }
	return 0, db_result(rc)
}

db_tag_bounds :: proc(db: ^DB, id: i64) -> (start, end: i64, result: DB_Result) {
	stmt, ok := db_prepare(db, `SELECT StartUtcMs, EndUtcMs FROM Activity WHERE ActivityId=?1 AND TimelineId=1`)
	if !ok { return 0, 0, db_failure(db) }
	defer sqlite3_finalize(stmt)
	bound := db_result(bind_i64(stmt, 1, id))
	if bound != .Ok { return 0, 0, bound }
	rc := sqlite3_step(stmt)
	if rc == SQLITE_ROW { return col_i64(stmt, 0), col_i64(stmt, 1), .Ok }
	if rc == SQLITE_DONE { return 0, 0, .Not_Found }
	return 0, 0, db_result(rc)
}

db_task_boundary :: proc(db: ^DB, id, start: i64) -> (boundary: i64, found: bool, result: DB_Result) {
	stmt, ok := db_prepare(db, `SELECT MIN(StartUtcMs) FROM Activity
		WHERE TimelineId=1 AND ActivityId<>?1 AND StartUtcMs>=?2 AND EndUtcMs>StartUtcMs`)
	if !ok { return 0, false, db_failure(db) }
	defer sqlite3_finalize(stmt)
	bound := db_bind_result(bind_i64(stmt, 1, id), bind_i64(stmt, 2, start))
	if bound != .Ok { return 0, false, bound }
	rc := sqlite3_step(stmt)
	if rc != SQLITE_ROW { return 0, false, .Failed if rc == SQLITE_DONE else db_result(rc) }
	if col_is_null(stmt, 0) { return 0, false, .Ok }
	return col_i64(stmt, 0), true, .Ok
}

// Neighbors, ownership validation and resizing share the same writer transaction.
// stopped means the requested end passed a neighbor, matching task_tick's prior
// exact-boundary behavior. No endpoint is returned as acknowledged before COMMIT.
db_extend_task_until_boundary :: proc(db: ^DB, id, expected_start, requested_end: i64) -> (end: i64, stopped: bool, result: DB_Tag_Result) {
	if id <= 0 || requested_end <= expected_start { return 0, false, .Invalid }
	if !db_exec(db, "BEGIN IMMEDIATE") { return 0, false, db_tag_result(db_failure(db)) }
	committed := false
	defer if !committed { db_exec(db, "ROLLBACK") }
	start, saved_end, loaded := db_tag_bounds(db, id)
	if loaded != .Ok { return 0, false, db_tag_result(loaded) }
	if start != expected_start || requested_end < saved_end { return 0, false, .Invalid }
	boundary, has_boundary, checked := db_task_boundary(db, id, start)
	if checked != .Ok { return 0, false, db_tag_result(checked) }
	end = requested_end
	if has_boundary { end = min(end, boundary) }
	if end <= start { return 0, false, .Overlap }
	free, available := db_tag_range_check(db, start, end, id)
	if available != .Ok { return 0, false, db_tag_result(available) }
	if !free { return 0, false, .Overlap }
	written := db_resize_tag_result(db, id, start, end)
	if written != .Ok { return 0, false, db_tag_result(written) }
	if !db_exec(db, "COMMIT") { return 0, false, db_tag_result(db_failure(db)) }
	committed = true
	return end, end < requested_end, .Ok
}
