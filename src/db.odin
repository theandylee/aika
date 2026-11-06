package main

import "core:c"
import "core:fmt"
import "core:strings"
import "core:crypto/sha2"
import "core:encoding/base64"

DB :: struct {
	handle: ^sqlite3,
	path:   string,
}

// Empty successful reads are Ok; a missing individual record is Not_Found.
// Busy is retryable contention, while Failed needs attention (and may still
// recover, e.g. after disk space or permissions are restored).
DB_Result :: enum { Ok, Not_Found, Busy, Failed }

db_result :: proc(rc: c.int) -> DB_Result {
	switch rc & 0xFF {
	case SQLITE_OK, SQLITE_DONE, SQLITE_ROW: return .Ok
	case SQLITE_BUSY, SQLITE_LOCKED: return .Busy
	}
	return .Failed
}

db_failure :: proc(db: ^DB) -> DB_Result {
	result := db_result(sqlite3_errcode(db.handle))
	return .Failed if result == .Ok else result
}

SCHEMA_SQL :: `
CREATE TABLE IF NOT EXISTS Timeline (
	TimelineId INTEGER PRIMARY KEY,
	TypeName TEXT NOT NULL,
	DisplayName TEXT,
	DisplayOrder INTEGER NOT NULL DEFAULT 0,
	GenericTypeName TEXT,
	SourceTypeName TEXT,
	SourceAddress TEXT,
	UpdateInterval INTEGER NOT NULL DEFAULT 10,
	TextData TEXT,
	UpdatedTimestamp INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS "Group" (
	GroupId INTEGER PRIMARY KEY AUTOINCREMENT,
	TimelineId INTEGER NOT NULL,
	DisplayName TEXT,
	Color INTEGER NOT NULL DEFAULT 0,
	FolderId INTEGER,
	TextData TEXT,
	Key TEXT NOT NULL,
	DeleteWhenNotUsed INTEGER NOT NULL DEFAULT 1,
	UpdatedTimestamp INTEGER NOT NULL DEFAULT 0,
	SkipColor INTEGER NOT NULL DEFAULT 0,
	UNIQUE(TimelineId, Key)
);

CREATE TABLE IF NOT EXISTS Activity (
	ActivityId INTEGER PRIMARY KEY AUTOINCREMENT,
	TimelineId INTEGER NOT NULL,
	DisplayName TEXT,
	GroupId INTEGER,
	GroupListId INTEGER,
	StartLocalDate INTEGER NOT NULL,
	StartLocalTime TEXT NOT NULL,
	StartUtcTime TEXT NOT NULL,
	EndLocalDate INTEGER NOT NULL,
	EndLocalTime TEXT NOT NULL,
	EndUtcTime TEXT NOT NULL,
	StartUtcMs INTEGER NOT NULL DEFAULT 0,
	EndUtcMs INTEGER NOT NULL DEFAULT 0,
	TextData TEXT,
	UpdatedTimestamp INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS IX_Activity_Timeline_Date ON Activity (TimelineId, StartLocalDate, EndLocalDate);
CREATE INDEX IF NOT EXISTS IX_Activity_Updated ON Activity (UpdatedTimestamp);

CREATE TABLE IF NOT EXISTS Document (
	DocumentId INTEGER PRIMARY KEY AUTOINCREMENT,
	DocumentType TEXT,
	Content TEXT,
	UpdatedTimestamp INTEGER NOT NULL DEFAULT 0,
	Index1 TEXT,
	Index2 TEXT,
	Index3 TEXT
);

CREATE TABLE IF NOT EXISTS Sequence (
	Name TEXT PRIMARY KEY,
	Value INTEGER NOT NULL DEFAULT 0
);

-- aika import provenance, schema version 1. Source IDs never become local IDs.
CREATE TABLE IF NOT EXISTS ImportActivityMap (
	SourceId TEXT NOT NULL CHECK(length(SourceId) > 0),
	SourceActivityId INTEGER NOT NULL CHECK(SourceActivityId > 0),
	SourceTimelineId INTEGER NOT NULL CHECK(SourceTimelineId BETWEEN 1 AND 4),
	SourceStartUtcMs INTEGER NOT NULL CHECK(SourceStartUtcMs > 0),
	LocalActivityId INTEGER UNIQUE REFERENCES Activity(ActivityId) ON DELETE SET NULL,
	SourceFingerprint TEXT NOT NULL,
	LocalFingerprint TEXT NOT NULL,
	PRIMARY KEY (SourceId, SourceActivityId)
);
`

