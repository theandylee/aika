package main

import "core:strings"

UsageKind :: enum {
	Active,
	Away,
	SessionLocked,
	PowerOff,
}

usage_display_name :: proc(kind: UsageKind) -> string {
	switch kind {
	case .Active:
		return "Active"
	case .Away:
		return "Away"
	case .SessionLocked:
		return "Session locked"
	case .PowerOff:
		return "Power off"
	}
	return "Active"
}

CurrentActivity :: struct {
	active:             bool,
	persisted_id:       i64,
	group_id:           i64,
	group_color:        u32,
	app_name:           string,
	title:              string,
	exe_path:           string,
	start_ms:           i64,
	last_db_update_ms:  i64,
}

Tracker :: struct {
	enabled:               bool,
	current:               CurrentActivity,
	usage_kind:            UsageKind,
	usage_id:              i64,
	usage_start_ms:        i64,
	usage_last_db_update:  i64,
	last_tick_ms:          i64,
	idle_threshold_ms:     i64,
}

App :: struct {
	db:             DB,
	tracker:        Tracker,
	date:           int,
	activities:     []Activity,
	loaded_date:    int,
	last_load_ms:   i64,
	db_path:        string,
	show_help:      bool,
}

clear_current :: proc(c: ^CurrentActivity) {
	if len(c.app_name) > 0 { delete(c.app_name) }
	if len(c.title) > 0 { delete(c.title) }
	if len(c.exe_path) > 0 { delete(c.exe_path) }
	c^ = CurrentActivity{}
}

start_usage :: proc(app: ^App, kind: UsageKind, start_ms: i64) {
	name := usage_display_name(kind)
	group_id := db_usage_group(&app.db, kind)
	app.tracker.usage_kind = kind
	app.tracker.usage_start_ms = start_ms
	app.tracker.usage_last_db_update = now_ms()
	app.tracker.usage_id = db_insert_activity(&app.db, TIMELINE_COMPUTER, name, group_id, start_ms, start_ms)
}

finish_usage :: proc(app: ^App, end_ms: i64) {
	if app.tracker.usage_id > 0 {
		db_update_activity_end(&app.db, app.tracker.usage_id, end_ms)
		app.tracker.usage_id = 0
	}
}

extend_usage :: proc(app: ^App, now: i64) {
	if app.tracker.usage_id > 0 && now - app.tracker.usage_last_db_update >= 10_000 {
		db_update_activity_end(&app.db, app.tracker.usage_id, now)
		app.tracker.usage_last_db_update = now
	}
}

start_new_current :: proc(app: ^App, group_id: i64, color: u32, app_name, title, exe_path: string, start_ms: i64) {
	// If this is the same app+title as the last persisted row, extend that row
	// instead of creating a new one. This handles quick switch-away-and-back.
	if last, ok := db_last_activity(&app.db, TIMELINE_APPS); ok {
		defer if len(last.display_name) > 0 { delete(last.display_name) }
		if last.group_id == group_id && last.display_name == title && start_ms - last.end_ms <= 1000 && start_ms >= last.start_ms {
			app.tracker.current = CurrentActivity{
				active = true,
				persisted_id = last.id,
				group_id = group_id,
				group_color = color,
				app_name = strings.clone(app_name),
				title = strings.clone(title),
				exe_path = strings.clone(exe_path),
				start_ms = last.start_ms,
				last_db_update_ms = now_ms(),
			}
			db_update_activity_end(&app.db, last.id, start_ms)
			return
		}
	}

	app.tracker.current = CurrentActivity{
		active = true,
		group_id = group_id,
		group_color = color,
		app_name = strings.clone(app_name),
		title = strings.clone(title),
		exe_path = strings.clone(exe_path),
		start_ms = start_ms,
	}
}

// Returns the time at which the next activity should start. If a very short
// activity is discarded, this is the discarded activity's start (backdating).
finish_current :: proc(app: ^App, end_ms: i64, force_save: bool) -> i64 {
	c := &app.tracker.current
	if !c.active {
		return end_ms
	}
	duration := end_ms - c.start_ms
	next_start := end_ms

	if c.persisted_id == 0 {
		if duration < 5000 && !force_save {
			next_start = c.start_ms
			clear_current(c)
			return next_start
		}
		if duration > 0 {
			c.persisted_id = db_insert_activity(&app.db, TIMELINE_APPS, c.title, c.group_id, c.start_ms, end_ms)
			c.last_db_update_ms = now_ms()
		}
	} else {
		db_update_activity_end(&app.db, c.persisted_id, end_ms)
	}
	clear_current(c)
	return next_start
}

