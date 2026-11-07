package main

import "core:fmt"
import "core:strings"
import "core:sys/windows"

// --- Extra Win32 bindings not present in core:sys/windows ---

foreign import aika_k32 "system:kernel32.lib"
foreign import aika_u32 "system:user32.lib"
foreign import aika_theme "system:uxtheme.lib"
foreign import aika_dwm "system:dwmapi.lib"
foreign import aika_gdi "system:gdi32.lib"

@(default_calling_convention = "system")
foreign aika_gdi {
	GetPixel :: proc(dc: windows.HDC, x, y: i32) -> windows.COLORREF ---
	ExtTextOutW :: proc(dc: windows.HDC, x, y: i32, options: u32, rect: ^windows.RECT, text: windows.LPCWSTR, count: u32, dx: [^]i32) -> windows.BOOL ---
	// Returns MAKELONG(width, height), or 0 on failure.
	GetCharacterPlacementW :: proc(dc: windows.HDC, text: windows.LPCWSTR, count, max_extent: i32, results: ^GCP_RESULTSW, flags: u32) -> u32 ---
	GetGlyphIndicesW :: proc(dc: windows.HDC, text: windows.LPCWSTR, count: i32, glyphs: [^]u16, flags: u32) -> u32 ---
	GetCharWidth32W :: proc(dc: windows.HDC, first, last: u32, widths: [^]i32) -> windows.BOOL ---
}

ETO_CLIPPED :: 0x0004
GCP_USEKERNING :: 0x0008
GGI_MARK_NONEXISTING_GLYPHS :: 0x0001

GCP_RESULTSW :: struct {
	size:       u32,
	out_string: [^]u16,
	order:      [^]u32,
	dx:         [^]i32,
	caret_pos:  [^]i32,
	class:      [^]u8,
	glyphs:     [^]u16,
	n_glyphs:   u32, // in: capacity of the arrays above
	max_fit:    i32,
}

@(default_calling_convention = "system")
foreign aika_dwm {
	DwmSetWindowAttribute :: proc(hwnd: windows.HWND, attribute: u32, value: rawptr, size: u32) -> i32 ---
}

// UxTheme paints into our GDI backbuffer; no extra UI framework is required.
Theme_Handle :: distinct rawptr

@(default_calling_convention = "system")
foreign aika_theme {
	SetWindowTheme :: proc(hwnd: windows.HWND, app_name, id_list: windows.LPCWSTR) -> i32 ---
	OpenThemeData :: proc(hwnd: windows.HWND, class_list: windows.LPCWSTR) -> Theme_Handle ---
	CloseThemeData :: proc(theme: Theme_Handle) -> i32 ---
	DrawThemeBackground :: proc(theme: Theme_Handle, dc: windows.HDC, part, state: i32, rect, clip: ^windows.RECT) -> i32 ---
	DrawThemeText :: proc(theme: Theme_Handle, dc: windows.HDC, part, state: i32, text: windows.LPCWSTR, count: i32, flags, flags2: u32, rect: ^windows.RECT) -> i32 ---
}

@(default_calling_convention = "system")
foreign aika_k32 {
	QueryFullProcessImageNameW :: proc(hProcess: windows.HANDLE, dwFlags: windows.DWORD, lpExeName: windows.LPWSTR, lpdwSize: ^windows.DWORD) -> windows.BOOL ---
	GetLocalTime :: proc(lpSystemTime: ^windows.SYSTEMTIME) ---
	GetSystemTime :: proc(lpSystemTime: ^windows.SYSTEMTIME) ---
	GetTickCount64 :: proc() -> u64 ---
	TzSpecificLocalTimeToSystemTime :: proc(lpTimeZoneInformation: ^windows.TIME_ZONE_INFORMATION, lpLocalTime: ^windows.SYSTEMTIME, lpUniversalTime: ^windows.SYSTEMTIME) -> windows.BOOL ---
}

LASTINPUTINFO :: struct {
	cbSize: windows.UINT,
	dwTime: windows.DWORD,
}

