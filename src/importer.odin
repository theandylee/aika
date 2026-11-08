package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import vmem "core:mem/virtual"

ImportGroup :: struct {
	groupId:     i64    `json:"groupId"`,
	timelineId:  i64    `json:"timelineId"`,
	displayName: string `json:"displayName"`,
	color:       i64    `json:"color"`,
	key:         string `json:"key"`,
	textData:    string `json:"textData"`,
}

ImportActivity :: struct {
	activityId:  i64    `json:"activityId"`,
	timelineId:  i64    `json:"timelineId"`,
	displayName: string `json:"displayName"`,
	groupId:     i64    `json:"groupId"`,
	startUtcMs:  i64    `json:"startUtcMs"`,
	endUtcMs:    i64    `json:"endUtcMs"`,
	textData:    string `json:"textData"`,
	groupListId: i64    `json:"groupListId"`, // optional: tag list (several tags per block)
}

// An ordered set of tags, as in ManicTime's GroupList/GroupListItem.
ImportGroupList :: struct {
	groupListId: i64    `json:"groupListId"`,
	timelineId:  i64    `json:"timelineId"`,
	key:         string `json:"key"`,
	groupIds:    []i64  `json:"groupIds"`,
}

Import_Stage :: enum { Reading, Writing }

// Called periodically with a running count; return false to cancel.
Import_Progress_Proc :: proc(stage: Import_Stage, done, total: int, data: rawptr) -> bool

ImportFile :: struct {
	source:     string          `json:"source"`,
	sourceId:   string          `json:"sourceId"`,
	groups:     []ImportGroup    `json:"groups"`,
	groupLists: []ImportGroupList `json:"groupLists"`,
	activities: []ImportActivity `json:"activities"`,
}

import_manictime_json :: proc(db: ^DB, path: string, source_override: string = "") -> bool {
	data, err := os.read_entire_file(path, context.allocator)
	defer delete(data)
	if err != nil {
		fmt.eprintln("cannot read import file:", path)
		return false
	}
	return import_manictime_data(db, data, source_override)
}

import_source_id :: proc(imp: ^ImportFile, override: string) -> (string, bool) {
	if imp.source != "" && imp.source != "ManicTime" { return "", false }
	for id in ([2]string{imp.sourceId, override}) {
		if id != "" && (strings.trim_space(id) != id || len(id) > 256 || strings.contains(id, "\x00")) {
			return "", false
		}
	}
	if imp.sourceId != "" && override != "" && imp.sourceId != override { return "", false }
	id := imp.sourceId if imp.sourceId != "" else override
	return id, id != ""
}

import_manictime_data :: proc(db: ^DB, data: []byte, source_override: string = "") -> bool {
	// Parsing and maps have one owned lifetime, including partial parse failures.
	// SQL, conversions and fingerprints use separately resettable per-row scratch.
	owned, scratch: vmem.Arena
	if err := vmem.arena_init_growing(&owned); err != nil { return false }
	defer vmem.arena_destroy(&owned)
	if err := vmem.arena_init_growing(&scratch); err != nil { return false }
	defer vmem.arena_destroy(&scratch)
	context.allocator = vmem.arena_allocator(&owned)
	context.temp_allocator = vmem.arena_allocator(&scratch)

	imp: ImportFile
	if err := json.unmarshal(data, &imp); err != nil {
		fmt.eprintln("json parse error:", err)
		return false
	}
	return import_apply(db, &imp, source_override)
}

