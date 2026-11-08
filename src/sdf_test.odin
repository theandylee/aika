package main

import "core:testing"

@(test)
sdf_unix_ms_converts_sql_datetime :: proc(t: ^testing.T) {
	// 1970-01-01 00:00:00 is day 25567 since 1900-01-01.
	testing.expect_value(t, sdf_unix_ms(Sdf_DateTime{days = 25567, ticks = 0}), i64(0))
	// 1/300 s ticks: 300 ticks = 1 s, rounded to whole milliseconds.
	testing.expect_value(t, sdf_unix_ms(Sdf_DateTime{days = 25567, ticks = 300}), i64(1000))
	testing.expect_value(t, sdf_unix_ms(Sdf_DateTime{days = 25568, ticks = 1}), i64(86_400_003))
}

@(test)
sdf_packed_reads_20_bit_slots :: proc(t: ^testing.T) {
	// Three 20-bit values 1, 2, 3 in one little-endian 64-bit word at offset 4.
	word := u64(1) | u64(2) << 20 | u64(3) << 40
	b: [16]u8
	for i in 0 ..< 8 { b[4 + i] = u8(word >> uint(8 * i)) }
	testing.expect_value(t, sdf_packed(b[:], 4, 0), u32(1))
	testing.expect_value(t, sdf_packed(b[:], 4, 1), u32(2))
	testing.expect_value(t, sdf_packed(b[:], 4, 2), u32(3))
	testing.expect_value(t, sdf_packed(b[:], 4, 6), u32(0)) // beyond the buffer
}

@(test)
sdf_decode_text_handles_both_encodings :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	testing.expect_value(t, sdf_decode_text([]u8{'h', 'i', 0xE9}, true), "hié")
	utf16 := []u8{'a', 0, 0x3D, 0xD8, 0x00, 0xDE, 'b', 0} // a, U+1F600 (surrogate pair), b
	testing.expect_value(t, sdf_decode_text(utf16, false), "a😀b")
}

Progress_Probe :: struct { calls, last_done: int, cancel_at: int }

progress_probe :: proc(stage: Import_Stage, done, total: int, data: rawptr) -> bool {
	p := cast(^Progress_Probe)data
	p.calls += 1
	p.last_done = done
	return p.cancel_at == 0 || done < p.cancel_at
}

@(test)
import_progress_reports_and_cancel_rolls_back :: proc(t: ^testing.T) {
	db, ok := db_open(":memory:")
	defer db_close(&db)
	testing.expect(t, ok)
	n := 3000
	// import_apply frees the temp allocator after every row, so keep input elsewhere.
	acts := make([]ImportActivity, n)
	defer delete(acts)
	for i in 0 ..< n {
		acts[i] = ImportActivity{activityId = i64(i + 1), timelineId = TIMELINE_APPS,
			startUtcMs = 1_700_000_000_000 + i64(i) * 10_000, endUtcMs = 1_700_000_000_000 + i64(i) * 10_000 + 5000}
	}
	imp := ImportFile{source = "ManicTime", sourceId = "t", activities = acts}

	cancel := Progress_Probe{cancel_at = 1024}
	cancelled: bool
	testing.expect(t, !import_apply(&db, &imp, "", progress_probe, &cancel, &cancelled))
	testing.expect(t, cancelled)

	// Nothing was committed, so a full run adds all rows again from scratch.
	full := Progress_Probe{}
	testing.expect(t, import_apply(&db, &imp, "", progress_probe, &full))
	testing.expect_value(t, full.calls, 3) // 0, 1024, 2048
	testing.expect_value(t, full.last_done, 2048)
}

@(test)
sdf_reads_never_go_out_of_bounds :: proc(t: ^testing.T) {
	short := []u8{1, 2, 3}
	testing.expect_value(t, sdf_u32(short, 0), u32(0))
	testing.expect_value(t, sdf_u16(short, 2), u16(0))
	testing.expect_value(t, sdf_u64(short, -1), u64(0))
	_, ok := sdf_cat_decode(short)
	testing.expect(t, !ok)
}
