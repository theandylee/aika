package main

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:testing"

// Audit item #14: the day query is split into an ordinary branch (start-time
// seek) and a long-interval branch (partial index). These tests pin both
// branches to the former date-index query and to a brute-force overlap.

DAYEDGE_DATE :: 20261106

@(test)
long_activity_constants_agree :: proc(t: ^testing.T) {
	n, ok := strconv.parse_i64(LONG_ACTIVITY_SQL)
	testing.expect(t, ok && n == LONG_ACTIVITY_MS)
}

dayedge_insert :: proc(db: ^DB, tl, s, e: i64) -> i64 {
	group := i64(0)
	if tl == 1 { group = db_ensure_tag(db, "Edge") }
	if e < s {
		// db_insert_activity refuses these; imports or old bugs could still leave them.
		stmt, prepared := db_prepare(db, `
			INSERT INTO Activity (TimelineId, DisplayName, GroupId,
				StartLocalDate, StartLocalTime, StartUtcTime, EndLocalDate, EndLocalTime, EndUtcTime,
				StartUtcMs, EndUtcMs, TextData, UpdatedTimestamp)
			VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, NULL, 0)`)
		if !prepared { return 0 }
		defer sqlite3_finalize(stmt)
		if !dayload_insert(stmt, tl, "Edge", group, s, e) { return 0 }
		return sqlite3_last_insert_rowid(db.handle)
	}
	id, result := db_insert_activity(db, tl, "Edge", group, s, e)
	if result != .Ok { return 0 }
	return id
}

dayedge_check :: proc(t: ^testing.T, db: ^DB, date: int, brute: bool) -> int {
	got, ok := day_load_ids(db, date)
	defer delete(got)
	testing.expect(t, ok)
	legacy, legacy_ok := day_load_legacy_ids(db, date)
	defer delete(legacy)
	testing.expect(t, legacy_ok)
	testing.expectf(t, slice.equal(got[:], legacy[:]), "date %d: new %v != legacy %v", date, got[:], legacy[:])
	if brute {
		all, fetched := dayload_fetch_all(db)
		defer delete(all)
		testing.expect(t, fetched)
		want := dayload_brute_ids(all[:], date)
		defer delete(want)
		testing.expectf(t, slice.equal(got[:], want[:]), "date %d: new %v != brute %v", date, got[:], want[:])
	}
	return len(got)
}

