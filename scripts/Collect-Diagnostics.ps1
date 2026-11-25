<#
  Collect-Diagnostics.ps1 -- read-only Windows lag triage.

  Prints evidence grouped by the four bottleneck classes. Changes nothing.
  ASCII only (Windows PowerShell 5.1 parses BOM-less .ps1 in the OEM code page).

  Usage:
    powershell -ExecutionPolicy Bypass -File .\Collect-Diagnostics.ps1
    powershell -ExecutionPolicy Bypass -File .\Collect-Diagnostics.ps1 -Days 7 -Csv .\evidence.csv
#>
[CmdletBinding()]
param(
  [int]$Days = 3,
  [string]$Csv = ''
)

$ErrorActionPreference = 'SilentlyContinue'
$since = (Get-Date).AddDays(-$Days)
$rows = New-Object System.Collections.ArrayList
function Add-Row($area, $item, $value, $note) {
  [void]$rows.Add([pscustomobject]@{ Area=$area; Item=$item; Value=$value; Note=$note })
}
function Sec($t) { "`n=== $t ===" }

# ---------- 0. baseline ----------
Sec 'BASELINE'
$os = Get-CimInstance Win32_OperatingSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$uptimeH = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)
$freeGB  = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
$totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
$usedPct = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize * 100, 1)
"host       : $env:COMPUTERNAME"
"os         : $($os.Caption) build $($os.BuildNumber)"
"cpu        : $($cpu.Name) cores=$($cpu.NumberOfCores) threads=$($cpu.NumberOfLogicalProcessors) load=$($cpu.LoadPercentage)%"
"uptime     : ${uptimeH}h   processes=$((Get-Process).Count)"
"memory     : ${totalGB}GB total / ${freeGB}GB free / ${usedPct}% used"
Get-PhysicalDisk | ForEach-Object {
  "disk       : $($_.FriendlyName) $($_.MediaType) $($_.BusType) health=$($_.HealthStatus) fw=$($_.FirmwareVersion)"
  Add-Row 'baseline' 'disk' $_.FriendlyName $_.HealthStatus
}

