package main

import "core:os"
import "core:fmt"
import "core:strings"
import "core:sys/windows"

// Scratch folder for tests that need real database files: <system temp>\aika-tests.
// Created on demand; the string lives in the temp allocator.
test_temp_dir :: proc() -> string {
	buf: [windows.MAX_PATH_WIDE]u16
	n := windows.GetTempPathW(u32(len(buf)), cstring16(&buf[0]))
	base := "."
	if n > 0 && n < u32(len(buf)) {
		if s, err := windows.utf16_to_utf8(buf[:n], context.temp_allocator); err == nil {
			base = strings.trim_right(s, "\\/")
		}
	}
	dir := fmt.tprintf("%s\\aika-tests", base)
	os.make_directory(dir)
	return dir
}
