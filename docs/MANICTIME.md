# ManicTime reverse-engineering notes

These notes preserve what was learned by decompiling the installed ManicTime
build. They are the reference for aika's compatibility decisions. Future agents
should not need to repeat this work unless they want to verify a specific detail.

Target:

```
C:\Program Files (x86)\ManicTime
```

Database:

```
C:\Users\<user>\AppData\Local\Finkit\ManicTime\ManicTime.sdf
```

ManicTime uses SQL Server Compact 4.0 (`.sdf`).

---

## 1. Tooling: Ghidra cannot decompile this

All of the tracking logic is **managed .NET**. The only native binaries in the
install are the bundled SQL CE engine (`sqlce*.dll`) and the VC90 runtime.

Ghidra 12.0.2 was run headlessly on `ManicTime.exe`:

```bat
D:\Programs\ghidra\support\analyzeHeadless.bat <project> MTProject ^
  -import ManicTime.exe ^
  -scriptPath <scripts> -postScript DumpMtInfo.java
```

Ghidra's PE loader recognizes the CLR header and even recovers managed method
names (`Main`, `SystemEvents_SessionEnding`, etc.), but it has no CIL/MSIL
processor. It maps the IL method bodies as x86 and produces nonsense such as:

```c
/* .NET CLR Managed Code */
void __fastcall Main(int args, byte *param_2)
{
    char cVar1;
    ...
    iVar7 = *(int *)(unaff_EDI + 0x3f);
    *in_EAX = *in_EAX + (char)in_EAX;
    ...
}
```

Use **ILSpy** (`ilspycmd`) or **dnSpyEx** for this codebase. The decompilation
used during the original analysis was:

```bat
ilspycmd -p -o <out> -r "C:\Program Files (x86)\ManicTime" ^
  "C:\Program Files (x86)\ManicTime\Finkit.ManicTime.Tracker.O.dll"
```

A temporary copy of the decompiled C# was at:

```
C:\Users\xatar\AppData\Local\Temp\opencode\mt-decomp\
```

That path is not guaranteed to survive. Re-run the command if needed.

---

## 2. Assembly map

| Assembly | Role |
|---|---|
| `ManicTime.exe` | tracker/tray process, managed |
| `Finkit.ManicTime.Tracker.O.dll` | obfuscated core tracking logic |
| `Finkit.ManicTime.Tracker.dll` | event pipeline, DB writers |
| `Finkit.ManicTime.Common.dll` | Win32 wrappers, models, repositories |
| `Finkit.ManicTime.Client.dll` | WPF day view and timeline UI |
| `Plugins\Plugins.*.dll` | browser/Office document retrievers |

Key classes:

```
ActivityTracker.ApplicationTracking.MonitorActiveApplication
ActivityTracker.ApplicationTracking.ApplicationTracker
ActivityTracker.ApplicationTracking.ActiveApplication
ActivityTracker.ApplicationTracking.MonitorDocument
ActivityTracker.ComputerUsageTracking.ComputerUsageTracker
ActivityTracker.ComputerUsageTracking.TimeLimitedInactivity
ActivityTracker.ComputerUsageTracking.ScreenSaverInactivity
ActivityTracker.ComputerUsageTracking.WindowsMessageForm

Finkit.ManicTime.Tracker.TrackerCache.EventTracker
Finkit.ManicTime.Tracker.Tracking.TrackerEventProcessor.ApplicationDocument.ApplicationDocumentProcessor
Finkit.ManicTime.Tracker.TrackerEventProcessor.ActivityProcessor
Finkit.ManicTime.Tracker.Tracking.TrackerEventProcessor.ApplicationDocument.ApplicationDBWriter
Finkit.ManicTime.Tracker.Tracking.TrackerEventProcessor.ApplicationDocument.DocumentDBWriter
Finkit.ManicTime.Tracker.Main.ApplicationGroupLibrary

Finkit.ManicTime.Common.Win32.WindowsFunctions
Finkit.ManicTime.Plugins.TimelineEntityWithKey
Finkit.ManicTime.Plugins.Timelines.Applications.ApplicationGroup
Finkit.ManicTime.Plugins.Timelines.Documents.DocumentGroup
Finkit.ManicTime.Common.ActivityHelper

Finkit.ManicTime.Client.Plugins.LocalServerType.LocalDayViewLoader
Finkit.ManicTime.Client.Views.DayView.DayViewActivity
Finkit.ManicTime.Client.Views.DayView.DayViewUpdater
Finkit.ManicTime.Client.Views.DayView.DayTimelines

Plugins.Chrome.ChromeUrlRetreiver
```

