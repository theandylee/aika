package main

import "core:encoding/json"
import "core:fmt"
import "core:os"

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
}

ImportFile :: struct {
	groups:     []ImportGroup    `json:"groups"`,
	activities: []ImportActivity `json:"activities"`,
}

import_manictime_json :: proc(db: ^DB, path: string) -> bool {
	data, ok := os.read_entire_file(path)
	if !ok {
		fmt.eprintln("cannot read import file:", path)
		return false
	}
	defer delete(data)

	imp: ImportFile
	if err := json.unmarshal(data, &imp); err != nil {
		fmt.eprintln("json parse error:", err)
		return false
	}

	fmt.println("importing", len(imp.groups), "groups and", len(imp.activities), "activities")

	if !db_exec(db, "BEGIN;") {
		return false
	}

	for g in imp.groups {
		key := g.key
		if key == "" {
			key = key_hash(g.displayName)
		}
		if !db_import_group(db, g.groupId, g.timelineId, g.displayName, u32(g.color), key, g.textData) {
			fmt.eprintln("failed to import group", g.groupId, g.displayName)
			db_exec(db, "ROLLBACK;")
			return false
		}
	}

	for a in imp.activities {
		if a.startUtcMs == 0 || a.endUtcMs == 0 {
			continue
		}
		if !db_insert_activity_full(db, a.activityId, a.timelineId, a.displayName, a.groupId, a.startUtcMs, a.endUtcMs, a.textData) {
			fmt.eprintln("failed to import activity", a.activityId)
			db_exec(db, "ROLLBACK;")
			return false
		}
	}

	return db_exec(db, "COMMIT;")
}
