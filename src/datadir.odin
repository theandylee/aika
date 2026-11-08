package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/windows"

// Where aika keeps its database and the sidecar files beside it (.settings,
// .theme). The default is %LOCALAPPDATA%\aika. A custom folder is remembered in
// a one-line pointer file that always lives in the default folder, because the
// custom folder cannot say where it is itself. `--db` overrides everything.

foreign import aika_shell "system:shell32.lib"

Browse_Info :: struct {
	owner:        windows.HWND,
	root:         rawptr,
	display_name: windows.LPWSTR,
	title:        windows.LPCWSTR,
	flags:        u32,
	callback:     proc "system" (hwnd: windows.HWND, msg: u32, lp: windows.LPARAM, data: windows.LPARAM) -> i32,
	lparam:       windows.LPARAM,
	image:        i32,
}

@(default_calling_convention = "system")
foreign aika_shell {
	SHBrowseForFolderW :: proc(info: ^Browse_Info) -> rawptr ---
	SHGetPathFromIDListW :: proc(pidl: rawptr, path: windows.LPWSTR) -> windows.BOOL ---
}

BIF_RETURNONLYFSDIRS :: 0x0001
BIF_EDITBOX          :: 0x0010
BIF_NEWDIALOGUI      :: 0x0040
BFFM_INITIALIZED     :: 1
BFFM_SETSELECTIONW   :: 0x0467

DATA_DB_NAME :: "aika.db"
DATA_POINTER_NAME :: "data-folder.txt"

// Files that belong to one database; "-wal"/"-shm" only exist after an unclean
// close, but a WAL carries committed rows, so it travels with the database.
DATA_SUFFIXES :: [5]string{"", "-wal", "-shm", ".settings", ".theme"}

// Set by --db: the data folder is then fixed for this run.
db_path_overridden := false

datadir_norm :: proc(path: string) -> string {
	p, _ := strings.replace_all(strings.trim_space(path), "/", "\\", context.temp_allocator)
	for len(p) > 3 && strings.has_suffix(p, "\\") { p = p[:len(p) - 1] }
	return p
}

datadir_is_abs :: proc(path: string) -> bool {
	if strings.has_prefix(path, "\\\\") { return len(path) > 2 }
	return len(path) >= 3 && path[1] == ':' && path[2] == '\\'
}

datadir_default :: proc() -> string {
	buf: [2048]u16
	n := windows.GetEnvironmentVariableW(wtext("LOCALAPPDATA"), &buf[0], u32(len(buf)))
	if n == 0 || int(n) >= len(buf) { return "data" }
	base, err := windows.utf16_to_utf8(buf[:n], context.temp_allocator)
	if err != nil { return "data" }
	return fmt.tprintf("%s\\aika", datadir_norm(base))
}

datadir_pointer_path :: proc() -> string {
	return fmt.tprintf("%s\\%s", datadir_default(), DATA_POINTER_NAME)
}

// The custom folder, or "" when the default is in use.
datadir_configured :: proc() -> string {
	data, err := os.read_entire_file(datadir_pointer_path(), context.temp_allocator)
	if err != nil { return "" }
	dir := datadir_norm(string(data))
	return dir if datadir_is_abs(dir) else ""
}

datadir_resolve :: proc() -> string {
	if dir := datadir_configured(); dir != "" { return dir }
	return datadir_default()
}

datadir_exists :: proc(path: string) -> bool {
	return windows.GetFileAttributesW(wtext(path)) != windows.INVALID_FILE_ATTRIBUTES
}

datadir_is_dir :: proc(path: string) -> bool {
	attrs := windows.GetFileAttributesW(wtext(path))
	return attrs != windows.INVALID_FILE_ATTRIBUTES && attrs & windows.FILE_ATTRIBUTE_DIRECTORY != 0
}

// Creates `dir` and any missing parents.
datadir_make :: proc(dir: string) -> bool {
	for i in 3 ..< len(dir) {
		if dir[i] == '\\' { windows.CreateDirectoryW(wtext(dir[:i]), nil) }
	}
	windows.CreateDirectoryW(wtext(dir), nil)
	return datadir_is_dir(dir)
}

datadir_writable :: proc(dir: string) -> bool {
	probe := fmt.tprintf("%s\\.aika-write-test", dir)
	if os.write_entire_file(probe, []u8{'x'}) != nil { return false }
	os.remove(probe)
	return true
}

// Records the choice; the default folder is represented by no pointer at all.
datadir_set_pointer :: proc(dir: string) -> bool {
	def := datadir_default()
	if !datadir_make(def) { return false }
	path := datadir_pointer_path()
	if strings.equal_fold(datadir_norm(dir), def) {
		return windows.DeleteFileW(wtext(path)) == windows.TRUE || !datadir_exists(path)
	}
	return os.write_entire_file(path, transmute([]u8)fmt.tprintf("%s\n", datadir_norm(dir))) == nil
}