SEED_SQL :: `
INSERT OR IGNORE INTO Timeline (TimelineId, TypeName, DisplayName, DisplayOrder, UpdateInterval) VALUES
	(1, 'ManicTime/Tags', 'Tags', 1, 10),
	(2, 'ManicTime/ComputerUsage', 'Computer usage', 2, 10),
	(3, 'ManicTime/Applications', 'Applications', 3, 10),
	(4, 'ManicTime/Documents', 'Documents', 4, 10);

INSERT OR IGNORE INTO "Group" (TimelineId, DisplayName, Color, TextData, Key, UpdatedTimestamp) VALUES
	(2, 'Active', 4281257073, NULL, 'W4yiNcyXGPLtSeJd09iJhvbDr6EL/BE2HWKJS8johz8=', 0),
	(2, 'Away', 4286611584, NULL, 'jaM0cRC0p2E80XobDIz5aMfg8NBucI9QrcoCdb0ll2o=', 0),
	(2, 'Session locked', 4282663982, NULL, 'S7sALuDiUUUJfMuqfN8d1nFc/kVH3SgUYCDbTWNju+c=', 0),
	(2, 'Power off', 4279308561, NULL, 'kw+obQQ1f/3ZFvvhV3kgmhQRNnt+Lr2cgk7gFZdu/LU=', 0);
`

GROUP_COLORS := []u32 {
	0xFF4E79A7,
	0xFFF28E2B,
	0xFFE15759,
	0xFF76B7B2,
	0xFF59A14F,
	0xFFEDC948,
	0xFFB07AA1,
	0xFFFF9DA7,
	0xFF9C755F,
	0xFFBAB0AC,
	0xFF6A9FB5,
	0xFFA07E4F,
}

db_error :: proc(db: ^DB) -> string {
	return string(sqlite3_errmsg(db.handle))
}

db_exec :: proc(db: ^DB, sql: string) -> bool {
	sql_c := strings.clone_to_cstring(sql, context.temp_allocator)
	err: cstring
	rc := sqlite3_exec(db.handle, sql_c, nil, nil, &err)
	if rc != SQLITE_OK {
		if err != nil {
			fmt.eprintln("sqlite exec error:", string(err))
			sqlite3_free(rawptr(err))
		} else {
			fmt.eprintln("sqlite exec error:", db_error(db))
		}
		return false
	}
	return true
}

db_open :: proc(path: string) -> (DB, bool) {
	db := DB{path = strings.clone(path)}
	path_c := strings.clone_to_cstring(path, context.temp_allocator)
	flags := SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
	rc := sqlite3_open_v2(path_c, &db.handle, c.int(flags), nil)
	if rc != SQLITE_OK {
		fmt.eprintln("cannot open database:", path, db_error(&db))
		return db, false
	}
	sqlite3_busy_timeout(db.handle, 5000)
	if !db_exec(&db, "PRAGMA journal_mode=WAL;") ||
	   !db_exec(&db, "PRAGMA synchronous=NORMAL;") ||
	   !db_exec(&db, "PRAGMA foreign_keys=ON;") ||
	   !db_init_schema(&db) {
		sqlite3_close_v2(db.handle)
		db.handle = nil
		return db, false
	}
	return db, true
}

