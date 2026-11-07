package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
db_hot_query_plans :: proc(t: ^testing.T) {
	scratch: Scratch
	context.temp_allocator = scratch_begin(&scratch)
	defer scratch_end(&scratch)
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&db)
	for query in ([3]struct{sql, index: string}{
		{`SELECT ActivityId FROM Activity WHERE TimelineId=3 AND EndUtcMs>0
		 ORDER BY StartUtcMs DESC, ActivityId DESC LIMIT 1`, "IX_Activity_Timeline_Start"},
		{`SELECT MIN(StartUtcMs) FROM Activity WHERE TimelineId=1 AND ActivityId<>1
		 AND StartUtcMs>=1 AND EndUtcMs>StartUtcMs`, "IX_Activity_Timeline_Start"},
		{LOAD_ACTIVITIES_SQL, "IX_Activity_Timeline_Date"},
	}) {
		stmt, prepared := db_prepare(&db, fmt.tprintf("EXPLAIN QUERY PLAN %s", query.sql))
		testing.expect(t, prepared)
		if !prepared { continue }
		found := false
		for sqlite3_step(stmt) == SQLITE_ROW {
			plan := col_text(stmt, 3)
			found = found || strings.contains(plan, query.index)
			delete(plan)
		}
		sqlite3_finalize(stmt)
		testing.expect(t, found)
	}
}

// Opt-in, no performance thresholds in correctness tests. Uses the statically
// linked production SQLite on a synthetic in-memory history, never a live DB.
@(test)
db_representative_history_measurement :: proc(t: ^testing.T) {
	benchmark := os.get_env("AIKA_BENCHMARK", context.allocator)
	defer delete(benchmark)
	if benchmark != "1" { return }
	scratch: Scratch
	context.temp_allocator = scratch_begin(&scratch)
	defer scratch_end(&scratch)
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&db)
	testing.expect(t, db_exec(&db, `DROP INDEX IX_Activity_Timeline_Start;
	WITH RECURSIVE days(d) AS (VALUES(0) UNION ALL SELECT d+1 FROM days WHERE d<364),
	items(i) AS (VALUES(0) UNION ALL SELECT i+1 FROM items WHERE i<899),
	lanes(t,n) AS (VALUES(1,24),(2,2),(3,900))
	INSERT INTO Activity(TimelineId,DisplayName,StartLocalDate,StartLocalTime,StartUtcTime,
	EndLocalDate,EndLocalTime,EndUtcTime,StartUtcMs,EndUtcMs)
	SELECT t,'item',d,'','',d,'','',1700000000000+d*86400000+i*(86400000/n),
	1700000000000+d*86400000+(i+1)*(86400000/n)
	FROM days CROSS JOIN items CROSS JOIN lanes WHERE i<n;`))
	day_unpinned, _ := strings.replace_all(LOAD_ACTIVITIES_SQL, " INDEXED BY IX_Activity_Timeline_Date", "", context.temp_allocator)
	for phase in 0 ..< 2 {
		if phase == 1 { testing.expect(t, db_exec(&db, `CREATE INDEX IX_Activity_Timeline_Start ON Activity(TimelineId,StartUtcMs,ActivityId)`)) }
		for query in ([4]struct{name, sql: string}{
			{"latest app", `SELECT ActivityId,COALESCE(GroupId,0),COALESCE(DisplayName,''),StartUtcMs,EndUtcMs
			 FROM Activity WHERE TimelineId=3 AND EndUtcMs>0 ORDER BY StartUtcMs DESC,ActivityId DESC LIMIT 1`},
			{"task neighbor", `SELECT MIN(StartUtcMs) FROM Activity WHERE TimelineId=1 AND ActivityId<>0
			 AND StartUtcMs>=1731449600000 AND EndUtcMs>StartUtcMs`},
			{"day unpinned", day_unpinned}, {"day pinned", LOAD_ACTIVITIES_SQL},
		}) {
			samples: [21]f64
			for &sample in samples {
				start := time.tick_now()
				stmt, prepared := db_prepare(&db, query.sql)
				testing.expect(t, prepared)
				if !prepared { return }
				if strings.has_prefix(query.name, "day") {
					bind_i64(stmt, 1, 364)
					bind_i64(stmt, 2, 1731449600000)
					bind_i64(stmt, 3, 1731536000000)
				}
				count := 0
				for {
					rc := sqlite3_step(stmt)
					if rc != SQLITE_ROW { testing.expect(t, rc == SQLITE_DONE); break }
					count += 1
				}
				testing.expect(t, count == (926 if strings.has_prefix(query.name, "day") else 1))
				sqlite3_finalize(stmt)
				sample = time.duration_milliseconds(time.tick_since(start))
			}
			for i in 1 ..< len(samples) {
				for j := i; j > 0 && samples[j] < samples[j-1]; j -= 1 { samples[j], samples[j-1] = samples[j-1], samples[j] }
			}
			fmt.printf("history benchmark phase=%d %s median=%.3f ms\n", phase, query.name, samples[10])
		}
	}
}
