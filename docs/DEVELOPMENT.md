# Development

## Toolchain

| Tool | Tested version / path |
|---|---|
| Odin | `dev-2025-11-nightly:e5153a9` |
| raylib/raygui | bundled with Odin under `vendor:raylib` (raylib 5.5; raygui 4.0 still linked but unused — see below) |
| SQLite | 3.54.1 amalgamation, statically linked |
| C compiler for SQLite | MSVC 2022 (`cl.exe` 14.38) |
| PowerShell | Windows PowerShell 5.1 for the exporter |

Odin on this machine:

```
C:\Users\<user>\AppData\Local\Microsoft\WinGet\Packages\odin-lang.Odin_...\odin.exe
```

The project does not require `ODIN_ROOT` to be set; `odin` on `PATH` is enough.

---

## Build

```bat
cd /d D:\Dev\aika
build.bat
```

`build.bat` runs:

```bat
odin build src -out:build\aika.exe -define:RAYLIB_SHARED=true -subsystem:windows
odin build src -out:build\aika-cli.exe -define:RAYLIB_SHARED=true
copy /Y vendor\raylib\raylib.dll build\raylib.dll
```

`aika.exe` is the GUI build (no console). `aika-cli.exe` is the console build for
imports and debugging.

Run:

```bat
run.bat
```

or:

```bat
build\aika.exe --db data\aika.db
```

---

## Why raylib is linked shared

Odin's `vendor:raylib` ships both `raylib.lib` (static) and `raylibdll.lib`
(import library). The static library defines a function named `CloseWindow`,
which collides with Win32 `CloseWindow` from `user32.lib`:

```
raylib.lib(rcore.obj) : error LNK2005: CloseWindow already defined in user32.lib(USER32.dll)
```

Use `-define:RAYLIB_SHARED=true` and ship `raylib.dll` next to the executable.
Do not "fix" this with `/FORCE:MULTIPLE`; the wrong `CloseWindow` may be chosen
at runtime.

The runtime DLL is copied from:

```
vendor\raylib\raylib.dll
```

This file should match the Odin vendor version. If you upgrade Odin, copy the
new `vendor\raylib\windows\raylib.dll` into `vendor\raylib\`.

---

## UI scale, fonts, and buttons

### The `UI_S` scale factor

Everything readable in the UI is multiplied by `UI_S :: 1.4`, defined at the top
of `src/ui.odin`. The rules that keep it consistent:

- `draw_text` / `measure_text` / `truncate_to_width` multiply the *authored*
  font size by `UI_S` internally. Never pre-scale font sizes at call sites —
  pass the unscaled size (e.g. `15`, `22`) and let the helper scale it.
- Coordinates, paddings, lane heights, button rectangles etc. must be scaled
  explicitly at each call site (`24 * UI_S`, `32 * UI_S`, ...). The scale is
  applied to positions manually because most coordinates are relative to panel
  bounds, which auto-adapt to the window size.
- If you add new `draw_text` calls or layout constants, follow the same pattern.
  A missing `* UI_S` on a position shows up as overlapping text at larger
  scale; a double-scaled font size shows up as gigantic text.

### Font atlas size

`load_ui_font` loads `segoeui.ttf` with `LoadFontEx(path, 48, ...)`. The base
size should be **>= the largest rendered size** (`32 * UI_S ≈ 45 px` for the
header). With a base size smaller than the drawn size, glyphs are upscaled and
look blurry. Raising it also increases the atlas; the codepoint range
(32..0x500, needed for Cyrillic in process names) still fits.

### Buttons are custom, not raygui

The four header buttons use `gui_button` in `src/ui.odin` (raylib rectangle
drawing + hit test), not `rl.GuiButton`. Reason: see "Invisible raygui captions"
below. `vendor:raygui` is still linked because it ships with the Odin vendor
package, but no calls remain — do not reintroduce raygui controls without
re-testing text rendering.

---

## Invisible raygui captions (post-mortem)

While scaling the UI, all `GuiButton` captions stopped rendering — the buttons
drew as plain gray rectangles, with glyph pixels entirely absent (verified by
screenshot pixel analysis, not by eyeballing).

Findings, usefully accurate for anyone touching UI text:

1. **Symptom was conditional and weird.** With `.DEFAULT` style writes
   (`TEXT_SIZE`) captions rendered; adding **any control-level style write**
   (`GuiSetStyle(.BUTTON, ...)`) made them vanish. Same `TEXT_SIZE`.
2. **The cause lives in the prebuilt static `raygui.lib`** shipped with the
   Odin vendor package. It is opaque (no source in the repo), so behavior can
   only be established empirically. Root cause was never fully pinned down;
   a real suspect is raygui 4.0's `GuiDrawText`, which leaves `glyphWidth`
   uninitialized in the `TEXT_WRAP_NONE` path (fixed upstream after 4.0, but
   the vendored build may predate the fix) — a garbage `glyphWidth` would skip
   every glyph via the
   `textOffsetX <= textBounds.width - glyphWidth` check.
3. **Bisect empirically, but beware stale binaries.** The biggest time sink was
   results from *old* executables: `taskkill` without `/F` fails silently, a
   rename onto a running exe fails, and `Start-Process` then launches the
   previous build. When iterating on a GUI repro: `taskkill /F`, wait for the
   file lock, `Remove-Item -Force` the copy target, and check the build output
   before launching.
4. **Verify pixels, not impressions.** A screenshot crop plus a color histogram
   (`System.Drawing` in PowerShell) distinguishes "text drawn in wrong color"
   (extra color clusters) from "text not drawn at all" (only fill/border
   colors). The failing case was the latter.
5. **Fix:** stop using raygui controls. `gui_button` gives the same
   functionality for the four buttons in use, with the app font and theme
   colors, and no raygui state involved.

If raygui is ever needed again (e.g. settings panel in the roadmap), test text
rendering first with a minimal `GuiButton` + custom font + one style write,
before building anything on top.

---

## SQLite

The repo includes a prebuilt static library:

```
vendor\sqlite\sqlite3.lib
```

It was built with MSVC. Rebuild only if you change SQLite version/flags.

The amalgamation source is not committed (it is in `.gitignore`), but it is
available locally in `vendor\sqlite\sqlite3.c` and `sqlite3.h`.

Rebuild with MSVC:

```bat
call "C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat"