db_init_schema :: proc(db: ^DB) -> bool {
	stmt, ok := db_prepare(db, "PRAGMA user_version")
	if !ok { return false }
	rc := sqlite3_step(stmt)
	version := col_i64(stmt, 0) if rc == SQLITE_ROW else -1
	sqlite3_finalize(stmt)
	if version < 0 || version > 1 {
		fmt.eprintln("unsupported database schema version:", version)
		return false
	}
	if !db_exec(db, "BEGIN IMMEDIATE") { return false }
	committed := false
	defer if !committed { db_exec(db, "ROLLBACK") }
	if !db_exec(db, SCHEMA_SQL) || !db_exec(db, SEED_SQL) ||
	   !db_exec(db, "PRAGMA user_version = 1") || !db_exec(db, "COMMIT") { return false }
	committed = true
	return true
}

db_close :: proc(db: ^DB) {
	if db.handle != nil {
		sqlite3_close_v2(db.handle)
		db.handle = nil
	}
	if len(db.path) > 0 {
		delete(db.path)
		db.path = ""
	}
}

db_prepare :: proc(db: ^DB, sql: string) -> (^sqlite3_stmt, bool) {
	sql_c := strings.clone_to_cstring(sql, context.temp_allocator)
	stmt: ^sqlite3_stmt
	rc := sqlite3_prepare_v2(db.handle, sql_c, -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.eprintln("sqlite prepare error:", db_error(db), "sql:", sql)
		return nil, false
	}
	return stmt, true
}

bind_text :: proc(stmt: ^sqlite3_stmt, idx: int, s: string) -> c.int {
	cstr := strings.clone_to_cstring(s, context.temp_allocator)
	return sqlite3_bind_text(stmt, c.int(idx), cstr, c.int(len(s)), SQLITE_TRANSIENT)
}

bind_i64 :: proc(stmt: ^sqlite3_stmt, idx: int, v: i64) -> c.int {
	return sqlite3_bind_int64(stmt, c.int(idx), v)
}

bind_i32 :: proc(stmt: ^sqlite3_stmt, idx: int, v: i32) -> c.int {
	return sqlite3_bind_int(stmt, c.int(idx), c.int(v))
}

bind_null :: proc(stmt: ^sqlite3_stmt, idx: int) -> c.int {
	return sqlite3_bind_null(stmt, c.int(idx))
}

db_bind_result :: proc(codes: ..c.int) -> DB_Result {
	for rc in codes {
		if rc != SQLITE_OK { return db_result(rc) }
	}
	return .Ok
}

col_i64 :: proc(stmt: ^sqlite3_stmt, col: int) -> i64 {
	return sqlite3_column_int64(stmt, c.int(col))
}

col_i32 :: proc(stmt: ^sqlite3_stmt, col: int) -> i32 {
	return i32(sqlite3_column_int(stmt, c.int(col)))
}

col_text :: proc(stmt: ^sqlite3_stmt, col: int) -> string {
	p := sqlite3_column_text(stmt, c.int(col))
	if p == nil {
		return ""
	}
	n := int(sqlite3_column_bytes(stmt, c.int(col)))
	if n <= 0 {
		return ""
	}
	bytes := ([^]u8)(p)[:n]
	return strings.clone(string(bytes))
}

col_is_null :: proc(stmt: ^sqlite3_stmt, col: int) -> bool {
	return sqlite3_column_type(stmt, c.int(col)) == SQLITE_NULL
}

group_color_for_key :: proc(key: string) -> u32 {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]byte)key)
	digest: [32]byte
	sha2.final(&ctx, digest[:])
	return GROUP_COLORS[int(digest[0]) % len(GROUP_COLORS)]
}

key_hash :: proc(key: string) -> string {
	lower, _ := strings.to_lower(key, context.temp_allocator)
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]byte)lower)
	digest: [32]byte
	sha2.final(&ctx, digest[:])
	encoded, _ := base64.encode(digest[:], allocator = context.temp_allocator)
	return encoded
}

