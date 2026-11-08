package main

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/windows"
import "core:thread"

// Self-updater. A background thread asks GitHub for the latest release; when it
// is newer than AIKA_VERSION the status bar shows an "Update to vX" label. A
// click downloads the release's `aika.exe` next to the running one, then the UI
// thread swaps the files (a running EXE can be renamed, not overwritten),
// starts the new copy with --wait-pid and exits. The new process waits for this
// one to die (single-instance mutex) and deletes the leftover `.old` file.
//
// Dev builds (AIKA_VERSION "dev") never check. All network/file work happens on
// worker threads; they only touch `updater` under its mutex and wake the UI
// thread with a posted message.

UPDATE_ASSET_NAME   :: "aika.exe"
UPDATE_API_URL      :: "https://api.github.com/repos/theandylee/aika/releases/latest"
UPDATE_FIRST_CHECK_MS :: i64(8_000)
UPDATE_INTERVAL_MS  :: i64(6 * 60 * 60 * 1000)
UPDATE_RETRY_MS     :: i64(30 * 60 * 1000)
UPDATE_MAX_JSON     :: 1 << 20
UPDATE_MAX_EXE      :: 256 << 20
UPDATE_WAIT_MS      :: 20_000

UPDATE_CHECKED    :: windows.WM_APP + 3 // worker -> UI: a check finished; repaint
UPDATE_DOWNLOADED :: windows.WM_APP + 4 // worker -> UI: download finished (wParam 1 = success)

Update_State :: enum { Idle, Checking, Available, Downloading }

Updater :: struct {
	mu:        sync.Mutex,
	state:     Update_State,
	latest:    string, // version without the leading "v"; heap-owned
	asset_url: string, // heap-owned
	asset_size: i64,
	next_check_ms: i64,
	started:   bool,
	on_start, periodic: bool, // set from settings (update_set_policy)
}

updater := Updater{on_start = true, periodic = true}

Release_Asset :: struct {
	name:                 string,
	size:                 i64,
	browser_download_url: string,
}

Release_Info :: struct {
	tag_name: string,
	assets:   []Release_Asset,
}

foreign import aika_winhttp "system:winhttp.lib"

@(default_calling_convention = "system")
foreign aika_winhttp {
	WinHttpOpen :: proc(agent: windows.LPCWSTR, access: u32, proxy, bypass: windows.LPCWSTR, flags: u32) -> rawptr ---
	WinHttpSetTimeouts :: proc(h: rawptr, resolve, connect, send, receive: i32) -> windows.BOOL ---
	WinHttpConnect :: proc(session: rawptr, server: windows.LPCWSTR, port: u16, reserved: u32) -> rawptr ---
	WinHttpOpenRequest :: proc(connect: rawptr, verb, path, version, referrer: windows.LPCWSTR, accept: rawptr, flags: u32) -> rawptr ---
	WinHttpSendRequest :: proc(req: rawptr, headers: windows.LPCWSTR, headers_len: u32, optional: rawptr, optional_len, total_len: u32, ctx: uintptr) -> windows.BOOL ---
	WinHttpReceiveResponse :: proc(req: rawptr, reserved: rawptr) -> windows.BOOL ---
	WinHttpQueryHeaders :: proc(req: rawptr, level: u32, name: windows.LPCWSTR, buf: rawptr, buf_len: ^u32, index: ^u32) -> windows.BOOL ---
	WinHttpReadData :: proc(req: rawptr, buf: rawptr, n: u32, read: ^u32) -> windows.BOOL ---
	WinHttpCloseHandle :: proc(h: rawptr) -> windows.BOOL ---
}

WINHTTP_FLAG_SECURE        :: u32(0x00800000)
WINHTTP_QUERY_STATUS_CODE  :: u32(19)
WINHTTP_QUERY_FLAG_NUMBER  :: u32(0x20000000)

// --- Version comparison ---

// Numeric dotted version ("v1.2.3", "1.2", "1.2.3-rc1" -> 1.2.3); ok = false when
// no leading number is found.
parse_version :: proc(s: string) -> (parts: [3]int, ok: bool) {
	rest := strings.trim_prefix(strings.trim_space(s), "v")
	for i in 0 ..< 3 {
		end := 0
		for end < len(rest) && rest[end] >= '0' && rest[end] <= '9' { end += 1 }
		if end == 0 { return parts, ok && i > 0 }
		n, _ := strconv.parse_int(rest[:end])
		parts[i] = n
		ok = true
		rest = rest[end:]
		if len(rest) == 0 || rest[0] != '.' { break }
		rest = rest[1:]
	}
	return
}