cd /d D:\Dev\aika\vendor\sqlite
cl /nologo /c /O2 /DSQLITE_THREADSAFE=1 /DSQLITE_OMIT_LOAD_EXTENSION /DSQLITE_DQS=0 sqlite3.c /Fosqlite3.obj
lib /nologo /out:sqlite3.lib sqlite3.obj
```

Do **not** build the static lib with the default LLVM/MinGW target. It emits
`___chkstk_ms` references that MSVC's linker cannot resolve:

```
sqlite3.lib(sqlite3.obj) : error LNK2019:
unresolved external symbol ___chkstk_ms referenced in function sqlite3_win32_write_debug
```

If you must use MinGW, build a DLL and generate an import library instead.

---

## Debugging

### Static checks

```bat
odin check src -vet
```

The project currently has zero vet warnings. Keep it that way.

### Console output

The GUI build is `-subsystem:windows`, so `fmt.println` may not appear when
launched from Explorer. To see logs:

- run `build\aika-cli.exe`, or
- launch `build\aika.exe` from an existing terminal and redirect stdout, or
- temporarily build without `-subsystem:windows`.

Do not leave debug prints in `draw_frame`; they flood.

### Database inspection

Use Python read-only:

```python
import sqlite3
p = r"D:\Dev\aika\data\aika.db"
c = sqlite3.connect(f"file:{p}?mode=ro", uri=True)
print(c.execute("select count(*) from Activity").fetchone())
for r in c.execute("select * from Activity order by ActivityId desc limit 5"):
    print(r)
