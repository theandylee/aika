"""Repeatable query-plan/timing comparison; synthetic TEMP DBs only.

Python SQLite is a query/index proxy, not a benchmark of Odin or its SQLite build.
The schema and day SELECT are read from the repository, never a user's DB.
"""
from pathlib import Path
import os
import re
import sqlite3
import statistics
import tempfile
import time
from contextlib import closing

source = (Path(__file__).resolve().parents[1] / "src/db.odin").read_text()
schema = re.search(r'SCHEMA_SQL :: `(.*?)`', source, re.S)[1]
day_sql = re.search(r'LOAD_ACTIVITIES_SQL :: `(.*?)`', source, re.S)[1].replace(" INDEXED BY IX_Activity_Timeline_Date", "")
index_sql = "CREATE INDEX IX_Activity_Timeline_Start ON Activity(TimelineId, StartUtcMs, ActivityId)"
root = Path(os.environ["LOCALAPPDATA"]) / "Temp/opencode"
with tempfile.TemporaryDirectory(prefix="aika-bench-", dir=root) as folder:
    with closing(sqlite3.connect(Path(folder) / "history.db", cached_statements=0)) as db:
        db.executescript(schema)
        db.execute("DROP INDEX IF EXISTS IX_Activity_Timeline_Start")
        # 365 days, 900 app switches + 24 tags + 2 usage rows per day.
        origin = 1_700_000_000_000
        rows = []
        for day in range(365):
            for tl, count in [(1, 24), (2, 2), (3, 900)]:
                for item in range(count):
                    start = origin + day * 86_400_000 + item * (86_400_000 // count)
                    rows.append((tl, f"item {item}", 0, day, "", "", day, "", "",
                                 start, start + 86_400_000 // count))
        db.executemany("INSERT INTO Activity(TimelineId,DisplayName,GroupId,StartLocalDate,"
                       "StartLocalTime,StartUtcTime,EndLocalDate,EndLocalTime,EndUtcTime,"
                       "StartUtcMs,EndUtcMs) VALUES (?,?,?,?,?,?,?,?,?,?,?)", rows)
        db.commit()
        queries = {
            "latest app": ("SELECT ActivityId, COALESCE(GroupId,0), COALESCE(DisplayName,''), StartUtcMs, EndUtcMs "
                           "FROM Activity WHERE TimelineId=?1 AND EndUtcMs>0 "
                           "ORDER BY StartUtcMs DESC, ActivityId DESC LIMIT 1", (3,)),
            "task neighbor": ("SELECT MIN(StartUtcMs) FROM Activity WHERE TimelineId=1 AND ActivityId<>?1 "
                              "AND StartUtcMs>=?2 AND EndUtcMs>StartUtcMs", (0, origin + 364 * 86_400_000)),
            "recent day": (day_sql, (364, origin + 364 * 86_400_000, origin + 365 * 86_400_000)),

            "recent day pinned": (day_sql.replace("FROM Activity a", "FROM Activity a INDEXED BY IX_Activity_Timeline_Date"),
                                  (364, origin + 364 * 86_400_000, origin + 365 * 86_400_000)),
        }
        print(f"SQLite {sqlite3.sqlite_version}; {len(rows)} synthetic rows; 21 warm executions, median ms")
        for phase in ["before", "after"]:
            if phase == "after":
                db.execute(index_sql)
                db.commit()
            print(phase)
            for name, (sql, params) in queries.items():
                expected = db.execute(sql, params).fetchall()
                elapsed = []
                for _ in range(21):
                    begin = time.perf_counter()
                    actual = db.execute(sql, params).fetchall()
                    elapsed.append((time.perf_counter() - begin) * 1000)
                    assert actual == expected
                print(f"  {name}: {statistics.median(elapsed):.3f} ms, {len(expected)} rows")
                print("   ", [r[3] for r in db.execute("EXPLAIN QUERY PLAN " + sql, params)])