// True when `latest` is strictly newer than `current`; unparsable versions never update.
version_newer :: proc(latest, current: string) -> bool {
	a, ok_a := parse_version(latest)
	b, ok_b := parse_version(current)
	if !ok_a || !ok_b { return false }
	for i in 0 ..< 3 {
		if a[i] != b[i] { return a[i] > b[i] }
	}
	return false
}

// --- HTTP ---

// GET an https URL (redirects are followed by WinHTTP). The body goes to `out`
// when given, otherwise to the open file handle. Fails on non-200 or over `limit`.
http_get :: proc(url: string, out: ^[dynamic]u8, file: windows.HANDLE, limit: int) -> (written: int, ok: bool) {
	if !strings.has_prefix(url, "https://") { return }
	rest := url[len("https://"):]
	slash := strings.index_byte(rest, '/')
	if slash <= 0 { return }
	host, path := rest[:slash], rest[slash:]

	session := WinHttpOpen(wtext(fmt.tprintf("aika/%s", AIKA_VERSION)), 0, nil, nil, 0)
	if session == nil { return }
	defer WinHttpCloseHandle(session)
	WinHttpSetTimeouts(session, 10_000, 10_000, 30_000, 60_000)
	conn := WinHttpConnect(session, wtext(host), 443, 0)
	if conn == nil { return }
	defer WinHttpCloseHandle(conn)
	req := WinHttpOpenRequest(conn, wtext("GET"), wtext(path), nil, nil, nil, WINHTTP_FLAG_SECURE)
	if req == nil { return }
	defer WinHttpCloseHandle(req)

	headers := wtext("Accept: application/vnd.github+json")
	if !WinHttpSendRequest(req, headers, 0xFFFFFFFF, nil, 0, 0, 0) || !WinHttpReceiveResponse(req, nil) { return }
	status, size := u32(0), u32(size_of(u32))
	if !WinHttpQueryHeaders(req, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, nil, &status, &size, nil) || status != 200 {
		return
	}
	buf := make([]u8, 64 * 1024)
	defer delete(buf)
	for {
		n: u32
		if !WinHttpReadData(req, raw_data(buf), u32(len(buf)), &n) { return }
		if n == 0 { break }
		written += int(n)
		if written > limit { return }
		if out != nil {
			append(out, ..buf[:n])
		} else {
			done: u32
			if !windows.WriteFile(file, raw_data(buf), n, &done, nil) || done != n { return }
		}
	}
	return written, true
}

// --- Check ---

UPDATE_NEVER :: max(i64) // next_check_ms value meaning "nothing scheduled"

// Settings: check once shortly after launch, and/or re-check every
// UPDATE_INTERVAL_MS. Dev builds never check regardless.
update_policy :: proc() -> (on_start, periodic: bool) {
	sync.mutex_lock(&updater.mu)
	defer sync.mutex_unlock(&updater.mu)
	return updater.on_start, updater.periodic
}

// Changing the policy while running: switching periodic checks on schedules one
// right away, switching them off cancels the pending one. (on_start only matters
// at the next launch.)
update_set_policy :: proc(on_start, periodic: bool) {
	sync.mutex_lock(&updater.mu)
	defer sync.mutex_unlock(&updater.mu)
	if updater.started && periodic != updater.periodic {
		updater.next_check_ms = monotonic_ms() if periodic else UPDATE_NEVER
	}
	updater.on_start, updater.periodic = on_start, periodic
}

// Next check after one at `now`: only when periodic checks are on. Caller holds the mutex.
update_next_after :: proc(now: i64, delay: i64) -> i64 {
	return now + delay if updater.periodic else UPDATE_NEVER
}

// Called from the UI timer: starts a background check when one is due.
update_tick :: proc() {
	if AIKA_VERSION == "dev" { return }
	now := monotonic_ms()
	sync.mutex_lock(&updater.mu)
	defer sync.mutex_unlock(&updater.mu)
	if !updater.started {
		updater.started = true
		if updater.on_start {
			updater.next_check_ms = now + UPDATE_FIRST_CHECK_MS
		} else {
			updater.next_check_ms = update_next_after(now, UPDATE_INTERVAL_MS)
		}
	}
	if updater.state != .Idle || now < updater.next_check_ms { return }
	updater.state = .Checking
	updater.next_check_ms = update_next_after(now, UPDATE_INTERVAL_MS)
	thread.create_and_start(update_check_worker, self_cleanup = true)
}

