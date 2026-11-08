package main

import "core:fmt"
import "core:os"
import "core:testing"
import "core:sys/windows"

datadir_test_root :: proc(name: string) -> string {
	buf: [1024]u16
	n := windows.GetTempPathW(u32(len(buf)), cstring16(&buf[0]))
	base, _ := windows.utf16_to_utf8(buf[:n], context.temp_allocator)
	return datadir_norm(fmt.tprintf("%saika-datadir-%s-%d", base, name, now_ms()))
}

datadir_test_clear :: proc(root: string) {
	for dir in ([2]string{"old", "new"}) {
		for file in datadir_files(fmt.tprintf("%s\\%s\\%s", root, dir, DATA_DB_NAME)) {
			os.remove(file)
		}
		os.remove(fmt.tprintf("%s\\%s", root, dir))
	}
	os.remove(root)
}

@(test)
datadir_switch_moves_database_and_settings :: proc(t: ^testing.T) {
	input: Tracker_Test_Input
	root := datadir_test_root("move")
	defer datadir_test_clear(root)
	old_path := fmt.tprintf("%s\\old\\%s", root, DATA_DB_NAME)
	new_dir := fmt.tprintf("%s\\new", root)
	testing.expect(t, datadir_make(fmt.tprintf("%s\\old", root)))

	app, _ := tracker_test_app(&input)
	db_close(&app.db)
	db, ok := db_open(old_path)
	testing.expect(t, ok)
	if !ok { return }
	app.db = db
	app.db_path = fmt.aprintf("%s", old_path)
	defer { db_close(&app.db); tracker_release(&app.tracker); free_activities(app.activities); delete(app.db_path) }
	testing.expect(t, settings_save_current(old_path, 7))
	tracker_init(&app)
	testing.expect(t, app.tracker.idle_threshold_ms == 7 * MS_PER_MINUTE)

	// Refuses to overwrite a database that is already there.
	testing.expect(t, datadir_make(new_dir))
	new_path := fmt.tprintf("%s\\%s", new_dir, DATA_DB_NAME)
	testing.expect(t, os.write_entire_file(new_path, []u8{'x'}) == nil)
	testing.expect(t, datadir_switch(&app, new_dir, true, false) == .Has_Data)
	testing.expect(t, app.db_path == old_path)
	os.remove(new_path)

	result := datadir_switch(&app, new_dir, true, false)
	testing.expect_value(t, result, Data_Switch_Result.Ok)
	testing.expect(t, app.db_path == new_path)
	testing.expect(t, app.db.handle != nil)
	testing.expect(t, datadir_exists(new_path) && datadir_exists(settings_path(new_path)))
	testing.expect(t, !datadir_exists(old_path) && !datadir_exists(settings_path(old_path)),
		"A successful move removes the originals")
	testing.expect(t, app.tracker.idle_threshold_ms == 7 * MS_PER_MINUTE, "Settings travel with the database")
	testing.expect(t, app.tracker.enabled, "Tracking resumes on the new database")
}

@(test)
datadir_switch_without_move_keeps_old_files :: proc(t: ^testing.T) {
	input: Tracker_Test_Input
	root := datadir_test_root("keep")
	defer datadir_test_clear(root)
	old_path := fmt.tprintf("%s\\old\\%s", root, DATA_DB_NAME)
	new_dir := fmt.tprintf("%s\\new", root)
	testing.expect(t, datadir_make(fmt.tprintf("%s\\old", root)))

	app, _ := tracker_test_app(&input)
	db_close(&app.db)
	db, ok := db_open(old_path)
	testing.expect(t, ok)
	if !ok { return }
	app.db = db
	app.db_path = fmt.aprintf("%s", old_path)
	defer { db_close(&app.db); tracker_release(&app.tracker); free_activities(app.activities); delete(app.db_path) }
	tracker_init(&app)

	testing.expect_value(t, datadir_switch(&app, new_dir, false, false), Data_Switch_Result.Ok)
	new_path := fmt.tprintf("%s\\%s", new_dir, DATA_DB_NAME)
	testing.expect(t, app.db_path == new_path && datadir_exists(new_path))
	testing.expect(t, datadir_exists(old_path), "Not moving leaves the old database untouched")
}

@(test)
datadir_norm_and_abs :: proc(t: ^testing.T) {
	testing.expect(t, datadir_norm(" C:/Users/x/aika/ ") == "C:\\Users\\x\\aika")
	testing.expect(t, datadir_norm("C:\\") == "C:\\")
	testing.expect(t, datadir_is_abs("C:\\data") && datadir_is_abs("\\\\srv\\share"))
	testing.expect(t, !datadir_is_abs("data") && !datadir_is_abs("data\\x") && !datadir_is_abs("C:data"))
}
