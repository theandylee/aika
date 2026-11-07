package main

import "core:fmt"
import "core:path/filepath"
import "core:sys/windows"

// Portable "start with Windows": a per-user Run value (no installer, no admin)
// pointing at the exe's current location. Moving the folder requires toggling
// the option off and on again.

foreign import aika_advapi "system:advapi32.lib"

@(default_calling_convention = "system")
foreign aika_advapi {
	RegDeleteValueW :: proc(hKey: windows.HKEY, lpValueName: windows.LPCWSTR) -> windows.LSTATUS ---
}

AUTOSTART_KEY  :: `Software\Microsoft\Windows\CurrentVersion\Run`
AUTOSTART_NAME :: "aika"
ERROR_FILE_NOT_FOUND :: 2

// Command line registered for login: absolute exe and db paths (Run entries
// start with an unrelated working directory), launched hidden in the tray.
autostart_command :: proc(db_path: string) -> (cmd: string, ok: bool) {
	buf: [windows.MAX_PATH_WIDE]u16
	n := windows.GetModuleFileNameW(nil, &buf[0], u32(len(buf)))
	if n == 0 || int(n) >= len(buf) { return }
	exe, err := windows.utf16_to_utf8(buf[:n], context.temp_allocator)
	if err != nil { return }
	db, abs_err := filepath.abs(db_path, context.temp_allocator)
	if abs_err != nil { return }
	return fmt.tprintf("\"%s\" --db \"%s\" --hidden", exe, db), true
}

autostart_enabled :: proc() -> bool {
	size: windows.DWORD
	return windows.RegGetValueW(windows.HKEY_CURRENT_USER, wtext(AUTOSTART_KEY), wtext(AUTOSTART_NAME),
		windows.RRF_RT_REG_SZ, nil, nil, &size) == 0
}

autostart_set :: proc(enable: bool, db_path: string) -> bool {
	key: windows.HKEY
	if windows.RegCreateKeyExW(windows.HKEY_CURRENT_USER, wtext(AUTOSTART_KEY), 0, nil, 0,
		windows.KEY_SET_VALUE, nil, &key, nil) != 0 { return false }
	defer windows.RegCloseKey(key)
	if !enable {
		status := RegDeleteValueW(key, wtext(AUTOSTART_NAME))
		return status == 0 || status == ERROR_FILE_NOT_FOUND
	}
	cmd, ok := autostart_command(db_path)
	if !ok { return false }
	// wtext is NUL-terminated; REG_SZ size includes the terminator.
	chars := len(windows.utf8_to_utf16(cmd, context.temp_allocator))
	return windows.RegSetValueExW(key, wtext(AUTOSTART_NAME), 0, windows.REG_SZ,
		(^windows.BYTE)(rawptr(wtext(cmd))), u32((chars + 1) * 2)) == 0
}