@(default_calling_convention = "system")
foreign aika_u32 {
	MonitorFromWindow :: proc(hwnd: windows.HWND, flags: u32) -> windows.HANDLE ---
	GetMonitorInfoW :: proc(monitor: windows.HANDLE, info: ^Monitor_Info) -> windows.BOOL ---
	DrawFocusRect :: proc(dc: windows.HDC, rect: ^windows.RECT) -> windows.BOOL ---
	GetLastInputInfo :: proc(plii: ^LASTINPUTINFO) -> windows.BOOL ---
	SetScrollInfo :: proc(hwnd: windows.HWND, bar: i32, info: ^Scroll_Info, redraw: windows.BOOL) -> i32 ---
	GetScrollInfo :: proc(hwnd: windows.HWND, bar: i32, info: ^Scroll_Info) -> windows.BOOL ---
}

Scroll_Info :: struct {
	cbSize: u32,
	fMask: u32,
	nMin, nMax: i32,
	nPage: u32,
	nPos, nTrackPos: i32,
}

Draw_Item :: struct {
	CtlType, CtlID, itemID, itemAction, itemState: u32,
	hwndItem: windows.HWND,
	hDC: windows.HDC,
	rcItem: windows.RECT,
	itemData: uintptr,
}

Monitor_Info :: struct {
	cbSize: u32,
	rcMonitor, rcWork: windows.RECT,
	dwFlags: u32,
}

PROCESS_QUERY_LIMITED_INFORMATION :: 0x1000

message_box :: proc(text, caption: string, flags: windows.UINT = 0x40) {
	tw := windows.utf8_to_wstring(text, context.temp_allocator)
	cw := windows.utf8_to_wstring(caption, context.temp_allocator)
	windows.MessageBoxW(nil, tw, cw, flags)
}

WIN_TIME :: windows.SYSTEMTIME

now_local :: proc() -> WIN_TIME {
	st: WIN_TIME
	GetLocalTime(&st)
	return st
}

now_utc :: proc() -> WIN_TIME {
	st: WIN_TIME
	GetSystemTime(&st)
	return st
}

systemtime_to_unix_ms :: proc(st: WIN_TIME) -> i64 {
	st_local := st
	ft: windows.FILETIME
	if !windows.SystemTimeToFileTime(&st_local, &ft) {
		return 0
	}
	return windows.FILETIME_as_unix_nanoseconds(ft) / 1_000_000
}

local_to_utc :: proc(local: WIN_TIME, zone: ^windows.TIME_ZONE_INFORMATION = nil) -> WIN_TIME {
	local_copy := local
	utc: WIN_TIME
	TzSpecificLocalTimeToSystemTime(zone, &local_copy, &utc)
	return utc
}

local_systemtime_to_unix_ms :: proc(local: WIN_TIME, zone: ^windows.TIME_ZONE_INFORMATION = nil) -> i64 {
	utc := local_to_utc(local, zone)
	return systemtime_to_unix_ms(utc)
}

unix_ms_to_utc :: proc(ms: i64) -> WIN_TIME {
	total := u64(ms) + 11644473600000
	value := total * 10000
	ft := windows.FILETIME {
		dwLowDateTime  = u32(value & 0xFFFF_FFFF),
		dwHighDateTime = u32(value >> 32),
	}
	st: WIN_TIME
	windows.FileTimeToSystemTime(&ft, &st)
	return st
}

unix_ms_to_local :: proc(ms: i64) -> WIN_TIME {
	utc := unix_ms_to_utc(ms)
	local: WIN_TIME
	windows.SystemTimeToTzSpecificLocalTime(nil, &utc, &local)
	return local
}

now_ms :: proc() -> i64 {
	return systemtime_to_unix_ms(now_utc())
}

date_int_from_systemtime :: proc(st: WIN_TIME) -> int {
	return int(st.year) * 10000 + int(st.month) * 100 + int(st.day)
}

date_int_from_unix_ms :: proc(ms: i64) -> int {
	return date_int_from_systemtime(unix_ms_to_local(ms))
}