db_ensure_group :: proc(db: ^DB, timeline_id: i64, key: string, display_name: string, text_data: string) -> (i64, u32, DB_Result) {
	stmt, ok := db_prepare(db, `SELECT GroupId, Color FROM "Group" WHERE TimelineId = ?1 AND Key = ?2 LIMIT 1`)
	if !ok {
		return 0, 0, db_failure(db)
	}
	defer sqlite3_finalize(stmt)
	bound := db_bind_result(bind_i64(stmt, 1, timeline_id), bind_text(stmt, 2, key))
	if bound != .Ok { return 0, 0, bound }
	rc := sqlite3_step(stmt)
	if rc == SQLITE_ROW {
		id := col_i64(stmt, 0)
		color := u32(col_i64(stmt, 1))
		return id, color, .Ok
	}
	if rc != SQLITE_DONE { return 0, 0, db_result(rc) }

	color := group_color_for_key(key)
	insert, ok2 := db_prepare(db, `INSERT INTO "Group" (TimelineId, DisplayName, Color, TextData, Key, UpdatedTimestamp) VALUES (?1, ?2, ?3, ?4, ?5, ?6)`)
	if !ok2 {
		return 0, 0, db_failure(db)
	}
	defer sqlite3_finalize(insert)
	bound = db_bind_result(
		bind_i64(insert, 1, timeline_id), bind_text(insert, 2, display_name),
		bind_i64(insert, 3, i64(color)), bind_text(insert, 4, text_data),
		bind_text(insert, 5, key), bind_i64(insert, 6, now_ms() / 1000))
	if bound != .Ok { return 0, color, bound }
	rc = sqlite3_step(insert)
	if rc != SQLITE_DONE {
		fmt.eprintln("group insert failed:", db_error(db))
		return 0, color, db_result(rc)
	}
	if sqlite3_changes(db.handle) != 1 { return 0, color, .Failed }
	return sqlite3_last_insert_rowid(db.handle), color, .Ok
}

db_ensure_group_id :: proc(db: ^DB, timeline_id: i64, key: string, display_name: string, text_data: string) -> i64 {
	id, _, _ := db_ensure_group(db, timeline_id, key, display_name, text_data)
	return id
}

db_insert_activity :: proc(db: ^DB, timeline_id: i64, display_name: string, group_id: i64, start_ms, end_ms: i64) -> (i64, DB_Result) {
	if end_ms < start_ms { return 0, .Failed }
	start_local := unix_ms_to_local(start_ms)
	start_utc := unix_ms_to_utc(start_ms)
	end_local := unix_ms_to_local(end_ms)
	end_utc := unix_ms_to_utc(end_ms)

	stmt, ok := db_prepare(db, `
		INSERT INTO Activity (
			TimelineId, DisplayName, GroupId,
			StartLocalDate, StartLocalTime, StartUtcTime,
			EndLocalDate, EndLocalTime, EndUtcTime,
			StartUtcMs, EndUtcMs, TextData, UpdatedTimestamp
		) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, NULL, ?12)
	`)
	if !ok {
		return 0, db_failure(db)
	}
	defer sqlite3_finalize(stmt)
	bound := db_bind_result(
		bind_i64(stmt, 1, timeline_id), bind_text(stmt, 2, display_name), bind_i64(stmt, 3, group_id),
		bind_i64(stmt, 4, manic_date_from_date_int(date_int_from_systemtime(start_local))),
		bind_text(stmt, 5, format_systemtime(start_local)), bind_text(stmt, 6, format_systemtime(start_utc)),
		bind_i64(stmt, 7, manic_date_from_date_int(date_int_from_systemtime(end_local))),
		bind_text(stmt, 8, format_systemtime(end_local)), bind_text(stmt, 9, format_systemtime(end_utc)),
		bind_i64(stmt, 10, start_ms), bind_i64(stmt, 11, end_ms), bind_i64(stmt, 12, now_ms() / 1000))
	if bound != .Ok { return 0, bound }
	rc := sqlite3_step(stmt)
	if rc != SQLITE_DONE {
		fmt.eprintln("activity insert failed:", db_error(db))
		return 0, db_result(rc)
	}
	if sqlite3_changes(db.handle) != 1 { return 0, .Failed }
	return sqlite3_last_insert_rowid(db.handle), .Ok
}

