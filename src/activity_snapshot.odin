package main

import "core:slice"
import "core:strings"

// Borrowed strings; the arrays belong to the caller's scratch allocator. Full
// bounds describe the activity, displayed bounds describe this selected day.
Snapshot_Activity :: struct {
	activity: Activity,
	start_ms, end_ms: i64,
	live, pending: bool,
}

Day_Snapshot :: struct {
	now, day_start, day_end: i64,
	rows: []Snapshot_Activity,
}

fmt_snapshot_clock :: proc(snapshot: Day_Snapshot, ms: i64) -> string {
	return "24:00" if ms == snapshot.day_end && day_shift_hours == 0 else fmt_clock_hm(ms)
}

snapshot_live_end :: proc(app: ^App, now, mono: i64) -> i64 {
	t := &app.tracker
	end := now
	if t.clock_ready && abs((now - t.last_wall_ms) - (mono - t.last_wall_mono)) > CLOCK_JUMP_TOLERANCE_MS {
		end = t.last_wall_ms
	}
	if t.idle_pending { end = min(end, t.idle_observed) }
	return end
}

// A pure projection: no database calls, mutations, global UI state or clock reads.
build_day_snapshot :: proc(app: ^App, now, mono: i64) -> Day_Snapshot {
	ds, de := day_bounds_ms(app.date)
	rows := make([dynamic]Snapshot_Activity, 0, len(app.activities) + app.tracker.pending_count + 2, context.temp_allocator)
	by_id := make(map[i64]int, context.temp_allocator)
	for a in app.activities {
		by_id[a.id] = len(rows)
		append(&rows, Snapshot_Activity{activity = a})
	}
	for p, i in app.tracker.pending[:app.tracker.pending_count] {
		a := pending_activity(p)
		if a.id == 0 { a.id = -i64(i) - 3 }
		snapshot_overlay(&rows, &by_id, a, false, true)
	}
	end := snapshot_live_end(app, now, mono)
	c := &app.tracker.current
	if c.active {
		a := Activity{id = c.persisted_id, timeline_id = TIMELINE_APPS,
			group_id = c.group_id, display_name = c.title, group_name = c.app_name,
			color = c.group_color, start_ms = c.start_ms, end_ms = max(c.start_ms, end)}
		if a.id == 0 { a.id = -1 }
		snapshot_overlay(&rows, &by_id, a, true, c.persisted_id == 0 || app.tracker.current_result != .Ok)
	}
	t := &app.tracker
	if t.usage_active {
		a := pending_activity(Pending_Activity{id = t.usage_id, timeline = TIMELINE_COMPUTER,
			group = t.usage_group, start_ms = t.usage_start_ms, end_ms = max(t.usage_start_ms, end),
			title = usage_display_name(t.usage_kind), usage_kind = t.usage_kind, color = t.usage_color})
		if a.id == 0 { a.id = -2 }
		snapshot_overlay(&rows, &by_id, a, true, t.usage_id == 0 || t.usage_result != .Ok)
	}
	// Tasks are shown through their acknowledged endpoint, not beyond a tag
	// neighbor that only task_tick's repository query can safely establish.
	if task := &app.task; task.id > 0 {
		a := Activity{id = task.id, timeline_id = TIMELINE_TAGS, group_id = task.group_id,
			display_name = task.name, group_name = task.name, color = task.color,
			start_ms = task.start_ms, end_ms = task.end_ms}
		snapshot_overlay(&rows, &by_id, a, true, false)
	}
	n := 0
	for entry in rows {
		row := entry
		row.start_ms = max(ds, row.activity.start_ms)
		row.end_ms = min(de, row.activity.end_ms)
		if row.end_ms <= row.start_ms { continue }
		rows[n] = row
		n += 1
	}
	resize(&rows, n)
	slice.sort_by(rows[:], proc(a, b: Snapshot_Activity) -> bool {
		if a.activity.start_ms != b.activity.start_ms { return a.activity.start_ms < b.activity.start_ms }
		return a.activity.id < b.activity.id
	})
	return Day_Snapshot{now = now, day_start = ds, day_end = de, rows = rows[:]}
}

