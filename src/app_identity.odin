package main

import "core:sys/windows"

// Windows labels notifications with the app's identity. An unpackaged exe without
// one is shown by file name ("aika.exe"). Give the process an explicit
// AppUserModelID and register its display name under HKCU (no installer or admin
// rights), so the notification header reads just "aika".

foreign import aika_identity_shell "system:shell32.lib"

@(default_calling_convention = "system")
foreign aika_identity_shell {
	SetCurrentProcessExplicitAppUserModelID :: proc(app_id: windows.PCWSTR) -> windows.HRESULT ---
}

APP_USER_MODEL_ID  :: "aika"
APP_DISPLAY_NAME   :: "aika"
APP_ID_REGISTRY_KEY :: `Software\Classes\AppUserModelId\` + APP_USER_MODEL_ID

// Call once at startup, before the tray icon is added. Failures are harmless: the
// notification then falls back to the exe name.
app_identity_register :: proc() {
	SetCurrentProcessExplicitAppUserModelID(wtext(APP_USER_MODEL_ID))

	key: windows.HKEY
	if windows.RegCreateKeyExW(windows.HKEY_CURRENT_USER, wtext(APP_ID_REGISTRY_KEY), 0, nil, 0,
		windows.KEY_SET_VALUE, nil, &key, nil) != 0 { return }
	defer windows.RegCloseKey(key)
	// wtext is NUL-terminated; REG_SZ size includes the terminator.
	chars := len(windows.utf8_to_utf16(APP_DISPLAY_NAME, context.temp_allocator))
	windows.RegSetValueExW(key, wtext("DisplayName"), 0, windows.REG_SZ,
		(^windows.BYTE)(rawptr(wtext(APP_DISPLAY_NAME))), u32((chars + 1) * 2))
}
