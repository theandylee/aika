package main

import "core:strings"
import "core:sys/windows"
import "core:testing"

Focus_Test_Input :: struct {
	now, mono: i64,
	key: Process_Identity,
	hwnd: windows.HWND,
	title: string,
	info: WindowInfo,
	sample_ok, identity_ok, metadata_ok, fail_group: bool,
	samples, probes, reads, groups: int,
	metadata_key: Process_Identity,
}

focus_test_now :: proc(data: rawptr) -> i64 { return (^Focus_Test_Input)(data).now }
focus_test_mono :: proc(data: rawptr) -> i64 { return (^Focus_Test_Input)(data).mono }
focus_test_idle :: proc(data: rawptr) -> i64 { return 0 }
focus_test_sample :: proc(data: rawptr) -> (WindowInfo, bool) {
	i := (^Focus_Test_Input)(data)
	i.samples += 1
	return WindowInfo{hwnd = i.hwnd, pid = i.key.pid, title = i.title}, i.sample_ok
}
focus_test_identify :: proc(data: rawptr, pid: u32) -> (Process_Identity, bool) {
	i := (^Focus_Test_Input)(data)
	i.probes += 1
	return i.key, i.identity_ok
}
focus_test_metadata :: proc(data: rawptr, key: Process_Identity) -> (WindowInfo, bool) {
	i := (^Focus_Test_Input)(data)
	i.reads += 1
	i.metadata_key = key
	return i.info, i.metadata_ok
}
focus_test_group :: proc(data: rawptr, db: ^DB, hash, name, text: string) -> (i64, Argb, DB_Result) {
	i := (^Focus_Test_Input)(data)
	i.groups += 1
	if i.fail_group { return 0, 0, .Busy }
	return db_ensure_group(db, TIMELINE_APPS, hash, name, text)
}
focus_test_app :: proc(input: ^Focus_Test_Input) -> (App, bool) {
	db, ok := db_open(":memory:")
	input^ = Focus_Test_Input{now = 1_793_923_200_000, key = Process_Identity{pid = 11, created = 100},
		hwnd = windows.HWND(uintptr(1)), title = "Document", sample_ok = true, identity_ok = true, metadata_ok = true,
		info = WindowInfo{path = "C:\\Editor.exe", file_name = "Editor.exe", product = "Editor", company = "Company", description = "Description"}}
	app := App{db = db}
	app.tracker.io = Tracker_IO{data = input, now = focus_test_now, monotonic = focus_test_mono, idle = focus_test_idle,
		sample = focus_test_sample, identify = focus_test_identify, metadata = focus_test_metadata, ensure_focus_group = focus_test_group}
	return app, ok
}
focus_test_tick :: proc(app: ^App, input: ^Focus_Test_Input, elapsed: i64 = 1000) {
	input.now += elapsed
	input.mono += elapsed
	tracker_tick(app, input.now)
}

@(test)
focus_cache_samples_title_pid_and_identity_on_every_tick :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	input: Focus_Test_Input
	app, ok := focus_test_app(&input)
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&app.db)
	defer tracker_release(&app.tracker)
	tracker_init(&app)
	defer tracker_shutdown(&app)
	group := app.tracker.current.group_id
	focus_test_tick(&app, &input, 5000)
	first := app.tracker.current.persisted_id
	input.hwnd, input.title = windows.HWND(uintptr(2)), "Other document"
	focus_test_tick(&app, &input)
	testing.expect(t, input.samples == 3 && input.probes == 3)
	testing.expect(t, input.reads == 1 && input.groups == 1)
	testing.expect(t, app.tracker.current.group_id == group && app.tracker.current.title == input.title)
	testing.expect(t, app.tracker.current.persisted_id == 0 && first > 0,
		"A fresh title in the same process still starts a new activity")
	input.now += 3600_000
	input.mono += 1000
	tracker_tick(&app, input.now)
	testing.expect(t, app.tracker.current.start_ms == input.now && input.reads == 1 && input.groups == 1,
		"Wall-clock jumps split activities without expiring the monotonic metadata cache")
}