// Validates and writes one parsed export in a single transaction. The caller
// owns imp and sets context.allocator / context.temp_allocator to arenas:
// temp memory is freed after every row.
import_apply :: proc(db: ^DB, imp: ^ImportFile, source_override: string = "",
	progress: Import_Progress_Proc = nil, progress_data: rawptr = nil, cancelled: ^bool = nil) -> bool {
	if imp.source != "" && imp.source != "ManicTime" {
		fmt.eprintln("unsupported import source:", imp.source)
		return false
	}
	source, identified := import_source_id(imp, source_override)
	if !identified {
		fmt.eprintln("import requires a stable sourceId (legacy exports: --import-source <database-id>); IDs must agree and contain no surrounding whitespace")
		return false
	}
	groups := make(map[i64]int)
	for g, i in imp.groups {
		if _, duplicate := groups[g.groupId]; duplicate || g.groupId <= 0 ||
		   g.timelineId < TIMELINE_TAGS || g.timelineId > TIMELINE_DOCS ||
		   strings.trim_space(g.key) == "" || strings.contains(g.key, "\x00") {
			fmt.eprintln("invalid or duplicate source group:", g.groupId)
			return false
		}
		groups[g.groupId] = i
	}
	lists := make(map[i64]int)
	for l, i in imp.groupLists {
		if _, duplicate := lists[l.groupListId]; duplicate || l.groupListId <= 0 || len(l.groupIds) == 0 ||
		   l.timelineId < TIMELINE_TAGS || l.timelineId > TIMELINE_DOCS ||
		   strings.trim_space(l.key) == "" || strings.contains(l.key, "\x00") {
			fmt.eprintln("invalid or duplicate source group list:", l.groupListId)
			return false
		}
		for g in l.groupIds {
			gi, found := groups[g]
			if !found || imp.groups[gi].timelineId != l.timelineId {
				fmt.eprintln("group list", l.groupListId, "references a missing or cross-timeline group:", g)
				return false
			}
		}
		lists[l.groupListId] = i
	}
	activities := make(map[i64]bool)
	for a in imp.activities {
		if a.groupListId > 0 {
			li, found := lists[a.groupListId]
			if !found || imp.groupLists[li].timelineId != a.timelineId {
				fmt.eprintln("missing or cross-timeline group list for activity:", a.activityId)
				return false
			}
		}
		if activities[a.activityId] || a.activityId <= 0 || a.timelineId < TIMELINE_TAGS || a.timelineId > TIMELINE_DOCS ||
		   a.startUtcMs <= 0 || a.endUtcMs < a.startUtcMs || a.endUtcMs > 253402300799999 || a.groupId < 0 {
			fmt.eprintln("invalid or duplicate source activity:", a.activityId)
			return false
		}
		activities[a.activityId] = true
		if a.groupId > 0 {
			i, found := groups[a.groupId]
			if !found || imp.groups[i].timelineId != a.timelineId {
				fmt.eprintln("missing or cross-timeline source group for activity:", a.activityId)
				return false
			}
		}
	}

	fmt.println("importing", len(imp.groups), "groups and", len(imp.activities), "activities")

	if !db_exec(db, "BEGIN IMMEDIATE") {
		return false
	}
	committed := false
	defer if !committed { db_exec(db, "ROLLBACK") }
	local_groups := make([]i64, len(imp.groups))

	for g, i in imp.groups {
		id, result := db_import_group(db, g)
		if result != .Ok {
			fmt.eprintln("failed to import group", g.groupId, g.displayName)
			return false
		}
		local_groups[i] = id
		free_all(context.temp_allocator)
	}

	local_lists := make([]i64, len(imp.groupLists))
	for l, i in imp.groupLists {
		ids := make([]i64, len(l.groupIds), context.temp_allocator)
		for g, k in l.groupIds { ids[k] = local_groups[groups[g]] }
		id, result := db_ensure_group_list(db, l.timelineId, l.key, ids)
		if result != .Ok {
			fmt.eprintln("failed to import group list", l.groupListId)
			return false
		}
		local_lists[i] = id
		free_all(context.temp_allocator)
	}

	counts: [Import_Action]int
	for a, n in imp.activities {
		if progress != nil && n % 1024 == 0 && !progress(.Writing, n, len(imp.activities), progress_data) {
			if cancelled != nil { cancelled^ = true }
			return false // deferred ROLLBACK discards everything
		}
		group: i64
		if a.groupId > 0 { group = local_groups[groups[a.groupId]] }
		list: i64
		if a.groupListId > 0 { list = local_lists[lists[a.groupListId]] }
		action, result := db_import_activity(db, source, a, group, list)
		if result != .Ok {
			fmt.eprintln("failed to import activity", a.activityId, result)
			return false
		}
		counts[action] += 1
		free_all(context.temp_allocator)
	}

	if !db_exec(db, "COMMIT") { return false }
	committed = true
	fmt.println("imported:", counts[.Added], "added,", counts[.Updated], "updated,", counts[.Unchanged], "unchanged,", counts[.Deleted], "locally deleted")
	return true
}
