package main

import "core:encoding/json"
import "core:testing"

import_test_file :: proc(source: string = "test-db") -> ImportFile {
	start, _ := day_bounds_ms(20261106)
	groups := make([]ImportGroup, 1, context.temp_allocator)
	groups[0] = ImportGroup{groupId = 1, timelineId = TIMELINE_APPS,
		displayName = "Imported app", color = 0xFF123456, key = "remote-key", textData = "remote metadata"}
	activities := make([]ImportActivity, 1, context.temp_allocator)
	activities[0] = ImportActivity{activityId = 1, timelineId = TIMELINE_APPS,
		groupId = 1, displayName = "Imported title", startUtcMs = start + 1000,
		endUtcMs = start + 7000, textData = "Imported text"}
	return ImportFile{source = "ManicTime", sourceId = source, groups = groups, activities = activities}
}

import_test_apply :: proc(db: ^DB, imp: ImportFile, source: string = "") -> bool {
	data, err := json.marshal(imp, allocator = context.temp_allocator)
	if err != nil { return false }
	return import_manictime_data(db, data, source)
}

import_test_scalar :: proc(db: ^DB, sql: string) -> i64 {
	stmt, ok := db_prepare(db, sql)
	if !ok { return -1 }
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW { return -1 }
	return col_i64(stmt, 0)
}

@(test)
import_ids_cannot_replace_local_history :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&db)
	group, _, ensured := db_ensure_group(&db, TIMELINE_APPS, "local-key", "Local app", "local metadata")
	testing.expect(t, ensured == .Ok)
	imp := import_test_file()
	start := imp.activities[0].startUtcMs
	id, inserted := db_insert_activity(&db, TIMELINE_APPS, "Local title", group, start, start + 1000)
	testing.expect(t, inserted == .Ok)
	imp.groups[0].groupId, imp.activities[0].groupId = group, group
	imp.activities[0].activityId = id
	testing.expect(t, import_test_apply(&db, imp))
	rows, loaded := db_load_activities(&db, 20261106)
	defer free_activities(rows)
	testing.expect(t, loaded == .Ok && len(rows) == 2)
	for row in rows {
		if row.id == id {
			testing.expect(t, row.display_name == "Local title" && row.group_name == "Local app")
			testing.expect(t, row.group_id == group && row.end_ms == start + 1000)
		} else {
			testing.expect(t, row.display_name == "Imported title" && row.group_id != group)
		}
	}
	testing.expect(t, import_test_scalar(&db, `SELECT count(*) FROM Activity a LEFT JOIN "Group" g ON a.GroupId=g.GroupId WHERE a.GroupId IS NOT NULL AND g.GroupId IS NULL`) == 0)
	testing.expect(t, import_test_scalar(&db, "SELECT count(*) FROM ImportActivityMap") == 1)
}

@(test)
import_group_identity_preserves_existing_metadata :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&db)
	group, color, ensured := db_ensure_group(&db, TIMELINE_APPS, "remote-key", "Keep local name", "Keep metadata")
	testing.expect(t, ensured == .Ok)
	imp := import_test_file()
	imp.groups[0].groupId, imp.activities[0].groupId = 9999, 9999
	testing.expect(t, import_test_apply(&db, imp))
	testing.expect(t, import_test_scalar(&db, `SELECT count(*) FROM "Group"`) == 5)
	rows, loaded := db_load_activities(&db, 20261106)
	defer free_activities(rows)
	testing.expect(t, loaded == .Ok && len(rows) == 1)
	if len(rows) == 1 {
		testing.expect(t, rows[0].group_id == group && rows[0].group_name == "Keep local name" && rows[0].color == color)
	}
}