@(test)
day_load_edge_rows_match_legacy_and_bruteforce :: proc(t: ^testing.T) {
	scratch: Scratch
	context.temp_allocator = scratch_begin(&scratch)
	defer scratch_end(&scratch)
	db, opened := db_open(":memory:")
	testing.expect(t, opened)
	if !opened { return }
	defer db_close(&db)
	ds, de := day_bounds_ms(DAYEDGE_DATE)
	L := LONG_ACTIVITY_MS
	want_in, want_out := make([dynamic]i64, context.temp_allocator), make([dynamic]i64, context.temp_allocator)
	add :: proc(list: ^[dynamic]i64, id: i64) { append(list, id) }
	for tl in ([3]i64{1, 2, 3}) {
		// Half-open edges: ends exactly at day start / starts exactly at day end.
		add(&want_out, dayedge_insert(&db, tl, ds - 5000, ds))
		add(&want_out, dayedge_insert(&db, tl, de, de + 5000))
		add(&want_in, dayedge_insert(&db, tl, ds - 5000, ds + 1))
		add(&want_in, dayedge_insert(&db, tl, de - 1, de + 5000))
		// Midnight crossings at both edges.
		add(&want_in, dayedge_insert(&db, tl, ds - 1000, ds + 1000))
		add(&want_in, dayedge_insert(&db, tl, de - 1000, de + 1000))
		// Duration exactly LONG (ordinary branch) and LONG + 1 (long branch).
		add(&want_out, dayedge_insert(&db, tl, ds - L, ds)) // ends at day start
		add(&want_in, dayedge_insert(&db, tl, ds - L + 1, ds + 1)) // == LONG, starts just inside the seek window
		add(&want_in, dayedge_insert(&db, tl, ds - L, ds + 1)) // LONG + 1
		add(&want_in, dayedge_insert(&db, tl, de - L, de)) // == LONG, ends at day end
		add(&want_out, dayedge_insert(&db, tl, de, de + L)) // == LONG, starts at day end
		add(&want_out, dayedge_insert(&db, tl, de, de + L + 1)) // LONG + 1, starts at day end
		add(&want_out, dayedge_insert(&db, tl, ds - L - 1, ds)) // LONG + 1, ends at day start
		// Multi-day rows spanning the whole target day and beyond.
		add(&want_in, dayedge_insert(&db, tl, ds - 3 * L, de + 2 * L))
		add(&want_in, dayedge_insert(&db, tl, ds - 2 * L + 5, ds + 5))
		add(&want_in, dayedge_insert(&db, tl, ds + 5, de + 4 * L))
		// Far past / far future rows of every length.
		add(&want_out, dayedge_insert(&db, tl, ds - 40 * L, ds - 39 * L))
		add(&want_out, dayedge_insert(&db, tl, ds - 40 * L, ds - 3000))
		add(&want_out, dayedge_insert(&db, tl, de + 40 * L, de + 41 * L))
		// Zero-length and one-ms rows inside the day.
		add(&want_in, dayedge_insert(&db, tl, ds + 777, ds + 777))
		add(&want_in, dayedge_insert(&db, tl, ds + 777, ds + 778))
	}
	// Timelines outside 1..3 never load.
	add(&want_out, dayedge_insert(&db, 4, ds + 10, ds + 5000))
	add(&want_out, dayedge_insert(&db, 5, ds + 10, ds + 5000))
	// End before start (corrupt rows), overlapping and not overlapping the day.
	for tl in ([2]i64{2, 3}) {
		for row in ([5][2]i64{{ds + 100, ds + 50}, {ds + 100, ds - 3 * L}, {de + 5, ds + 50}, {de - 5, ds - 5 * L}, {ds + 5, ds - 1}}) {
			id := dayedge_insert(&db, tl, row[0], row[1])
			// Same rule the former query used: start < day end and end > day start.
			append(&want_in if row[0] < de && row[1] > ds else &want_out, id)
		}
	}
	for id in want_in { testing.expect(t, id != 0) }
	for id in want_out { testing.expect(t, id != 0) }

	got, ok := day_load_ids(&db, DAYEDGE_DATE)
	defer delete(got)
	testing.expect(t, ok)
	testing.expectf(t, len(got) == len(want_in), "loaded %d rows, expected %d", len(got), len(want_in))
	set := make(map[i64]bool, context.temp_allocator)
	for id in got { set[id] = true }
	for id in want_in { testing.expectf(t, set[id], "id %d must load", id) }
	for id in want_out { testing.expectf(t, !set[id], "id %d must not load", id) }
	for i in 1 ..< len(got) { testing.expect(t, got[i-1] != got[i]) }

	for offset in -3 ..< 6 {
		date := add_days(DAYEDGE_DATE, offset)
		dayedge_check(t, &db, date, true)
	}

	// Rows whose stored local dates disagree with their UTC range: the old
	// query's local-date terms still decide, and so must the new one.
	odd := fmt.tprintf(`INSERT INTO Activity (TimelineId, DisplayName, GroupId, StartLocalDate, StartLocalTime,
		StartUtcTime, EndLocalDate, EndLocalTime, EndUtcTime, StartUtcMs, EndUtcMs, TextData, UpdatedTimestamp)
		VALUES (2,'odd',0,%[0]d,'','',%[0]d,'','',%[1]d,%[2]d,NULL,0),
		       (2,'odd',0,0,'','',0,'','',%[3]d,%[4]d,NULL,0),
		       (3,'odd',0,1,'','',1,'','',%[3]d,%[4]d,NULL,0)`,
		manic_date_from_date_int(DAYEDGE_DATE) + 40, ds + 10, ds + 20, ds + 10, ds + 20 + 3 * L)
	testing.expect(t, db_exec(&db, odd))
	count := dayedge_check(t, &db, DAYEDGE_DATE, false)
	testing.expect(t, count == len(want_in), "odd local-date rows must stay excluded exactly as before")
}

