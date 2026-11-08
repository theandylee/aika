package main

import "core:fmt"
import "core:os"
import "core:testing"

@(test)
settings_timeout_validation :: proc(t: ^testing.T) {
	for text in ([4]string{"1", "60", "500", " 2\n"}) {
		minutes, ok := settings_parse_minutes(text)
		testing.expect(t, ok && minutes >= 1 && minutes <= 500)
	}
	for text in ([7]string{"", "0", "-1", "501", "1.5", "abc", "999999999999999999999999"}) {
		_, ok := settings_parse_minutes(text)
		testing.expect(t, !ok, text)
	}
	testing.expect(t, settings_load_minutes("") == 1)
	testing.expect(t, !settings_save_current("", 0))
	testing.expect(t, !settings_save_current("", 501))
}

@(test)
settings_toml_parse_and_compat :: proc(t: ^testing.T) {
	// Legacy bare number: minutes only, update options default on.
	s := settings_parse_toml("7\n")
	testing.expect(t, s == Settings{idle_minutes = 7, updates_on_start = true, updates_periodic = true, dark = false})
	// Missing/garbage input keeps defaults.
	testing.expect(t, settings_parse_toml("") == SETTINGS_DEFAULT)
	testing.expect(t, settings_parse_toml("not toml at all\n[x\n=\n") == SETTINGS_DEFAULT)
	// Full file with comments, spacing, unknown keys and out-of-range values.
	s = settings_parse_toml("# aika\n[tracking]\nidle_minutes = 12 # idle\nother = 1\n\n[updates]\non_start=false\nperiodic = true\n[appearance]\ntheme = \"dark\"\n[misc]\non_start = true\n")
	testing.expect(t, s == Settings{idle_minutes = 12, updates_on_start = false, updates_periodic = true, dark = true})
	s = settings_parse_toml("[tracking]\nidle_minutes = 9000\n[updates]\nperiodic = maybe\n")
	testing.expect(t, s == SETTINGS_DEFAULT, "invalid values are ignored")
	// Format round trip.
	for want in ([3]Settings{{idle_minutes = 5, dark = true}, {idle_minutes = 500, updates_on_start = true, picker_w = 600, picker_h = 480}, {idle_minutes = 1, updates_periodic = true, dark = true}}) {
		testing.expect(t, settings_parse_toml(settings_format_toml(want)) == want)
	}
	testing.expect(t, !settings_save("x", Settings{idle_minutes = 0}))
}

@(test)
settings_file_roundtrip :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	on_start, periodic := update_policy()
	defer update_set_policy(on_start, periodic)
	path := fmt.tprintf("%s\\settings-roundtrip.db", test_temp_dir())
	defer os.remove(settings_path(path))
	os.remove(settings_path(path))

	testing.expect(t, settings_load(path) == SETTINGS_DEFAULT)
	testing.expect(t, os.write_entire_file(settings_path(path), transmute([]u8)string("7\n")) == nil)
	testing.expect(t, settings_load_minutes(path) == 7)

	update_set_policy(false, true)
	testing.expect(t, settings_save_current(path, 9))
	testing.expect(t, settings_load(path) == Settings{idle_minutes = 9, updates_on_start = false, updates_periodic = true, dark = ui.dark})
}

@(test)
settings_migrate_legacy_files :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := fmt.tprintf("%s\\migrate.db", test_temp_dir())
	legacy_settings, legacy_theme := fmt.tprintf("%s.settings", path), fmt.tprintf("%s.theme", path)
	cleanup :: proc(a, b, c: string) { os.remove(a); os.remove(b); os.remove(c) }
	defer cleanup(settings_path(path), legacy_settings, legacy_theme)
	cleanup(settings_path(path), legacy_settings, legacy_theme)

	// Nothing to migrate: no file is created.
	settings_migrate_legacy(path)
	testing.expect(t, !datadir_exists(settings_path(path)))

	// v0.1.0 layout: bare-number .settings plus a .theme file.
	testing.expect(t, os.write_entire_file(legacy_settings, transmute([]u8)string("11\n")) == nil)
	testing.expect(t, os.write_entire_file(legacy_theme, transmute([]u8)string("dark")) == nil)
	settings_migrate_legacy(path)
	testing.expect(t, settings_load(path) == Settings{idle_minutes = 11, updates_on_start = true, updates_periodic = true, dark = true})
	testing.expect(t, !datadir_exists(legacy_settings) && !datadir_exists(legacy_theme), "legacy files are removed")

	// An existing new file always wins; leftover legacy files are not re-read.
	testing.expect(t, os.write_entire_file(legacy_settings, transmute([]u8)string("3\n")) == nil)
	settings_migrate_legacy(path)
	testing.expect(t, settings_load_minutes(path) == 11)
}