@(test)
import_reimports_update_only_owned_unchanged_rows :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&db)
	imp := import_test_file()
	testing.expect(t, import_test_apply(&db, imp))
	id := import_test_scalar(&db, "SELECT LocalActivityId FROM ImportActivityMap")
	testing.expect(t, import_test_apply(&db, imp))
	testing.expect(t, db_count_activities(&db) == 1)
	imp.activities[0].endUtcMs += 5000
	imp.activities[0].displayName = "Updated imported title"
	testing.expect(t, import_test_apply(&db, imp))
	testing.expect(t, db_count_activities(&db) == 1)
	last, result := db_last_activity(&db, TIMELINE_APPS)
	defer delete(last.display_name)
	testing.expect(t, result == .Ok && last.id == id && last.end_ms == imp.activities[0].endUtcMs)
	testing.expect(t, last.display_name == "Updated imported title")
	testing.expect(t, db_update_activity_end(&db, id, last.end_ms + 1000) == .Ok)
	// An identical reimport preserves a local edit too; a changed source row
	// must conflict instead of overwriting the local edit or tracker extension.
	testing.expect(t, import_test_apply(&db, imp))
	imp.activities[0].endUtcMs += 5000
	extra := make([]ImportGroup, 2, context.temp_allocator)
	extra[0] = imp.groups[0]
	extra[1] = ImportGroup{groupId = 99, timelineId = TIMELINE_APPS, key = "must-roll-back", displayName = "New group"}
	imp.groups = extra
	testing.expect(t, !import_test_apply(&db, imp))
	testing.expect(t, import_test_scalar(&db, "SELECT EndUtcMs FROM Activity") == last.end_ms + 1000)
	testing.expect(t, db_count_activities(&db) == 1)
	testing.expect(t, import_test_scalar(&db, `SELECT count(*) FROM "Group"`) == 5, "Conflicts roll back newly resolved groups too")
}

@(test)
import_sources_are_separate_and_legacy_requires_identity :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&db)
	imp := import_test_file("")
	testing.expect(t, !import_test_apply(&db, imp))
	testing.expect(t, import_test_apply(&db, imp, "first-db"))
	testing.expect(t, import_test_apply(&db, imp, "first-db"))
	testing.expect(t, import_test_apply(&db, imp, "second-db"))
	testing.expect(t, db_count_activities(&db) == 2)
	testing.expect(t, import_test_scalar(&db, "SELECT count(*) FROM ImportActivityMap") == 2)
	imp.sourceId = "first-db"
	testing.expect(t, !import_test_apply(&db, imp, "second-db"))
	imp.activities[0].startUtcMs += 1
	testing.expect(t, !import_test_apply(&db, imp), "Reused IDs with a new start require a new source identity")
	testing.expect(t, db_count_activities(&db) == 2)
}

@(test)
import_deletions_remain_tombstoned :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&db)
	imp := import_test_file()
	imp.groups[0].timelineId, imp.activities[0].timelineId = TIMELINE_TAGS, TIMELINE_TAGS
	testing.expect(t, import_test_apply(&db, imp))
	id := import_test_scalar(&db, "SELECT LocalActivityId FROM ImportActivityMap")
	testing.expect(t, db_delete_tag_block(&db, id))
	testing.expect(t, import_test_scalar(&db, "SELECT count(*) FROM ImportActivityMap WHERE LocalActivityId IS NULL") == 1)
	imp.activities[0].endUtcMs += 1000
	testing.expect(t, import_test_apply(&db, imp))
	testing.expect(t, db_count_activities(&db) == 0, "Reimport must not resurrect locally deleted tags")
}

@(test)
import_validation_prevents_partial_or_ambiguous_history :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&db)
	for scenario in 0 ..< 13 {
		imp := import_test_file()
		switch scenario {
		case 0: imp.groups[0].key = ""
		case 1: imp.activities[0].groupId = 123456
		case 2: imp.activities[0].timelineId = TIMELINE_TAGS
		case 3: imp.activities[0].endUtcMs = imp.activities[0].startUtcMs - 1
		case 4: imp.activities[0].startUtcMs = 0
		case 5: imp.activities[0].activityId = 0
		case 6: imp.groups[0].timelineId = 99
		case 7: imp.activities = []ImportActivity{imp.activities[0], imp.activities[0]}
		case 8: imp.groups = []ImportGroup{imp.groups[0], imp.groups[0]}
		case 9: imp.sourceId = "   "
		case 10: imp.sourceId = "test-db\x00other"
		case 11: imp.source = "Other product"
		case 12: imp.activities[0].endUtcMs = 253402300800000
		}
		testing.expect(t, !import_test_apply(&db, imp))
		testing.expect(t, db_count_activities(&db) == 0 && import_test_scalar(&db, `SELECT count(*) FROM "Group"`) == 4)
	}
	imp := import_test_file()
	imp.groups = nil
	imp.activities[0].groupId = 1 // seeded local Active is not a source group
	testing.expect(t, !import_test_apply(&db, imp))
	imp.activities[0].groupId = 0
	testing.expect(t, import_test_apply(&db, imp), "Explicitly ungrouped source activities are supported")
	testing.expect(t, import_test_scalar(&db, "SELECT count(*) FROM Activity WHERE GroupId IS NULL") == 1)
}

