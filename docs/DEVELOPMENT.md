# Development

## Toolchain

| Tool | Tested version / path |
|---|---|
| Odin | `dev-2025-11-nightly:e5153a9` |
| raylib/raygui | bundled with Odin under `vendor:raylib` (raylib 5.5, raygui 4.0) |
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
| `Access to the database file is not allowed` | SQL CE needs `Temp Path`; close ManicTime |
| `there was an error parsing the query ... Key` | quote `[Key]` or `"Key"` / use `"Group"` |
| Dates off by decades | used `yyyyMMdd` instead of days since 2000-01-01 |
| App rows missing but usage rows present | <5 s titles, idle, or paused |
| Import JSON parse `Unsupported_Type_Error` | PowerShell serialized a `List` as `CliXml` |
