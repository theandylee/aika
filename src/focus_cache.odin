package main

import "core:strings"

FOCUS_CACHE_TTL_MS :: 60_000

Process_Identity :: struct {
	pid: u32,
	created: u64, // raw process creation FILETIME; PID alone is not an identity
}

// One validated process, not an unbounded PID map. Titles/window handles are
// never retained here. Metadata/hash/XML are owned; name borrows that metadata.
Focus_Cache :: struct {
	key: Process_Identity,
	info: WindowInfo,
	name, hash, text_data: string,
	loaded_mono: i64,
	group_id: i64,
	color: Argb,
	db_handle: ^sqlite3,
}

focus_cache_clear :: proc(cache: ^Focus_Cache) {
	delete(cache.info.path)
	delete(cache.info.file_name)
	delete(cache.info.product)
	delete(cache.info.company)
	delete(cache.info.description)
	delete(cache.hash)
	delete(cache.text_data)
	cache^ = {}
}

focus_name :: proc(info: WindowInfo) -> string {
	if info.product != "" { return info.product }
	name := strip_extension(info.file_name)
	if name != "" { return name }
	return "Unknown"
}

// Split sampler: every call still obtains foreground HWND/PID/title, then probes
// the process instance. Only stable metadata and resolved group work are cached.
tracker_cached_foreground :: proc(app: ^App) -> (WindowInfo, bool) {
	io := &app.tracker.io
	sample: WindowInfo
	ok: bool
	if io.sample != nil { sample, ok = io.sample(io.data) } else { sample, ok = get_foreground_window_sample() }
	if !ok { return {}, false }
	key: Process_Identity
	identified: bool
	if io.identify != nil {
		key, identified = io.identify(io.data, sample.pid)
	} else {
		key, identified = query_process_identity(sample.pid)
	}
	identified = identified && sample.pid != 0 && key.pid == sample.pid && key.created != 0
	if !identified { key = Process_Identity{pid = sample.pid} }
	cache := &app.tracker.focus_cache
	mono := tracker_monotonic(app)
	age := mono - cache.loaded_mono
	if !identified || cache.key != key || age < 0 || age >= FOCUS_CACHE_TTL_MS {
		focus_cache_clear(cache)
		info: WindowInfo
		cacheable: bool
		if io.metadata != nil {
			info, cacheable = io.metadata(io.data, key)
		} else {
			info, cacheable = query_process_metadata(key)
		}
		if info.file_name == "" { info.file_name = base_name(info.path) }
		if identified && cacheable && info.path != "" && info.file_name != "" {
			cache.key, cache.loaded_mono = key, mono
			cache.info = WindowInfo{path = strings.clone(info.path), file_name = strings.clone(info.file_name),
				product = strings.clone(info.product), company = strings.clone(info.company),
				description = strings.clone(info.description)}
			cache.name = focus_name(cache.info)
			cache.hash = strings.clone(key_hash(make_group_key(info.file_name, info.product)))
			cache.text_data = strings.clone(make_group_text_data(info.file_name, cache.name, info.company, info.path, info.description))
		} else {
			// Keep the original uncached fallback behavior, but retry on every
			// subsequent sample. Never use a PID-only entry after failed validation.
			info.hwnd, info.pid, info.title = sample.hwnd, sample.pid, sample.title
			if info.file_name == "" { info.file_name = focus_pid_name(sample.pid) }
			info.cacheable, info.created = false, 0
			return info, true
		}
	}
	info := cache.info
	info.hwnd, info.pid, info.title = sample.hwnd, sample.pid, sample.title
	info.created, info.cacheable = key.created, true
	return info, true
}

tracker_focus_group :: proc(app: ^App, info: WindowInfo) -> (i64, Argb, DB_Result) {
	cache := &app.tracker.focus_cache
	if info.cacheable && cache.key.created != 0 && cache.key == (Process_Identity{pid = info.pid, created = info.created}) {
		if cache.group_id > 0 && cache.db_handle == app.db.handle { return cache.group_id, cache.color, .Ok }
		id, color, result := tracker_ensure_focus_group(app, cache.hash, cache.name, cache.text_data)
		if result == .Ok {
			cache.group_id, cache.color, cache.db_handle = id, color, app.db.handle
		}
		return id, color, result
	}
	name := focus_name(info)
	hash := key_hash(make_group_key(info.file_name, info.product))
	text := make_group_text_data(info.file_name, name, info.company, info.path, info.description)
	return tracker_ensure_focus_group(app, hash, name, text)
}

tracker_ensure_focus_group :: proc(app: ^App, hash, name, text: string) -> (i64, Argb, DB_Result) {
	io := &app.tracker.io
	if io.ensure_focus_group != nil { return io.ensure_focus_group(io.data, &app.db, hash, name, text) }
	return db_ensure_group(&app.db, TIMELINE_APPS, hash, name, text)
}
