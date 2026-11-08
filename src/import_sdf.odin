package main

import "core:fmt"
import "core:os"
import "core:strings"
import vmem "core:mem/virtual"

// Stable identity of the local ManicTime database for re-imports. Change it
// only if ManicTime's database is replaced/reset (see docs/DATABASE.md).
MANICTIME_SOURCE_ID :: "manictime-local"

Import_Sdf_Result :: enum {
	Ok,
	Not_Found,
	Cannot_Open,
	Not_Sdf,
	Encrypted,
	Missing_Tables,
	Read_Failed,
	Apply_Failed,
	Cancelled,
}

// %LOCALAPPDATA%\Finkit\ManicTime\ManicTime.sdf
manictime_sdf_path :: proc() -> (path: string, ok: bool) {
	base := os.get_env("LOCALAPPDATA", context.temp_allocator)
	if base == "" { return }
	path = fmt.tprintf("%s\\Finkit\\ManicTime\\ManicTime.sdf", base)
	return path, os.exists(path)
}

Manic_List_Item :: struct { group, order: i64 }

// ManicTime tags live in GroupList (one list per tag combination); tag
// activities carry GroupListId and no GroupId or name of their own.
Manic_Reader :: struct {
	groups:     [dynamic]ImportGroup,
	activities: [dynamic]ImportActivity,
	act_list:   [dynamic]i64, // GroupListId per activity, parallel to activities
	list_keys:  map[i64]string,
	list_items: map[i64][dynamic]Manic_List_Item,
	skipped:    int,
	cols:       [8]int, // column indexes of the table being read, in field order
	progress:   Import_Progress_Proc,
	progress_data: rawptr,
	total_rows: int, // activity row estimate for progress
	cancelled:  bool,
}

manic_list_row :: proc(t: ^Sdf_Table, row: []Sdf_Value, data: rawptr) -> bool {
	r := cast(^Manic_Reader)data
	id, _ := sdf_int(manic_cell(row, r.cols[0]))
	r.list_keys[id] = sdf_text(manic_cell(row, r.cols[1]))
	return true
}

manic_list_item_row :: proc(t: ^Sdf_Table, row: []Sdf_Value, data: rawptr) -> bool {
	r := cast(^Manic_Reader)data
	list, _ := sdf_int(manic_cell(row, r.cols[0]))
	group, _ := sdf_int(manic_cell(row, r.cols[1]))
	order, _ := sdf_int(manic_cell(row, r.cols[2]))
	items := r.list_items[list]
	append(&items, Manic_List_Item{group, order})
	r.list_items[list] = items
	return true
}

// Gives list-only activities a group and name: the tag itself for one-tag
// lists, a synthetic "A, B" tag (keyed by the list's key) for combinations.
manic_resolve_lists :: proc(r: ^Manic_Reader) {
	index := make(map[i64]int)
	next_id: i64 = 1
	for g, i in r.groups { index[g.groupId] = i; next_id = max(next_id, g.groupId + 1) }
	synthetic := make(map[i64]i64)

	for &a, i in r.activities {
		list := r.act_list[i]
		if a.groupId != 0 || list == 0 { continue }
		items := r.list_items[list]
		for j in 1 ..< len(items) { // insertion sort by DisplayOrder
			for k := j; k > 0 && items[k - 1].order > items[k].order; k -= 1 { items[k - 1], items[k] = items[k], items[k - 1] }
		}
		if len(items) == 0 { continue }
		first, found := index[items[0].group]
		if !found || r.groups[first].timelineId != a.timelineId { continue }

		gid := r.groups[first].groupId
		name := r.groups[first].displayName
		if len(items) > 1 {
			known, made := synthetic[list]
			if made {
				gid = known
			} else {
				parts := make([dynamic]string)
				for it in items {
					if gi, ok := index[it.group]; ok { append(&parts, r.groups[gi].displayName) }
				}
				joined := strings.join(parts[:], ", ")
				key := r.list_keys[list]
				if key == "" { key = fmt.aprintf("list:%d", list) }
				gid = next_id
				next_id += 1
				index[gid] = len(r.groups)
				append(&r.groups, ImportGroup{groupId = gid, timelineId = a.timelineId, displayName = joined,
					color = r.groups[first].color, key = key})
				synthetic[list] = gid
			}
			name = r.groups[index[gid]].displayName
		}
		a.groupId = gid
		if a.displayName == "" { a.displayName = name }
	}
}

sdf_int :: proc(v: Sdf_Value) -> (i64, bool) {
	#partial switch x in v {
	case i64: return x, true
	case bool: return i64(x), true
	}
	return 0, false
}

// Persistent copy (row memory is freed after each callback).
sdf_text :: proc(v: Sdf_Value) -> string {
	if s, ok := v.(string); ok { return strings.clone(s) }
	return ""
}

manic_cell :: proc(row: []Sdf_Value, idx: int) -> Sdf_Value {
	if idx < 0 || idx >= len(row) { return nil }
	return row[idx]
}

manic_group_row :: proc(t: ^Sdf_Table, row: []Sdf_Value, data: rawptr) -> bool {
	r := cast(^Manic_Reader)data
	id, _ := sdf_int(manic_cell(row, r.cols[0]))
	timeline, _ := sdf_int(manic_cell(row, r.cols[1]))
	color, _ := sdf_int(manic_cell(row, r.cols[3]))
	append(&r.groups, ImportGroup{
		groupId = id, timelineId = timeline, color = color,
		displayName = sdf_text(manic_cell(row, r.cols[2])),
		key = sdf_text(manic_cell(row, r.cols[4])),
		textData = sdf_text(manic_cell(row, r.cols[5])),
	})
	return true
}

