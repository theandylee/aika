package main

import "core:strings"

TRACKER_PENDING_LIMIT :: 256
TRACKER_RETRY_BATCH :: 4

Pending_Activity :: struct {
	id, timeline, group: i64,
	start_ms, end_ms: i64,
	title: string, // owned only while queued
	usage_kind: UsageKind, // resolve a missing usage group again on retry
}

tracker_write :: proc(app: ^App, write: ^Pending_Activity) -> DB_Result {
	if write.id > 0 { return tracker_update_end(app, write.id, write.end_ms) }
	if write.timeline == TIMELINE_COMPUTER && write.group == 0 {
		group, result := db_usage_group(&app.db, write.usage_kind)
		if result != .Ok { return result }
		write.group = group
	}
	id, result := tracker_insert(app, write.timeline, write.title, write.group, write.start_ms, write.end_ms)
	if result == .Ok { write.id = id }
	return result
}

tracker_queue :: proc(app: ^App, write: Pending_Activity, result: DB_Result) {
	t := &app.tracker
	// Tick/resume reserve space for both live intervals before accepting input.
	assert(t.pending_count < TRACKER_PENDING_LIMIT)
	owned := write
	owned.title = strings.clone(write.title)
	t.pending[t.pending_count] = owned
	t.pending_count += 1
	t.pending_result = result
}

tracker_retry :: proc(app: ^App, budget: int = TRACKER_RETRY_BATCH) {
	t := &app.tracker
	for _ in 0 ..< budget {
		if t.pending_count == 0 { break }
		result := tracker_write(app, &t.pending[0])
		if result != .Ok {
			t.pending_result = result
			return
		}
		delete(t.pending[0].title)
		copy(t.pending[:], t.pending[1:t.pending_count])
		t.pending_count -= 1
		t.pending[t.pending_count] = {}
	}
	if t.pending_count == 0 { t.pending_result = .Ok }
}

tracker_write_error :: proc(app: ^App) -> DB_Result {
	t := &app.tracker
	for result in ([4]DB_Result{t.pending_result, t.current_result, t.usage_result, t.focus_result}) {
		if result != .Ok { return result }
	}
	return .Ok
}

app_storage_status :: proc(app: ^App) -> string {
	if app.tracker.retry_paused { return "Tracking paused: save queue full; retrying" }
	if tracker_write_error(app) != .Ok || app.tracker.pending_count > 0 {
		return "Tracking save error: retrying; keep aika open"
	}
	if app.load_result != .Ok { return "Day load failed: showing last loaded data; retrying" }
	return ""
}
