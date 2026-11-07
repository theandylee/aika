package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:testing"
import "core:time"

// Baseline for audit item #14 (day-load query cost). Nothing here changes
// indexes or queries. The opt-in benchmark builds a synthetic temp-file DB;
// the normal test checks db_load_activities against a brute-force overlap on
// a small :memory: DB. day_load_ids/day_load_hash are meant to be reused to
// compare a future query rewrite against the current one.

DAYLOAD_DAY_MS :: i64(86_400_000)

Dayload_Rng :: struct { s: u64 }

dayload_rand :: proc(r: ^Dayload_Rng, lo, hi: i64) -> i64 {
	r.s ~= r.s << 13
	r.s ~= r.s >> 7
	r.s ~= r.s << 17
	if hi <= lo { return lo }
	return lo + i64((r.s * 0x2545F4914F6CDD1D) >> 11) % (hi - lo + 1)
}

Dayload_Info :: struct {
	days:          int, // history length in local days, ending today
	today_manic:   i64,
	rows:          i64,
	long_mid_date: int, // local date inside a multi-day span
}

dayload_insert :: proc(stmt: ^sqlite3_stmt, tl: i64, name: string, gid: i64, s, e: i64) -> bool {
	sqlite3_reset(stmt)
	bound := db_bind_result(bind_i64(stmt, 1, tl), bind_text(stmt, 2, name), bind_i64(stmt, 3, gid))
	if bound != .Ok { return false }
	if db_bind_time(stmt, s, DB_Time_Columns{4, 5, 6, 10}) != .Ok { return false }
	if db_bind_time(stmt, e, DB_Time_Columns{7, 8, 9, 11}) != .Ok { return false }
	return sqlite3_step(stmt) == SQLITE_DONE
}

// Deterministic ~8-year shape: timeline 2 = 3 spans/day, timeline 1 = a tag on
// about half the days, timeline 3 = dense short rows, ~0.1% multi-day rows on
// timelines 1/2, and some rows crossing local midnight.
dayload_build :: proc(db: ^DB, rows: int, days: int) -> (info: Dayload_Info, ok: bool) {
	scratch: Scratch
	context.temp_allocator = scratch_begin(&scratch)
	defer scratch_end(&scratch)
	today := today_date_int()
	info.days = days
	info.today_manic = manic_date_from_date_int(today)
	rng := Dayload_Rng{0x9E3779B97F4A7C15}
	long_count := max(5, rows / 1000)
	n3 := max(8, (rows - 3 * days - days / 2 - long_count) / days)
	groups: [48]i64
	for &g, i in groups {
		g = db_ensure_group_id(db, 3, fmt.tprintf("bench-app-%d", i), fmt.tprintf("Bench App %d", i), "")
		if g == 0 { return }
	}
	stmt, prepared := db_prepare(db, `
		INSERT INTO Activity (TimelineId, DisplayName, GroupId,
			StartLocalDate, StartLocalTime, StartUtcTime, EndLocalDate, EndLocalTime, EndUtcTime,
			StartUtcMs, EndUtcMs, TextData, UpdatedTimestamp)
		VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, NULL, 0)`)
	if !prepared { return }
	defer sqlite3_finalize(stmt)
	if !db_exec(db, "BEGIN") { return }
	committed := false
	defer if !committed { db_exec(db, "ROLLBACK") }

	day_starts := make([]i64, days + 1)
	defer delete(day_starts)
	for d in 0 ..< days {
		date := date_int_from_manic_date(info.today_manic - i64(days - 1 - d))
		day_starts[d], _ = day_bounds_ms(date)
	}
	_, day_starts[days] = day_bounds_ms(today)
	count := i64(0)
	put :: proc(stmt: ^sqlite3_stmt, count: ^i64, tl: i64, name: string, gid: i64, s, e: i64) -> bool {
		if !dayload_insert(stmt, tl, name, gid, s, e) { return false }
		count^ += 1
		if count^ % 2048 == 0 { free_all(context.temp_allocator) }
		return true
	}
	for d in 0 ..< days {
		ds := day_starts[d]
		length := day_starts[d + 1] - ds
		h := length / 24
		jitter := proc(r: ^Dayload_Rng, ms: i64) -> i64 { return dayload_rand(r, 0, ms) }
		// ComputerUsage: three long spans; every 4th day the last runs past midnight.
		last_end := ds + 23 * h + 50 * 60_000
		if d % 4 == 0 { last_end = ds + length + dayload_rand(&rng, 60_000, 40 * 60_000) }
		if !put(stmt, &count, 2, "ComputerUsage", 0, ds + 7 * h + jitter(&rng, 600_000), ds + 12 * h) ||
		   !put(stmt, &count, 2, "ComputerUsage", 0, ds + 13 * h, ds + 18 * h + jitter(&rng, 600_000)) ||
		   !put(stmt, &count, 2, "ComputerUsage", 0, ds + 19 * h, last_end) { return }
		if dayload_rand(&rng, 0, 1) == 0 {
			s := ds + dayload_rand(&rng, 0, length - 2 * h)
			if !put(stmt, &count, 1, "Tag", 0, s, s + dayload_rand(&rng, 10 * 60_000, 90 * 60_000)) { return }
		}
		slot := length / i64(n3)
		cap := min(30 * 60_000, slot * 3 / 4)
		if cap < 5000 { cap = 5000 }
		for i in 0 ..< n3 {
			s := ds + i64(i) * slot + dayload_rand(&rng, 0, slot / 4)
			rnd := dayload_rand(&rng, 0, 1000)
			e := s + 5000 + (rnd * rnd * (cap - 5000)) / 1_000_000
			if i == n3 - 1 && d % 4 == 1 { e = ds + length + dayload_rand(&rng, 60_000, 10 * 60_000) }
			if !put(stmt, &count, 3, "App", groups[dayload_rand(&rng, 0, 47)], s, e) { return }
		}
	}
	for i in 0 ..< long_count {
		d := int(dayload_rand(&rng, 0, i64(days - 8)))
		s := day_starts[d] + dayload_rand(&rng, 0, DAYLOAD_DAY_MS - 1)
		e := s + dayload_rand(&rng, 1, 4) * DAYLOAD_DAY_MS + dayload_rand(&rng, 0, DAYLOAD_DAY_MS)
		tl := i64(2) if i % 2 == 0 else 1
		if !put(stmt, &count, tl, "Long", 0, s, e) { return }
		if i == 0 { info.long_mid_date = date_int_from_unix_ms(s + (e - s) / 2) }
	}
	if !db_exec(db, "COMMIT") { return }
	committed = true
	info.rows = count
	ok = true
	return
}

