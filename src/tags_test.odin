package main

import "core:testing"
import "core:strings"

// Shared UI state is reset by the audit #25 harness, so this is an
// independent @(test).
@(test)
tag_drag_behavior :: proc(t: ^testing.T) {
	g := ui_test_begin()
	defer ui_test_end(&g)
	lay := compute_layout(1320, 860)
	tag_ui = TagUi{anchor = 5000, view_start = 1000, view_end = 9000}
	tag_begin(.New_Range, 0)
	tag_pointer_move(lay.chart_x, lay)
	testing.expect(t, tag_ui.start_ms == 1000 && tag_ui.end_ms == 5000)
	tag_pointer_move(lay.chart_x + lay.chart_w + 100, lay)
	testing.expect(t, tag_ui.start_ms == 5000 && tag_ui.end_ms == 9000)
	interaction_end()
	tag_begin(.Left_Edge, 0)
	tag_pointer_move(lay.chart_x + lay.chart_w, lay)
	testing.expect(t, tag_ui.start_ms == tag_ui.end_ms - 1)
	interaction_end()
	tag_begin(.Right_Edge, 0)
	tag_pointer_move(lay.chart_x - 100, lay)
	testing.expect(t, tag_ui.end_ms == tag_ui.start_ms + 1)
	neighbors := [3]Activity{
		{id = 1, timeline_id = TIMELINE_TAGS, start_ms = 1000, end_ms = 3000},
		{id = 2, timeline_id = TIMELINE_TAGS, start_ms = 6000, end_ms = 7000},
		{id = 3, timeline_id = TIMELINE_TAGS, start_ms = 8000, end_ms = 9000},
	}
	tag_ui = TagUi{id = 2, start_ms = 6000, end_ms = 7000, view_start = 0, view_end = 10000}
	tag_begin(.Left_Edge, 2)
	tag_pointer_move(lay.chart_x, lay, neighbors[:])
	testing.expect(t, tag_ui.start_ms == 3000, "Left resize stops at previous tag")
	interaction_end()
	tag_begin(.Right_Edge, 2)
	tag_pointer_move(lay.chart_x + lay.chart_w, lay, neighbors[:])
	testing.expect(t, tag_ui.end_ms == 8000, "Right resize stops at next tag")

	app := App{date = 20261106}
	ds, de := day_bounds_ms(app.date)
	ui.tab, ui.zoom_start, ui.zoom_end = .Day, 0.25, 0.75
	vs, ve := zoom_bounds(ds, de)
	activities := [1]Activity{{id = 42, timeline_id = TIMELINE_TAGS, start_ms = ds, end_ms = ds + (de - ds) / 2}}
	app.activities = activities[:]
	id, edge := tag_edge_hit(&app, x_for_ms(activities[0].end_ms, vs, ve, lay.chart_x, lay.chart_w), lay.lane_y + 10, lay)
	testing.expect(t, id == 42 && edge == .Right_Edge)
	id, _ = tag_edge_hit(&app, lay.chart_x, lay.lane_y + 10, lay)
	testing.expect(t, id == 0, "Clipped start must not become a resize handle")
	testing.expect(t, lane_timeline(.Tags) == TIMELINE_TAGS)
	testing.expect(t, tag_block_hit(&app, lay.chart_x + 20, lay.lane_y + 10, lay) == 42,
		"Clipped tag interiors still have a context menu")
	testing.expect(t, tag_block_hit(&app, lay.chart_x + lay.chart_w - 20, lay.lane_y + 10, lay) == 0)
	testing.expect(t, tag_block_hit(&app, lay.chart_x + 20, lay.lane_y + lay.lane_h + 10, lay) == 0)
	adjacent := [2]Activity{
		{id = 10, timeline_id = TIMELINE_TAGS, start_ms = vs, end_ms = ds + (de - ds) / 2},
		{id = 11, timeline_id = TIMELINE_TAGS, start_ms = ds + (de - ds) / 2, end_ms = ve},
	}
	app.activities = adjacent[:]
	boundary := x_for_ms(adjacent[0].end_ms, vs, ve, lay.chart_x, lay.chart_w)
	for offset := i32(1); offset <= 6; offset += 1 {
		id, edge = tag_edge_hit(&app, boundary - offset, lay.lane_y + 10, lay)
		testing.expect(t, id == 10 && edge == .Right_Edge, "Left interior selects left block's right handle")
		id, edge = tag_edge_hit(&app, boundary + offset, lay.lane_y + 10, lay)
		testing.expect(t, id == 11 && edge == .Left_Edge, "Right interior selects right block's left handle")
	}
	// Selection must not depend on activity storage/paint order.
	adjacent[0], adjacent[1] = adjacent[1], adjacent[0]
	id, edge = tag_edge_hit(&app, boundary - 2, lay.lane_y + 10, lay)
	testing.expect(t, id == 10 && edge == .Right_Edge)
	id, edge = tag_edge_hit(&app, boundary + 2, lay.lane_y + 10, lay)
	testing.expect(t, id == 11 && edge == .Left_Edge)
	app.activities = activities[:]
	// A live application must not leak into the tags totals.
	app.tracker.current.active = true
	app.tracker.current.start_ms = ds
	snapshot := build_day_snapshot(&app, ds + 1000, 1000)
	totals := build_totals(snapshot, TIMELINE_TAGS)
	defer free_totals_slice(totals)
	testing.expect(t, len(totals) == 1 && totals[0].group_id == 0)
}