format_systemtime :: proc(st: WIN_TIME) -> string {
	return fmt.tprintf("%04d-%02d-%02d %02d:%02d:%02d", st.year, st.month, st.day, st.hour, st.minute, st.second)
}

format_time_only :: proc(st: WIN_TIME) -> string {
	return fmt.tprintf("%02d:%02d", st.hour, st.minute)
}

date_systemtime :: proc(date_int: int) -> WIN_TIME {
	y := windows.WORD(date_int / 10000)
	m := windows.WORD((date_int / 100) % 100)
	d := windows.WORD(date_int % 100)
	return WIN_TIME{year = y, month = m, day = d}
}

// Civil date arithmetic (no timezone dependence).
days_in_month :: proc(y, m: int) -> int {
	switch m {
	case 1, 3, 5, 7, 8, 10, 12:
		return 31
	case 4, 6, 9, 11:
		return 30
	case 2:
		if (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0) {
			return 29
		}
		return 28
	}
	return 30
}

add_days :: proc(date_int: int, delta: int) -> int {
	y := date_int / 10000
	m := (date_int / 100) % 100
	d := date_int % 100
	step := 1 if delta >= 0 else -1
	n := delta if delta >= 0 else -delta
	for _ in 0 ..< n {
		d += step
		if step > 0 && d > days_in_month(y, m) {
			d = 1
			m += 1
			if m > 12 {
				m = 1
				y += 1
			}
		} else if step < 0 && d < 1 {
			m -= 1
			if m < 1 {
				m = 12
				y -= 1
			}
			d = days_in_month(y, m)
		}
	}
	return y * 10000 + m * 100 + d
}

// ManicTime stores StartLocalDate/EndLocalDate as days since 2000-01-01.
days_from_civil :: proc(y, m, d: int) -> i64 {
	yy := y
	if m <= 2 {
		yy -= 1
	}
	era := yy / 400
	yoe := yy - era * 400
	doy := (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	return i64(era) * 146097 + i64(doe) - 719468
}

civil_from_days :: proc(z_in: i64) -> (y, m, d: int) {
	z := z_in + 719468
	era := z / 146097
	doe := z - era * 146097
	yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	yy := int(yoe + era * 400)
	doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
	mp := (5 * doy + 2) / 153
	d = int(doy - (153 * mp + 2) / 5 + 1)
	m = int(mp + (mp < 10 ? 3 : -9))
	y = yy + (m <= 2 ? 1 : 0)
	return
}

MANIC_DATE_EPOCH :: i64(10957) // 2000-01-01 as days since 1970-01-01

manic_date_from_date_int :: proc(date_int: int) -> i64 {
	y := date_int / 10000
	m := (date_int / 100) % 100
	d := date_int % 100
	return days_from_civil(y, m, d) - MANIC_DATE_EPOCH
}

date_int_from_manic_date :: proc(manic_date: i64) -> int {
	y, m, d := civil_from_days(manic_date + MANIC_DATE_EPOCH)
	return y * 10000 + m * 100 + d
}

weekday_from_date :: proc(y, m, d: int) -> int {
	// Sakamoto's algorithm, 0 = Sunday.
	t := []int{0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4}
	yy := y
	if m < 3 {
		yy -= 1
	}
	return (yy + yy / 4 - yy / 100 + yy / 400 + t[m - 1] + d) % 7
}

date_label :: proc(date_int: int) -> string {
	y := date_int / 10000
	m := (date_int / 100) % 100
	d := date_int % 100
	wd := weekday_from_date(y, m, d)
	weekdays := []string{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}
	months := []string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
	return fmt.tprintf("%s %02d %s %04d", weekdays[wd], d, months[m - 1], y)
}

today_date_int :: proc() -> int {
	return date_int_from_systemtime(now_local())
}

day_bounds_ms :: proc(date_int: int, zone: ^windows.TIME_ZONE_INFORMATION = nil) -> (start_ms, end_ms: i64) {
	local_start := date_systemtime(date_int)
	start_ms = local_systemtime_to_unix_ms(local_start, zone)

	next_date := add_days(date_int, 1)
	local_next := date_systemtime(next_date)
	end_ms = local_systemtime_to_unix_ms(local_next, zone)
	return
}

idle_ms :: proc() -> i64 {
	lii: LASTINPUTINFO
	lii.cbSize = windows.UINT(size_of(LASTINPUTINFO))
	if !GetLastInputInfo(&lii) {
		return 0
	}
	now_low := u32(GetTickCount64() & 0xFFFF_FFFF)
	last := u64(lii.dwTime)
	if u64(now_low) >= last {
		return i64(u64(now_low) - last)
	}
	return i64((0x1_0000_0000 - last) + u64(now_low))
}

// --- Process / window introspection ---

WindowInfo :: struct {
	hwnd:           windows.HWND,
	pid:            u32,
	created:        u64,
	cacheable:      bool,
	path:           string,
	file_name:      string,
	title:          string,
	product:        string,
	company:        string,
	description:    string,
}

base_name :: proc(path: string) -> string {
	last := 0
	for i in 0 ..< len(path) {
		if path[i] == '\\' || path[i] == '/' {
			last = i + 1
		}
	}
	return path[last:]
}

strip_extension :: proc(name: string) -> string {
	for i := len(name) - 1; i >= 0; i -= 1 {
		if name[i] == '.' {
			return name[:i]
		}
	}
	return name
}

query_process_path :: proc(pid: u32) -> string {
	h := windows.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, windows.DWORD(pid))
	if h == nil {
		return ""
	}
	defer windows.CloseHandle(h)
	return query_process_path_handle(h)
}

