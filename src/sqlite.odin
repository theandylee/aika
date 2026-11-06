package main

import "core:c"

foreign import aika_sqlite "../vendor/sqlite/sqlite3.lib"

sqlite3 :: struct {}
sqlite3_stmt :: struct {}

SQLITE_OK :: 0
SQLITE_BUSY :: 5
SQLITE_LOCKED :: 6
SQLITE_ROW :: 100
SQLITE_DONE :: 101

SQLITE_INTEGER :: 1
SQLITE_FLOAT :: 2
SQLITE_TEXT :: 3
SQLITE_BLOB :: 4
SQLITE_NULL :: 5

SQLITE_OPEN_READONLY :: 0x0000_0001
SQLITE_OPEN_READWRITE :: 0x0000_0002
SQLITE_OPEN_CREATE :: 0x0000_0004
SQLITE_OPEN_FULLMUTEX :: 0x0001_0000

SQLITE_TRANSIENT :: rawptr(~uintptr(0))

@(default_calling_convention = "c")
foreign aika_sqlite {
	sqlite3_open_v2 :: proc(filename: cstring, ppDb: ^^sqlite3, flags: c.int, zVfs: cstring) -> c.int ---
	sqlite3_close_v2 :: proc(db: ^sqlite3) -> c.int ---
	sqlite3_errmsg :: proc(db: ^sqlite3) -> cstring ---
	sqlite3_errcode :: proc(db: ^sqlite3) -> c.int ---
	sqlite3_exec :: proc(db: ^sqlite3, sql: cstring, callback: rawptr, arg: rawptr, errmsg: ^cstring) -> c.int ---
	sqlite3_free :: proc(ptr: rawptr) ---
	sqlite3_busy_timeout :: proc(db: ^sqlite3, ms: c.int) -> c.int ---
	sqlite3_prepare_v2 :: proc(db: ^sqlite3, zSql: cstring, nByte: c.int, ppStmt: ^^sqlite3_stmt, pzTail: ^cstring) -> c.int ---
	sqlite3_step :: proc(stmt: ^sqlite3_stmt) -> c.int ---
	sqlite3_reset :: proc(stmt: ^sqlite3_stmt) -> c.int ---
	sqlite3_finalize :: proc(stmt: ^sqlite3_stmt) -> c.int ---
	sqlite3_bind_text :: proc(stmt: ^sqlite3_stmt, idx: c.int, text: cstring, n: c.int, destructor: rawptr) -> c.int ---
	sqlite3_bind_int64 :: proc(stmt: ^sqlite3_stmt, idx: c.int, value: i64) -> c.int ---
	sqlite3_bind_int :: proc(stmt: ^sqlite3_stmt, idx: c.int, value: c.int) -> c.int ---
	sqlite3_bind_null :: proc(stmt: ^sqlite3_stmt, idx: c.int) -> c.int ---
	sqlite3_column_int64 :: proc(stmt: ^sqlite3_stmt, col: c.int) -> i64 ---
	sqlite3_column_int :: proc(stmt: ^sqlite3_stmt, col: c.int) -> c.int ---
	sqlite3_column_text :: proc(stmt: ^sqlite3_stmt, col: c.int) -> ^u8 ---
	sqlite3_column_bytes :: proc(stmt: ^sqlite3_stmt, col: c.int) -> c.int ---
	sqlite3_column_type :: proc(stmt: ^sqlite3_stmt, col: c.int) -> c.int ---
	sqlite3_last_insert_rowid :: proc(db: ^sqlite3) -> i64 ---
	sqlite3_changes :: proc(db: ^sqlite3) -> c.int ---
	sqlite3_progress_handler :: proc(db: ^sqlite3, instructions: c.int, callback: proc "c" (data: rawptr) -> c.int, data: rawptr) ---
}
