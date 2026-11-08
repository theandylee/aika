package main

import "core:sys/windows"
import rt "base:runtime"

filter_edit_original: windows.WNDPROC

filter_word_start :: proc(text: []u16, caret: int) -> int {
	i := clamp(caret, 0, len(text))
	// EDIT selections use UTF-16 offsets. Whitespace boundaries cannot split
	// surrogate pairs, so non-ASCII words remain intact as well.
	for i > 0 && filter_word_space(text[i - 1]) { i -= 1 }
	for i > 0 && !filter_word_space(text[i - 1]) { i -= 1 }
	return i
}

filter_word_space :: proc(c: u16) -> bool {
	return c == ' ' || (c >= 9 && c <= 13) || c == 0x85 || c == 0xA0 ||
	       c == 0x1680 || (c >= 0x2000 && c <= 0x200A) ||
	       c == 0x2028 || c == 0x2029 || c == 0x202F || c == 0x205F || c == 0x3000
}

// Gives an EDIT control Ctrl+Backspace word deletion. Shared by the filter bar
// and the tag picker; both are plain EDIT controls, so one original proc serves.
edit_enable_word_delete :: proc(hwnd: windows.HWND) -> bool {
	if hwnd == nil { return false }
	previous := windows.SetWindowLongPtrW(hwnd, windows.GWLP_WNDPROC, transmute(windows.LONG_PTR)(windows.WNDPROC(filter_edit_proc)))
	if previous == 0 { return false }
	if filter_edit_original == nil { filter_edit_original = transmute(windows.WNDPROC)(previous) }
	return true
}

filter_edit_proc :: proc "std" (hwnd: windows.HWND, msg: u32, wp: windows.WPARAM, lp: windows.LPARAM) -> windows.LRESULT {
	context = rt.default_context()
	scratch: Scratch
	context.temp_allocator = scratch_begin(&scratch)
	defer scratch_end(&scratch)
	// Ctrl+Backspace translates to DEL, which a plain Win32 EDIT inserts.
	if msg == windows.WM_CHAR && wp == CHAR_DELETE {
		start, end: u32
		windows.SendMessageW(hwnd, EM_GETSEL, windows.WPARAM(uintptr(&start)), windows.LPARAM(uintptr(&end)))
		if start == end {
			n := windows.GetWindowTextLengthW(hwnd)
			text := make([]u16, int(n) + 1, context.temp_allocator)
			count := windows.GetWindowTextW(hwnd, &text[0], n + 1)
			start = u32(filter_word_start(text[:count], int(start)))
		}
		if start != end {
			windows.SendMessageW(hwnd, EM_SETSEL, windows.WPARAM(start), windows.LPARAM(end))
			empty: [1]u16
			windows.SendMessageW(hwnd, EM_REPLACESEL, 1, windows.LPARAM(uintptr(&empty[0]))) // undoable
		}
		return 0
	}
	return windows.CallWindowProcW(filter_edit_original, hwnd, msg, wp, lp)
}