extend_current :: proc(app: ^App, now: i64) {
	c := &app.tracker.current
	if !c.active {
		return
	}
	if c.persisted_id == 0 {
		if now - c.start_ms >= 5000 {
			c.persisted_id = db_insert_activity(&app.db, TIMELINE_APPS, c.title, c.group_id, c.start_ms, now)
			c.last_db_update_ms = now
		}
	} else if now - c.last_db_update_ms >= 10_000 {
		db_update_activity_end(&app.db, c.persisted_id, now)
		c.last_db_update_ms = now
	}
}

poll_focus :: proc(app: ^App, now: i64) {
	info, ok := get_foreground_window_info()
	if !ok {
		return
	}

	name := info.product
	if name == "" {
		name = strip_extension(info.file_name)
	}
	if name == "" {
		name = "Unknown"
	}

	title := info.title
	if title == "" {
		title = name
	}

	key := make_group_key(info.file_name, info.product)
	hash := key_hash(key)
	text_data := make_group_text_data(info.file_name, name, info.company, info.path, info.description)
	group_id, color := db_ensure_group(&app.db, TIMELINE_APPS, hash, name, text_data)
	if group_id == 0 {
		return
	}

	c := &app.tracker.current
	if c.active && c.group_id == group_id && c.title == title {
		extend_current(app, now)
		return
	}

	next_start := now
	if c.active {
		next_start = finish_current(app, now, false)
	}
	start_new_current(app, group_id, color, name, title, info.path, next_start)
	extend_current(app, now)
}

tracker_init :: proc(app: ^App) {
	app.tracker.enabled = true
	app.tracker.idle_threshold_ms = 10 * 60 * 1000
	app.tracker.last_tick_ms = 0
	now := now_ms()
	start_usage(app, .Active, now)
	poll_focus(app, now)
}

tracker_tick :: proc(app: ^App, now: i64) {
	t := &app.tracker
	if !t.enabled {
		return
	}
	if now - t.last_tick_ms < 1000 {
		return
	}
	t.last_tick_ms = now

	idle := idle_ms()
	desired: UsageKind = .Away if idle >= t.idle_threshold_ms else .Active

	if desired != t.usage_kind {
		if desired == .Away {
			transition := now - t.idle_threshold_ms
			if transition < t.usage_start_ms {
				transition = now
			}
			finish_current(app, transition, false)
			finish_usage(app, transition)
			start_usage(app, .Away, transition)
		} else {
			finish_usage(app, now)
			start_usage(app, .Active, now)
			poll_focus(app, now)
		}
		return
	}

	switch t.usage_kind {
	case .Active:
		poll_focus(app, now)
		extend_current(app, now)
		extend_usage(app, now)
	case .Away, .SessionLocked, .PowerOff:
		extend_usage(app, now)
	}
}

tracker_pause :: proc(app: ^App) {
	if !app.tracker.enabled {
		return
	}
	now := now_ms()
	finish_current(app, now, true)
	finish_usage(app, now)
	app.tracker.enabled = false
}

tracker_resume :: proc(app: ^App) {
	if app.tracker.enabled {
		return
	}
	now := now_ms()
	app.tracker.enabled = true
	app.tracker.last_tick_ms = 0
	start_usage(app, .Active, now)
	poll_focus(app, now)
}

tracker_shutdown :: proc(app: ^App) {
	now := now_ms()
	finish_current(app, now, true)
	finish_usage(app, now)
}

// --- UI helpers on the tracker ---

current_is_today :: proc(app: ^App) -> bool {
	return app.tracker.current.active && date_int_from_unix_ms(app.tracker.current.start_ms) == app.date
}

current_usage_is_today :: proc(app: ^App) -> bool {
	return app.tracker.usage_id > 0 && date_int_from_unix_ms(app.tracker.usage_start_ms) == app.date
}
