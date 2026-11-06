package main

import "core:testing"

@(test)
settings_timeout_validation :: proc(t: ^testing.T) {
	for text in ([4]string{"1", "60", "500", " 2\n"}) {
		minutes, ok := settings_parse_minutes(text)
		testing.expect(t, ok && minutes >= 1 && minutes <= 500)
	}
	for text in ([7]string{"", "0", "-1", "501", "1.5", "abc", "999999999999999999999999"}) {
		_, ok := settings_parse_minutes(text)
		testing.expect(t, !ok, text)
	}
	testing.expect(t, settings_load_minutes("") == 1)
	testing.expect(t, !settings_save_minutes("", 0))
	testing.expect(t, !settings_save_minutes("", 501))
}