// Normalized absolute folder holding the open database.
datadir_current :: proc(app: ^App) -> string {
	dir := filepath.dir(app.db_path)
	if abs, err := filepath.abs(dir, context.temp_allocator); err == nil { dir = abs }
	return datadir_norm(dir)
}

Data_Switch_Result :: enum {
	Ok,
	Unusable_Folder,
	Has_Data,
	Pointer_Failed,
	Flush_Failed,
	Copy_Failed,
	Open_Failed,
}

datadir_reopen :: proc(app: ^App, path: string) -> bool {
	db, ok := db_open(path)
	if !ok { return false }
	app.db = db
	// A GUI operation must not sleep for the CLI/import busy timeout.
	sqlite3_busy_timeout(app.db.handle, 0)
	return true
}

// Tracking restarts from scratch, exactly like at startup: group ids are
// per-database, so nothing may carry over from the previous connection.
datadir_restart_tracking :: proc(app: ^App) {
	tracker_release(&app.tracker)
	tracker_init(app)
	load_day(app)
}

// Switches the live database to `new_dir`, optionally copying the existing
// files first. Originals are deleted only after the new database opened, so any
// failure leaves the old location intact and in use.
datadir_switch :: proc(app: ^App, new_dir: string, move: bool, remember := true) -> Data_Switch_Result {
	new_path := fmt.tprintf("%s\\%s", new_dir, DATA_DB_NAME)
	if !datadir_make(new_dir) || !datadir_writable(new_dir) { return .Unusable_Folder }
	if move && datadir_exists(new_path) { return .Has_Data }

	// `remember` is false only in tests, which must not touch the user's pointer.
	previous := datadir_configured()
	if remember && !datadir_set_pointer(new_dir) { return .Pointer_Failed }
	switched := false
	defer if remember && !switched { datadir_set_pointer(previous if previous != "" else datadir_default()) }

	if !task_stop(app, now_ms()) || !tracker_shutdown(app) {
		tracker_resume(app)
		return .Flush_Failed
	}
	old_path := strings.clone(app.db_path, context.temp_allocator)
	db_exec(&app.db, "PRAGMA wal_checkpoint(TRUNCATE)")
	db_close(&app.db)

	suffixes := DATA_SUFFIXES
	copied: [len(DATA_SUFFIXES)]bool
	drop_copies :: proc(path: string, copied: [len(DATA_SUFFIXES)]bool) {
		suffixes := DATA_SUFFIXES
		for suffix, i in suffixes {
			if copied[i] { windows.DeleteFileW(wtext(fmt.tprintf("%s%s", path, suffix))) }
		}
	}
	if move {
		for suffix, i in suffixes {
			src := fmt.tprintf("%s%s", old_path, suffix)
			if !datadir_exists(src) { continue }
			if windows.CopyFileW(wtext(src), wtext(fmt.tprintf("%s%s", new_path, suffix)), windows.TRUE) == windows.FALSE {
				drop_copies(new_path, copied)
				datadir_reopen(app, old_path)
				datadir_restart_tracking(app)
				return .Copy_Failed
			}
			copied[i] = true
		}
	}
	if !datadir_reopen(app, new_path) {
		drop_copies(new_path, copied)
		datadir_reopen(app, old_path)
		datadir_restart_tracking(app)
		return .Open_Failed
	}
	switched = true
	delete(app.db_path)
	app.db_path = strings.clone(new_path)
	if move { drop_copies(old_path, copied) }
	datadir_restart_tracking(app)
	return .Ok
}

browse_callback :: proc "system" (hwnd: windows.HWND, msg: u32, lp: windows.LPARAM, data: windows.LPARAM) -> i32 {
	if msg == BFFM_INITIALIZED && data != 0 { windows.SendMessageW(hwnd, BFFM_SETSELECTIONW, 1, data) }
	return 0
}

// Native folder picker; `initial` preselects a folder when it exists.
datadir_browse :: proc(owner: windows.HWND, initial: string) -> (path: string, ok: bool) {
	windows.CoInitializeEx(nil, .APARTMENTTHREADED)
	display: [windows.MAX_PATH]u16
	info := Browse_Info{owner = owner, display_name = &display[0], title = wtext("Choose where aika keeps its data"),
		flags = BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGUI | BIF_EDITBOX, callback = browse_callback}
	if datadir_is_dir(initial) { info.lparam = windows.LPARAM(uintptr(rawptr(wtext(initial)))) }
	pidl := SHBrowseForFolderW(&info)
	if pidl == nil { return }
	defer windows.CoTaskMemFree(pidl)
	buf: [windows.MAX_PATH]u16
	if SHGetPathFromIDListW(pidl, &buf[0]) == windows.FALSE { return }
	text, err := windows.wstring_to_utf8(windows.wstring(&buf[0]), -1, context.temp_allocator)
	if err != nil { return }
	return datadir_norm(text), true
}