Note: `Finkit.ManicTime.Tracker.O.dll` is obfuscated. Public class/property names
survive, but internal method names are hashes such as `c0764c1739...`. The
control flow is flattened and contains dead `switch` blocks. Read it by class
shape and Win32 calls, not by internal names.

---

## 3. How ManicTime detects the focused window

It does **not** use `SetWinEventHook` or a keyboard/mouse hook. It polls.

`MonitorActiveApplication`:

- A `System.Timers.Timer` is set to **1000 ms**.
- Each tick calls `GetActiveWindow()`.
- A re-entrancy guard skips ticks while a previous tick is still running.

`GetActiveWindow()`:

1. `GetForegroundWindow()`
2. `GetWindowThreadProcessId()`
3. `ProcessUtil.GetProcessFileName()`:
   - `QueryFullProcessImageName` on Vista+
   - `GetProcessImageFileName` + `QueryDosDevice` fallback
4. `FileVersionInfo`:
   - `ProductName`
   - `CompanyName`
   - `FileDescription`
   - version parts
5. `GetWindowTextW` for the title; fallback to the process's main window title
6. `MonitorDocument.GetDocument(ApplicationInfo)` for an optional URL/file path
7. Cache the resolved process per HWND for 2 minutes

`ActiveApplication` comparison:

```csharp
Process.ProcessId == other.Process.ProcessId &&
Title == other.Title &&
DocumentInfo.Equals(other.DocumentInfo)
```

If unchanged, no event. If changed, `ApplicationTracker` raises
`ApplicationActivated`.

Important consequences:

- 1-second sampling resolution.
- Only the foreground top-level window.
- A title change in the same process is a new activity (browser tab switches).
- Two windows with the same process and title are indistinguishable.
- The HWND is only a runtime cache key; it is not persisted.

### Document/URL layer

`MonitorDocument` runs `IDocumentRetreiver` plugins in `CallOrder` order and
caches results per window. `DocumentInfo` has:

- `DocumentDisplayName`
- `DocumentName`
- `DocumentGroupName` (stable identity)
- `DocumentType` (`File`, `WebSite`, `Other`)

`Plugins.Chrome.ChromeUrlRetreiver`:

- Enumerates child windows with `EnumChildWindows`.
- Finds the omnibox control by class name.
- Sends `WM_GETTEXT` (`SendMessage(hwnd, 13, ...)`).
- Extracts the URL with `UrlHelper.ExtractUrl`.

Similar plugins exist for Firefox, IE, Office, Acrobat, Photoshop, etc.

---

## 4. Event pipeline and persistence

```
ApplicationActivated
  -> EventTracker (queue)
  -> TrackerEventsEvent
  -> ApplicationDocumentProcessor
  -> ApplicationActivity + DocumentActivity
  -> Activity/Group rows
```

`EventTracker`:

- Subscribes to `ApplicationActivated` only when tracking is on the record.
- On activation: `ApplicationEvent(now, activeApplication)`.
- On timer: `ExtendingEvent(now)` then publishes the queue.
- Timer interval:
  - **10 seconds** while the day view is visible
  - **60 seconds** otherwise
- Power suspend suppresses publishing.

`ApplicationDocumentProcessor`:

- On a non-Active computer usage event:
  - `FinishAndSaveActivities(now)`
  - `DeleteFromRepositoryAfterTime(awayStartedAt)`
  - This removes application activity after the real away start.
- On `ApplicationEvent`:
  - creates `ApplicationActivity` with `StartTime = event.At`
  - `EndTime = StartTime`
  - creates `DocumentActivity` if a document was recognized
