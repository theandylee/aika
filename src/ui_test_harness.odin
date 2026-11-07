package main

import "core:sync"

// Shared harness for UI behavior tests (audit #25).
//
// The behavior tests mutate the same globals the running application uses
// (`ui`, `tag_ui`, `global_app`, the active palette mirrored into the `C_*`
// variables, and the DPI stored on `ui`). The test runner executes @(test)s
// in parallel by default, so every test touching that state holds
// `ui_test_mutex` for its whole body; otherwise two behavior tests trample
// each other's globals (reproduced as order-dependent geometry/DPI failures
// when the old serial `zoom_behavior` chain was split up). This keeps every
// behavior test an independent @(test) — no chaining through one another —
// while guaranteeing only one runs at a time. Non-UI tests never take the
// lock and still run freely in parallel.

// Serializes all tests that read or write the shared UI globals.
ui_test_mutex: sync.Mutex

Ui_Test_Guard :: struct {
	ui:      UiState,
	tag_ui:  TagUi,
	app:     ^App,
	palette: Palette,
}

// Save the shared UI state and start the test from a clean slate. Does not
// lock; for a whole test use ui_test_begin, for a nested scope whose caller
// already holds the lock use this pair directly.
ui_test_guard_begin :: proc() -> Ui_Test_Guard {
	g := Ui_Test_Guard{ui = ui, tag_ui = tag_ui, app = global_app, palette = palette_active}
	ui = {}
	tag_ui = {}
	return g
}

// Restore the state captured by ui_test_guard_begin, including the C_*
// mirror of the previously active palette. Does not unlock.
ui_test_guard_end :: proc(g: ^Ui_Test_Guard) {
	ui = g.ui
	tag_ui = g.tag_ui
	global_app = g.app
	palette_apply(g.palette)
}

// Begin a UI behavior test: hold the shared-state lock and snapshot the
// globals. Register `defer ui_test_end(&g)` immediately; register any further
// cleanup defers (map deletes, font/GDI cleanup, temp-allocator resets)
// after it so they run before the state is restored and unlocked.
ui_test_begin :: proc() -> Ui_Test_Guard {
	sync.lock(&ui_test_mutex)
	return ui_test_guard_begin()
}

// End a UI behavior test started with ui_test_begin.
ui_test_end :: proc(g: ^Ui_Test_Guard) {
	ui_test_guard_end(g)
	sync.unlock(&ui_test_mutex)
}