query_process_path_handle :: proc(h: windows.HANDLE) -> string {
	buf: [2048]u16
	size := windows.DWORD(len(buf))
	if !QueryFullProcessImageNameW(h, 0, &buf[0], &size) {
		return ""
	}
	res, _ := windows.utf16_to_utf8(buf[:size], context.temp_allocator)
	return res
}

query_version_strings :: proc(path: string) -> (product, company, description: string) {
	product, company, description, _ = query_version_strings_result(path)
	return
}

// Missing version resources are a valid stable fallback; I/O/access errors and
// a failed read after a successful size query are transient and not cacheable.
query_version_strings_result :: proc(path: string) -> (product, company, description: string, cacheable: bool) {
	path_w := windows.utf8_to_utf16(path, context.temp_allocator)
	if len(path_w) == 0 {
		return "", "", "", false
	}
	wpath := windows.wstring(raw_data(path_w))

	windows.SetLastError(0)
	size := windows.GetFileVersionInfoSizeW(wpath, nil)
	if size == 0 {
		switch u32(windows.GetLastError()) {
		case 1812, 1813, 1814, 1815: // resource data/type/name/language absent
			return "", "", "", true
		}
		return "", "", "", false
	}
	data := make([]byte, int(size), context.temp_allocator)
	if !windows.GetFileVersionInfoW(wpath, 0, size, raw_data(data)) {
		return "", "", "", false
	}

	lang: u16 = 0x0409
	codepage: u16 = 0x04B0
	trans_ptr: windows.LPVOID
	trans_len: windows.UINT
	if windows.VerQueryValueW(raw_data(data), windows.L("\\VarFileInfo\\Translation"), &trans_ptr, &trans_len) && trans_len >= 4 && trans_ptr != nil {
		vals := ([^]u16)(trans_ptr)
		lang = vals[0]
		codepage = vals[1]
	}

	query :: proc(data: []byte, lang, codepage: u16, field: string) -> string {
		sub := fmt.tprintf("\\StringFileInfo\\%04x%04x\\%s", lang, codepage, field)
		sub_w := windows.utf8_to_utf16(sub, context.temp_allocator)
		if len(sub_w) == 0 {
			return ""
		}
		ptr: windows.LPVOID
		n: windows.UINT
		if !windows.VerQueryValueW(raw_data(data), windows.wstring(raw_data(sub_w)), &ptr, &n) || ptr == nil || n == 0 {
			return ""
		}
		chars := ([^]u16)(ptr)
		s, _ := windows.utf16_to_utf8(chars[:int(n)], context.temp_allocator)
		return s
	}

	product = query(data, lang, codepage, "ProductName")
	company = query(data, lang, codepage, "CompanyName")
	description = query(data, lang, codepage, "FileDescription")

	if product == "" && (lang != 0x0409 || codepage != 0x04B0) {
		product = query(data, 0x0409, 0x04B0, "ProductName")
		company = query(data, 0x0409, 0x04B0, "CompanyName")
		description = query(data, 0x0409, 0x04B0, "FileDescription")
	}
	cacheable = true
	return
}

