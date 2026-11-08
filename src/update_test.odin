package main

import "core:sync"
import "core:testing"

@(test)
update_version_comparison :: proc(t: ^testing.T) {
	testing.expect(t, version_newer("v0.2.0", "0.1.0"))
	testing.expect(t, version_newer("1.0.0", "0.9.9"))
	testing.expect(t, version_newer("v1.10.0", "1.9.0"), "numeric, not lexical")
	testing.expect(t, version_newer("1.2", "1.1.9"))
	testing.expect(t, !version_newer("1.0.0", "1.0.0"))
	testing.expect(t, !version_newer("0.9.0", "1.0.0"))
	testing.expect(t, !version_newer("1.0.0", "1.0"), "missing parts are zero")
	testing.expect(t, !version_newer("nightly", "1.0.0"), "unparsable never updates")
	testing.expect(t, !version_newer("2.0.0", "dev"), "dev builds never update")

	parts, ok := parse_version("v1.2.3-rc1")
	testing.expect(t, ok && parts == [3]int{1, 2, 3})
	_, ok = parse_version("")
	testing.expect(t, !ok)
}

@(test)
update_label_is_hidden_without_update :: proc(t: ^testing.T) {
	_, state := update_label()
	testing.expect(t, state == .Idle)
	testing.expect(t, rect_empty(update_rect(1320, 860)))
	testing.expect(t, !update_clickable())
}

@(test)
update_policy_scheduling :: proc(t: ^testing.T) {
	saved := updater
	defer { updater.on_start, updater.periodic, updater.started, updater.next_check_ms = saved.on_start, saved.periodic, saved.started, saved.next_check_ms }
	updater.started = true
	updater.next_check_ms = 12345
	update_set_policy(true, true) // unchanged periodic: schedule untouched
	testing.expect(t, updater.next_check_ms == 12345)
	update_set_policy(true, false) // periodic off: nothing scheduled
	testing.expect(t, updater.next_check_ms == UPDATE_NEVER)
	update_set_policy(false, true) // periodic on again: due right away
	testing.expect(t, updater.next_check_ms < UPDATE_NEVER && updater.next_check_ms <= monotonic_ms())
	sync.mutex_lock(&updater.mu)
	testing.expect(t, update_next_after(1000, 50) == 1050)
	updater.periodic = false
	testing.expect(t, update_next_after(1000, 50) == UPDATE_NEVER)
	sync.mutex_unlock(&updater.mu)
}
