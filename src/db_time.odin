package main

DB_Time_Columns :: struct {
	local_date, local_time, utc_time, utc_ms: int,
}

// One instant, four representations. SQLite copies text bindings before scratch
// expires. Callers select columns because insert/update/import SQL layouts differ.
db_bind_time :: proc(stmt: ^sqlite3_stmt, ms: i64, cols: DB_Time_Columns) -> DB_Result {
	local := unix_ms_to_local(ms)
	utc := unix_ms_to_utc(ms)
	return db_bind_result(
		bind_i64(stmt, cols.local_date, manic_date_from_date_int(date_int_from_systemtime(local))),
		bind_text(stmt, cols.local_time, format_systemtime(local)),
		bind_text(stmt, cols.utc_time, format_systemtime(utc)),
		bind_i64(stmt, cols.utc_ms, ms))
}
