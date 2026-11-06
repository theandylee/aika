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

### ImportActivityMap (aika extension, schema version 1)

```sql
CREATE TABLE ImportActivityMap (
    SourceId TEXT NOT NULL CHECK(length(SourceId) > 0),
    SourceActivityId INTEGER NOT NULL CHECK(SourceActivityId > 0),
    SourceTimelineId INTEGER NOT NULL CHECK(SourceTimelineId BETWEEN 1 AND 4),
    SourceStartUtcMs INTEGER NOT NULL CHECK(SourceStartUtcMs > 0),
    LocalActivityId INTEGER UNIQUE REFERENCES Activity(ActivityId) ON DELETE SET NULL,
    SourceFingerprint TEXT NOT NULL,
    LocalFingerprint TEXT NOT NULL,
    PRIMARY KEY (SourceId, SourceActivityId)
);
```

`SourceId` is an explicit, case-sensitive identifier for one source database
generation. Source activity IDs are namespaced by it, never inserted into
`Activity.ActivityId`. `LocalActivityId` is allocated by SQLite; NULL means the
local row was deleted and must not be resurrected by reimporting.

`SourceFingerprint` hashes the last imported timeline, resolved local group,
start/end UTC milliseconds, title and text data. `LocalFingerprint` hashes the
stored activity fields (including all timestamp representations and GroupListId,
excluding the bookkeeping UpdatedTimestamp). They are case-sensitive SHA-256
hashes with Base64 encoding, not ManicTime's lowercased group-key hashes. A changed
source payload may update its mapped activity only when the current local row
still matches that baseline. Both mapping and activity writes share one transaction.

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
  AND StartUtcMs < :nextLocalMidnightUtcMs
  AND EndUtcMs > :localMidnightUtcMs
```

Intervals are half-open `[start, end)`. Local-day bounds are midnight through
exclusive next midnight (23/24/25 hours as appropriate), not midnight minus 1 ms.
The UTC predicates exclude an activity ending exactly at the selected day's
start, while retaining activities that span midnight. Repository insert/endpoint
updates reject reversed intervals; no migration repairs old malformed history.

Idle reconciliation is one transaction over pending writes, current-spell-owned
application rows, and Active/Away endpoints. It trims rows crossing the cutoff and
deletes those starting after it. Ownership is by runtime ID/spell, not timestamp
coincidence, so unrelated/imported history is not rewritten after a clock jump.

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
  AND a.StartUtcMs < :day_end AND a.EndUtcMs > :day_start
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
  AND a.StartUtcMs < :day_end AND a.EndUtcMs > :day_start
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

Usage groups are seeded by timeline/key. The following numeric IDs are typical
only for a fresh database; always resolve identity by `(TimelineId, Key)` rather
than assuming source IDs or these local IDs:

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
  "sourceId": "home-manictime-1",
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

Pass `-SourceId home-manictime-1` to the exporter. Reuse it across files, date
ranges, renames and copies for that same source database. Choose a new ID only
after replacing/resetting the source database. Do not derive IDs from timestamps,
export paths or the generic `"source": "ManicTime"` label. IDs must contain
1–256 UTF-8 bytes with no surrounding whitespace or embedded NUL.

Legacy JSON without `sourceId`, including the checked-in sample, needs an explicit
identity:

```bat
build\aika-cli.exe --db data\import-test.db --import tools\manictime-today.json --import-source manictime-sample --quiet
```

If both the payload and CLI supply an ID, they must agree. The importer:

1. Parses the JSON into an import-owned arena and validates every row before
   starting any import writes. Source IDs must be positive/unique, timelines must
   be 1–4, keys nonempty, and nonzero group references must resolve in the file on
   the same timeline. Zero/missing, reversed, and out-of-range timestamps fail the
   whole import rather than being silently skipped. Supported UTC milliseconds
   are after the Unix epoch through year 9999, with `end >= start`.
2. Starts `BEGIN IMMEDIATE`. Resolves groups by `(TimelineId, Key)`, allocating
   local IDs for new identities. Existing names, colors and metadata win; new
   groups preserve source colors and metadata. Multiple source group IDs can map
   to the same identity. No `INSERT OR REPLACE` is used.
3. Allocates new local activity IDs and records source mappings. Explicitly
   ungrouped activities (`groupId: 0`) store SQL NULL, not a guessed local group.
4. Treats identical source payloads as no-ops, including after local edits. A
   changed source payload updates only a mapped, locally unchanged row; a local
   conflict aborts the whole transaction. A changed timeline/start for the same
   source activity ID is an identity conflict, not an implicit replacement.
   Legitimate source start-time edits need reviewed reconciliation; do not invent
   a new source ID merely to bypass a conflict.
5. Keeps locally deleted rows tombstoned. Reimports never delete rows merely
   absent from a particular exported date range.
6. Recomputes all local/UTC timestamp representations together on writes, then
   commits activities, groups and provenance atomically. Any write or commit
   failure rolls back everything. Per-row scratch is reset only after its
   statements have finalized; all parsed/scratch storage is released on return.

`--quiet` suppresses the GUI message box for scripted imports. Use
`build\aika-cli.exe` for a console build. Exit codes: 0 on success, 1 on database
or import failure, 2 for invalid/missing CLI arguments.

**Pre-provenance imports:** existing activities are never adopted by numeric ID
or content guesses. Back up an existing database first. Reimporting legacy history
can add a duplicate copy once because the old rows have no source ownership.
Prefer a fresh DB for a clean reimport or review existing history first. The new
importer does not repair earlier orphaned/overwritten history automatically.

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

`db_init_schema` performs schema/seed initialization in a transaction and uses
`PRAGMA user_version`. Version 0 (the old schema) upgrades additively to version 1
by creating `ImportActivityMap`; existing activity/group rows are retained without
inferring provenance or changing their primary keys. New databases start at
version 1. Higher, unsupported versions are rejected rather than downgraded.
Tables/indexes still use `CREATE ... IF NOT EXISTS`.

If you change the schema:

1. Bump/annotate a version in a new `PRAGMA user_version` or a `SchemaVersion`
   table.
2. Add a migration function in `db_open`.
3. Document it here.
4. Test against both a fresh DB and an imported ManicTime DB.

If you change the date semantics, you will corrupt imported history. Do not.