// Canonical result of the day load: activity ids in the order the app sees them.
day_load_ids :: proc(db: ^DB, date_int: int) -> (ids: [dynamic]i64, ok: bool) {
	activities, result := db_load_activities(db, date_int)
	if result != .Ok { return nil, false }
	defer free_activities(activities)
	for a in activities { append(&ids, a.id) }
	return ids, true
}

// Same projection as db_load_activities but through LEGACY_LOAD_ACTIVITIES_SQL.
day_load_legacy_ids :: proc(db: ^DB, date_int: int) -> (ids: [dynamic]i64, ok: bool) {
	stmt, prepared := db_prepare(db, LEGACY_LOAD_ACTIVITIES_SQL)
	if !prepared { return nil, false }
	defer sqlite3_finalize(stmt)
	day_start, day_end := day_bounds_ms(date_int)
	if db_bind_result(bind_i64(stmt, 1, manic_date_from_date_int(date_int)),
		bind_i64(stmt, 2, day_start), bind_i64(stmt, 3, day_end)) != .Ok { return nil, false }
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE { return ids, true }
		if rc != SQLITE_ROW { delete(ids); return nil, false }
		append(&ids, col_i64(stmt, 0))
	}
}

// FNV-1a over ids in order; cheap fingerprint for comparing many days.
day_load_hash :: proc(ids: []i64) -> u64 {
	h := u64(0xcbf29ce484222325)
	for id in ids {
		v := u64(id)
		for _ in 0 ..< 8 {
			h = (h ~ (v & 0xFF)) * 0x100000001b3
			v >>= 8
		}
	}
	return h ~ u64(len(ids))
}

Dayload_Row :: struct { id, tl, start, end: i64 }

