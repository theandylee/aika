package main

import "core:testing"

// Shared view state is reset by the audit #25 harness, so this is an
// independent @(test).
@(test)
totals_tree_behavior :: proc(t: ^testing.T) {
	g := ui_test_begin()
	defer ui_test_end(&g)
	defer free_all(context.temp_allocator)
	ui = {}
	ui.totals_expanded = make(map[string]bool)
	defer delete(ui.totals_expanded)
	totals := [?]TotRow{
		{name = "Work/Project/Code", ms = 60},
		{name = "Work/Project/Review", ms = 30},
		{name = "Work/Admin", ms = 20},
		{name = "Work", ms = 10},
		{name = "Personal/Read", ms = 40},
		{name = " / Work // Project / Code / ", ms = 5},
		{name = "///", ms = 3},
	}
	rows := totals_tree_rows(totals[:])
	testing.expect(t, len(rows) == 3)
	testing.expect(t, rows[0].name == "Work" && rows[0].ms == 125)
	testing.expect(t, rows[1].name == "Personal" && rows[1].ms == 40)
	testing.expect(t, rows[2].ms == 3)
	ui.totals_expanded["0:/Work"] = true
	rows = totals_tree_rows(totals[:])
	testing.expect(t, len(rows) == 5)
	testing.expect(t, rows[1].name == "Project" && rows[1].ms == 95 && rows[1].depth == 1)
	testing.expect(t, rows[2].name == "Admin" && rows[2].ms == 20)
	ui.totals_expanded["0:/Work/Project"] = true
	rows = totals_tree_rows(totals[:])
	testing.expect(t, len(rows) == 7)
	testing.expect(t, rows[2].name == "Code" && rows[2].ms == 65 && rows[2].depth == 2)
	testing.expect(t, rows[3].name == "Review" && rows[3].ms == 30)
	// Lane-specific state cannot accidentally fold similarly named tags/apps.
	ui.lane = .Apps
	testing.expect(t, len(totals_tree_rows(totals[:])) == 3)
	ui.lane = .Tags
	ui.totals_expanded["0:/Work"] = false
	testing.expect(t, len(totals_tree_rows(totals[:])) == 3)
	testing.expect(t, len(totals_tree_rows(nil)) == 0)
	lay := compute_layout(720, 480)
	r := totals_mode_rect(lay)
	testing.expect(t, r.left > lay.sidebar_x && r.right < lay.sidebar_x + lay.sidebar_w)
	testing.expect(t, hit_test(r.left + 2, r.top + 2, 720, 480) == .Totals_Tree)
}
