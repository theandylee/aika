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
	// Pomodoro: pomo_ms > 0 makes the task stop itself pomo_ms after it started,
	// measured on the monotonic clock (pomo_deadline_mono).
	pomo_ms, pomo_deadline_mono: i64,
}

// A pomodoro that ran to completion. app_tick shows its notification once.
Pomodoro_Done :: struct {
	pending: bool,
	name: string, // owned
	minutes: i64,
}

task_clear :: proc(task: ^RunningTask) {
	delete(task.name)
	task^ = RunningTask{}
}

// Hands the finished pomodoro to the caller, who owns (and deletes) the name.
task_pomodoro_take :: proc(app: ^App) -> (name: string, minutes: i64, ok: bool) {
	done := &app.pomo_done
	if !done.pending { return }
	name, minutes, ok = done.name, done.minutes, true
	done^ = Pomodoro_Done{}
	return
}

task_pomodoro_finish :: proc(app: ^App) {
	done := &app.pomo_done
	delete(done.name)
	done^ = Pomodoro_Done{pending = true, name = app.task.name, minutes = app.task.pomo_ms / MS_PER_MINUTE}
	app.task.name = "" // ownership moved
	task_clear(&app.task)
}

// Milliseconds left on a running pomodoro, or -1 for a task without one.
task_pomodoro_remaining :: proc(app: ^App, mono: i64) -> i64 {
	task := &app.task
	if task.id == 0 || task.pomo_ms <= 0 { return -1 }
	return max(task.pomo_deadline_mono - mono, 0)
}

task_start :: proc(app: ^App, group_id: i64, name: string, start: i64, pomodoro_ms: i64 = 0) -> bool {
	picks := [1]Tag_Pick{{group_id, name}}
	return task_start_picks(app, picks[:], start, pomodoro_ms)
}

// Starts a task carrying one or more distinct tags; its title is the joined names.
// pomodoro_ms > 0 makes it a pomodoro that stops itself after that long.
task_start_picks :: proc(app: ^App, picks: []Tag_Pick, start: i64, pomodoro_ms: i64 = 0) -> bool {
	if app.task.id != 0 || len(picks) == 0 { return false }
	block, result := db_start_task_multi(&app.db, picks, start)
	if result != .Ok { return false }
	name := picks[0].name
	if len(picks) > 1 {
		names := make([]string, len(picks), context.temp_allocator)
		for p, i in picks { names[i] = p.name }
		name = strings.join(names, ", ", context.temp_allocator)
	}
	mono := tracker_monotonic(app)
	app.task = RunningTask{id = block.id, start_ms = start, end_ms = start + 1,
		last_wall = start, last_mono = mono, save_mono = mono,
		group_id = block.group_id, name = strings.clone(name), color = block.color,
		pomo_ms = max(pomodoro_ms, 0), pomo_deadline_mono = mono + max(pomodoro_ms, 0)}
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
	// A pomodoro that reached its deadline saves exactly start + duration, however
	// late this tick runs, and then stops.
	due := task.pomo_ms > 0 && mono >= task.pomo_deadline_mono
	target := now
	if due { target = min(now, task.start_ms + task.pomo_ms) }
	if target > task.end_ms && (force || due || mono - task.save_mono >= TASK_SAVE_INTERVAL_MS) {
		end, stopped, result := db_extend_task_until_boundary(&app.db, task.id, task.start_ms, target)
		if result != .Ok { return false }
		task.end_ms = end
		task.save_mono = mono
		cache_activity_write(app, Pending_Activity{id = task.id, timeline = TIMELINE_TAGS,
			group = task.group_id, title = task.name, group_name = task.name, color = task.color,
			start_ms = task.start_ms, end_ms = end})
		if stopped { task_clear(task); return true } // ran into another block: not a completed pomodoro
	}
	if due { task_pomodoro_finish(app) }
	return true
}

task_stop :: proc(app: ^App, now: i64) -> bool {
	if !task_tick(app, now, true) { return false }
	task_clear(&app.task)
	return true
}
