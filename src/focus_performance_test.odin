package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:sys/windows"
import "core:testing"
import "core:time"

// Explicit baseline of the original stable-process path. Only introspects the
// benchmark's own process and writes to an isolated in-memory database.
focus_benchmark_uncached :: proc(db: ^DB, pid: u32) -> DB_Result {
	path := query_process_path(pid)
	product, company, description := query_version_strings(path)
	file := base_name(path)
	name := product if product != "" else strip_extension(file)
	hash := key_hash(make_group_key(file, product))
	text := make_group_text_data(file, name, company, path, description)
	_, _, result := db_ensure_group(db, TIMELINE_APPS, hash, name, text)
	return result
}

focus_benchmark_sample :: proc(data: rawptr) -> (WindowInfo, bool) {
	return WindowInfo{pid = (^u32)(data)^, title = "Benchmark title"}, true
}

@(test)
focus_polling_measurement :: proc(t: ^testing.T) {
	flag := os.get_env("AIKA_FOCUS_BENCHMARK", context.allocator)
	defer delete(flag)
	if flag != "1" { return }
	db, ok := db_open(":memory:")
	testing.expect(t, ok)
	if !ok { return }
	defer db_close(&db)
	pid := u32(windows.GetCurrentProcessId())
	app := App{db = db}
	app.tracker.io = Tracker_IO{data = &pid, sample = focus_benchmark_sample}
	defer tracker_release(&app.tracker)
	for phase in 0 ..< 2 {
		samples: [101]f64
		for &sample in samples {
			scratch: Scratch
			context.temp_allocator = scratch_begin(&scratch)
			start := time.tick_now()
			result: DB_Result
			if phase == 0 {
				result = focus_benchmark_uncached(&db, pid)
			} else {
				info, available := tracker_foreground(&app)
				testing.expect(t, available)
				_, _, result = tracker_focus_group(&app, info)
			}
			sample = time.duration_microseconds(time.tick_since(start))
			testing.expect(t, result == .Ok)
			scratch_end(&scratch)
		}
		slice.sort(samples[:])
		label := "uncached" if phase == 0 else "identity-validated cache"
		fmt.printf("focus own-process benchmark %s median=%.3f us p95=%.3f us samples=%d\n", label, samples[50], samples[95], len(samples))
	}
	testing.expect(t, app.tracker.focus_cache.key.created != 0)
}