db_update_activity_end :: proc(db: ^DB, activity_id: i64, end_ms: i64) -> DB_Result {
	if activity_id <= 0 {
		return .Not_Found
	}
	end_local := unix_ms_to_local(end_ms)
	end_utc := unix_ms_to_utc(end_ms)
	stmt, ok := db_prepare(db, `
		UPDATE Activity SET
			EndLocalDate = ?1, EndLocalTime = ?2, EndUtcTime = ?3, EndUtcMs = ?4, UpdatedTimestamp = ?5
		WHERE ActivityId = ?6 AND StartUtcMs <= ?4
	`)
	if !ok {
		return db_failure(db)
	}
	defer sqlite3_finalize(stmt)
	bound := db_bind_result(
		bind_i64(stmt, 1, manic_date_from_date_int(date_int_from_systemtime(end_local))),
		bind_text(stmt, 2, format_systemtime(end_local)), bind_text(stmt, 3, format_systemtime(end_utc)),
		bind_i64(stmt, 4, end_ms), bind_i64(stmt, 5, now_ms() / 1000), bind_i64(stmt, 6, activity_id))
	if bound != .Ok { return bound }
	rc := sqlite3_step(stmt)
	if rc != SQLITE_DONE { return db_result(rc) }
	if sqlite3_changes(db.handle) != 1 { return .Not_Found }
	return .Ok
}

db_delete_activity :: proc(db: ^DB, activity_id: i64) {
	if activity_id <= 0 {
		return
	}
	stmt, ok := db_prepare(db, `DELETE FROM Activity WHERE ActivityId = ?1`)
	if !ok {
		return
	}
	defer sqlite3_finalize(stmt)
	bind_i64(stmt, 1, activity_id)
	sqlite3_step(stmt)
}

Tag :: struct {
	id: i64,
	name: string,
}

db_delete_tag_block :: proc(db: ^DB, id: i64) -> bool {
	if id <= 0 { return false }
	stmt, ok := db_prepare(db, `DELETE FROM Activity WHERE ActivityId = ?1 AND TimelineId = 1`)
	if !ok { return false }
	defer sqlite3_finalize(stmt)
	bind_i64(stmt, 1, id)
	return sqlite3_step(stmt) == SQLITE_DONE && sqlite3_changes(db.handle) == 1
}

db_load_tags :: proc(db: ^DB) -> ([]Tag, DB_Result) {
	stmt, ok := db_prepare(db, `SELECT GroupId, DisplayName FROM "Group"
		WHERE TimelineId = 1 AND COALESCE(DisplayName, '') <> '' ORDER BY DisplayName COLLATE NOCASE`)
	if !ok { return nil, db_failure(db) }
	defer sqlite3_finalize(stmt)
	tags := make([dynamic]Tag)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE { return tags[:], .Ok }
		if rc != SQLITE_ROW {
			free_tags(tags[:])
			return nil, db_result(rc)
		}
		append(&tags, Tag{col_i64(stmt, 0), col_text(stmt, 1)})
	}
}

free_tags :: proc(tags: []Tag) {
	for tag in tags { delete(tag.name) }
	if tags != nil { delete(tags) }
}

// Reuse imported tags by name too, even if their original key differs.
db_ensure_tag :: proc(db: ^DB, raw_name: string) -> i64 {
	name := strings.trim_space(raw_name)
	if name == "" { return 0 }
	tags, result := db_load_tags(db)
	if result != .Ok { return 0 }
	defer free_tags(tags)
	lower := strings.to_lower(name, context.temp_allocator)
	for tag in tags {
		if strings.to_lower(tag.name, context.temp_allocator) == lower { return tag.id }
	}
	return db_ensure_group_id(db, TIMELINE_TAGS, key_hash(name), name, "")
}

// Half-open intervals allow blocks to share an edge, but not occupied time.
// Call within the creation transaction so the check and insert stay together.
db_tag_range_free :: proc(db: ^DB, start_ms, end_ms: i64) -> bool {
	if end_ms <= start_ms { return false }
	stmt, ok := db_prepare(db, `SELECT NOT EXISTS (SELECT 1 FROM Activity
		WHERE TimelineId = 1 AND StartUtcMs < ?2 AND EndUtcMs > ?1)`)
	if !ok { return false }
	defer sqlite3_finalize(stmt)
	bind_i64(stmt, 1, start_ms)
	bind_i64(stmt, 2, end_ms)
	return sqlite3_step(stmt) == SQLITE_ROW && col_i64(stmt, 0) == 1
}