dayload_fetch_all :: proc(db: ^DB) -> (rows: [dynamic]Dayload_Row, ok: bool) {
	stmt, prepared := db_prepare(db, "SELECT ActivityId, TimelineId, StartUtcMs, EndUtcMs FROM Activity")
	if !prepared { return nil, false }
	defer sqlite3_finalize(stmt)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&rows, Dayload_Row{col_i64(stmt, 0), col_i64(stmt, 1), col_i64(stmt, 2), col_i64(stmt, 3)})
	}
	return rows, true
}

// Half-open [start,end) overlap with the local day, timelines 1..3, ordered by
// StartUtcMs ASC, ActivityId ASC.
dayload_brute_ids :: proc(rows: []Dayload_Row, date_int: int) -> (ids: [dynamic]i64) {
	ds, de := day_bounds_ms(date_int)
	hits := make([dynamic]Dayload_Row, context.temp_allocator)
	for r in rows {
		if r.tl >= 1 && r.tl <= 3 && r.start < de && r.end > ds { append(&hits, r) }
	}
	slice.sort_by(hits[:], proc(a, b: Dayload_Row) -> bool {
		return a.start < b.start || (a.start == b.start && a.id < b.id)
	})
	for r in hits { append(&ids, r.id) }
	return
}

@(test)
day_load_matches_bruteforce_overlap :: proc(t: ^testing.T) {
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
	testing.expect(t, info.rows >= 15000)
	all, fetched := dayload_fetch_all(&db)
	testing.expect(t, fetched)
	defer delete(all)
	multi_day, crossing := 0, 0
	for r in all {
		if r.end - r.start >= DAYLOAD_DAY_MS { multi_day += 1 }
		if date_int_from_unix_ms(r.start) != date_int_from_unix_ms(r.end - 1) { crossing += 1 }
	}
	testing.expect(t, multi_day >= 5)
	testing.expect(t, crossing > 50)
	multi_days_seen, mid_seen := 0, false
	for k in -3 ..< days + 3 {
		date := date_int_from_manic_date(info.today_manic - i64(days - 1) + i64(k))
		got, ok := day_load_ids(&db, date)
		testing.expect(t, ok)
		want := dayload_brute_ids(all[:], date)
		testing.expectf(t, slice.equal(got[:], want[:]), "date %d: got %d rows, want %d", date, len(got), len(want))
		testing.expect(t, day_load_hash(got[:]) == day_load_hash(want[:]))
		if date == info.long_mid_date { mid_seen = len(got) > 0 }
		multi_days_seen += len(got)
		delete(got)
		delete(want)
	}
	testing.expect(t, mid_seen)
	testing.expect(t, multi_days_seen > 15000)
}

dayload_env_int :: proc(name: string, fallback: int) -> int {
	v := os.get_env(name, context.allocator)
	defer delete(v)
	n, ok := strconv.parse_int(v)
	return n if ok && n > 0 else fallback
}

dayload_stats :: proc(samples: []f64) -> (median, p95: f64) {
	slice.sort(samples)
	return samples[len(samples) / 2], samples[(len(samples) * 95 + 99) / 100 - 1]
}