@(test)
import_write_and_commit_failures_roll_back_everything :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&db)
	imp := import_test_file()
	testing.expect(t, db_exec(&db, `CREATE TRIGGER deny_map BEFORE INSERT ON ImportActivityMap BEGIN SELECT RAISE(ABORT, 'test failure'); END`))
	testing.expect(t, !import_test_apply(&db, imp))
	testing.expect(t, db_count_activities(&db) == 0 && import_test_scalar(&db, `SELECT count(*) FROM "Group"`) == 4)
	testing.expect(t, db_exec(&db, "DROP TRIGGER deny_map"))
	testing.expect(t, db_exec(&db, `CREATE TABLE CommitGuard (ref INTEGER REFERENCES Timeline(TimelineId) DEFERRABLE INITIALLY DEFERRED);
		CREATE TRIGGER fail_commit AFTER INSERT ON ImportActivityMap BEGIN INSERT INTO CommitGuard VALUES (999); END`))
	testing.expect(t, !import_test_apply(&db, imp))
	testing.expect(t, db_count_activities(&db) == 0 && import_test_scalar(&db, "SELECT count(*) FROM ImportActivityMap") == 0)
	testing.expect(t, import_test_scalar(&db, "SELECT count(*) FROM CommitGuard") == 0)
	testing.expect(t, db_exec(&db, "DROP TRIGGER fail_commit"))
	testing.expect(t, import_test_apply(&db, imp), "Failed commit must leave no transaction open")
}

@(test)
import_parse_errors_release_owned_data :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&db)
	invalid: string = `{"sourceId":"test-db","groups":[{"groupId":"not an integer"}]}`
	for _ in 0 ..< 10 {
		testing.expect(t, !import_manictime_data(&db, transmute([]byte)invalid))
	}
}

@(test)
import_alias_groups_and_binary_text_are_stable :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&db)
	imp := import_test_file()
	first := imp.groups[0]
	second := first
	second.groupId, second.displayName = 99, "Alias must not replace first metadata"
	imp.groups = []ImportGroup{first, second}
	imp.activities[0].groupId = 99
	imp.activities[0].displayName = "Case;😀\x00A"
	imp.activities[0].textData = "é;X\x00y"
	testing.expect(t, import_test_apply(&db, imp))
	testing.expect(t, import_test_scalar(&db, `SELECT count(*) FROM "Group"`) == 5)
	imp.activities[0].displayName = "case;😀\x00A"
	testing.expect(t, import_test_apply(&db, imp), "Source hashes must not lowercase activity text")
	rows, loaded := db_load_activities(&db, 20261106)
	defer free_activities(rows)
	testing.expect(t, loaded == .Ok && len(rows) == 1)
	if len(rows) == 1 { testing.expect(t, rows[0].display_name == "case;😀\x00A" && rows[0].group_name == first.displayName) }
	stmt, prepared := db_prepare(&db, "SELECT TextData FROM Activity")
	testing.expect(t, prepared)
	if !prepared { return }
	defer sqlite3_finalize(stmt)
	testing.expect(t, sqlite3_step(stmt) == SQLITE_ROW)
	text := col_text(stmt, 0)
	defer delete(text)
	testing.expect(t, text == imp.activities[0].textData, "SQLite text binding must preserve embedded NUL bytes")
}

@(test)
import_mapping_update_failure_preserves_activity :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&db)
	imp := import_test_file()
	testing.expect(t, import_test_apply(&db, imp))
	before := imp.activities[0].endUtcMs
	imp.activities[0].endUtcMs += 1000
	testing.expect(t, db_exec(&db, `CREATE TRIGGER ignore_map BEFORE UPDATE ON ImportActivityMap BEGIN SELECT RAISE(IGNORE); END`))
	testing.expect(t, !import_test_apply(&db, imp))
	testing.expect(t, import_test_scalar(&db, "SELECT EndUtcMs FROM Activity") == before)
	testing.expect(t, db_exec(&db, "DROP TRIGGER ignore_map"))
	testing.expect(t, import_test_apply(&db, imp))
	testing.expect(t, import_test_scalar(&db, "SELECT EndUtcMs FROM Activity") == before + 1000)
}
