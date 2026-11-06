"""Collision-safe imports, reimports, CLI failures, and additive schema upgrade.

Run: python tools/test-import.py build/aika-cli.exe
Uses only isolated temporary databases; never reads/writes data/aika.db.
"""
from contextlib import closing
from datetime import datetime, date, timezone
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile

exe = str(Path(sys.argv[1] if len(sys.argv) > 1 else "build/aika-cli.exe").resolve())
sample = Path(__file__).with_name("manictime-today.json").resolve()
root = Path(os.environ["LOCALAPPDATA"]) / "Temp" / "opencode"


def run(*args, code=0):
    result = subprocess.run([exe, "--quiet", *map(str, args)], capture_output=True, text=True, timeout=20)
    assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
    return result


def query(db, sql, values=()):
    with closing(sqlite3.connect(f"file:{db}?mode=ro", uri=True)) as conn:
        return conn.execute(sql, values).fetchall()


with tempfile.TemporaryDirectory(prefix="aika-import-", dir=root) as folder:
    db = Path(folder) / "history.db"
    payload = json.loads(sample.read_text(encoding="utf-8-sig"))
    run("--db", db, "--import", sample, code=1)  # No guessed legacy identity.
    assert query(db, "SELECT count(*) FROM Activity") == [(0,)]
    run("--db", db, "--import", sample, "--import-source", "sample-db")
    assert query(db, 'SELECT count(*) FROM "Group"') == [(2745,)]
    assert query(db, "SELECT count(*) FROM Activity") == [(202,)]
    original = query(db, "SELECT * FROM Activity ORDER BY ActivityId")
    run("--db", db, "--import", sample, "--import-source", "sample-db")
    assert query(db, "SELECT * FROM Activity ORDER BY ActivityId") == original
    # A renamed export and a payload sourceId use the same persistent namespace.
    payload["sourceId"] = "sample-db"
    renamed = Path(folder) / "renamed export.json"
    renamed.write_text(json.dumps(payload), encoding="utf-8")
    run("--db", db, "--import", renamed)
    assert query(db, "SELECT * FROM Activity ORDER BY ActivityId") == original
    run("--db", db, "--import", renamed, "--import-source", "wrong-db", code=1)
    # A changed source endpoint updates only its mapped, locally unchanged row.
    source_row = payload["activities"][0]
    source_row["endUtcMs"] += 1000
    renamed.write_text(json.dumps(payload), encoding="utf-8")
    run("--db", db, "--import", renamed)
    local_id = query(db, "SELECT LocalActivityId FROM ImportActivityMap WHERE SourceId=? AND SourceActivityId=?",
                     ("sample-db", source_row["activityId"]))[0][0]
    end = source_row["endUtcMs"]
    local_time = datetime.fromtimestamp(end / 1000)
    utc_time = datetime.fromtimestamp(end / 1000, timezone.utc)
    assert query(db, "SELECT EndUtcMs, EndUtcTime, EndLocalTime, EndLocalDate FROM Activity WHERE ActivityId=?", (local_id,)) == [
        (end, utc_time.strftime("%Y-%m-%d %H:%M:%S"), local_time.strftime("%Y-%m-%d %H:%M:%S"),
         (local_time.date() - date(2000, 1, 1)).days)
    ]
    # Local edits win; a conflicting source change rolls back the whole import.
    with closing(sqlite3.connect(db)) as conn:
        conn.execute("UPDATE Activity SET DisplayName='Local edit' WHERE ActivityId=?", (local_id,))
        conn.commit()
    edited = query(db, "SELECT * FROM Activity ORDER BY ActivityId")
    run("--db", db, "--import", renamed)  # Same source payload preserves local edit.
    assert query(db, "SELECT * FROM Activity ORDER BY ActivityId") == edited
    source_row["endUtcMs"] += 1000
    renamed.write_text(json.dumps(payload), encoding="utf-8")
    run("--db", db, "--import", renamed, code=1)
    assert query(db, "SELECT * FROM Activity ORDER BY ActivityId") == edited
    # Different source databases can reuse all the same numeric IDs safely.
    payload["sourceId"] = "another-db"
    renamed.write_text(json.dumps(payload), encoding="utf-8")
    run("--db", db, "--import", renamed)
    assert query(db, "SELECT count(*) FROM Activity") == [(404,)]
    assert query(db, "SELECT count(*) FROM ImportActivityMap") == [(404,)]
    assert query(db, 'SELECT count(*) FROM Activity a LEFT JOIN "Group" g ON a.GroupId=g.GroupId '
                     'WHERE a.GroupId IS NOT NULL AND (g.GroupId IS NULL OR a.TimelineId<>g.TimelineId)') == [(0,)]
    assert query(db, "PRAGMA foreign_key_check") == []
    # Simulate a pre-provenance DB. Upgrading adds the table, never infers ID
    # ownership or silently rewrites/deduplicates previously imported history.
    legacy = Path(folder) / "legacy.db"
    run("--db", legacy, "--import", sample, "--import-source", "old-db")
    old_rows = query(legacy, "SELECT * FROM Activity ORDER BY ActivityId")
    with closing(sqlite3.connect(legacy)) as conn:
        conn.executescript("DROP TABLE ImportActivityMap; PRAGMA user_version=0;")
    run("--db", legacy, "--import", sample, code=1)
    assert query(legacy, "PRAGMA user_version") == [(1,)]
    assert query(legacy, "SELECT * FROM Activity ORDER BY ActivityId") == old_rows
    assert query(legacy, "SELECT count(*) FROM ImportActivityMap") == [(0,)]
    run("--db", legacy, "--import", sample, "--import-source", "new-provenance")
    assert query(legacy, "SELECT count(*) FROM Activity") == [(404,)]
    assert query(legacy, "SELECT * FROM Activity WHERE ActivityId<=202 ORDER BY ActivityId") == old_rows
    with closing(sqlite3.connect(legacy)) as conn:
        conn.execute("PRAGMA user_version=2")
    run("--db", legacy, "--import", sample, "--import-source", "new-provenance", code=1)
    assert query(legacy, "PRAGMA user_version") == [(2,)]  # Never downgrade an unknown future schema.
    assert query(legacy, "SELECT count(*) FROM Activity") == [(404,)]
    run("--db", db, "--import", Path(folder) / "missing.json", code=1)
    malformed = Path(folder) / "malformed.json"
    malformed.write_text('{"groups":[', encoding="utf-8")
    run("--db", db, "--import", malformed, code=1)
    run("--db", folder, "--import", sample, code=1)  # A directory is not an openable DB file.
    for args in (("--import",), ("--import-source",), ("--db",), ("--unknown",), ("--import-source", "orphan")):
        run(*args, code=2)
    print("PASS: sample/reimports, independent sources, guarded updates, CLI failures, legacy schema upgrade")