```

If you need the current focused app at time T, see `docs/DATABASE.md`.

### Window not drawing / white window

Past causes:

1. The app hung inside `load_ui_font` because the font codepoint array was
   allocated with `context.temp_allocator` and `defer delete` at return.
   **Fix:** allocate with the default allocator.
2. A stale executable was running after a failed build. Rebuild and verify the
   exe timestamp.
3. The draw loop was blocked before `BeginDrawing`. Add one-shot prints at each
   stage, not per-frame prints.

### Focus tracking not recording

Check:

1. Is `tracker.enabled` true? The header button toggles it.
2. Is the user idle? `idle_ms() >= 10 min` switches to Away and stops app rows.
3. Is the window title changing every couple of seconds? The 5 s rule discards
   short activities, so a rapidly changing title can produce no rows.
4. Is the app window itself foreground? aika records itself too.
5. Check stderr for `activity insert failed` / `group insert failed`.
6. Query `Activity` for timeline 3, not timeline 2.

### Import fails

- Use `build\aika-cli.exe`, not the GUI, to see output.
- `--quiet` suppresses the message box.
- Verify the JSON starts with `{"source":"ManicTime",...,"groups":[...`.
  A PowerShell `List[object]` serialized as `{"CliXml":...}` is invalid; the
  exporter must call `.ToArray()`.
- SQL CE read-only connections need `Temp Path=...`.
- Close ManicTime if SQL CE reports `FileWrite` / access denied.

---

## Coding conventions

- One package: all `.odin` files in `src/` are `package main`.
- No background threads. Keep DB and tracker access on the main thread.
- Use `snake_case` for Odin procedures/variables, `PascalCase` for types.
- Prefer explicit `i64` for timestamps.
- Keep Win32 bindings in `win32.odin`; do not scatter `foreign import` blocks.
- Keep SQL in `db.odin`; do not build SQL strings from user input.
- Free cloned strings when replacing `CurrentActivity` / loading activities.
  `free_activities()` is the existing pattern.
- Use `context.temp_allocator` for short-lived formatting; do not free from it
  manually (see font bug above).
- Quote `"Group"` in every SQL statement.

---

## Adding a feature

### New timeline lane

1. Add a `Timeline` seed row in `SEED_SQL`.
2. Add a `TIMELINE_*` constant in `main.odin`.
3. Extend `db_load_activities` to include the timeline id.
4. Add drawing in `ui.odin` (`draw_timeline`).
5. Add group seeding/lookup if the lane has fixed groups.
6. Update `docs/DATABASE.md`.

### New tracker event

1. Extend `UsageKind` or add a struct in `tracker.odin`.
2. Persist via `db_insert_activity` / `db_update_activity_end`.
3. Trim application activities on transition if appropriate.
4. Add UI rendering and a verification query.
5. Document the event's semantics and group key.

### New document retriever

1. Define a `DocumentInfo` equivalent in Odin.
2. Add a plugin registry ordered by priority.
3. Implement the Win32 retrieval (window hierarchy, UI Automation, etc.).
4. Insert a `DocumentActivity` on timeline 4 and a `DocumentGroup`.
5. Keep title-only tracking as the fallback.

---

## Testing checklist

There is no automated test suite yet. Use this manual checklist:

1. `odin check src -vet`
2. `build.bat`
3. Start GUI; verify the window draws.
4. Focus different apps; verify new rows in timeline 3 after 5 s.
5. Wait 10 s; verify the last row's `EndLocalTime` advances.
6. Switch away from the keyboard for >10 min; verify an `Away` row in timeline 2
   and a gap in timeline 3.
7. Pause tracking; verify no new rows. Resume; verify rows resume.
8. Navigate dates; verify the timeline reloads.
9. Import the sample JSON into a fresh DB; verify 202 activities / 2745 groups.
10. Close via the window close button; verify the current activity is flushed.

---

## Common error reference

| Symptom | Cause / fix |
|---|---|
| `LNK2005 CloseWindow already defined` | raylib static; build with `RAYLIB_SHARED=true` |
| `LNK2019 ___chkstk_ms` | SQLite built with MinGW; rebuild with MSVC |
| White window / no draw | font temp-allocator hang or stale exe |
| Raygui button captions invisible | prebuilt `raygui.lib` stops drawing text after control-level style writes; see "Invisible raygui captions" — buttons are custom now, don't reintroduce raygui |
| Blurry text | font atlas base size smaller than drawn size; see "Font atlas size" |
| Uniformly too-small UI | missing `* UI_S` scaling; see "The `UI_S` scale factor" |
| `Access to the database file is not allowed` | SQL CE needs `Temp Path`; close ManicTime |
| `there was an error parsing the query ... Key` | quote `[Key]` or `"Key"` / use `"Group"` |
| Dates off by decades | used `yyyyMMdd` instead of days since 2000-01-01 |
| App rows missing but usage rows present | <5 s titles, idle, or paused |
| Import JSON parse `Unsupported_Type_Error` | PowerShell serialized a `List` as `CliXml` |