@(test)
focus_cache_pid_reuse_and_process_switches_never_adopt_stale_metadata :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	input: Focus_Test_Input
	app, ok := focus_test_app(&input)
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&app.db)
	defer tracker_release(&app.tracker)
	tracker_init(&app)
	defer tracker_shutdown(&app)
	start, group := app.tracker.current.start_ms, app.tracker.current.group_id
	// Another instance of the same app is not another group or activity when
	// (group_id,title) is unchanged. PID/window identity is cache validation only.
	input.key = Process_Identity{pid = 22, created = 200}
	focus_test_tick(&app, &input)
	testing.expect(t, input.reads == 2 && input.groups == 2)
	testing.expect(t, app.tracker.current.group_id == group && app.tracker.current.start_ms == start)
	// Windows may reuse that PID for an unrelated executable.
	input.key.created = 300
	input.info = WindowInfo{path = "C:\\Browser.exe", file_name = "Browser.exe", product = "Browser"}
	focus_test_tick(&app, &input)
	testing.expect(t, input.reads == 3 && input.metadata_key == input.key)
	testing.expect(t, app.tracker.current.group_id != group && app.tracker.current.app_name == "Browser")
}

@(test)
focus_cache_failures_retry_without_pid_only_or_unknown_entries :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	input: Focus_Test_Input
	app, ok := focus_test_app(&input)
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&app.db)
	defer tracker_release(&app.tracker)
	tracker_init(&app)
	defer tracker_shutdown(&app)
	input.identity_ok, input.metadata_ok = false, false
	input.info = {}
	focus_test_tick(&app, &input)
	testing.expect(t, app.tracker.focus_cache.key.created == 0 && input.metadata_key.created == 0)
	testing.expect(t, app.tracker.current.app_name == "pid_11")
	focus_test_tick(&app, &input)
	testing.expect(t, input.reads == 3 && input.groups == 3, "Unverified fallbacks must be retried, not cached")
	// Identity succeeded but metadata failed (including a process-instance race).
	input.identity_ok = true
	focus_test_tick(&app, &input)
	testing.expect(t, input.metadata_key == input.key && app.tracker.focus_cache.key.created == 0)
	input.metadata_ok = true
	input.info = WindowInfo{path = "C:\\Recovered.exe", file_name = "Recovered.exe", product = "Recovered"}
	focus_test_tick(&app, &input)
	testing.expect(t, app.tracker.current.app_name == "Recovered" && input.reads == 5)
	focus_test_tick(&app, &input)
	testing.expect(t, input.reads == 5 && input.groups == 5)
	input.sample_ok = false // exited/destroyed foreground: no cached process is selected
	focus_test_tick(&app, &input)
	testing.expect(t, input.probes == 6 && input.reads == 5)
}

@(test)
focus_cache_group_failure_retries_group_not_metadata :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	input: Focus_Test_Input
	app, ok := focus_test_app(&input)
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&app.db)
	defer tracker_release(&app.tracker)
	input.fail_group = true
	tracker_init(&app)
	defer tracker_shutdown(&app)
	testing.expect(t, !app.tracker.current.active && app.tracker.focus_cache.group_id == 0)
	testing.expect(t, tracker_write_error(&app) == .Busy)
	input.fail_group = false
	focus_test_tick(&app, &input)
	testing.expect(t, app.tracker.current.active && tracker_write_error(&app) == .Ok)
	focus_test_tick(&app, &input)
	testing.expect(t, input.reads == 1 && input.groups == 2 && input.probes == 3)
}

@(test)
focus_cache_expiry_reloads_metadata_and_retries_failed_refresh :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	input: Focus_Test_Input
	app, ok := focus_test_app(&input)
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&app.db)
	defer tracker_release(&app.tracker)
	tracker_init(&app)
	defer tracker_shutdown(&app)
	input.info.product = "Updated product"
	focus_test_tick(&app, &input, FOCUS_CACHE_TTL_MS - 1000)
	testing.expect(t, input.reads == 1 && app.tracker.current.app_name == "Editor")
	input.metadata_ok = false
	focus_test_tick(&app, &input)
	testing.expect(t, input.reads == 2 && app.tracker.focus_cache.key.created == 0)
	input.metadata_ok = true
	focus_test_tick(&app, &input)
	testing.expect(t, input.reads == 3 && app.tracker.focus_cache.info.product == "Updated product")
	// Same process can observe a local color change on the next bounded refresh.
	testing.expect(t, db_exec(&app.db, `UPDATE "Group" SET Color=4279383126 WHERE TimelineId=3`))
	focus_test_tick(&app, &input, FOCUS_CACHE_TTL_MS)
	testing.expect(t, app.tracker.focus_cache.color == 4279383126 && input.reads == 4)
}

