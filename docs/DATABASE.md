# Database

aika uses SQLite. The schema is deliberately shaped like ManicTime's SQL Server
Compact schema so that existing data can be imported and the same queries are
meaningful.

Default database path:

```
data\aika.db
```

Override with:

```bat
build\aika.exe --db D:\somewhere\aika.db
```

SQLite is opened with:

```sql
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA foreign_keys = ON;
```

WAL means you may see `aika.db-wal` and `aika.db-shm` next to the database.

---

## 1. Schema

The canonical schema lives in `src/db.odin` as `SCHEMA_SQL`.

### Timeline

```sql
CREATE TABLE Timeline (
    TimelineId       INTEGER PRIMARY KEY,
    TypeName         TEXT NOT NULL,
    DisplayName      TEXT,
    DisplayOrder     INTEGER NOT NULL DEFAULT 0,
    GenericTypeName  TEXT,
    SourceTypeName   TEXT,
    SourceAddress    TEXT,
    UpdateInterval   INTEGER NOT NULL DEFAULT 10,
    TextData         TEXT,
    UpdatedTimestamp INTEGER NOT NULL DEFAULT 0
);
```

Seeded rows:

| ID | TypeName | Meaning |
|---:|---|---|
| 1 | `ManicTime/Tags` | user tags |
| 2 | `ManicTime/ComputerUsage` | Active / Away / Session locked / Power off |
| 3 | `ManicTime/Applications` | application activity |
| 4 | `ManicTime/Documents` | document/URL activity (not implemented) |

### Group

`Group` is a reserved word in SQLite; always quote it as `"Group"`.

```sql
CREATE TABLE "Group" (
    GroupId          INTEGER PRIMARY KEY AUTOINCREMENT,
    TimelineId       INTEGER NOT NULL,
    DisplayName      TEXT,
    Color            INTEGER NOT NULL DEFAULT 0,
    FolderId         INTEGER,
    TextData         TEXT,
    Key              TEXT NOT NULL,
    DeleteWhenNotUsed INTEGER NOT NULL DEFAULT 1,
    UpdatedTimestamp INTEGER NOT NULL DEFAULT 0,
    SkipColor        INTEGER NOT NULL DEFAULT 0,
    UNIQUE(TimelineId, Key)
);
```

Important columns:

- `Key`: a Base64 SHA-256 hash. It is **not** the plain display key.
- `Color`: ARGB packed into a signed/unsigned 32-bit integer. Values may be
  negative in ManicTime exports. aika casts through `u32` when reading.
- `TextData`: for application groups:

```xml
<ApplicationGroupTextData>
  <FileName>OpenCode.exe</FileName>
  <Name>OpenCode</Name>
  <Company>OpenCode</Company>
  <FullPath>C:\...\OpenCode.exe</FullPath>
  <Description>OpenCode</Description>
</ApplicationGroupTextData>
```

For document groups:

```xml
<DocumentGroupTextData>
  <Path>C:\some\file.txt</Path>
</DocumentGroupTextData>
```

### Activity

```sql
CREATE TABLE Activity (
    ActivityId       INTEGER PRIMARY KEY AUTOINCREMENT,
    TimelineId       INTEGER NOT NULL,
    DisplayName      TEXT,
    GroupId          INTEGER,
    GroupListId      INTEGER,
    StartLocalDate   INTEGER NOT NULL,
    StartLocalTime   TEXT NOT NULL,
    StartUtcTime     TEXT NOT NULL,
    EndLocalDate     INTEGER NOT NULL,
    EndLocalTime     TEXT NOT NULL,
    EndUtcTime       TEXT NOT NULL,
    StartUtcMs       INTEGER NOT NULL DEFAULT 0,
    EndUtcMs         INTEGER NOT NULL DEFAULT 0,
    TextData         TEXT,
    UpdatedTimestamp INTEGER NOT NULL DEFAULT 0
);
```

Field semantics:

| Field | Meaning |
|---|---|
| `DisplayName` | window title for Applications, document name for Documents |
| `GroupId` | application/document/usage group |
| `StartLocalDate` | **days since 2000-01-01** |
| `StartLocalTime` | local wall clock, `YYYY-MM-DD HH:MM:SS` |
| `StartUtcTime` | UTC wall clock, `YYYY-MM-DD HH:MM:SS` |
| `StartUtcMs` | aika extension: UTC Unix milliseconds |
| `End...` | same semantics as Start |
| `UpdatedTimestamp` | Unix seconds; reserved for incremental sync |

