package main

import "core:testing"
import vmem "core:mem/virtual"

@(test)
multi_tag_block_stores_ordered_list_and_loads_tags :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&db)
	date := 20261106
	ds, _ := day_bounds_ms(date)
	start := ds + 3_600_000

	picks := []Tag_Pick{{0, "Work"}, {0, "Meeting"}, {0, "work"}} // duplicate by name collapses
	block, result := db_create_tag_block_multi(&db, picks, start, start + 600_000)
	testing.expect_value(t, result, DB_Tag_Result.Ok)

	acts, loaded := db_load_activities(&db, date)
	testing.expect_value(t, loaded, DB_Result.Ok)
	defer free_activities(acts)
	found := false
	for a in acts {
		if a.id != block.id { continue }
		found = true
		testing.expect_value(t, a.display_name, "Work, Meeting")
		testing.expect_value(t, len(a.tags), 2)
		if len(a.tags) == 2 {
			testing.expect_value(t, a.tags[0].name, "Work")
			testing.expect_value(t, a.tags[1].name, "Meeting")
			testing.expect_value(t, a.group_id, a.tags[0].id)
		}
	}
	testing.expect(t, found)

	// The same combination reuses its list; a different order is a different list.
	again, again_result := db_create_tag_block_multi(&db, picks[:2], start + 700_000, start + 800_000)
	testing.expect_value(t, again_result, DB_Tag_Result.Ok)
	rev, rev_result := db_create_tag_block_multi(&db, []Tag_Pick{{0, "Meeting"}, {0, "Work"}}, start + 900_000, start + 1_000_000)
	testing.expect_value(t, rev_result, DB_Tag_Result.Ok)
	stmt, prepared := db_prepare(&db, `SELECT COUNT(DISTINCT GroupListId) FROM Activity WHERE ActivityId IN (?1,?2,?3)`)
	testing.expect(t, prepared)
	if !prepared { return }
	defer sqlite3_finalize(stmt)
	bind_i64(stmt, 1, block.id); bind_i64(stmt, 2, again.id); bind_i64(stmt, 3, rev.id)
	testing.expect(t, sqlite3_step(stmt) == SQLITE_ROW)
	testing.expect_value(t, col_i64(stmt, 0), i64(2))
}

@(test)
multi_tag_totals_credit_every_tag_but_blocks_count_once :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	tags := []Activity_Tag{{1, "A", 0xFF112233}, {2, "B", 0xFF445566}}
	rows := []Snapshot_Activity{
		{activity = Activity{id = 1, timeline_id = TIMELINE_TAGS, group_id = 1, display_name = "A, B", tags = tags}, start_ms = 0, end_ms = 60_000},
		{activity = Activity{id = 2, timeline_id = TIMELINE_TAGS, group_id = 2, display_name = "B", tags = tags[1:]}, start_ms = 60_000, end_ms = 90_000},
	}
	totals := build_totals(Day_Snapshot{rows = rows}, TIMELINE_TAGS)
	defer free_totals_slice(totals)
	testing.expect_value(t, len(totals), 2)
	for row in totals {
		switch row.name {
		case "A": testing.expect_value(t, row.ms, i64(60_000))
		case "B": testing.expect_value(t, row.ms, i64(90_000))
		case: testing.fail(t)
		}
	}
}

@(test)
import_keeps_tag_lists_and_updates_already_imported_rows :: proc(t: ^testing.T) {
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&db)
	// Same allocator contract as the real callers: owned data and per-row scratch on arenas.
	owned, scratch: vmem.Arena
	testing.expect(t, vmem.arena_init_growing(&owned) == nil)
	defer vmem.arena_destroy(&owned)
	testing.expect(t, vmem.arena_init_growing(&scratch) == nil)
	defer vmem.arena_destroy(&scratch)
	context.allocator = vmem.arena_allocator(&owned)
	context.temp_allocator = vmem.arena_allocator(&scratch)
	groups := []ImportGroup{
		{groupId = 1, timelineId = TIMELINE_TAGS, displayName = "A", key = "ka"},
		{groupId = 2, timelineId = TIMELINE_TAGS, displayName = "B", key = "kb"},
	}
	ids := []i64{1, 2}
	lists := []ImportGroupList{{groupListId = 7, timelineId = TIMELINE_TAGS, key = "kl", groupIds = ids}}
	// import_apply frees the temp allocator per row: keep inputs on the heap.
	acts := make([]ImportActivity, 1)
	acts[0] = ImportActivity{activityId = 1, timelineId = TIMELINE_TAGS, groupId = 1, displayName = "A",
		startUtcMs = 1_700_000_000_000, endUtcMs = 1_700_000_060_000}

	// First import without the list, as an older aika did.
	imp := ImportFile{source = "ManicTime", sourceId = "s", groups = groups, activities = acts}
	testing.expect(t, import_apply(&db, &imp))

	// Re-import with the list: the existing row must gain it.
	acts[0].groupListId = 7
	acts[0].displayName = "A, B"
	imp.groupLists = lists
	testing.expect(t, import_apply(&db, &imp))

	stmt, prepared := db_prepare(&db, `SELECT COUNT(*) FROM GroupListItem li JOIN Activity a ON a.GroupListId = li.GroupListId`)
	testing.expect(t, prepared)
	if !prepared { return }
	defer sqlite3_finalize(stmt)
	testing.expect(t, sqlite3_step(stmt) == SQLITE_ROW)
	testing.expect_value(t, col_i64(stmt, 0), i64(2))

	// A list that references an unknown group is rejected before any write.
	bad := []i64{1, 99}
	imp.groupLists = []ImportGroupList{{groupListId = 8, timelineId = TIMELINE_TAGS, key = "bad", groupIds = bad}}
	testing.expect(t, !import_apply(&db, &imp))
}