@(test)
tag_persistence :: proc(t: ^testing.T) {
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&db)
	id := db_ensure_tag(&db, "  Development  ")
	testing.expect(t, id > 0 && db_ensure_tag(&db, "development") == id)
	testing.expect(t, db_ensure_tag(&db, "  ") == 0)
	tags, result := db_load_tags(&db)
	testing.expect(t, result == .Ok)
	testing.expect(t, len(tags) == 1 && tags[0].name == "Development")
	free_tags(tags)
	ds, de := day_bounds_ms(20261106)
	start, end := ds + 3600_000, ds + 7200_000
	aid, inserted := db_insert_activity(&db, TIMELINE_TAGS, "Development", id, start, end)
	testing.expect(t, aid > 0 && inserted == .Ok)
	testing.expect(t, db_resize_tag(&db, aid, start - 1000, de + 1000))
	testing.expect(t, !db_resize_tag(&db, aid, end, start))
	rows, loaded := db_load_activities(&db, 20261106)
	testing.expect(t, loaded == .Ok)
	defer free_activities(rows)
	testing.expect(t, len(rows) == 1)
	if len(rows) != 1 { return }
	testing.expect(t, rows[0].start_ms == start - 1000 && rows[0].end_ms == de + 1000)
	testing.expect(t, rows[0].group_name == "Development" && rows[0].color != 0)
	stmt, prepared := db_prepare(&db, `SELECT StartLocalDate, EndLocalDate, StartLocalTime, EndUtcTime FROM Activity WHERE ActivityId = ?1`)
	testing.expect(t, prepared)
	if !prepared { return }
	defer sqlite3_finalize(stmt)
	bind_i64(stmt, 1, aid)
	testing.expect(t, sqlite3_step(stmt) == SQLITE_ROW)
	testing.expect(t, col_i64(stmt, 0) == manic_date_from_date_int(20261106))
	testing.expect(t, col_i64(stmt, 1) == manic_date_from_date_int(20261107))
	s, e := col_text(stmt, 2), col_text(stmt, 3)
	defer { delete(s); delete(e) }
	testing.expect(t, strings.has_prefix(s, "2026-11-06"))
	testing.expect(t, e == format_systemtime(unix_ms_to_utc(de + 1000)))
	// Tag editing must not touch automatically tracked activity.
	app_id, app_inserted := db_insert_activity(&db, TIMELINE_APPS, "Window", id, start, end)
	testing.expect(t, app_inserted == .Ok)
	testing.expect(t, !db_resize_tag(&db, app_id, ds, de))
	last, found := db_last_activity(&db, TIMELINE_APPS)
	defer delete(last.display_name)
	testing.expect(t, found == .Ok && last.start_ms == start && last.end_ms == end)
	testing.expect(t, !db_tag_range_free(&db, start, end))
	testing.expect(t, !db_tag_range_free(&db, end, start))
	testing.expect(t, db_tag_range_free(&db, ds, start - 1000))
	neighbor, neighbor_inserted := db_insert_activity(&db, TIMELINE_TAGS, "Development", id, ds, start - 1000)
	testing.expect(t, neighbor > 0 && neighbor_inserted == .Ok)
	testing.expect(t, !db_resize_tag(&db, aid, ds + 1000, de + 1000))
	testing.expect(t, !db_resize_tag(&db, neighbor, ds, start))
	testing.expect(t, db_resize_tag(&db, neighbor, ds + 1000, start - 1000), "Touching edges are allowed")
	testing.expect(t, !db_delete_tag_block(&db, app_id), "Delete cannot affect tracker activities")
	testing.expect(t, db_delete_tag_block(&db, aid))
	testing.expect(t, !db_delete_tag_block(&db, aid), "Already deleted block reports no change")
	testing.expect(t, db_tag_range_free(&db, start - 1000, de + 1000))
	tags, result = db_load_tags(&db)
	testing.expect(t, result == .Ok)
	testing.expect(t, len(tags) == 1 && tags[0].id == id, "Deleting a block preserves the reusable tag")
	free_tags(tags)
}