// Only user-authored tags are editable here. Update all timestamp representations
// together; tracking's incremental end-time updates remain separate.
db_resize_tag :: proc(db: ^DB, id, start_ms, end_ms: i64) -> bool {
	if id <= 0 || end_ms <= start_ms { return false }
	stmt, ok := db_prepare(db, `UPDATE Activity SET
		StartLocalDate = ?1, StartLocalTime = ?2, StartUtcTime = ?3, StartUtcMs = ?4,
		EndLocalDate = ?5, EndLocalTime = ?6, EndUtcTime = ?7, EndUtcMs = ?8,
		UpdatedTimestamp = ?9 WHERE ActivityId = ?10 AND TimelineId = 1
		AND NOT EXISTS (SELECT 1 FROM Activity other WHERE other.TimelineId = 1
			AND other.ActivityId <> ?10 AND other.StartUtcMs < ?8 AND other.EndUtcMs > ?4)`)
	if !ok { return false }
	defer sqlite3_finalize(stmt)
	s, e := unix_ms_to_local(start_ms), unix_ms_to_local(end_ms)
	bind_i64(stmt, 1, manic_date_from_date_int(date_int_from_systemtime(s)))
	bind_text(stmt, 2, format_systemtime(s))
	bind_text(stmt, 3, format_systemtime(unix_ms_to_utc(start_ms)))
	bind_i64(stmt, 4, start_ms)
	bind_i64(stmt, 5, manic_date_from_date_int(date_int_from_systemtime(e)))
	bind_text(stmt, 6, format_systemtime(e))
	bind_text(stmt, 7, format_systemtime(unix_ms_to_utc(end_ms)))
	bind_i64(stmt, 8, end_ms)
	bind_i64(stmt, 9, now_ms() / 1000)
	bind_i64(stmt, 10, id)
	return sqlite3_step(stmt) == SQLITE_DONE && sqlite3_changes(db.handle) == 1
}

LastActivity :: struct {
	id:           i64,
	group_id:     i64,
	display_name: string,
	start_ms:     i64,
	end_ms:       i64,
}

db_last_activity :: proc(db: ^DB, timeline_id: i64) -> (LastActivity, DB_Result) {
	stmt, ok := db_prepare(db, `
		SELECT ActivityId, COALESCE(GroupId, 0), COALESCE(DisplayName, ''), StartUtcMs, EndUtcMs
		FROM Activity
		WHERE TimelineId = ?1 AND EndUtcMs > 0
		ORDER BY StartUtcMs DESC, ActivityId DESC
		LIMIT 1
	`)
	if !ok {
		return {}, db_failure(db)
	}
	defer sqlite3_finalize(stmt)
	bound := db_result(bind_i64(stmt, 1, timeline_id))
	if bound != .Ok { return {}, bound }
	rc := sqlite3_step(stmt)
	if rc == SQLITE_DONE { return {}, .Not_Found }
	if rc != SQLITE_ROW { return {}, db_result(rc) }
	return LastActivity{
		id = col_i64(stmt, 0),
		group_id = col_i64(stmt, 1),
		display_name = col_text(stmt, 2),
		start_ms = col_i64(stmt, 3),
		end_ms = col_i64(stmt, 4),
	}, .Ok
}

Activity :: struct {
	id:           i64,
	timeline_id:  i64,
	display_name: string,
	group_id:     i64,
	start_ms:     i64,
	end_ms:       i64,
	start_date:   int,
	group_name:   string,
	color:        u32,
}

LOAD_ACTIVITIES_SQL :: `
		SELECT a.ActivityId, a.TimelineId, COALESCE(a.DisplayName, ''), COALESCE(a.GroupId, 0),
		       a.StartUtcMs, a.EndUtcMs, a.StartLocalDate,
		       COALESCE(g.DisplayName, ''), COALESCE(g.Color, 0)
		FROM Activity a
		LEFT JOIN "Group" g ON g.GroupId = a.GroupId
		WHERE a.TimelineId IN (1, 2, 3)
		  AND a.StartLocalDate <= ?1 AND a.EndLocalDate >= ?1
		  AND a.StartUtcMs < ?3 AND a.EndUtcMs > ?2
		ORDER BY a.StartUtcMs ASC, a.ActivityId ASC
	`

