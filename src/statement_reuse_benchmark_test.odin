package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:testing"
import "core:time"

// Opt-in benchmark for audit item #17 (statement reuse). Gated by
// AIKA_STMT_BENCHMARK=1. Uses only temp-file databases under the opencode temp
// directory. Reports (a) a full synthetic import, (b) tracker-style autocommit
// insert/update-end calls, (c) the task-tick transaction, and (d) the raw
// prepare+finalize cost of the hot SQL, so the prepare share can be derived.



stmt_bench_remove :: proc(path: string) {
	for suffix in ([3]string{"", "-wal", "-shm"}) { os.remove(fmt.tprintf("%s%s", path, suffix)) }
}

stmt_bench_json :: proc(groups, activities: int) -> []byte {
	imp := ImportFile{source = "ManicTime", sourceId = "stmt-bench"}
	imp.groups = make([]ImportGroup, groups)
	imp.activities = make([]ImportActivity, activities)
	defer delete(imp.groups)
	defer delete(imp.activities)
	base, _ := day_bounds_ms(20261106)
	for i in 0 ..< groups {
		imp.groups[i] = ImportGroup{groupId = i64(i + 1), timelineId = TIMELINE_APPS,
			displayName = fmt.tprintf("Bench app %d", i), color = 0xFF123456,
			key = fmt.tprintf("bench-key-%d", i), textData = "bench metadata"}
	}
	for i in 0 ..< activities {
		start := base + i64(i) * 10_000
		imp.activities[i] = ImportActivity{activityId = i64(i + 1), timelineId = TIMELINE_APPS,
			groupId = i64(i % groups + 1), displayName = fmt.tprintf("Bench window %d", i),
			startUtcMs = start, endUtcMs = start + 8_000, textData = "bench text"}
	}
	data, err := json.marshal(imp)
	if err != nil { return nil }
	return data
}

stmt_bench_median :: proc(samples: []f64) -> f64 {
	slice.sort(samples)
	return samples[len(samples) / 2]
}

stmt_bench_prepare_us :: proc(db: ^DB, sql: string, n: int) -> f64 {
	start := time.tick_now()
	for _ in 0 ..< n {
		stmt, ok := db_prepare(db, sql)
		if ok { sqlite3_finalize(stmt) }
	}
	return time.duration_microseconds(time.tick_since(start)) / f64(n)
}