focus_test_warm_scratch :: proc(app: ^App, input: ^Focus_Test_Input) {
	scratch: Scratch
	context.temp_allocator = scratch_begin(&scratch)
	defer scratch_end(&scratch)
	input.info = WindowInfo{path = strings.clone("C:\\Editor.exe", context.temp_allocator),
		file_name = strings.clone("Editor.exe", context.temp_allocator), product = strings.clone("Editor", context.temp_allocator)}
	tracker_init(app)
}

@(test)
focus_cache_owns_metadata_and_has_repeatable_teardown :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	input: Focus_Test_Input
	app, ok := focus_test_app(&input)
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&app.db)
	defer tracker_release(&app.tracker)
	focus_test_warm_scratch(&app, &input)
	input.info = {} // Source strings' scratch has been destroyed.
	focus_test_tick(&app, &input)
	testing.expect(t, input.reads == 1 && app.tracker.focus_cache.info.path == "C:\\Editor.exe")
	testing.expect(t, strings.contains(app.tracker.focus_cache.text_data, "Editor.exe"))
	testing.expect(t, tracker_shutdown(&app))
	testing.expect(t, app.tracker.focus_cache.key.created == 0 && app.tracker.focus_cache.hash == "")
	focus_cache_clear(&app.tracker.focus_cache)
}

@(test)
focus_cache_group_ids_are_scoped_to_database_connection :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	input: Focus_Test_Input
	app, ok := focus_test_app(&input)
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&app.db)
	defer tracker_release(&app.tracker)
	tracker_init(&app)
	defer tracker_shutdown(&app)
	other, opened := db_open(":memory:")
	testing.expect(t, opened)
	if !opened { return }
	defer db_close(&other)
	old := app.db
	app.db = other
	info, available := tracker_foreground(&app)
	_, _, result := tracker_focus_group(&app, info)
	testing.expect(t, available && result == .Ok && input.reads == 1 && input.groups == 2)
	testing.expect(t, import_test_scalar(&other, `SELECT count(*) FROM "Group" WHERE TimelineId=3`) == 1)
	app.db = old
}

@(test)
focus_cache_legitimate_versionless_fallback_is_cacheable :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	input: Focus_Test_Input
	app, ok := focus_test_app(&input)
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&app.db)
	defer tracker_release(&app.tracker)
	input.info.product, input.info.company, input.info.description = "", "", ""
	input.title = ""
	tracker_init(&app)
	defer tracker_shutdown(&app)
	focus_test_tick(&app, &input)
	testing.expect(t, app.tracker.current.app_name == "Editor" && app.tracker.current.title == "Editor")
	testing.expect(t, input.reads == 1 && input.groups == 1 && input.probes == 2)
	testing.expect(t, focus_name(WindowInfo{file_name = ".exe"}) == "Unknown")
}

@(test)
focus_native_identity_and_metadata_reject_changed_creation_time :: proc(t: ^testing.T) {
	scratch: Scratch
	context.temp_allocator = scratch_begin(&scratch)
	defer scratch_end(&scratch)
	pid := u32(windows.GetCurrentProcessId())
	key, valid := query_process_identity(pid)
	testing.expect(t, valid && key.pid == pid && key.created != 0)
	if !valid { return }
	info, cacheable := query_process_metadata(key)
	testing.expect(t, cacheable && info.path != "" && info.file_name != "")
	wrong := key
	wrong.created += 1
	_, cacheable = query_process_metadata(wrong)
	testing.expect(t, !cacheable, "An instance change between validation and metadata read cannot populate the cache")
	_, valid = query_process_identity(0)
	testing.expect(t, !valid)
	_, _, _, cacheable = query_version_strings_result("C:\\aika-nonexistent-metadata-file-7b2e.exe")
	testing.expect(t, !cacheable, "I/O failure must not be mistaken for a legitimate absence of version resources")
}
