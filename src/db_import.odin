package main

import "core:crypto/sha2"
import "core:encoding/base64"
import "core:fmt"
import "core:strings"

Import_Action :: enum { Added, Updated, Unchanged, Deleted, Conflict }

// All import repository operations run inside the caller's BEGIN IMMEDIATE.
// Existing group metadata wins; source numeric IDs are only lookup keys in
// the import's in-memory group map, never SQLite primary keys.
db_import_group :: proc(db: ^DB, group: ImportGroup) -> (i64, DB_Result) {
	lookup_lease, ok := db_lease(db, .Import_Group_Lookup, `SELECT GroupId FROM "Group" WHERE TimelineId=?1 AND Key=?2`)
	if !ok { return 0, db_failure(db) }
	defer db_release(&lookup_lease)
	lookup := lookup_lease.stmt
	bound := db_bind_result(bind_i64(lookup, 1, group.timelineId), bind_text(lookup, 2, group.key))
	if bound != .Ok { return 0, bound }
	rc := sqlite3_step(lookup)
	if rc == SQLITE_ROW { return col_i64(lookup, 0), .Ok }
	if rc != SQLITE_DONE { return 0, db_result(rc) }
	name := group.displayName
	if name == "" {
		switch group.key {
		case "W4yiNcyXGPLtSeJd09iJhvbDr6EL/BE2HWKJS8johz8=": name = "Active"
		case "jaM0cRC0p2E80XobDIz5aMfg8NBucI9QrcoCdb0ll2o=": name = "Away"
		case "S7sALuDiUUUJfMuqfN8d1nFc/kVH3SgUYCDbTWNju+c=": name = "Session locked"
		case "kw+obQQ1f/3ZFvvhV3kgmhQRNnt+Lr2cgk7gFZdu/LU=": name = "Power off"
		case: name = extract_xml_tag(group.textData, "Name")
		}
	}
	lease, prepared := db_lease(db, .Import_Group_Insert, `INSERT INTO "Group"
		(TimelineId, DisplayName, Color, TextData, Key, UpdatedTimestamp) VALUES (?1,?2,?3,?4,?5,?6)`)
	if !prepared { return 0, db_failure(db) }
	defer db_release(&lease)
	stmt := lease.stmt
	bound = db_bind_result(bind_i64(stmt, 1, group.timelineId), bind_text(stmt, 2, name),
		bind_i64(stmt, 3, i64(u32(group.color))), bind_text(stmt, 4, group.textData),
		bind_text(stmt, 5, group.key), bind_i64(stmt, 6, now_ms() / 1000))
	if bound != .Ok { return 0, bound }
	rc = sqlite3_step(stmt)
	if rc != SQLITE_DONE { return 0, db_result(rc) }
	if sqlite3_changes(db.handle) != 1 { return 0, .Failed }
	return sqlite3_last_insert_rowid(db.handle), .Ok
}

// Deliberately case-sensitive, unlike the lowercase ManicTime group-key hash.
import_hash :: proc(text: string) -> string {
	hash: sha2.Context_256
	sha2.init_256(&hash)
	sha2.update(&hash, transmute([]byte)text)
	digest: [32]byte
	sha2.final(&hash, digest[:])
	encoded, _ := base64.encode(digest[:], allocator = context.temp_allocator)
	return encoded
}

import_source_fingerprint :: proc(activity: ImportActivity, group: i64) -> string {
	// Length prefixes preserve separators, Unicode and embedded NUL bytes.
	return import_hash(fmt.tprintf("%d;%d;%d;%d;%d:%s;%d:%s", activity.timelineId, group,
		activity.startUtcMs, activity.endUtcMs, len(activity.displayName), activity.displayName,
		len(activity.textData), activity.textData))
}

db_import_local_fingerprint :: proc(db: ^DB, id: i64) -> (string, DB_Result) {
	// Row strings/fingerprints live in per-row scratch, not the parsed-data arena.
	context.allocator = context.temp_allocator
	lease, ok := db_lease(db, .Import_Local_Fingerprint, `SELECT TimelineId, DisplayName, GroupId, GroupListId,
		StartLocalDate, StartLocalTime, StartUtcTime, EndLocalDate, EndLocalTime, EndUtcTime,
		StartUtcMs, EndUtcMs, TextData FROM Activity WHERE ActivityId=?1`)
	if !ok { return "", db_failure(db) }
	defer db_release(&lease)
	stmt := lease.stmt
	bound := db_result(bind_i64(stmt, 1, id))
	if bound != .Ok { return "", bound }
	rc := sqlite3_step(stmt)
	if rc == SQLITE_DONE { return "", .Not_Found }
	if rc != SQLITE_ROW { return "", db_result(rc) }
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	for col in 0 ..< 13 {
		kind := sqlite3_column_type(stmt, i32(col))
		text := col_text(stmt, col)
		strings.write_string(&b, fmt.tprintf("%d;%d:%s;", kind, len(text), text))
	}
	return import_hash(strings.to_string(b)), .Ok
}