@(test)
statement_reuse_measurement :: proc(t: ^testing.T) {
	flag := os.get_env("AIKA_STMT_BENCHMARK", context.allocator)
	defer delete(flag)
	if flag != "1" { return }
	GROUPS, ACTIVITIES :: 3000, 20000
	data := stmt_bench_json(GROUPS, ACTIVITIES)
	defer delete(data)
	testing.expect(t, data != nil)
	if data == nil { return }

	for cached in ([2]bool{false, true}) {
	label := "one-off prepare" if !cached else "statement cache"
	// (a) full import into a fresh file DB, then an unchanged re-import.
	fresh, again: [5]f64
	for i in 0 ..< len(fresh) {
		path := fmt.aprintf("%s\\aika-stmt-import-%d.db", test_temp_dir(), i)
		defer delete(path)
		stmt_bench_remove(path)
		db, ok := db_open(path)
		testing.expect(t, ok)
		if !ok { return }
		db_set_stmt_cache(&db, cached)
		start := time.tick_now()
		testing.expect(t, import_manictime_data(&db, data))
		fresh[i] = time.duration_milliseconds(time.tick_since(start))
		start = time.tick_now()
		testing.expect(t, import_manictime_data(&db, data))
		again[i] = time.duration_milliseconds(time.tick_since(start))
		testing.expect(t, import_test_scalar(&db, "SELECT count(*) FROM Activity") == ACTIVITIES)
		testing.expect(t, import_test_scalar(&db, `SELECT count(*) FROM "Group" WHERE TimelineId=3`) == GROUPS)
		testing.expect(t, import_test_scalar(&db, "SELECT count(*) FROM ImportActivityMap") == ACTIVITIES)
		db_close(&db)
		stmt_bench_remove(path)
	}
	fmt.printf("STMT [%s] import %d groups/%d activities: fresh median=%.0f ms | unchanged re-import median=%.0f ms\n",
		label, GROUPS, ACTIVITIES, stmt_bench_median(fresh[:]), stmt_bench_median(again[:]))

	path := fmt.aprintf("%s\\aika-stmt-hot.db", test_temp_dir())
	defer delete(path)
	stmt_bench_remove(path)
	db, ok := db_open(path)
	testing.expect(t, ok)
	if !ok { return }
	defer { db_close(&db); stmt_bench_remove(path) }
	db_set_stmt_cache(&db, cached)

	// (b) tracker-style autocommit writes.
	group := db_ensure_group_id(&db, TIMELINE_APPS, "bench-app", "Bench app", "")
	base := now_ms() + 3_600_000
	inserts, updates: [1001]f64
	for i in 0 ..< len(inserts) {
		s := base + i64(i) * 60_000
		start := time.tick_now()
		id, result := db_insert_activity(&db, TIMELINE_APPS, "App", group, s, s + 5000)
		inserts[i] = time.duration_microseconds(time.tick_since(start))
		testing.expect(t, result == .Ok)
		start = time.tick_now()
		result = db_update_activity_end(&db, id, s + 15000)
		updates[i] = time.duration_microseconds(time.tick_since(start))
		testing.expect(t, result == .Ok)
		free_all(context.temp_allocator)
	}
	fmt.printf("STMT [%s] autocommit: db_insert_activity median=%.1f us | db_update_activity_end median=%.1f us (n=%d)\n",
		label, stmt_bench_median(inserts[:]), stmt_bench_median(updates[:]), len(inserts))

	// (c) task tick: BEGIN IMMEDIATE + bounds + neighbor + range check + resize + COMMIT.
	start_ms := base + 10_000_000
	block, created := db_start_task(&db, 0, "Bench task", start_ms)
	testing.expect(t, created == .Ok)
	ticks: [1001]f64
	end := start_ms + 1
	for i in 0 ..< len(ticks) {
		requested := end + 1000
		start := time.tick_now()
		got, _, result := db_extend_task_until_boundary(&db, block.id, start_ms, requested)
		ticks[i] = time.duration_microseconds(time.tick_since(start))
		testing.expect(t, result == .Ok && got == requested)
		end = got
		free_all(context.temp_allocator)
	}
	fmt.printf("STMT [%s] task tick (not converted): db_extend_task_until_boundary median=%.1f us (n=%d)\n", label, stmt_bench_median(ticks[:]), len(ticks))
	}

	path := fmt.aprintf("%s\\aika-stmt-hot.db", test_temp_dir())
	defer delete(path)
	stmt_bench_remove(path)
	db, ok := db_open(path)
	testing.expect(t, ok)
	if !ok { return }
	defer { db_close(&db); stmt_bench_remove(path) }

	// (d) raw prepare+finalize cost of representative hot SQL.
	fmt.printf("STMT prepare+finalize: update_end=%.1f us | insert_activity=%.1f us | import_map_lookup=%.1f us | local_fingerprint=%.1f us | task_bounds=%.1f us | tag_range_check=%.1f us\n",
		stmt_bench_prepare_us(&db, `UPDATE Activity SET
			EndLocalDate = ?1, EndLocalTime = ?2, EndUtcTime = ?3, EndUtcMs = ?4, UpdatedTimestamp = ?5
		WHERE ActivityId = ?6 AND StartUtcMs <= ?4`, 2000),
		stmt_bench_prepare_us(&db, `INSERT INTO Activity (TimelineId, DisplayName, GroupId,
			StartLocalDate, StartLocalTime, StartUtcTime, EndLocalDate, EndLocalTime, EndUtcTime,
			StartUtcMs, EndUtcMs, TextData, UpdatedTimestamp) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, NULL, ?12)`, 2000),
		stmt_bench_prepare_us(&db, `SELECT LocalActivityId, SourceTimelineId, SourceStartUtcMs,
			SourceFingerprint, LocalFingerprint FROM ImportActivityMap WHERE SourceId=?1 AND SourceActivityId=?2`, 2000),
		stmt_bench_prepare_us(&db, `SELECT TimelineId, DisplayName, GroupId, GroupListId,
			StartLocalDate, StartLocalTime, StartUtcTime, EndLocalDate, EndLocalTime, EndUtcTime,
			StartUtcMs, EndUtcMs, TextData FROM Activity WHERE ActivityId=?1`, 2000),
		stmt_bench_prepare_us(&db, `SELECT MIN(StartUtcMs) FROM Activity
			WHERE TimelineId=1 AND ActivityId<>?1 AND StartUtcMs>=?2 AND EndUtcMs>StartUtcMs`, 2000),
		stmt_bench_prepare_us(&db, `SELECT NOT EXISTS (SELECT 1 FROM Activity
			WHERE TimelineId = 1 AND ActivityId<>?3 AND StartUtcMs < ?2 AND EndUtcMs > ?1)`, 2000))
}