@(test)
day_load_measurement :: proc(t: ^testing.T) {
	flag := os.get_env("AIKA_DAYLOAD_BENCHMARK", context.allocator)
	defer delete(flag)
	if flag != "1" { return }
	scratch: Scratch
	context.temp_allocator = scratch_begin(&scratch)
	defer scratch_end(&scratch)
	rows := dayload_env_int("AIKA_DAYLOAD_ROWS", 500000)
	dir :: `C:\Users\xatar\AppData\Local\Temp\opencode`
	os.make_directory(dir)
	path := fmt.aprintf("%s\\aika-dayload-%d.db", dir, rows)
	defer delete(path)
	for suffix in ([3]string{"", "-wal", "-shm"}) { os.remove(fmt.tprintf("%s%s", path, suffix)) }
	db, opened := db_open(path)
	testing.expect(t, opened)
	if !opened { return }
	build_start := time.tick_now()
	info, built := dayload_build(&db, rows, 8 * 365)
	testing.expect(t, built)
	if !built { db_close(&db); return }
	db_exec(&db, "PRAGMA wal_checkpoint(TRUNCATE)")
	db_close(&db)
	// Reopen like the app does, so caches are cold at the start.
	db, opened = db_open(path)
	testing.expect(t, opened)
	if !opened { return }
	defer {
		db_close(&db)
		for suffix in ([3]string{"", "-wal", "-shm"}) { os.remove(fmt.tprintf("%s%s", path, suffix)) }
	}
	fmt.printf("day-load benchmark: rows=%d days=%d build=%.1fs file=%s\n", info.rows, info.days,
		time.duration_seconds(time.tick_since(build_start)), path)

	// Upgrade cost: an old DB lacks the partial index; db_open builds it once.
	testing.expect(t, db_exec(&db, "DROP INDEX IX_Activity_Long"))
	db_close(&db)
	upgrade_start := time.tick_now()
	db, opened = db_open(path)
	testing.expect(t, opened)
	if !opened { return }
	fmt.printf("upgrade open (builds IX_Activity_Long on %d rows): %.0f ms\n", info.rows,
		time.duration_milliseconds(time.tick_since(upgrade_start)))

	today := info.today_manic
	targets := [6]struct{name: string, date: int}{
		{"today", date_int_from_manic_date(today)},
		{"1 month ago", date_int_from_manic_date(today - 30)},
		{"1 year ago", date_int_from_manic_date(today - 365)},
		{"3 years ago", date_int_from_manic_date(today - 3 * 365)},
		{"oldest", date_int_from_manic_date(today - i64(info.days - 1))},
		{"inside multi-day", info.long_mid_date},
	}
	fmt.println("target            date      rows  median_us   p95_us  hash")
	for target in targets {
		samples: [21]f64
		count := 0
		hash := u64(0)
		for &sample, i in samples {
			start := time.tick_now()
			activities, result := db_load_activities(&db, target.date)
			sample = time.duration_microseconds(time.tick_since(start))
			testing.expect(t, result == .Ok)
			if i == 0 {
				count = len(activities)
				ids := make([dynamic]i64, context.temp_allocator)
				for a in activities { append(&ids, a.id) }
				hash = day_load_hash(ids[:])
			}
			free_activities(activities)
		}
		median, p95 := dayload_stats(samples[:])
		legacy_hash := u64(0)
		legacy_us := f64(0)
		{
			start := time.tick_now()
			legacy, legacy_ok := day_load_legacy_ids(&db, target.date)
			legacy_us = time.duration_microseconds(time.tick_since(start))
			testing.expect(t, legacy_ok)
			legacy_hash = day_load_hash(legacy[:])
			delete(legacy)
		}
		fmt.printf("%-17s %d %6d %10.0f %8.0f  %016x legacy(cold,1 run)=%.0fus %s\n", target.name, target.date, count,
			median, p95, hash, legacy_us, "SAME" if legacy_hash == hash else "MISMATCH")
		testing.expect(t, legacy_hash == hash)
	}

	plan, plan_ok := db_prepare(&db, fmt.tprintf("EXPLAIN QUERY PLAN %s", LOAD_ACTIVITIES_SQL))
	testing.expect(t, plan_ok)
	if plan_ok {
		fmt.println("EXPLAIN QUERY PLAN (day load):")
		for sqlite3_step(plan) == SQLITE_ROW {
			text := col_text(plan, 3)
			fmt.printf("  %s\n", text)
			delete(text)
		}
		sqlite3_finalize(plan)
	}

	// Tracker-style autocommit writes at the end of history.
	group := db_ensure_group_id(&db, 3, "bench-app-0", "Bench App 0", "")
	base := now_ms() + 3_600_000
	inserts, updates: [501]f64
	for i in 0 ..< len(inserts) {
		s := base + i64(i) * 60_000
		start := time.tick_now()
		id, result := db_insert_activity(&db, 3, "App", group, s, s + 5000)
		inserts[i] = time.duration_microseconds(time.tick_since(start))
		testing.expect(t, result == .Ok)
		start = time.tick_now()
		result = db_update_activity_end(&db, id, s + 15000)
		updates[i] = time.duration_microseconds(time.tick_since(start))
		testing.expect(t, result == .Ok)
		free_all(context.temp_allocator)
	}
	im, ip := dayload_stats(inserts[:])
	um, up := dayload_stats(updates[:])
	fmt.printf("db_insert_activity median=%.0f us p95=%.0f us | db_update_activity_end median=%.0f us p95=%.0f us (n=%d)\n",
		im, ip, um, up, len(inserts))
}
