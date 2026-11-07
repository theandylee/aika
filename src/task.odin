package main

import "core:strings"

// A task owns one ordinary Tags activity. Persist at 1 Hz; a crash loses at
// most the last second, and graceful exit saves the exact final endpoint.
RunningTask :: struct {
	id, start_ms, end_ms: i64,
	last_wall, last_mono, save_mono: i64,
	group_id: i64,
	name: string,
	color: Argb,
}

task_clear :: proc(task: ^RunningTask) {
	delete(task.name)
	task^ = RunningTask{}
}

task_start :: proc(app: ^App, group_id: i64, name: string, start: i64) -> bool {
	if app.task.id != 0 { return false }
	block, result := db_start_task(&app.db, group_id, name, start)
	if result != .Ok { return false }
	mono := tracker_monotonic(app)
	app.task = RunningTask{id = block.id, start_ms = start, end_ms = start + 1,
		last_wall = start, last_mono = mono, save_mono = mono,
		group_id = block.group_id, name = strings.clone(name), color = block.color}
	cache_activity_write(app, Pending_Activity{id = block.id, timeline = TIMELINE_TAGS,
		group = block.group_id, title = name, group_name = name, color = block.color, start_ms = start, end_ms = start + 1})
	return true
}

task_tick :: proc(app: ^App, now: i64, force: bool = false) -> bool {
	task := &app.task
	if task.id == 0 { return true }
	mono := tracker_monotonic(app)
	if abs((now - task.last_wall) - (mono - task.last_mono)) > CLOCK_JUMP_TOLERANCE_MS {
		// A tag cannot be stretched across a wall-clock adjustment safely.
		// Stop at the last acknowledged endpoint; the user can start a new task.
		task_clear(task)
		return true
	}
	task.last_wall, task.last_mono = now, mono
	if now <= task.end_ms || (!force && mono - task.save_mono < TASK_SAVE_INTERVAL_MS) { return true }
	end, stopped, result := db_extend_task_until_boundary(&app.db, task.id, task.start_ms, now)
	if result != .Ok { return false }
	task.end_ms = end
	task.save_mono = mono
	cache_activity_write(app, Pending_Activity{id = task.id, timeline = TIMELINE_TAGS,
		group = task.group_id, title = task.name, group_name = task.name, color = task.color,
		start_ms = task.start_ms, end_ms = end})
	if stopped { task_clear(task) }
	return true
}

task_stop :: proc(app: ^App, now: i64) -> bool {
	if !task_tick(app, now, true) { return false }
	task_clear(&app.task)
	return true
}