manic_activity_row :: proc(t: ^Sdf_Table, row: []Sdf_Value, data: rawptr) -> bool {
	r := cast(^Manic_Reader)data
	n := len(r.activities)
	if r.progress != nil && n % 2048 == 0 && !r.progress(.Reading, n, r.total_rows, r.progress_data) {
		r.cancelled = true
		return false
	}
	start, has_start := manic_cell(row, r.cols[4]).(Sdf_DateTime)
	end, has_end := manic_cell(row, r.cols[5]).(Sdf_DateTime)
	if !has_start || !has_end { r.skipped += 1; return true }
	id, _ := sdf_int(manic_cell(row, r.cols[0]))
	timeline, _ := sdf_int(manic_cell(row, r.cols[1]))
	group, _ := sdf_int(manic_cell(row, r.cols[3]))
	list, _ := sdf_int(manic_cell(row, r.cols[7]))
	append(&r.act_list, list)
	append(&r.activities, ImportActivity{
		activityId = id, timelineId = timeline, groupId = group,
		displayName = sdf_text(manic_cell(row, r.cols[2])),
		startUtcMs = sdf_unix_ms(start), endUtcMs = sdf_unix_ms(end),
		textData = sdf_text(manic_cell(row, r.cols[6])),
	})
	return true
}

// Resolves the wanted column names of a table; false if any is missing.
manic_columns :: proc(t: ^Sdf_Table, names: []string, out: ^[8]int) -> bool {
	for n, i in names {
		out[i] = sdf_column(t, n)
		if out[i] < 0 { return false }
	}
	return true
}

// Reads ManicTime's Group and Activity tables straight from the .sdf and
// imports them. No ManicTime DLLs, PowerShell or .NET involved.
import_manictime_sdf :: proc(db: ^DB, path: string, progress: Import_Progress_Proc = nil,
	progress_data: rawptr = nil) -> Import_Sdf_Result {
	owned, scratch: vmem.Arena
	if err := vmem.arena_init_growing(&owned); err != nil { return .Read_Failed }
	defer vmem.arena_destroy(&owned)
	if err := vmem.arena_init_growing(&scratch); err != nil { return .Read_Failed }
	defer vmem.arena_destroy(&scratch)
	context.allocator = vmem.arena_allocator(&owned)
	context.temp_allocator = vmem.arena_allocator(&scratch)

	s, ok := sdf_open(path)
	if !ok {
		#partial switch s.error {
		case .Open: return .Cannot_Open
		case .Encrypted: return .Encrypted
		}
		return .Not_Sdf
	}
	defer sdf_close(&s)

	group_table := sdf_table(&s, "Group")
	activity_table := sdf_table(&s, "Activity")
	if group_table == nil || activity_table == nil { return .Missing_Tables }

	reader := Manic_Reader{progress = progress, progress_data = progress_data,
		total_rows = sdf_row_count(&s, activity_table)}
	group_cols := [?]string{"GroupId", "TimelineId", "DisplayName", "Color", "Key", "TextData"}
	activity_cols := [?]string{"ActivityId", "TimelineId", "DisplayName", "GroupId", "StartUtcTime", "EndUtcTime", "TextData", "GroupListId"}
	list_cols := [?]string{"GroupListId", "Key"}
	item_cols := [?]string{"GroupListId", "GroupId", "DisplayOrder"}

	if !manic_columns(group_table, group_cols[:], &reader.cols) { return .Missing_Tables }
	if !sdf_each_row(&s, group_table, manic_group_row, &reader) { return .Read_Failed }
	// Optional: without them (very old databases) tags simply stay unnamed.
	list_table := sdf_table(&s, "GroupList")
	item_table := sdf_table(&s, "GroupListItem")
	if list_table != nil && item_table != nil {
		if manic_columns(list_table, list_cols[:], &reader.cols) &&
		   !sdf_each_row(&s, list_table, manic_list_row, &reader) { return .Read_Failed }
		if manic_columns(item_table, item_cols[:], &reader.cols) &&
		   !sdf_each_row(&s, item_table, manic_list_item_row, &reader) { return .Read_Failed }
	}
	if !manic_columns(activity_table, activity_cols[:], &reader.cols) { return .Missing_Tables }
	if !sdf_each_row(&s, activity_table, manic_activity_row, &reader) { return .Read_Failed }
	if reader.cancelled { return .Cancelled }
	manic_resolve_lists(&reader)
	if s.lob_errors > 0 { fmt.eprintln("unreadable text blobs skipped:", s.lob_errors) }
	if reader.skipped > 0 { fmt.eprintln("activities without a time range skipped:", reader.skipped) }

	imp := ImportFile{
		source = "ManicTime", sourceId = MANICTIME_SOURCE_ID,
		groups = reader.groups[:], activities = reader.activities[:],
	}
	cancelled: bool
	if !import_apply(db, &imp, MANICTIME_SOURCE_ID, progress, progress_data, &cancelled) {
		return .Cancelled if cancelled else .Apply_Failed
	}
	return .Ok
}

import_sdf_message :: proc(r: Import_Sdf_Result, path: string) -> string {
	switch r {
	case .Ok: return "Import complete."
	case .Not_Found: return fmt.tprintf("ManicTime database not found:\n%s", path)
	case .Cannot_Open: return fmt.tprintf("Could not open the ManicTime database:\n%s", path)
	case .Not_Sdf: return "That file is not a supported SQL Server Compact 4.0 database."
	case .Encrypted: return "The ManicTime database is password-protected, which is not supported."
	case .Missing_Tables: return "The database does not contain ManicTime's Group and Activity tables."
	case .Read_Failed: return "Reading the ManicTime database failed. If ManicTime is running, close it and try again."
	case .Apply_Failed: return "The import failed. No changes were applied."
	case .Cancelled: return "Import cancelled. No changes were applied."
	}
	return ""
}
