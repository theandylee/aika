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
	testing.expect(t, task_start(&app, 0, "Development", start))
	id := app.task.id
	testing.expect(t, id > 0)
	testing.expect(t, !task_start(&app, 0, "Other", start))
	testing.expect(t, task_tick(&app, midnight + 2000))
	rows := db_load_activities(&app.db, 20261107)
	testing.expect(t, len(rows) == 1)
	if len(rows) == 1 {
		testing.expect(t, rows[0].id == id && rows[0].start_ms == start && rows[0].end_ms == midnight + 2000)
	}
	free_activities(rows)
	testing.expect(t, task_stop(&app, midnight + 2200))
	testing.expect(t, app.task.id == 0)
	last, found := db_last_activity(&app.db, TIMELINE_TAGS)
	testing.expect(t, found && last.id == id && last.end_ms == midnight + 2200)
	delete(last.display_name)
	testing.expect(t, !task_start(&app, 0, "Overlap", start + 1000))
	testing.expect(t, task_start(&app, 0, "Next", midnight + 3000))
	testing.expect(t, task_stop(&app, midnight + 3001), "Very short tasks are retained")
}

@(test)
task_stops_at_neighbor :: proc(t: ^testing.T) {
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	app := App{db = db}
	defer db_close(&app.db)
	start, _ := day_bounds_ms(20261106)
	group := db_ensure_tag(&app.db, "Scheduled")
	testing.expect(t, db_insert_activity(&app.db, TIMELINE_TAGS, "Scheduled", group, start + 5000, start + 10000) > 0)
	testing.expect(t, task_start(&app, 0, "Live", start))
	id := app.task.id
	testing.expect(t, task_tick(&app, start + 6000))
	testing.expect(t, app.task.id == 0, "Task stops rather than overlapping an existing block")
	rows := db_load_activities(&app.db, 20261106)
	defer free_activities(rows)
	for a in rows {
		if a.id == id { testing.expect(t, a.end_ms == start + 5000) }
	}
}