- On `ExtendingEvent`:
  - `LastActivity.EndTime = now`

### The 5-second rule

`ActivityProcessor.ProcessTrackerEvents` / `SaveActivity`:

- Only saves rows once the last activity is at least 5 seconds old.
- A new activity starting less than 5 seconds after the previous start causes
  the previous row to be removed and the new one to be backdated.
- If the new activity matches the one before the previous, they are merged.
- Otherwise the previous row's end time is set to the new start time, keeping the
  active timeline contiguous.

---

## 5. Group identity

`ApplicationGroup`:

```csharp
public override string DisplayKey => FileName + ";" + Name;
```

`TimelineEntityWithKey`:

```csharp
Key     = displayKey.ToLowerInvariant()
KeyHash = HashHelper.GetHash(Key)
```

`HashHelper.GetHash`:

```csharp
Convert.ToBase64String(SHA256(UTF8(key)))
```

`Name` is `FileVersionInfo.ProductName`, `FileName` is the exe filename. The full
path is not part of the key. `ApplicationGroup.TextData` stores:

```xml
<ApplicationGroupTextData>
  <FileName>...</FileName>
  <Name>...</Name>
  <Company>...</Company>
  <FullPath>...</FullPath>
  <Description>...</Description>
</ApplicationGroupTextData>
```

Document groups use the path/URL as `DisplayKey`, with:

```xml
<DocumentGroupTextData><Path>...</Path></DocumentGroupTextData>
```

The group icon is extracted from the executable. The group color is derived from
the average HSV color of the icon.

Special cases in `ApplicationGroupLibrary`:

- `mmc.exe`: group name derived from the title before `-`.
- `WWAHost` / `explorer`: WMI `Win32_Process.CommandLine` is queried to recover
  the UWP app name.
- Microsoft OS binaries: `FileDescription` becomes the display name.

---

## 6. Database details

Tables used: `Timeline`, `Group`, `Activity`, `Document`, plus statistics and
sequence tables.

### Timeline rows

```
1  ManicTime/Tags
2  ManicTime/ComputerUsage
3  ManicTime/Applications
4  ManicTime/Documents
```

All local timelines had `UpdateInterval = 10` in the inspected database.

### Activity columns

```
ActivityId, TimelineId, DisplayName, GroupId, GroupListId,
StartLocalDate, StartLocalTime, StartUtcTime,
EndLocalDate, EndLocalTime, EndUtcTime,
TextData, UpdatedTimestamp
```

### Critical date encoding

`StartLocalDate` / `EndLocalDate` are **days since 2000-01-01**, not `yyyyMMdd`.

Verified examples from the real DB:

| Date | Value |
|---|---:|
| 2022-03-07 | 8104 |
| 2026-11-06 | 9806 |

This was the single most important compatibility discovery. aika implements the
same encoding.

### Group keys in the DB

`Group.Key` stores the Base64 SHA-256 hash, not the plain `FileName;Name` key.
`Group.TextData` stores the plain fields.

Examples:

```
W4yiNcyXGPLtSeJd09iJhvbDr6EL/BE2HWKJS8johz8=  -> ManicTime/Active
jaM0cRC0p2E80XobDIz5aMfg8NBucI9QrcoCdb0ll2o=  -> ManicTime/Away
S7sALuDiUUUJfMuqfN8d1nFc/kVH3SgUYCDbTWNju+c=  -> ManicTime/SessionLocked
kw+obQQ1f/3ZFvvhV3kgmhQRNnt+Lr2cgk7gFZdu/LU=  -> ManicTime/PowerOff
```

Computer usage `Group.DisplayName` is empty in the real DB. aika restores
readable names when importing.

### Computer usage detection

`ComputerUsageTracker` publishes `ComputerUsageEvent` with:

- `ManicTime/Active`
- `ManicTime/Away`
- `ManicTime/SessionLocked`
- `ManicTime/PowerOff`

Sources:

