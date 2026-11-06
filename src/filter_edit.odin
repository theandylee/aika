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

filter_edit_proc :: proc "std" (hwnd: windows.HWND, msg: u32, wp: windows.WPARAM, lp: windows.LPARAM) -> windows.LRESULT {
	context = rt.default_context()
	scratch: Scratch
	context.temp_allocator = scratch_begin(&scratch)
	defer scratch_end(&scratch)
	// Ctrl+Backspace translates to DEL, which a plain Win32 EDIT inserts.
	if msg == windows.WM_CHAR && wp == 0x7F {
		start, end: u32
		windows.SendMessageW(hwnd, 0xB0, windows.WPARAM(uintptr(&start)), windows.LPARAM(uintptr(&end))) // EM_GETSEL
		if start == end {
			n := windows.GetWindowTextLengthW(hwnd)
			text := make([]u16, int(n) + 1, context.temp_allocator)
			count := windows.GetWindowTextW(hwnd, &text[0], n + 1)
			start = u32(filter_word_start(text[:count], int(start)))
		}
		if start != end {
			windows.SendMessageW(hwnd, 0xB1, windows.WPARAM(start), windows.LPARAM(end)) // EM_SETSEL
			empty: [1]u16
			windows.SendMessageW(hwnd, 0xC2, 1, windows.LPARAM(uintptr(&empty[0]))) // EM_REPLACESEL, undoable
		}
		return 0
	}
	return windows.CallWindowProcW(filter_edit_original, hwnd, msg, wp, lp)
}