@(test)
day_load_matches_legacy_on_every_day_of_synthetic_history :: proc(t: ^testing.T) {
	scratch: Scratch
	context.temp_allocator = scratch_begin(&scratch)
	defer scratch_end(&scratch)
	db, opened := db_open(":memory:")
	testing.expect(t, opened)
	if !opened { return }
	defer db_close(&db)
	days := 120
	info, built := dayload_build(&db, 20000, days)
	testing.expect(t, built)
	if !built { return }
	for k in -3 ..< days + 3 {
		date := date_int_from_manic_date(info.today_manic - i64(days - 1) + i64(k))
		got, ok := day_load_ids(&db, date)
		legacy, legacy_ok := day_load_legacy_ids(&db, date)
		testing.expect(t, ok && legacy_ok)
		testing.expectf(t, slice.equal(got[:], legacy[:]), "date %d differs from legacy", date)
		delete(got)
		delete(legacy)
	}
}

@(test)
long_activity_index_is_added_to_existing_databases :: proc(t: ^testing.T) {
	scratch: Scratch
	context.temp_allocator = scratch_begin(&scratch)
	defer scratch_end(&scratch)
	db, opened := db_open(":memory:")
	testing.expect(t, opened)
	if !opened { return }
	defer db_close(&db)
	ds, _ := day_bounds_ms(DAYEDGE_DATE)
	long_id := dayedge_insert(&db, 2, ds - 3 * LONG_ACTIVITY_MS, ds + 1000)
	short_id := dayedge_insert(&db, 3, ds + 1000, ds + 6000)
	testing.expect(t, long_id != 0 && short_id != 0)
	index_exists :: proc(db: ^DB) -> bool {
		stmt, ok := db_prepare(db, "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='IX_Activity_Long'")
		if !ok { return false }
		defer sqlite3_finalize(stmt)
		return sqlite3_step(stmt) == SQLITE_ROW && col_i64(stmt, 0) == 1
	}
	user_version :: proc(db: ^DB) -> i64 {
		stmt, ok := db_prepare(db, "PRAGMA user_version")
		if !ok { return -1 }
		defer sqlite3_finalize(stmt)
		return col_i64(stmt, 0) if sqlite3_step(stmt) == SQLITE_ROW else -1
	}
	testing.expect(t, index_exists(&db) && user_version(&db) == 1)
	// A database created before the index existed: version 1, no IX_Activity_Long.
	testing.expect(t, db_exec(&db, "DROP INDEX IX_Activity_Long"))
	testing.expect(t, !index_exists(&db) && user_version(&db) == 1)
	// Reopening (schema init runs on every open) adds it back with existing rows indexed.
	testing.expect(t, db_init_schema(&db))
	testing.expect(t, index_exists(&db) && user_version(&db) == 1)
	rows, loaded := db_load_activities(&db, DAYEDGE_DATE)
	testing.expect(t, loaded == .Ok && len(rows) == 2 && rows[0].id == long_id && rows[1].id == short_id)
	free_activities(rows)
	// Idempotent, and a newer schema version is still refused.
	testing.expect(t, db_init_schema(&db) && index_exists(&db))
	testing.expect(t, db_exec(&db, "PRAGMA user_version = 2"))
	testing.expect(t, !db_init_schema(&db))
	testing.expect(t, db_exec(&db, "PRAGMA user_version = 1"))
}
