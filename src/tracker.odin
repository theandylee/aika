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
	io:                    Tracker_IO,
	enabled:               bool,
	current:               CurrentActivity,
	usage_kind:            UsageKind,
	usage_id:              i64,
	usage_active:          bool,
	usage_start_ms:        i64,
	usage_last_db_update:  i64,
	last_tick_ms:          i64,
	idle_threshold_ms:     i64,
	pending:               [TRACKER_PENDING_LIMIT]Pending_Activity,
	pending_count:         int,
	pending_result, current_result, usage_result, focus_result: DB_Result,
	retry_paused:          bool,
}

App :: struct {
	db:             DB,
	tracker:        Tracker,
	task:           RunningTask,
	date:           int,
	activities:     []Activity,
	loaded_date:    int,
	last_load_ms:   i64,
	last_load_attempt_ms: i64,
	load_result:    DB_Result,
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
	app.tracker.usage_active = true
	app.tracker.usage_kind = kind
	app.tracker.usage_start_ms = start_ms
	app.tracker.usage_id = 0
	app.tracker.usage_last_db_update = 0
	extend_usage(app, start_ms)
}

finish_usage :: proc(app: ^App, end_ms: i64) {
	t := &app.tracker
	if !t.usage_active { return }
	write := Pending_Activity{id = t.usage_id, timeline = TIMELINE_COMPUTER,
		start_ms = t.usage_start_ms, end_ms = end_ms,
		title = usage_display_name(t.usage_kind), usage_kind = t.usage_kind}
	result := tracker_write(app, &write)
	if result != .Ok { tracker_queue(app, write, result) }
	t.usage_active = false
	t.usage_id = 0
	t.usage_result = .Ok // pending queue now owns any failed final write
}

extend_usage :: proc(app: ^App, now: i64) {
	t := &app.tracker
	if !t.usage_active { return }
	if t.usage_id > 0 && now - t.usage_last_db_update < 10_000 { return }
	write := Pending_Activity{id = t.usage_id, timeline = TIMELINE_COMPUTER,
		start_ms = t.usage_start_ms, end_ms = now,
		title = usage_display_name(t.usage_kind), usage_kind = t.usage_kind}
	t.usage_result = tracker_write(app, &write)
	if t.usage_result == .Ok {
		t.usage_id = write.id
		t.usage_last_db_update = now
	}
}

start_new_current :: proc(app: ^App, group_id: i64, color: u32, app_name, title, exe_path: string, start_ms: i64) {
	// If this is the same app+title as the last persisted row, extend that row
	// instead of creating a new one. This handles quick switch-away-and-back.
	last, result := db_last_activity(&app.db, TIMELINE_APPS)
	if result != .Ok && result != .Not_Found { app.tracker.focus_result = result }
	if result == .Ok {
		defer if len(last.display_name) > 0 { delete(last.display_name) }
		if app.tracker.pending_count == 0 && last.group_id == group_id && last.display_name == title && start_ms - last.end_ms <= 1000 && start_ms >= last.start_ms {
			app.tracker.current = CurrentActivity{
				active = true,
				persisted_id = last.id,
				group_id = group_id,
				group_color = color,
				app_name = strings.clone(app_name),
				title = strings.clone(title),
				exe_path = strings.clone(exe_path),
				start_ms = last.start_ms,
				last_db_update_ms = last.end_ms,
			}
			app.tracker.current_result = tracker_update_end(app, last.id, start_ms)
			if app.tracker.current_result == .Ok {
				app.tracker.current.last_db_update_ms = tracker_now(app)
			}
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

	if c.persisted_id == 0 && duration < 5000 && !force_save {
		next_start = c.start_ms
		clear_current(c)
		app.tracker.current_result = .Ok
		return next_start
	}
	if c.persisted_id > 0 || duration > 0 {
		write := Pending_Activity{id = c.persisted_id, timeline = TIMELINE_APPS,
			group = c.group_id, title = c.title, start_ms = c.start_ms, end_ms = end_ms}
		result := tracker_write(app, &write)
		if result != .Ok { tracker_queue(app, write, result) }
	}
	app.tracker.current_result = .Ok
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
			id, result := tracker_insert(app, TIMELINE_APPS, c.title, c.group_id, c.start_ms, now)
			app.tracker.current_result = result
			if result == .Ok {
				c.persisted_id = id
				c.last_db_update_ms = now
			}
		}
	} else if now - c.last_db_update_ms >= 10_000 {
		app.tracker.current_result = tracker_update_end(app, c.persisted_id, now)
		if app.tracker.current_result == .Ok { c.last_db_update_ms = now }
	}
}

poll_focus :: proc(app: ^App, now: i64) {
	info, ok := tracker_foreground(app)
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
	group_id, color, result := db_ensure_group(&app.db, TIMELINE_APPS, hash, name, text_data)
	app.tracker.focus_result = result
	if result != .Ok {
		return
	}

	c := &app.tracker.current
	if c.active && c.group_id == group_id && c.title == title {
		return
	}

	next_start := now
	if c.active {
		next_start = finish_current(app, now, false)
	}
	start_new_current(app, group_id, color, name, title, info.path, next_start)
}

tracker_init :: proc(app: ^App) {
	app.tracker.enabled = true
	app.tracker.idle_threshold_ms = i64(settings_load_minutes(app.db_path)) * 60_000
	app.tracker.last_tick_ms = 0
	now := tracker_now(app)
	start_usage(app, .Active, now)
	poll_focus(app, now)
}

tracker_tick :: proc(app: ^App, now: i64) {
	t := &app.tracker
	if now - t.last_tick_ms < 1000 {
		return
	}
	t.last_tick_ms = now
	tracker_retry(app)
	if t.retry_paused && t.pending_count == 0 {
		t.retry_paused = false
		tracker_resume(app)
	}
	if !t.enabled { return }
	// Reserve enough space to finish both live intervals, even on shutdown
	// immediately after a failed transition. A prolonged outage cannot grow RAM
	// indefinitely. Sampling resumes with new intervals only after recovery.
	if t.pending_count >= TRACKER_PENDING_LIMIT - 4 {
		tracker_pause(app)
		t.retry_paused = true
		return
	}

	idle := tracker_idle(app)
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
	now := tracker_now(app)
	finish_current(app, now, true)
	finish_usage(app, now)
	app.tracker.enabled = false
}

tracker_resume :: proc(app: ^App) {
	if app.tracker.enabled {
		return
	}
	if app.tracker.pending_count >= TRACKER_PENDING_LIMIT - 4 {
		app.tracker.retry_paused = true
		return
	}
	now := tracker_now(app)
	app.tracker.enabled = true
	app.tracker.retry_paused = false
	app.tracker.last_tick_ms = 0
	start_usage(app, .Active, now)
	poll_focus(app, now)
}

tracker_shutdown :: proc(app: ^App) -> bool {
	now := tracker_now(app)
	finish_current(app, now, true)
	finish_usage(app, now)
	app.tracker.enabled = false
	tracker_retry(app, TRACKER_PENDING_LIMIT)
	return app.tracker.pending_count == 0
}

// --- UI helpers on the tracker ---

current_is_today :: proc(app: ^App) -> bool {
	return app.tracker.current.active && date_int_from_unix_ms(app.tracker.current.start_ms) == app.date
}

current_usage_is_today :: proc(app: ^App) -> bool {
	return app.tracker.usage_id > 0 && date_int_from_unix_ms(app.tracker.usage_start_ms) == app.date
}