Indexes:

```sql
CREATE INDEX IX_Activity_Timeline_Date
    ON Activity (TimelineId, StartLocalDate, EndLocalDate);

CREATE INDEX IX_Activity_Updated
    ON Activity (UpdatedTimestamp);
```

### Document

Present but currently unused by aika:

```sql
CREATE TABLE Document (
    DocumentId      INTEGER PRIMARY KEY AUTOINCREMENT,
    DocumentType    TEXT,
    Content         TEXT,
    UpdatedTimestamp INTEGER NOT NULL DEFAULT 0,
    Index1 TEXT, Index2 TEXT, Index3 TEXT
);
```

### Sequence

Present for ManicTime compatibility but not used yet:

```sql
CREATE TABLE Sequence (
    Name  TEXT PRIMARY KEY,
    Value INTEGER NOT NULL DEFAULT 0
);
```

ManicTime allocates IDs through this table. aika relies on SQLite
`AUTOINCREMENT` instead. If you need exact ManicTime-style ID allocation later,
use `Sequence` and explicit IDs.

---

## 2. ManicTime date encoding

This is the most important compatibility rule:

> `StartLocalDate` and `EndLocalDate` are **the number of days since
> 2000-01-01**, not `yyyyMMdd`.

Examples from the real ManicTime database:

| Date | Stored value |
|---|---:|
| 2022-03-07 | 8104 |
| 2026-11-06 | 9806 |

Conversion helpers in `src/win32.odin`:

```odin
manic_date_from_date_int(date_int) // yyyyMMdd -> days since 2000
date_int_from_manic_date(manic)    // days since 2000 -> yyyyMMdd
```

The helpers use a civil-date algorithm, not local-time subtraction, so they are
stable across DST.

When querying a day:

```sql
WHERE StartLocalDate <= :manicDate
  AND EndLocalDate   >= :manicDate
```

This handles activities that span midnight.

---

## 3. Group identity

For applications, ManicTime computes:

```
DisplayKey = FileName + ";" + Name
Key         = lowercase(DisplayKey)
KeyHash     = Base64(SHA256(UTF8(Key)))
```

`Name` is normally the executable's `ProductName` from its version resource.
`FileName` is the executable filename, not the full path.

Consequences:

- Two executables with the same filename and product name are one group.
- Moving an executable does not create a new group.
- Changing the product name creates a new group.
- `Group.TextData` preserves the full path for display.

For documents, `DisplayKey` is the path or URL; the same lowercase + SHA-256 +
Base64 scheme applies.

aika uses the same scheme in `key_hash()` / `db_ensure_group()`.

### Tags

User tags are groups on timeline 1; their key is `key_hash(trimmed_tag_name)`.
Names are reused case-insensitively, also for imported tags with different keys.
Each time block is an `Activity` on timeline 1 with the tag's `GroupId` and name
as `DisplayName`. `GroupListId` is unused (one tag per block). New/edited blocks
cannot overlap another tag; touching endpoints are allowed. Creation checks
`StartUtcMs < new_end AND EndUtcMs > new_start` within its transaction, and
resizing uses the same check excluding itself in the UPDATE. Existing imported
overlaps are not rewritten. Creating a tag and its initial block is one transaction. Resizing
updates local dates/times, UTC times, UTC milliseconds and `UpdatedTimestamp`
together, and is restricted to timeline 1. The existing schema is unchanged.

---

## 4. Example queries

### What was focused at time T?

```sql
SELECT a.StartLocalTime, a.EndLocalTime, a.DisplayName AS WindowTitle,
       g.DisplayName AS Application
FROM Activity a
JOIN "Group" g ON g.GroupId = a.GroupId
WHERE a.TimelineId = 3
  AND a.StartUtcMs <= :t_ms
  AND a.EndUtcMs   >  :t_ms
ORDER BY a.StartUtcMs DESC
LIMIT 1;
```

If no row matches, the user was away, locked, off, or the row has not been
flushed yet.

### Activities for a local day