- `SystemEvents.SessionSwitch` → lock/unlock
- `SystemEvents.PowerModeChanged` → suspend/resume
- `GetLastInputInfo` → idle
- hidden `WindowsMessageForm` → screen saver / monitor off / hotkeys

Two idle strategies:

- `TrackAwayWithIdleTime = true`:
  `TimeLimitedInactivity` uses `GetLastInputInfo`, checks every **5 minutes**,
  and backdates the away start to `now - threshold` (default 10 minutes).
- `TrackAwayWithIdleTime = false`:
  `ScreenSaverInactivity` handles screen saver/monitor off/lock.

aika implements the first strategy, but checks every second.

---

## 7. How ManicTime builds the day timeline

The `Activity` rows are the timeline. There is no separate session table.

`LocalDayViewLoader.BeginLoad`:

```csharp
new ActivityQuery()
    .WithTimelineIds(timelineIds)
    .WithFromDate(fromLocalTime.AsStartDate())
    .WithToDate(toLocalTime.AsEndDate());
```

`DayViewActivity`:

```csharp
StartValue = ActivityHelper.GetHoursForActivityStart(activity.StartTime, date, trim: true);
EndValue   = ActivityHelper.GetHoursForActivityEnd(activity.EndTime, date);
Length     = EndValue - StartValue;
```

The WPF view draws one bar per Activity in a lane per Timeline. The Applications
lane is colored by app group; the title is the `DisplayName`.

`DayViewUpdater` refreshes every second but only queries a timeline after its
`UpdateInterval` (10 seconds for local timelines). It uses incremental queries:

```sql
SELECT ... FROM Activity WHERE UpdatedTimestamp > @lastTimestamp
SELECT ... FROM DeletedEntity WHERE DeletedAfterTimestamp > @lastTimestamp
```

---

## 8. Differences between ManicTime and aika

| Area | ManicTime | aika |
|---|---|---|
| Storage | SQL CE 4.0 `.sdf` | SQLite `.db` |
| Focus detection | 1 Hz `GetForegroundWindow` | same |
| App identity | exe filename + ProductName hash | same |
| Date encoding | days since 2000-01-01 | same |
| Title storage | `Activity.DisplayName` | same |
| 5 s merge | yes | yes |
| Heartbeat | 10 s / 60 s | 10 s |
| Away detection | 5 min check, 10 min threshold | 1 s check, 10 min threshold |
| Session lock/power | yes | no (data model ready) |
| Documents/URLs | plugin retrievers | no |
| Tags/folders/stats | yes | no |
| DB import | n/a | one-way JSON exporter/importer |
| UI | WPF | raylib/raygui |
| Process architecture | tracker + WPF client | one process |

---

## 9. If you need to re-decompile

The installed ManicTime version is old (settings mention 2.4/5.x-era data), but
the core design above is stable across versions.

Commands:

```bat
ilspycmd -l c "C:\Program Files (x86)\ManicTime\Finkit.ManicTime.Tracker.O.dll"

ilspycmd -p -o out\TrackerO -r "C:\Program Files (x86)\ManicTime" ^
  "C:\Program Files (x86)\ManicTime\Finkit.ManicTime.Tracker.O.dll"
```

For a GUI debugger, use dnSpyEx and attach to `ManicTime.exe`.

For the live DB, read it read-only:

```powershell
$env:PATH = "C:\Program Files (x86)\ManicTime\AMD64;" + $env:PATH
Add-Type -Path "C:\Program Files (x86)\ManicTime\System.Data.SqlServerCe.dll"
$cs = "Data Source=$env:LOCALAPPDATA\Finkit\ManicTime\ManicTime.sdf;File Mode=Read Only;Temp Path=$env:TEMP\aika-sqlce;"
$c = New-Object System.Data.SqlServerCe.SqlCeConnection($cs)
$c.Open()
$cmd = $c.CreateCommand()
$cmd.CommandText = "SELECT TOP 10 ActivityId, TimelineId, StartLocalDate, StartLocalTime FROM Activity ORDER BY ActivityId DESC"
$r = $cmd.ExecuteReader()
while ($r.Read()) { $r[0], $r[1], $r[2], $r[3] }
$c.Close()
```
