package main

import "core:testing"

@(test)
filter_word_deletion :: proc(t: ^testing.T) {
	text := [?]u16{'o', 'n', 'e', ' ', 't', 'w', 'o', ' ', ' '}
	testing.expect(t, filter_word_start(text[:], 9) == 4)
	testing.expect(t, filter_word_start(text[:], 7) == 4)
	testing.expect(t, filter_word_start(text[:], 6) == 4)
	testing.expect(t, filter_word_start(text[:], 4) == 0)
	testing.expect(t, filter_word_start(text[:], 0) == 0)
	testing.expect(t, filter_word_start(nil, 0) == 0)
	unicode_text := [?]u16{'x', ' ', 0xD83D, 0xDE00, 0x2003}
	testing.expect(t, filter_word_start(unicode_text[:], 5) == 2)
}