db_load_activities :: proc(db: ^DB, date_int: int, include_current: i64 = 0) -> ([]Activity, DB_Result) {
	stmt, ok := db_prepare(db, LOAD_ACTIVITIES_SQL)
	if !ok {
		return nil, db_failure(db)
	}
	defer sqlite3_finalize(stmt)
	day_start, day_end := day_bounds_ms(date_int)
	bound := db_bind_result(bind_i64(stmt, 1, manic_date_from_date_int(date_int)),
		bind_i64(stmt, 2, day_start), bind_i64(stmt, 3, day_end))
	if bound != .Ok { return nil, bound }

	now := now_ms()
	result := make([dynamic]Activity, 0, 256)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE { return result[:], .Ok }
		if rc != SQLITE_ROW {
			free_activities(result[:])
			return nil, db_result(rc)
		}
		a := Activity{
			id = col_i64(stmt, 0),
			timeline_id = col_i64(stmt, 1),
			display_name = col_text(stmt, 2),
			group_id = col_i64(stmt, 3),
			start_ms = col_i64(stmt, 4),
			end_ms = col_i64(stmt, 5),
			start_date = int(col_i64(stmt, 6)),
			group_name = col_text(stmt, 7),
			color = u32(col_i64(stmt, 8)),
		}
		if include_current > 0 && a.id == include_current && now > a.end_ms {
			a.end_ms = now
		}
		append(&result, a)
	}
}

free_activities :: proc(activities: []Activity) {
	for a in activities {
		if len(a.display_name) > 0 {
			delete(a.display_name)
		}
		if len(a.group_name) > 0 {
			delete(a.group_name)
		}
	}
	if activities != nil {
		delete(activities)
	}
}

db_count_activities :: proc(db: ^DB) -> i64 {
	stmt, ok := db_prepare(db, `SELECT COUNT(*) FROM Activity`)
	if !ok {
		return 0
	}
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) == SQLITE_ROW {
		return col_i64(stmt, 0)
	}
	return 0
}

db_usage_group :: proc(db: ^DB, which: UsageKind) -> (i64, DB_Result) {
	key: string
	switch which {
	case .Active:
		key = "W4yiNcyXGPLtSeJd09iJhvbDr6EL/BE2HWKJS8johz8="
	case .Away:
		key = "jaM0cRC0p2E80XobDIz5aMfg8NBucI9QrcoCdb0ll2o="
	case .SessionLocked:
		key = "S7sALuDiUUUJfMuqfN8d1nFc/kVH3SgUYCDbTWNju+c="
	case .PowerOff:
		key = "kw+obQQ1f/3ZFvvhV3kgmhQRNnt+Lr2cgk7gFZdu/LU="
	}
	stmt, ok := db_prepare(db, `SELECT GroupId FROM "Group" WHERE TimelineId = 2 AND Key = ?1 LIMIT 1`)
	if !ok {
		return 0, db_failure(db)
	}
	defer sqlite3_finalize(stmt)
	bound := db_result(bind_text(stmt, 1, key))
	if bound != .Ok { return 0, bound }
	rc := sqlite3_step(stmt)
	if rc == SQLITE_ROW { return col_i64(stmt, 0), .Ok }
	if rc == SQLITE_DONE { return 0, .Not_Found }
	return 0, db_result(rc)
}

extract_xml_tag :: proc(xml, tag: string) -> string {
	if len(xml) == 0 {
		return ""
	}
	open := fmt.tprintf("<%s>", tag)
	close := fmt.tprintf("</%s>", tag)
	i := strings.index(xml, open)
	if i < 0 {
		return ""
	}
	start := i + len(open)
	j := strings.index(xml[start:], close)
	if j < 0 {
		return ""
	}
	return xml[start:start + j]
}
