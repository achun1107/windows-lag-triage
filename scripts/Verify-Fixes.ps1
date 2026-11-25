<#
  Verify-Fixes.ps1 -- same-yardstick check after Apply-SafeFixes.ps1.

  Read-only. Prints the numbers that must be compared before/after, plus the
  readback of every setting the fix script writes.

  Usage:
    powershell -ExecutionPolicy Bypass -File .\Verify-Fixes.ps1
    powershell -ExecutionPolicy Bypass -File .\Verify-Fixes.ps1 -Hours 2

  Pass criteria (typical for a low-cost SATA SSD on Windows 10/11):
    storahci 129 new occurrences .... 0 in the observation window
    Avg. Disk sec/Read .............. < 1.5 ms
    Current Disk Queue Length ....... 0-2 steady
    Page Writes/sec ................. 0 when not memory-starved
    HIPM/DIPM, PCIe ASPM ............ readback 0x0
#>
[CmdletBinding()]
param([int]$Hours = 2, [int]$Samples = 10)

$ErrorActionPreference = 'SilentlyContinue'

function Line($label, $value) { "{0,-34} {1}" -f $label, $value }

"=== observation window: last $Hours hour(s) ==="
$since = (Get-Date).AddHours(-$Hours)

$ev129 = Get-WinEvent -FilterHashtable @{ LogName='System'; Id=129; StartTime=$since } -ErrorAction SilentlyContinue
$n129 = ($ev129 | Measure-Object).Count
Line 'storahci 129 (new)' "$n129   $(if ($n129 -eq 0) {'PASS'} else {'FAIL - controller still resetting'})"
if ($n129 -gt 0) { $ev129 | ForEach-Object { "    $($_.TimeCreated)" } }

foreach ($c in @(
    @{ p='\PhysicalDisk(_Total)\Avg. Disk sec/Read';        u='ms'; limit=1.5 },
    @{ p='\PhysicalDisk(_Total)\Avg. Disk sec/Write';       u='ms'; limit=5.0 },
    @{ p='\PhysicalDisk(_Total)\Current Disk Queue Length'; u='';   limit=2 })) {
  $s = (Get-Counter $c.p -SampleInterval 1 -MaxSamples $Samples).CounterSamples
  $vals = $s | ForEach-Object { $_.CookedValue }
  $avg = ($vals | Measure-Object -Average).Average
  $max = ($vals | Measure-Object -Maximum).Maximum
  if ($c.u -eq 'ms') { $avgS = [math]::Round($avg*1000,2); $maxS = [math]::Round($max*1000,2) }
  else               { $avgS = [math]::Round($avg,2);      $maxS = [math]::Round($max,2) }
  $verdict = if ($avgS -le $c.limit) { 'PASS' } else { 'WATCH' }
  Line ($c.p -replace '.*\\','') ("avg=$avgS$($c.u) max=$maxS$($c.u)  $verdict")
}

$mc = (Get-Counter '\Memory\Pages/sec','\Memory\Page Writes/sec','\Memory\Committed Bytes','\Memory\Available MBytes' -SampleInterval 1 -MaxSamples $Samples).CounterSamples
foreach ($grp in ($mc | Group-Object Path)) {
  $avg = ($grp.Group | Measure-Object CookedValue -Average).Average
  $name = ($grp.Name -replace '.*\\','')
  switch -Regex ($name) {
    'Committed Bytes'  { Line $name ("{0}GB" -f [math]::Round($avg/1GB,2)) }
    'Available MBytes' { Line $name ("{0}MB" -f [math]::Round($avg,0)) }
    default            { Line $name ([math]::Round($avg,2)) }
  }
}
$pf = Get-CimInstance Win32_PageFileUsage
if ($pf) { foreach ($p in $pf) { Line 'pagefile current usage' ("{0}GB (peak {1}GB)" -f [math]::Round($p.CurrentUsage/1024,2), [math]::Round($p.PeakUsage/1024,2)) } }

"`n=== setting readback ==="
$hipmQ = (powercfg /query SCHEME_CURRENT SUB_DISK 0b2d69d7-a2a1-449c-9680-f91c70521c60) -join ' '
Line 'AHCI HIPM/DIPM' $(if ($hipmQ -match '0x00000000') { 'Active (0x0) PASS' } else { 'NOT active' })
$aspmQ = (powercfg /query SCHEME_CURRENT SUB_PCIEXPRESS ee12f906-d277-404b-b6da-e5fa1a576df5) -join ' '
Line 'PCIe ASPM' $(if ($aspmQ -match '0x00000000') { 'Off (0x0) PASS' } else { 'NOT off' })
$dtQ = (powercfg /query SCHEME_CURRENT SUB_DISK 6738e2c4-e8a5-4a42-b16a-e040e769756e) -join ' '
Line 'disk idle timeout' $(if ($dtQ -match '0x00000000') { 'never PASS' } else { 'not zero' })
Line 'Game DVR enabled' (Get-ItemProperty 'HKCU:\System\GameConfigStore').GameDVR_Enabled

$os = Get-CimInstance Win32_OperatingSystem
Line 'uptime (hours)' ([math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 2))
Line 'processes' ((Get-Process).Count)
Line 'memory used %' ([math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize * 100, 1))

"`nnote: an AHCI link-power change is applied by the storage driver on the next boot;"
"      run this again after a reboot before drawing conclusions."