update_check_worker :: proc() {
	defer free_all(context.temp_allocator)
	hwnd := ui.hwnd // read once; only used to post
	latest, url, size, result := update_fetch_latest()

	sync.mutex_lock(&updater.mu)
	switch result {
	case .Found:
		delete(updater.latest)
		delete(updater.asset_url)
		updater.latest, updater.asset_url, updater.asset_size = latest, url, size
		updater.state = .Available
	case .Up_To_Date:
		updater.state = .Idle
	case .Failed:
		updater.state = .Idle
		updater.next_check_ms = update_next_after(monotonic_ms(), UPDATE_RETRY_MS)
	}
	sync.mutex_unlock(&updater.mu)
	if hwnd != nil { windows.PostMessageW(hwnd, UPDATE_CHECKED, 0, 0) }
}

Fetch_Result :: enum { Failed, Up_To_Date, Found }

// Found = a newer release with an aika.exe asset exists (latest/url are then
// heap-owned by the caller).
update_fetch_latest :: proc() -> (latest, url: string, size: i64, result: Fetch_Result) {
	body: [dynamic]u8
	defer delete(body)
	if _, ok := http_get(UPDATE_API_URL, &body, nil, UPDATE_MAX_JSON); !ok { return }
	info: Release_Info
	if json.unmarshal(body[:], &info) != nil { return }
	defer {
		delete(info.tag_name)
		for a in info.assets { delete(a.name); delete(a.browser_download_url) }
		delete(info.assets)
	}
	result = .Up_To_Date
	if !version_newer(info.tag_name, AIKA_VERSION) { return }
	for a in info.assets {
		if a.name == UPDATE_ASSET_NAME && a.size > 0 && strings.has_prefix(a.browser_download_url, "https://") {
			return strings.clone(strings.trim_prefix(info.tag_name, "v")), strings.clone(a.browser_download_url), a.size, .Found
		}
	}
	return
}

// --- UI-facing state ---

// Label of the available update ("" when none); the caller formats text from it.
update_label :: proc() -> (label: string, state: Update_State) {
	sync.mutex_lock(&updater.mu)
	defer sync.mutex_unlock(&updater.mu)
	switch updater.state {
	case .Available:   return fmt.tprintf("Update to v%s", updater.latest), .Available
	case .Downloading: return "Updating...", .Downloading
	case .Idle, .Checking: return "", .Idle
	}
	return
}

// Clickable label just left of the version badge; empty when there is no update.
update_rect :: proc(w, h: i32) -> windows.RECT {
	label, state := update_label()
	if state == .Idle { return {} }
	v := version_rect(w, h)
	label_w := text_pixel_width(label, ui.font_bold)
	right := v.left
	return windows.RECT{right - label_w - 2 * dpi_px(VERSION_PAD), v.top, right, v.bottom}
}

update_clickable :: proc() -> bool {
	_, state := update_label()
	return state == .Available
}

draw_update :: proc(dc: windows.HDC, w, h: i32) {
	label, state := update_label()
	if state == .Idle { return }
	r := update_rect(w, h)
	hovered := state == .Available && ui.mouse_valid && rect_hit(r, ui.mouse.x, ui.mouse.y)
	color: Colorref = C_TXT if hovered else C_GREEN
	if state == .Downloading { color = C_DIM }
	draw_string(dc, label, r.left + dpi_px(VERSION_PAD), r.top + 4, ui.font_bold, color)
}

// --- Download + swap ---

update_exe_path :: proc() -> string {
	buf: [windows.MAX_PATH_WIDE]u16
	n := windows.GetModuleFileNameW(nil, &buf[0], u32(len(buf)))
	if n == 0 || n >= u32(len(buf)) { return "" }
	s, _ := windows.utf16_to_utf8(buf[:n], context.temp_allocator)
	return s
}

// Click on "Update to vX": download on a worker, finish in update_finish.
update_start :: proc() {
	sync.mutex_lock(&updater.mu)
	defer sync.mutex_unlock(&updater.mu)
	if updater.state != .Available { return }
	updater.state = .Downloading
	thread.create_and_start(update_download_worker, self_cleanup = true)
}

update_download_worker :: proc() {
	defer free_all(context.temp_allocator)
	hwnd := ui.hwnd
	sync.mutex_lock(&updater.mu)
	url, size := strings.clone(updater.asset_url), updater.asset_size
	sync.mutex_unlock(&updater.mu)
	defer delete(url)

	ok := false
	if exe := update_exe_path(); exe != "" {
		dest := fmt.tprintf("%s.new", exe)
		ok = update_download_file(url, dest, size)
		if !ok { windows.DeleteFileW(wtext(dest)) }
	}
	if hwnd != nil {
		windows.PostMessageW(hwnd, UPDATE_DOWNLOADED, windows.WPARAM(1 if ok else 0), 0)
	} else if !ok {
		update_reset_available()
	}
}

