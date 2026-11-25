<#
  Apply-SafeFixes.ps1 -- safe, reversible fixes for Windows lag caused by
  SATA link-power stalls and background capture overhead.

  Requires Administrator: the script relaunches itself through UAC when needed
  and writes progress to %TEMP%\windows-lag-triage\apply.log.

  What it changes (all reversible, no user data touched):
    1) AHCI link power management (HIPM/DIPM + Adaptive LPM) -> Active(0)
    2) PCIe ASPM -> off
    3) disk idle timeout -> never
    4) TRIM on the requested volumes
    5) Defender exclusions for the given paths (optional)
    6) Xbox Game DVR off (per-user, optional)

  Rollback:
    powercfg /setacvalueindex SCHEME_CURRENT SUB_DISK 0b2d69d7-a2a1-449c-9680-f91c70521c60 3
    powercfg /setacvalueindex SCHEME_CURRENT SUB_DISK dab60367-53fe-4fbc-825e-521d069d2456 1
    powercfg /setacvalueindex SCHEME_CURRENT SUB_PCIEXPRESS ee12f906-d277-404b-b6da-e5fa1a576df5 2
    powercfg /change disk-timeout-ac 20
    Remove-MpPreference -ExclusionPath <path>
    Set-ItemProperty 'HKCU:\System\GameConfigStore' -Name GameDVR_Enabled -Value 1 -Type DWord

  ASCII only (PowerShell 5.1 parses BOM-less .ps1 in the OEM code page).

  Usage:
    powershell -ExecutionPolicy Bypass -File .\Apply-SafeFixes.ps1
    powershell -ExecutionPolicy Bypass -File .\Apply-SafeFixes.ps1 -SkipTrim -SkipDefenderExclusions
    powershell -ExecutionPolicy Bypass -File .\Apply-SafeFixes.ps1 -ExclusionPath 'D:\dev','D:\work'
#>
[CmdletBinding()]
param(
  [string[]]$ExclusionPath = @(),
  [string[]]$TrimVolumes = @(),
  [switch]$SkipTrim,
  [switch]$SkipDefenderExclusions,
  [switch]$KeepGameDvr,
  [switch]$NoElevate
)

$ErrorActionPreference = 'Continue'
$logDir = Join-Path $env:TEMP 'windows-lag-triage'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$log = Join-Path $logDir 'apply.log'

function Log($m) {
  $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' | ' + $m
  Add-Content -Path $log -Value $line -Encoding UTF8
  Write-Host $line
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Log "start pid=$PID elevated=$isAdmin log=$log"

if (-not $isAdmin) {
  if ($NoElevate) { Log 'not elevated and -NoElevate given: abort'; exit 1 }
  Log 'relaunching elevated via UAC'
  $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $PSCommandPath)
  if ($TrimVolumes.Count) { $argList += @('-TrimVolumes', ($TrimVolumes -join ',')) }
  if ($ExclusionPath.Count) { $argList += @('-ExclusionPath', ($ExclusionPath -join ',')) }
  if ($SkipTrim) { $argList += '-SkipTrim' }
  if ($SkipDefenderExclusions) { $argList += '-SkipDefenderExclusions' }
  if ($KeepGameDvr) { $argList += '-KeepGameDvr' }
  $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -PassThru
  Log "elevated process started pid=$($p.Id); waiting up to 180s"
  if (-not $p.WaitForExit(180000)) { Log 'timeout waiting for elevated run' }
  else { Log "elevated run exit=$($p.ExitCode)" }
  Log 'see the elevated process log lines appended above'
  exit 0
}

# ---- 1. AHCI LPM ----
$hipm  = '0b2d69d7-a2a1-449c-9680-f91c70521c60'
$adapt = 'dab60367-53fe-4fbc-825e-521d069d2456'
try {
  powercfg -attributes SUB_DISK $hipm  -ATTRIB_HIDE
  powercfg -attributes SUB_DISK $adapt -ATTRIB_HIDE
  powercfg /setacvalueindex SCHEME_CURRENT SUB_DISK $hipm  0
  powercfg /setdcvalueindex SCHEME_CURRENT SUB_DISK $hipm  0
  powercfg /setacvalueindex SCHEME_CURRENT SUB_DISK $adapt 0
  powercfg /setdcvalueindex SCHEME_CURRENT SUB_DISK $adapt 0
  $q = (powercfg /query SCHEME_CURRENT SUB_DISK $hipm) -join ' '
  if ($q -match '0x00000000') { Log 'AHCI HIPM/DIPM = Active (verified 0x0)' }
  else { Log 'AHCI HIPM/DIPM write attempted, value NOT confirmed' }
  Log 'Adaptive LPM = 0 (write attempted)'
} catch { Log ('LPM failed: ' + $_.Exception.Message) }

