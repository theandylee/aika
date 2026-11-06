param(
    [int]$Days = 7,
    [string]$Out = "",
    [string]$SourceId = ""
)

$ErrorActionPreference = "Stop"

# Chosen once per source database generation, then reused for every date range.
# A path, machine name or export timestamp is not a safe database identity.
if ($SourceId -eq "" -or $SourceId -ne $SourceId.Trim() -or
    [System.Text.Encoding]::UTF8.GetByteCount($SourceId) -gt 256 -or $SourceId.Contains([string][char]0)) {
    throw "Pass -SourceId <stable-database-id> (1-256 UTF-8 bytes, no surrounding whitespace). Reuse it for this database; choose a new ID after replacing/resetting the database."
}

$manicDir = "C:\Program Files (x86)\ManicTime"
$sdf = Join-Path $env:LOCALAPPDATA "Finkit\ManicTime\ManicTime.sdf"
if (-not (Test-Path $sdf)) {
    throw "ManicTime database not found: $sdf"
}
if ($Out -eq "") {
    $Out = Join-Path $PSScriptRoot "manictime-export.json"
}

# SQL Server Compact native bits.
$env:PATH = (Join-Path $manicDir "AMD64") + ";" + $env:PATH
Add-Type -Path (Join-Path $manicDir "System.Data.SqlServerCe.dll")
Add-Type -Path (Join-Path $manicDir "Newtonsoft.Json.dll")

$toDate = Get-Date
$fromDate = $toDate.Date.AddDays(-[Math]::Max(0, $Days - 1))
$fromInt = [int]($fromDate.ToString("yyyyMMdd"))
$toInt = [int]($toDate.ToString("yyyyMMdd"))

# ManicTime stores StartLocalDate/EndLocalDate as days since 2000-01-01.
$manicEpoch = [DateTime]::new(2000, 1, 1)
$fromManic = [int](($fromDate.Date - $manicEpoch).TotalDays)
$toManic = [int](($toDate.Date - $manicEpoch).TotalDays)

$temp = Join-Path $env:TEMP "aika-sqlce-temp"
New-Item -ItemType Directory -Force -Path $temp | Out-Null

$cs = "Data Source=$sdf;File Mode=Read Only;Temp Path=$temp;"
$conn = New-Object System.Data.SqlServerCe.SqlCeConnection($cs)
$conn.Open()

Write-Host "Reading $sdf"
Write-Host "Date range: $fromInt .. $toInt (ManicTime date $fromManic .. $toManic)"

$groups = New-Object System.Collections.Generic.List[object]
$cmd = $conn.CreateCommand()
$cmd.CommandText = "SELECT GroupId, TimelineId, DisplayName, Color, [Key], TextData FROM [Group] ORDER BY GroupId"
$r = $cmd.ExecuteReader()
while ($r.Read()) {
    $groups.Add([ordered]@{
        groupId     = [int]$r["GroupId"]
        timelineId  = [int]$r["TimelineId"]
        displayName = if ($r["DisplayName"] -is [DBNull]) { "" } else { [string]$r["DisplayName"] }
        color       = [int64]$r["Color"]
        key         = if ($r["Key"] -is [DBNull]) { "" } else { [string]$r["Key"] }
        textData    = if ($r["TextData"] -is [DBNull]) { "" } else { [string]$r["TextData"] }
    })
}
$r.Close()

$epoch = [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
$activities = New-Object System.Collections.Generic.List[object]
$cmd.CommandText = @"
SELECT ActivityId, TimelineId, DisplayName, GroupId, StartUtcTime, EndUtcTime, TextData
FROM Activity
WHERE StartLocalDate <= $toManic AND EndLocalDate >= $fromManic
ORDER BY ActivityId
"@
$r = $cmd.ExecuteReader()
$count = 0
while ($r.Read()) {
    $start = [DateTime]::SpecifyKind([DateTime]$r["StartUtcTime"], [DateTimeKind]::Utc)
    $end   = [DateTime]::SpecifyKind([DateTime]$r["EndUtcTime"],   [DateTimeKind]::Utc)
    $activities.Add([ordered]@{
        activityId  = [int64]$r["ActivityId"]
        timelineId  = [int]$r["TimelineId"]
        displayName = if ($r["DisplayName"] -is [DBNull]) { "" } else { [string]$r["DisplayName"] }
        groupId     = if ($r["GroupId"] -is [DBNull]) { 0 } else { [int64]$r["GroupId"] }
        startUtcMs  = [int64](($start - $epoch).TotalMilliseconds)
        endUtcMs    = [int64](($end - $epoch).TotalMilliseconds)
        textData    = if ($r["TextData"] -is [DBNull]) { "" } else { [string]$r["TextData"] }
    })
    $count++
}
$r.Close()
$conn.Close()

$payload = [ordered]@{
    source     = "ManicTime"
    sourceId   = $SourceId
    exportedAt = (Get-Date).ToString("o")
    fromDate   = $fromInt
    toDate     = $toInt
    groups     = $groups.ToArray()
    activities = $activities.ToArray()
}

$json = [Newtonsoft.Json.JsonConvert]::SerializeObject($payload)
[System.IO.File]::WriteAllText($Out, $json, [System.Text.UTF8Encoding]::new($false))

Write-Host "Groups:     $($groups.Count)"
Write-Host "Activities: $count"
Write-Host "Wrote:      $Out"