@(test)
tags_load_most_recently_used_first :: proc(t: ^testing.T) {
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&db)
	alpha, beta, gamma, delta := db_ensure_tag(&db, "Alpha"), db_ensure_tag(&db, "Beta"), db_ensure_tag(&db, "Gamma"), db_ensure_tag(&db, "Delta")
	ds, _ := day_bounds_ms(20261106)
	// Beta used earliest, Alpha later; Gamma only as the second tag of a later multi-tag block.
	_, r1 := db_create_tag_block_multi(&db, []Tag_Pick{{beta, "Beta"}}, ds + 1000, ds + 2000)
	_, r2 := db_create_tag_block_multi(&db, []Tag_Pick{{alpha, "Alpha"}}, ds + 3000, ds + 4000)
	_, r3 := db_create_tag_block_multi(&db, []Tag_Pick{{alpha, "Alpha"}, {gamma, "Gamma"}}, ds + 5000, ds + 6000)
	_, r4 := db_create_tag_block_multi(&db, []Tag_Pick{{beta, "Beta"}}, ds + 7000, ds + 8000)
	testing.expect(t, r1 == .Ok && r2 == .Ok && r3 == .Ok && r4 == .Ok)
	tags, result := db_load_tags(&db)
	defer free_tags(tags)
	testing.expect(t, result == .Ok && len(tags) == 4)
	if len(tags) != 4 { return }
	// Beta (latest), then Alpha and Gamma (same last block, name order), then never-used Delta.
	testing.expect(t, tags[0].id == beta && tags[1].id == alpha && tags[2].id == gamma && tags[3].id == delta)
}

@(test)
tag_selection_avoids_occupied_time :: proc(t: ^testing.T) {
	// Unsorted input, and an application which must not block tagging.
	activities := [3]Activity{
		{timeline_id = TIMELINE_TAGS, start_ms = 60, end_ms = 80},
		{timeline_id = TIMELINE_APPS, start_ms = 0, end_ms = 100},
		{timeline_id = TIMELINE_TAGS, start_ms = 20, end_ms = 40},
	}
	cases := [][4]i64{
		{25, 35, 25, 25}, {35, 25, 35, 35}, // entirely occupied: empty
		{30, 50, 40, 50}, {30, 10, 10, 20}, // start inside, exit either side
		{10, 30, 10, 20}, {50, 30, 40, 50}, // end inside
		{10, 90, 10, 20}, {90, 10, 80, 90}, // stop at first obstacle
		{30, 70, 40, 60}, {70, 30, 40, 60}, // select the intervening gap
		{40, 60, 40, 60}, {60, 40, 40, 60}, // touching edges
		{20, 40, 20, 20}, {40, 20, 40, 40}, // exact occupied interval
		{50, 50, 50, 50},
	}
	for item in cases {
		s, e := tag_free_range(activities[:], item[0], item[1])
		testing.expect(t, s == item[2] && e == item[3])
	}
	// Touching/overlapping legacy tags form a continuous occupied region.
	chain := [3]Activity{
		{timeline_id = TIMELINE_TAGS, start_ms = 35, end_ms = 60},
		{timeline_id = TIMELINE_TAGS, start_ms = 60, end_ms = 80},
		{timeline_id = TIMELINE_TAGS, start_ms = 20, end_ms = 40},
	}
	s, e := tag_free_range(chain[:], 30, 90)
	testing.expect(t, s == 80 && e == 90)
	s, e = tag_free_range(chain[:], 70, 10)
	testing.expect(t, s == 10 && e == 20)
}

@(test)
tag_gap_selection :: proc(t: ^testing.T) {
	activities := [5]Activity{
		{timeline_id = TIMELINE_TAGS, start_ms = 80, end_ms = 100},
		{timeline_id = TIMELINE_TAGS, start_ms = 20, end_ms = 40},
		{timeline_id = TIMELINE_APPS, start_ms = 0, end_ms = 200},
		{timeline_id = TIMELINE_TAGS, start_ms = 60, end_ms = 70},
		{timeline_id = TIMELINE_TAGS, start_ms = 30, end_ms = 45}, // legacy overlap
	}
	for point in ([3]i64{45, 50, 59}) {
		s, e, found := tag_gap_at(activities[:], point)
		testing.expect(t, found && s == 45 && e == 60, "Uses exact nearest block boundaries")
	}
	s, e, found := tag_gap_at(activities[:], 75)
	testing.expect(t, found && s == 70 && e == 80)
	for point in ([7]i64{0, 19, 20, 44, 60, 100, 150}) {
		_, _, found = tag_gap_at(activities[:], point)
		testing.expect(t, !found, "Occupied and unbounded spaces are not gaps")
	}
	_, _, found = tag_gap_at(nil, 50)
	testing.expect(t, !found)
}