# ---- 2. PCIe ASPM ----
try {
  powercfg /setacvalueindex SCHEME_CURRENT SUB_PCIEXPRESS ee12f906-d277-404b-b6da-e5fa1a576df5 0
  powercfg /setdcvalueindex SCHEME_CURRENT SUB_PCIEXPRESS ee12f906-d277-404b-b6da-e5fa1a576df5 0
  $a = (powercfg /query SCHEME_CURRENT SUB_PCIEXPRESS ee12f906-d277-404b-b6da-e5fa1a576df5) -join ' '
  if ($a -match '0x00000000') { Log 'PCIe ASPM = Off (verified 0x0)' } else { Log 'PCIe ASPM write attempted, NOT confirmed' }
} catch { Log ('ASPM failed: ' + $_.Exception.Message) }

# ---- 3. disk idle timeout ----
try {
  powercfg /change disk-timeout-ac 0
  powercfg /change disk-timeout-dc 0
  Log 'disk idle timeout = never'
} catch { Log ('disk-timeout failed: ' + $_.Exception.Message) }

try { powercfg /setactive SCHEME_CURRENT; Log 'power scheme re-applied' } catch { Log 'setactive failed' }

# ---- 4. TRIM ----
if ($SkipTrim) { Log 'TRIM skipped by flag' }
else {
  if (-not $TrimVolumes.Count) {
    $TrimVolumes = @(Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' } | ForEach-Object { $_.DriveLetter })
  }
  foreach ($dl in $TrimVolumes) {
    try { Optimize-Volume -DriveLetter $dl -ReTrim -ErrorAction Stop | Out-Null; Log ("TRIM " + $dl + ": ok") }
    catch { Log ("TRIM " + $dl + " failed: " + $_.Exception.Message) }
  }
}

# ---- 5. Defender exclusions ----
if ($SkipDefenderExclusions) { Log 'Defender exclusions skipped by flag' }
else {
  if (-not $ExclusionPath.Count) {
    $candidates = @(
      (Join-Path $env:USERPROFILE '.dsh'),
      (Join-Path $env:USERPROFILE '.workbuddy'),
      'D:\dev','D:\work','D:\code'
    )
    $ExclusionPath = @($candidates | Where-Object { Test-Path $_ })
  }
  if (-not $ExclusionPath.Count) { Log 'no existing path to exclude' }
  foreach ($p in $ExclusionPath) {
    try { Add-MpPreference -ExclusionPath $p -ErrorAction Stop; Log ("excluded: " + $p) }
    catch { Log ("exclude failed " + $p + ": " + $_.Exception.Message) }
  }
}

# ---- 6. Game DVR ----
if (-not $KeepGameDvr) {
  try {
    if (-not (Test-Path 'HKCU:\System\GameConfigStore')) { New-Item -Path 'HKCU:\System\GameConfigStore' -Force | Out-Null }
    Set-ItemProperty 'HKCU:\System\GameConfigStore' -Name GameDVR_Enabled -Value 0 -Type DWord
    if (-not (Test-Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR')) {
      New-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Force | Out-Null
    }
    Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name AppCaptureEnabled -Value 0 -Type DWord
    Log 'Game DVR disabled (GameDVR_Enabled=0, AppCaptureEnabled=0)'
  } catch { Log ('Game DVR failed: ' + $_.Exception.Message) }
}

# ---- readback ----
Log '--- readback ---'
try {
  $ex = (Get-MpPreference).ExclusionPath
  Log ('defender exclusions: ' + (($ex | Where-Object { $_ }) -join ', '))
} catch { Log 'cannot read Defender exclusions' }
try {
  $n = (Get-WinEvent -FilterHashtable @{ LogName='System'; Id=129; StartTime=(Get-Date).AddDays(-2) } -ErrorAction SilentlyContinue | Measure-Object).Count
  Log ("storahci 129 in last 2 days: " + $n)
} catch { }

Log 'done. Reboot once so the AHCI link-power change is applied by the driver.'