snapshot_overlay :: proc(rows: ^[dynamic]Snapshot_Activity, by_id: ^map[i64]int, a: Activity, live, pending: bool) {
	a := a
	if i, found := by_id^[a.id]; found {
		old := rows^[i].activity
		if old.group_name != "" { a.group_name = old.group_name }
		if old.color != 0 { a.color = old.color }
		rows^[i] = Snapshot_Activity{activity = a, live = live, pending = pending}
	} else {
		// A not-yet-loaded row can still inherit group metadata from the cache.
		for row in rows^ {
			if row.activity.group_id == a.group_id && row.activity.timeline_id == a.timeline_id {
				if row.activity.group_name != "" { a.group_name = row.activity.group_name }
				if row.activity.color != 0 { a.color = row.activity.color }
				break
			}
		}
		by_id^[a.id] = len(rows^)
		append(rows, Snapshot_Activity{activity = a, live = live, pending = pending})
	}
}

pending_activity :: proc(p: Pending_Activity) -> Activity {
	a := Activity{id = p.id, timeline_id = p.timeline, group_id = p.group,
		display_name = p.title, group_name = p.group_name, color = p.color,
		start_ms = p.start_ms, end_ms = p.end_ms}
	if p.timeline == TIMELINE_COMPUTER {
		a.group_name = usage_display_name(p.usage_kind)
		if a.group_id == 0 { a.group_id = -i64(p.usage_kind) - 1 }
	}
	return a
}

// Write-through only after acknowledgement. Strings are owned exactly like
// db_load_activities results, and remain valid until the next successful load.
cache_activity_write :: proc(app: ^App, p: Pending_Activity) {
	if app.loaded_date == 0 { return }
	a := pending_activity(p)
	for &old in app.activities {
		if old.id != a.id { continue }
		old.start_ms, old.end_ms = a.start_ms, a.end_ms
		return
	}
	ds, de := day_bounds_ms(app.loaded_date)
	if a.start_ms >= de || a.end_ms <= ds { return }
	for old in app.activities {
		if old.group_id != a.group_id || old.timeline_id != a.timeline_id { continue }
		if old.group_name != "" { a.group_name = old.group_name }
		if old.color != 0 { a.color = old.color }
		break
	}
	a.display_name = strings.clone(a.display_name)
	a.group_name = strings.clone(a.group_name)
	rows := make([]Activity, len(app.activities) + 1)
	copy(rows, app.activities)
	rows[len(app.activities)] = a
	delete(app.activities)
	app.activities = rows
}

present_tracker_write :: proc(app: ^App, p: Pending_Activity) {
	if !app.tracker.cache_suspended { cache_activity_write(app, p) }
}

current_write :: proc(c: ^CurrentActivity, end: i64) -> Pending_Activity {
	return Pending_Activity{id = c.persisted_id, timeline = TIMELINE_APPS,
		group = c.group_id, title = c.title, group_name = c.app_name, color = c.group_color,
		start_ms = c.start_ms, end_ms = end}
}

// Match painted rectangles, including one-pixel bars. The last painted row wins;
// a shared right edge belongs to the next bar, not both bars.
snapshot_bar_hit :: proc(snapshot: Day_Snapshot, timeline: i64, mx, x, width: i32, start, end: i64) -> int {
	found := -1
	for row, i in snapshot.rows {
		if row.activity.timeline_id != timeline { continue }
		s, e := max(row.start_ms, start), min(row.end_ms, end)
		if e <= s { continue }
		x1 := x_for_ms(s, start, end, x, width)
		x2 := x_for_ms(e, start, end, x, width)
		if mx >= x1 && mx < x1 + max(1, x2 - x1) { found = i }
	}
	return found
}