update_download_file :: proc(url, dest: string, size: i64) -> bool {
	file := windows.CreateFileW(wtext(dest), windows.GENERIC_WRITE, 0, nil, windows.CREATE_ALWAYS, windows.FILE_ATTRIBUTE_NORMAL, nil)
	if file == windows.INVALID_HANDLE_VALUE { return false }
	n, ok := http_get(url, nil, file, UPDATE_MAX_EXE)
	windows.CloseHandle(file)
	return ok && i64(n) == size
}

update_reset_available :: proc() {
	sync.mutex_lock(&updater.mu)
	if updater.state == .Downloading { updater.state = .Available }
	sync.mutex_unlock(&updater.mu)
}

// UI thread, after a successful download: save and stop tracking, swap the EXE,
// start the new one and close this window. Any failure resumes normal operation.
update_finish :: proc(app: ^App) {
	exe := update_exe_path()
	staged, old := fmt.tprintf("%s.new", exe), fmt.tprintf("%s.old", exe)
	fail :: proc(app: ^App, staged: string, text: string) {
		windows.DeleteFileW(wtext(staged))
		update_reset_available()
		windows.InvalidateRect(ui.hwnd, nil, windows.FALSE)
		message_box(text, "aika", windows.MB_ICONERROR)
	}
	if exe == "" { fail(app, staged, "Could not locate aika.exe to update."); return }
	if !ui_request_exit(app) { // saves the task and flushes the tracker
		windows.DeleteFileW(wtext(staged))
		update_reset_available()
		windows.InvalidateRect(ui.hwnd, nil, windows.FALSE)
		return
	}
	windows.DeleteFileW(wtext(old))
	if !windows.MoveFileExW(wtext(exe), wtext(old), windows.MOVEFILE_REPLACE_EXISTING) {
		tracker_resume(app)
		fail(app, staged, "Could not replace aika.exe (is the folder writable?). Download the update from the releases page instead.")
		return
	}
	if !windows.MoveFileExW(wtext(staged), wtext(exe), windows.MOVEFILE_REPLACE_EXISTING) {
		windows.MoveFileExW(wtext(old), wtext(exe), windows.MOVEFILE_REPLACE_EXISTING) // roll back
		tracker_resume(app)
		fail(app, staged, "Could not install the downloaded update.")
		return
	}

	cmd, _ := windows.wstring_to_utf8(windows.GetCommandLineW(), -1, context.temp_allocator)
	cmdline := windows.utf8_to_utf16(fmt.tprintf("%s --wait-pid %d", cmd, windows.GetCurrentProcessId()), context.temp_allocator)
	cmdline = append_nul(cmdline) // CreateProcessW needs a writable, NUL-terminated buffer
	si := windows.STARTUPINFOW{cb = size_of(windows.STARTUPINFOW)}
	pi: windows.PROCESS_INFORMATION
	if windows.CreateProcessW(wtext(exe), cstring16(raw_data(cmdline)), nil, nil, false, 0, nil, nil, &si, &pi) {
		windows.CloseHandle(pi.hProcess)
		windows.CloseHandle(pi.hThread)
	} else {
		message_box("aika was updated but could not restart itself. Please start it again.", "aika")
	}
	settings_close()
	if tag_ui.popup != nil { tag_picker_close() }
	windows.DestroyWindow(ui.hwnd)
}

append_nul :: proc(s: []u16) -> []u16 {
	out := make([]u16, len(s) + 1, context.temp_allocator)
	copy(out, s)
	return out
}

// --- Startup helpers (the relaunched process) ---

// Block until the process that started us has exited, so its single-instance
// mutex is released. Best effort: a bad pid or timeout just proceeds.
update_wait_for_pid :: proc(pid: u32) {
	h := windows.OpenProcess(windows.SYNCHRONIZE, false, pid)
	if h == nil { return }
	windows.WaitForSingleObject(h, UPDATE_WAIT_MS)
	windows.CloseHandle(h)
}

// Remove the previous EXE left behind by an update (best effort).
update_cleanup_old :: proc() {
	if exe := update_exe_path(); exe != "" {
		windows.DeleteFileW(wtext(fmt.tprintf("%s.old", exe)))
	}
}