get_foreground_window_sample :: proc() -> (WindowInfo, bool) {
	info := WindowInfo{}
	info.hwnd = windows.GetForegroundWindow()
	if info.hwnd == nil {
		return info, false
	}

	pid: windows.DWORD
	if windows.GetWindowThreadProcessId(info.hwnd, &pid) == 0 || pid == 0 { return {}, false }
	info.pid = u32(pid)

	buf: [1024]u16
	n := windows.GetWindowTextW(info.hwnd, &buf[0], windows.INT(len(buf)))
	if n > 0 {
		info.title, _ = windows.utf16_to_utf8(buf[:n], context.temp_allocator)
	}

	return info, true
}

focus_pid_name :: proc(pid: u32) -> string { return fmt.tprintf("pid_%d", pid) }

process_identity_handle :: proc(h: windows.HANDLE, pid: u32) -> (Process_Identity, bool) {
	created, exited, kernel, user: windows.FILETIME
	if !windows.GetProcessTimes(h, &created, &exited, &kernel, &user) { return {}, false }
	stamp := (u64(created.dwHighDateTime) << 32) | u64(created.dwLowDateTime)
	return Process_Identity{pid = pid, created = stamp}, stamp != 0
}

query_process_identity :: proc(pid: u32) -> (Process_Identity, bool) {
	h := windows.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, windows.DWORD(pid))
	if h == nil { return {}, false }
	defer windows.CloseHandle(h)
	return process_identity_handle(h, pid)
}

query_process_metadata :: proc(key: Process_Identity) -> (WindowInfo, bool) {
	h := windows.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, windows.DWORD(key.pid))
	if h == nil { return {}, false }
	defer windows.CloseHandle(h)
	if key.created != 0 {
		actual, valid := process_identity_handle(h, key.pid)
		if !valid || actual != key { return {}, false }
	}
	path := query_process_path_handle(h)
	info := WindowInfo{path = path, file_name = base_name(path)}
	if path == "" { return info, false }
	product, company, description, valid := query_version_strings_result(path)
	info.product, info.company, info.description = product, company, description
	return info, valid
}

// --- Group identity ---

make_group_key :: proc(file_name, product: string) -> string {
	name := product
	if name == "" {
		name = strip_extension(file_name)
	}
	return fmt.tprintf("%s;%s", file_name, name)
}

xml_escape :: proc(s: string) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	for r in s {
		switch r {
		case '&':
			strings.write_string(&b, "&amp;")
		case '<':
			strings.write_string(&b, "&lt;")
		case '>':
			strings.write_string(&b, "&gt;")
		case '"':
			strings.write_string(&b, "&quot;")
		case '\'':
			strings.write_string(&b, "&apos;")
		case:
			strings.write_rune(&b, r)
		}
	}
	return strings.to_string(b)
}

make_group_text_data :: proc(file_name, name, company, full_path, description: string) -> string {
	return fmt.tprintf(
		"<ApplicationGroupTextData><FileName>%s</FileName><Name>%s</Name><Company>%s</Company><FullPath>%s</FullPath><Description>%s</Description></ApplicationGroupTextData>",
		xml_escape(file_name),
		xml_escape(name),
		xml_escape(company),
		xml_escape(full_path),
		xml_escape(description),
	)
}