```sql
SELECT a.ActivityId, a.DisplayName, g.DisplayName, a.StartUtcMs, a.EndUtcMs
FROM Activity a
LEFT JOIN "Group" g ON g.GroupId = a.GroupId
WHERE a.TimelineId = 3
  AND a.StartLocalDate <= :manic_date
  AND a.EndLocalDate   >= :manic_date
ORDER BY a.StartUtcMs;
```

### Per-application totals for a day

```sql
SELECT g.DisplayName, SUM(a.EndUtcMs - a.StartUtcMs) AS ms
FROM Activity a
JOIN "Group" g ON g.GroupId = a.GroupId
WHERE a.TimelineId = 3
  AND a.StartLocalDate <= :manic_date
  AND a.EndLocalDate   >= :manic_date
GROUP BY a.GroupId
ORDER BY ms DESC;
```

This does not clamp activities that cross the day boundary. The UI clamps them
before summing.

### Computer usage periods

```sql
SELECT a.StartLocalTime, a.EndLocalTime, g.DisplayName
FROM Activity a
JOIN "Group" g ON g.GroupId = a.GroupId
WHERE a.TimelineId = 2
ORDER BY a.StartUtcMs DESC;
```

Usage group IDs are seeded:

| GroupId | Key hash | Name |
|---:|---|---|
| 1 | `W4yiNcyXGPLtSeJd09iJhvbDr6EL/BE2HWKJS8johz8=` | Active |
| 2 | `jaM0cRC0p2E80XobDIz5aMfg8NBucI9QrcoCdb0ll2o=` | Away |
| 3 | `S7sALuDiUUUJfMuqfN8d1nFc/kVH3SgUYCDbTWNju+c=` | Session locked |
| 4 | `kw+obQQ1f/3ZFvvhV3kgmhQRNnt+Lr2cgk7gFZdu/LU=` | Power off |

The hashes are `Base64(SHA256("manictime/active"))` etc.

---

## 5. Import JSON format

`tools/export-manictime.ps1` produces:

```json
{
  "source": "ManicTime",
  "exportedAt": "2026-11-06T07:52:29.4112812+01:00",
  "fromDate": 20261106,
  "toDate": 20261106,
  "groups": [
    {
      "groupId": 2741,
      "timelineId": 3,
      "displayName": "OpenCode",
      "color": -15593722,
      "key": "5uj2cZ4UTSMJT2HAP2Mxk3bbzzzVTphIxw35yYO3XGU=",
      "textData": "<ApplicationGroupTextData>...</ApplicationGroupTextData>"
    }
  ],
  "activities": [
    {
      "activityId": 577627,
      "timelineId": 3,
      "displayName": "ManicTime window tracking in Ghidra - OpenCode",
      "groupId": 2741,
      "startUtcMs": 1793947021000,
      "endUtcMs": 1793947077000,
      "textData": ""
    }
  ]
}
```

The importer:

1. `json.unmarshal` into `ImportFile`.
2. Inserts groups with `INSERT OR REPLACE`, preserving IDs and colors.
3. Inserts activities with explicit IDs.
4. Recomputes local/UTC fields from `startUtcMs`/`endUtcMs`.
5. Runs inside a `BEGIN`/`COMMIT` transaction.

`--quiet` suppresses the GUI message box for scripted imports. Use
`build\aika-cli.exe` for a console build.

---

## 6. Reading the DB from Python

Always use read-only mode while aika or another tool may be writing:

```python
import sqlite3
p = r"D:\Dev\aika\data\aika.db"
c = sqlite3.connect(f"file:{p}?mode=ro", uri=True)
for row in c.execute("SELECT COUNT(*) FROM Activity"):
    print(row)
```

If you need to write while aika is running, close aika first. SQLite WAL allows
concurrent readers, not multiple writers.

---

## 7. Migration notes

There is no migration framework. The schema is created with
`CREATE TABLE IF NOT EXISTS` and indexes with `CREATE INDEX IF NOT EXISTS`.

If you change the schema:

1. Bump/annotate a version in a new `PRAGMA user_version` or a `SchemaVersion`
   table.
2. Add a migration function in `db_open`.
3. Document it here.
4. Test against both a fresh DB and an imported ManicTime DB.

If you change the date semantics, you will corrupt imported history. Do not.