// id==0 allocates a fresh local ID. A positive id may only come from a checked
// provenance mapping, never directly from ImportActivity.activityId.
db_import_write_activity :: proc(db: ^DB, id: i64, activity: ImportActivity, group: i64) -> (i64, DB_Result) {
	if activity.endUtcMs < activity.startUtcMs { return 0, .Failed }
	sql := `INSERT INTO Activity (TimelineId, DisplayName, GroupId,
		StartLocalDate, StartLocalTime, StartUtcTime, EndLocalDate, EndLocalTime, EndUtcTime,
		StartUtcMs, EndUtcMs, TextData, UpdatedTimestamp)
		VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)`
	slot := Stmt_Slot.Import_Activity_Insert
	if id > 0 {
		slot = .Import_Activity_Update
		sql = `UPDATE Activity SET TimelineId=?1, DisplayName=?2, GroupId=?3,
			StartLocalDate=?4, StartLocalTime=?5, StartUtcTime=?6,
			EndLocalDate=?7, EndLocalTime=?8, EndUtcTime=?9,
			StartUtcMs=?10, EndUtcMs=?11, TextData=?12, UpdatedTimestamp=?13 WHERE ActivityId=?14`
	}
	lease, ok := db_lease(db, slot, sql)
	if !ok { return 0, db_failure(db) }
	defer db_release(&lease)
	stmt := lease.stmt
	group_bound := bind_null(stmt, 3)
	if group > 0 { group_bound = bind_i64(stmt, 3, group) }
	bound := db_bind_result(bind_i64(stmt, 1, activity.timelineId), bind_text(stmt, 2, activity.displayName), group_bound,
		bind_text(stmt, 12, activity.textData), bind_i64(stmt, 13, now_ms() / 1000))
	if bound != .Ok { return 0, bound }
	bound = db_bind_time(stmt, activity.startUtcMs, DB_Time_Columns{4, 5, 6, 10})
	if bound != .Ok { return 0, bound }
	bound = db_bind_time(stmt, activity.endUtcMs, DB_Time_Columns{7, 8, 9, 11})
	if bound != .Ok { return 0, bound }
	if id > 0 {
		bound = db_result(bind_i64(stmt, 14, id))
		if bound != .Ok { return 0, bound }
	}
	rc := sqlite3_step(stmt)
	if rc != SQLITE_DONE { return 0, db_result(rc) }
	if sqlite3_changes(db.handle) != 1 { return 0, .Failed }
	return id if id > 0 else sqlite3_last_insert_rowid(db.handle), .Ok
}

db_import_activity :: proc(db: ^DB, source: string, activity: ImportActivity, group: i64) -> (Import_Action, DB_Result) {
	context.allocator = context.temp_allocator
	lookup_lease, ok := db_lease(db, .Import_Map_Lookup, `SELECT LocalActivityId, SourceTimelineId, SourceStartUtcMs,
		SourceFingerprint, LocalFingerprint FROM ImportActivityMap WHERE SourceId=?1 AND SourceActivityId=?2`)
	if !ok { return .Conflict, db_failure(db) }
	defer db_release(&lookup_lease)
	lookup := lookup_lease.stmt
	bound := db_bind_result(bind_text(lookup, 1, source), bind_i64(lookup, 2, activity.activityId))
	if bound != .Ok { return .Conflict, bound }
	rc := sqlite3_step(lookup)
	id: i64
	source_fingerprint := import_source_fingerprint(activity, group)
	existing := rc == SQLITE_ROW
	if existing {
		// These immutable anchors detect accidental reuse of a source identity
		// after its DB was reset/replaced. Never guess that it is the same row.
		if col_i64(lookup, 1) != activity.timelineId || col_i64(lookup, 2) != activity.startUtcMs {
			fmt.eprintln("import source activity identity changed:", activity.activityId, "(use a new sourceId for a different database)")
			return .Conflict, .Failed
		}
		if col_is_null(lookup, 0) { return .Deleted, .Ok }
		id = col_i64(lookup, 0)
		if col_text(lookup, 3) == source_fingerprint { return .Unchanged, .Ok }
		baseline := col_text(lookup, 4)
		current, result := db_import_local_fingerprint(db, id)
		if result != .Ok { return .Conflict, result }
		if current != baseline {
			fmt.eprintln("import conflicts with locally changed activity:", id, "(source activity", activity.activityId, ")")
			return .Conflict, .Failed
		}
	} else if rc != SQLITE_DONE {
		return .Conflict, db_result(rc)
	}
	local_id, written := db_import_write_activity(db, id, activity, group)
	if written != .Ok { return .Conflict, written }
	local_fingerprint, read := db_import_local_fingerprint(db, local_id)
	if read != .Ok { return .Conflict, read }
	sql := `INSERT INTO ImportActivityMap (SourceId, SourceActivityId, SourceTimelineId, SourceStartUtcMs,
		LocalActivityId, SourceFingerprint, LocalFingerprint) VALUES (?1,?2,?3,?4,?5,?6,?7)`
	slot := Stmt_Slot.Import_Map_Insert
	if existing {
		slot = .Import_Map_Update
		sql = `UPDATE ImportActivityMap SET SourceFingerprint=?6, LocalFingerprint=?7
			WHERE SourceId=?1 AND SourceActivityId=?2 AND SourceTimelineId=?3 AND SourceStartUtcMs=?4 AND LocalActivityId=?5`
	}
	map_lease, prepared := db_lease(db, slot, sql)
	if !prepared { return .Conflict, db_failure(db) }
	defer db_release(&map_lease)
	stmt := map_lease.stmt
	bound = db_bind_result(bind_text(stmt, 1, source), bind_i64(stmt, 2, activity.activityId),
		bind_i64(stmt, 3, activity.timelineId), bind_i64(stmt, 4, activity.startUtcMs), bind_i64(stmt, 5, local_id),
		bind_text(stmt, 6, source_fingerprint), bind_text(stmt, 7, local_fingerprint))
	if bound != .Ok { return .Conflict, bound }
	rc = sqlite3_step(stmt)
	if rc != SQLITE_DONE { return .Conflict, db_result(rc) }
	if sqlite3_changes(db.handle) != 1 { return .Conflict, .Failed }
	return .Updated if existing else .Added, .Ok
}