# ---------- 1. storage controller resets ----------
Sec 'STORAGE / CONTROLLER RESETS (event 129 = device reset)'
$diskEvt = Get-WinEvent -FilterHashtable @{ LogName='System'; Id=129,153,7,11,51; StartTime=$since } -ErrorAction SilentlyContinue
if ($diskEvt) {
  $diskEvt | Group-Object ProviderName, Id | Sort-Object Count -Descending |
    ForEach-Object { "  {0,-10} count={1}" -f $_.Name, $_.Count }
  "  last 5:"
  $diskEvt | Select-Object -First 5 | ForEach-Object { "    $($_.TimeCreated)  id=$($_.Id)  $((($_.Message -split "`n")[0]).Trim())" }
  $n129 = ($diskEvt | Where-Object Id -eq 129 | Measure-Object).Count
  Add-Row 'storage' 'event129' $n129 "in last $Days day(s)"
} else {
  "  none in last $Days day(s)"
  Add-Row 'storage' 'event129' 0 ''
}

Sec 'DISK LATENCY (10 samples)'
foreach ($c in @(
    @{ p='\PhysicalDisk(_Total)\Avg. Disk sec/Read';  u='ms' },
    @{ p='\PhysicalDisk(_Total)\Avg. Disk sec/Write'; u='ms' },
    @{ p='\PhysicalDisk(_Total)\Current Disk Queue Length'; u='' })) {
  $s = (Get-Counter $c.p -SampleInterval 1 -MaxSamples 10).CounterSamples
  $vals = $s | ForEach-Object { $_.CookedValue }
  $avg = ($vals | Measure-Object -Average).Average
  $max = ($vals | Measure-Object -Maximum).Maximum
  if ($c.u -eq 'ms') { "  {0,-32} avg={1}ms max={2}ms" -f ($c.p -replace '.*\\',''), [math]::Round($avg*1000,2), [math]::Round($max*1000,2) }
  else               { "  {0,-32} avg={1} max={2}"        -f ($c.p -replace '.*\\',''), [math]::Round($avg,2), [math]::Round($max,2) }
  Add-Row 'storage' ($c.p -replace '.*\\','') ([math]::Round($avg*1000,2)) $c.u
}

# ---------- 2. memory pressure ----------
Sec 'MEMORY / PAGING (all three must agree before acting)'
$mc = (Get-Counter '\Memory\Pages/sec','\Memory\Page Writes/sec','\Memory\Committed Bytes','\Memory\Available MBytes' -SampleInterval 1 -MaxSamples 10).CounterSamples
$g = $mc | Group-Object Path
foreach ($grp in $g) {
  $avg = ($grp.Group | Measure-Object CookedValue -Average).Average
  $name = ($grp.Name -replace '.*\\','')
  switch -Regex ($name) {
    'Committed Bytes' { "  {0,-32} avg={1}GB" -f $name, [math]::Round($avg/1GB,2) }
    'Available MBytes'{ "  {0,-32} avg={1}MB" -f $name, [math]::Round($avg,0) }
    default           { "  {0,-32} avg={1}"   -f $name, [math]::Round($avg,2) }
  }
}
$pf = Get-CimInstance Win32_PageFileUsage
if ($pf) { foreach ($p in $pf) { "  pagefile {0} now={1}GB peak={2}GB alloc={3}GB" -f $p.Name, [math]::Round($p.CurrentUsage/1024,2), [math]::Round($p.PeakUsage/1024,2), [math]::Round($p.AllocatedBaseSize/1024,1) } }

Sec 'COMMIT BY APP (top 15)'
Get-Process | Group-Object ProcessName | ForEach-Object {
  [pscustomobject]@{
    App = $_.Name; Procs = $_.Count
    CommitMB = [math]::Round((($_.Group | Measure-Object PrivateMemorySize64 -Sum).Sum / 1MB), 0)
  }
} | Sort-Object CommitMB -Descending | Select-Object -First 15 |
  ForEach-Object { "  {0,-24} procs={1,-3} commit={2}MB" -f $_.App, $_.Procs, $_.CommitMB }

# ---------- 3. CPU ----------
Sec 'CPU BY APP (8s sample, top 10)'
$s1 = @{}; Get-Process | ForEach-Object { $s1[$_.Id] = $_.CPU }
Start-Sleep -Seconds 8
$threads = [math]::Max($cpu.NumberOfLogicalProcessors, 1)
$perApp = Get-Process | ForEach-Object {
  if ($s1[$_.Id] -ne $null -and $_.CPU -ne $null) {
    [pscustomobject]@{ Name = $_.ProcessName; Pct = (($_.CPU - $s1[$_.Id]) / 8 * 100 / $threads) }
  }
} | Group-Object Name | ForEach-Object {
  [pscustomobject]@{ App = $_.Name; Pct = [math]::Round((($_.Group | Measure-Object Pct -Sum).Sum), 1) }
}
$perApp | Sort-Object Pct -Descending | Select-Object -First 10 | ForEach-Object { "  {0,-24} {1}%" -f $_.App, $_.Pct }

# ---------- 4. visible windows / autostart noise ----------
Sec 'VISIBLE CONSOLE WINDOWS (should be empty for scheduled automation)'
$vis = Get-Process cmd, powershell, pwsh, conhost, wscript -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 }
if ($vis) { $vis | ForEach-Object { "  {0} pid={1} title='{2}'" -f $_.ProcessName, $_.Id, $_.MainWindowTitle } }
else { '  none' }

Sec 'AUTOSTART (Run keys)'
foreach ($k in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run','HKLM:\Software\Microsoft\Windows\CurrentVersion\Run') {
  if (Test-Path $k) {
    "  $k"
    (Get-ItemProperty $k).PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } |
      ForEach-Object { "    $($_.Name) = $($_.Value)" }
  }
}

Sec 'HIGH-FREQUENCY SCHEDULED TASKS (non-Microsoft only)'
Get-ScheduledTask | Where-Object { $_.TaskPath -notlike '\Microsoft\*' } | ForEach-Object {
  $t = $_
  foreach ($tr in $t.Triggers) {
    if ($tr.Repetition -and $tr.Repetition.Interval) {
      $a = $t.Actions | Select-Object -First 1
      "  {0,-34} state={1,-9} every={2,-6} exec={3}" -f $t.TaskName, $t.State, $tr.Repetition.Interval, $a.Execute
    }
  }
}

Sec 'GAME DVR'
"  GameDVR_Enabled = " + (Get-ItemProperty 'HKCU:\System\GameConfigStore').GameDVR_Enabled

# ---------- 5. verdict ----------
Sec 'VERDICT HINTS'
$n129 = ($diskEvt | Where-Object Id -eq 129 | Measure-Object).Count
$last129 = $diskEvt | Where-Object Id -eq 129 | Select-Object -First 1
if ($n129 -gt 0) {
  $ageH = if ($last129) { [math]::Round(((Get-Date) - $last129.TimeCreated).TotalHours, 1) } else { -1 }
  if ($ageH -ge 0 -and $ageH -le 2) {
    '  [A] storahci 129 RECENT (<2h) -> SATA controller resets are happening now. Run Apply-SafeFixes.ps1.'
  } else {
    "  [A] storahci 129 HISTORICAL (last one $ageH h ago) -> apply-safe-fixes already holds; keep watching, do not re-apply blindly."
  }
}
if ($usedPct -gt 80) { '  [B] memory > 80% used -> check Pages/sec + Page Writes/sec + pagefile before acting.' }
if ($vis) { '  [C] visible console windows -> wrap those scheduled tasks with wscript window-style 0.' }
if ((Get-ItemProperty 'HKCU:\System\GameConfigStore').GameDVR_Enabled -ne 0) { '  [D] Game DVR on -> consider disabling (background capture overhead).' }
if (-not $n129 -and $usedPct -le 80 -and -not $vis) { '  no obvious software bottleneck: review app stacks + hardware capacity.' }

if ($Csv) {
  $rows | Export-Csv -Path $Csv -NoTypeInformation -Encoding UTF8
  "`nrows written to $Csv"
}
