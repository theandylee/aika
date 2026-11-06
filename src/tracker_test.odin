package main

import "core:testing"

@(test)
tracker_one_minute_idle_threshold :: proc(t: ^testing.T) {
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	app := App{db = db}
	defer db_close(&app.db)
	tracker_init(&app)
	defer tracker_shutdown(&app)
	testing.expect(t, app.tracker.idle_threshold_ms == 60_000,
		"Keyboard/mouse inactivity must trigger Away after one minute")
}
