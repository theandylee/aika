# Odin pitfalls — memo from the native-UI rewrite

Compiler errors we actually burned time on while writing `src/winui.odin` /
`src/ui.odin`. Read this before touching the GDI UI; it is a memo of observed
behavior on `dev-2025-11-nightly`, not general Odin documentation. The migration
notes below were verified on `dev-2026-11-nightly:10e57eb`.

## The error → fix table

| # | Error message (paraphrased) | Rule | Fix |
|---|---|---|---|
| 1 | `'rgb(...)' is not a compile-time known constant` | `::` constants must be compile-time values; a runtime proc call is not. | Palette/flag constants are hex literals (`0x00BBGGRR`), with the `rgb()` comment beside them. |
| 2 | `'DT_SINGLELINE' is not declared by 'windows'` | Enum members live in their enum's namespace, not the package's. | `windows.DrawTextFormat.DT_SINGLELINE`, `windows.BKMODE.TRANSPARENT`, etc. |
| 3 | `'context' has not been defined within this scope` (in `wnd_proc`) | Procedures with non-default calling conventions (`proc "std"`, `proc "c"`) are **contextless** and cannot call context-ful procs. The compiler suggests the fix. | First statement: `context = rt.default_context()` with `import rt "base:runtime"`. (`core:runtime` is deprecated spelling.) |
| 4 | `Mismatched types ... : 'i32' vs 'int'` (everywhere) | Untyped literals infer `int`; `len()`, array literals, etc. return `int`; UI math is `i32`. | Type the counter (`for hour := i32(0); ...`), the constant (`bh := i32(26)`), and cast at call sites (`i32(len(rows))`). |
| 5 | `Cannot compare expression 'int' and 'i32'` | Mixed-comparison loops (`i < len(rows)`) fail. | Bind `n := i32(len(rows))` then `i < n && i < skip + visible`. |
| 6 | `Cannot transmute untyped expression: '(32512)'` | `transmute` needs a typed value. | `transmute(cstring16)(u64(32512))` for `MAKEINTRESOURCE`-style IDs. |
| 7 | `transmute(cstring16, &p[0])` → `Too many values on the right hand side` | `transmute` syntax is `transmute(Type)(value)`, **not** comma-separated. | `transmute(cstring16)(&title[0])` |
| 8 | `'cstring16' is not declared by 'windows'` | `cstring16` is a builtin type, not part of the windows package. | Qualifier-less `cstring16`, via `transmute`. |
| 9 | `Cannot cast 'lparam' as '^MINMAXINFO' from 'int'` | int → pointer is not a plain cast. | `transmute(^windows.MINMAXINFO)(lparam)`. |
| 10 | `Cannot assign value ... of type 'int' to 'u32'` (COLORREF vars) | Hex `::` constants are untyped; `bg := CONST` infers `int`. | Annotate: `bg: windows.COLORREF = C_TAB_ACTIVE if active else C_TAB_BG`. |
| 11 | `Cannot compare untyped value 'nil' to 'string'` (`s != nil`) | Strings are not compared with `nil`. | `len(s) > 0` / `s != ""`; empty by default. |
| 12 | `'SIZE' has no field 'x'` | GDI types: `SIZE.cx/cy`, `POINT.x/y`, `RECT.left/top/right/bottom`. | Use `.cx` etc. |
| 13 | `Cannot assign a type 'SYSTEMTIME' to variable` | `st := windows.SYSTEMTIME` evaluates the *type* expression. | Declare: `st: windows.SYSTEMTIME`. |
| 14 | `Cannot take the pointer address of 'r' which is a procedure parameter` | Value parameters are not addressable. | Copy to a local: `rc := r; FillRect(dc, &rc, ...)`. |
| 15 | `Index 'ai' must be an integer, got Activity` + `'a' of type 'int'` | For slices/arrays the iteration form `for v, i in x` binds **value first, index second** (maps: key, value). | `for a, ai in app.activities { found = &app.activities[ai] }` |
| 16 | `Cannot assign value 'a' of type 'Activity' to '^Activity'` | Range-loop variables are values. | Keep the index (see #15) and store `&slice[idx]`. |
| 17 | `'GetLocalTime' is not declared by 'windows'` | Some Ada functions are declared in this repo's `foreign` blocks (`win32.odin`), shadowing the missing core binding. | Call unqualified `GetLocalTime(&st)`. |
| 18 | `'fmt' declared but not used` | Unused imports/variables are always hard errors, not warnings. | Delete the import. |
| 19 | `LMINMAXINFO`/BOOL constants — `windows.FALSE`/`windows.TRUE` exist | Typed constants exist alongside untyped ones; prefer the typed ones for API params. | `windows.FALSE`, `windows.TRUE`. |

## Allocator trap (runtime, not compile-time)

`make(..., context.temp_allocator)` + `delete(x)` is a **mismatch**: `delete`
uses `context.allocator` by default. In the paint path we do not free
temp-allocated row lists at all — the owning native callback destroys its private
scratch arena on return, including callbacks dispatched by modal loops. Do not
clear a shared temp allocator in nested callbacks or free temp objects with the
default allocator. Persistent metadata must not borrow callback scratch.

The old `mem.Dynamic_Arena` ignored per-request alignment and used its configured
value. On the November 2026 toolchain it honors requested alignment and calls the
configuration parameter `minimum_alignment` (formerly `alignment`). Scratch keeps
`runtime.MAP_CACHE_LINE_SIZE` as its minimum; default 16-byte alignment caused
snapshot maps to panic on the old toolchain.

## November 2026 toolchain migration

- `os.read_entire_file(path, allocator)` returns `(data, err)`; success is
  `err == nil`, not a boolean. Supply `context.allocator` for owned import bytes
  and free them even on read failure, which can return partial data. Preferences
  continue using callback scratch and fall back to defaults on read errors.
- `os.write_entire_file` returns an error too: compare with `nil` to retain the
  existing settings/theme save-failure behavior.
- `os.get_env` requires an explicit allocator; match it with the allocator used
  by `delete`.
- Use `windows.BOOL(ui.dark)` or `windows.TRUE` / `windows.FALSE`, not integer
  casts. The binding is now a boolean type; its Win32 ABI remains 32 bits.
- Vet rejects pointer-to-pointer `transmute` when a regular cast suffices:
  use `cstring16(&buffer[0])`. Integer-to-pointer resource IDs still require
  `transmute` (table entries #6 and #9).

## WndProc checklist (winui.odin)

- `proc "std"` → contextless → `context = rt.default_context()` on line 1.
- Install a local `Scratch` with `scratch_begin` and defer `scratch_end`.
- `WS_CLIPCHILDREN` on the main window, or the parent's `BitBlt` paints over
  the filter EDIT child.
- Create the EDIT control **before** the explicit `MoveWindow` layout call —
  a `WM_SIZE` during `CreateWindowExW` fires while `ui.edit` is still nil.

## Where this cost us time (source of truth)

- ~14 fix/compile iterations on `src/winui.odin` + `src/ui.odin` in the
  native-UI rewrite (2026-11-06). All rules above were verified against
  compiler output from that session, not from memory.
