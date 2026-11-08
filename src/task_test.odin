package main

import "core:testing"

@(test)
task_lifecycle :: proc(t: ^testing.T) {
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	app := App{db = db, date = 20261106}
	defer db_close(&app.db)
	start, midnight := day_bounds_ms(app.date)
	start = midnight - 2000
	input := Tracker_Test_Input{now = start}
	app.tracker.io = Tracker_IO{data = &input, monotonic = tracker_test_now}
	testing.expect(t, task_start(&app, 0, "Development", start))
	id := app.task.id
	testing.expect(t, id > 0)
	testing.expect(t, !task_start(&app, 0, "Other", start))
	input.now = midnight + 2000
	testing.expect(t, task_tick(&app, input.now))
	rows, result := db_load_activities(&app.db, 20261107)
	testing.expect(t, result == .Ok)
	testing.expect(t, len(rows) == 1)
	if len(rows) == 1 {
		testing.expect(t, rows[0].id == id && rows[0].start_ms == start && rows[0].end_ms == midnight + 2000)
	}
	free_activities(rows)
	input.now = midnight + 2200
	testing.expect(t, task_stop(&app, input.now))
	testing.expect(t, app.task.id == 0)
	last, found := db_last_activity(&app.db, TIMELINE_TAGS)
	testing.expect(t, found == .Ok && last.id == id && last.end_ms == midnight + 2200)
	delete(last.display_name)
	testing.expect(t, !task_start(&app, 0, "Overlap", start + 1000))
	input.now = midnight + 3000
	testing.expect(t, task_start(&app, 0, "Next", input.now))
	testing.expect(t, task_stop(&app, midnight + 3001), "Very short tasks are retained")
}

@(test)
task_pomodoro_stops_at_deadline :: proc(t: ^testing.T) {
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	app := App{db = db}
	defer db_close(&app.db)
	start, _ := day_bounds_ms(20261106)
	start += 3_600_000
	input := Tracker_Test_Input{now = start}
	app.tracker.io = Tracker_IO{data = &input, monotonic = tracker_test_now}
	pomo := 25 * MS_PER_MINUTE
	testing.expect(t, task_start(&app, 0, "Focus", start, pomo))
	id := app.task.id
	testing.expect(t, id > 0 && app.task.pomo_ms == pomo)
	testing.expect(t, task_pomodoro_remaining(&app, input.now) == pomo)

	// Before the deadline it just runs and counts down.
	input.now = start + 10 * MS_PER_MINUTE
	testing.expect(t, task_tick(&app, input.now))
	testing.expect(t, app.task.id == id && !app.pomo_done.pending)
	testing.expect(t, task_pomodoro_remaining(&app, input.now) == 15 * MS_PER_MINUTE)

	// A late tick still saves exactly start + duration, stops, and queues one notification.
	input.now = start + pomo + 900
	testing.expect(t, task_tick(&app, input.now))
	testing.expect(t, app.task.id == 0 && app.pomo_done.pending)
	last, found := db_last_activity(&app.db, TIMELINE_TAGS)
	testing.expect(t, found == .Ok && last.id == id && last.end_ms == start + pomo)
	delete(last.display_name)
	name, minutes, taken := task_pomodoro_take(&app)
	testing.expect(t, taken && name == "Focus" && minutes == 25)
	delete(name)
	_, _, again := task_pomodoro_take(&app)
	testing.expect(t, !again, "the notification is delivered once")
	testing.expect(t, task_pomodoro_remaining(&app, input.now) == -1)
}

@(test)
task_without_pomodoro_never_due :: proc(t: ^testing.T) {
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	app := App{db = db}
	defer db_close(&app.db)
	start, _ := day_bounds_ms(20261106)
	start += 3_600_000
	input := Tracker_Test_Input{now = start}
	app.tracker.io = Tracker_IO{data = &input, monotonic = tracker_test_now}
	testing.expect(t, task_start(&app, 0, "Plain", start))
	defer task_clear(&app.task)
	input.now = start + 3_600_000 // an hour in: no deadline, so never "due"
	testing.expect(t, task_tick(&app, input.now))
	testing.expect(t, app.task.id != 0 && !app.pomo_done.pending)
	testing.expect(t, task_pomodoro_remaining(&app, input.now) == -1)
}

@(test)
task_stops_at_neighbor :: proc(t: ^testing.T) {
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	app := App{db = db}
	defer db_close(&app.db)
	start, _ := day_bounds_ms(20261106)
	input := Tracker_Test_Input{now = start}
	app.tracker.io = Tracker_IO{data = &input, monotonic = tracker_test_now}
	group := db_ensure_tag(&app.db, "Scheduled")
	_, inserted := db_insert_activity(&app.db, TIMELINE_TAGS, "Scheduled", group, start + 5000, start + 10000)
	testing.expect(t, inserted == .Ok)
	testing.expect(t, task_start(&app, 0, "Live", start))
	id := app.task.id
	input.now = start + 6000
	testing.expect(t, task_tick(&app, input.now))
	testing.expect(t, app.task.id == 0, "Task stops rather than overlapping an existing block")
	rows, result := db_load_activities(&app.db, 20261106)
	testing.expect(t, result == .Ok)
	defer free_activities(rows)
	for a in rows {
		if a.id == id { testing.expect(t, a.end_ms == start + 5000) }
	}
}
