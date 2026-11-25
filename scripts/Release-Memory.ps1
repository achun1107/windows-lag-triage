<#
  Release-Memory.ps1 -- reclaim memory that is holding the working set hostage
  without touching anything the user is working in.

  Kills only:
    - WeChat mini-program host processes (WeChatAppEx). Chat windows and the
      WeChat main process are untouched; reopening a mini program restarts them.
    - Input-method / vendor update helpers whose WebView2 children are orphaned
      (wetype_update by default; add your own with -ExtraProcess).
    - Orphaned msedgewebview2 children whose parent no longer exists.

  Never kills: browsers, chat clients, Office, terminals, agents.

  Usage:
    powershell -ExecutionPolicy Bypass -File .\Release-Memory.ps1
    powershell -ExecutionPolicy Bypass -File .\Release-Memory.ps1 -WhatIfOnly
    powershell -ExecutionPolicy Bypass -File .\Release-Memory.ps1 -ExtraProcess 'SomeUpdater'
#>
[CmdletBinding()]
param(
  [string[]]$ExtraProcess = @(),
  [switch]$WhatIfOnly
)

$ErrorActionPreference = 'SilentlyContinue'

function FreeMB { [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB, 0) }

$before = FreeMB
"free before: $before MB"

$targets = @('WeChatAppEx', 'wetype_update') + $ExtraProcess
foreach ($name in $targets) {
  $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
  if (-not $procs) { "  $name : not running"; continue }
  $mb = [math]::Round((($procs | Measure-Object WS -Sum).Sum / 1MB), 0)
  "  $name : $($procs.Count) proc(s), $mb MB"
  if ($WhatIfOnly) { continue }
  # kill orphaned webview children first
  foreach ($p in $procs) {
    Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" |
      Where-Object { $_.ParentProcessId -eq $p.Id } |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
  }
}

if (-not $WhatIfOnly) {
  Start-Sleep -Seconds 2
  # sweep webview2 whose parent is gone
  foreach ($w in (Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'")) {
    $pp = Get-CimInstance Win32_Process -Filter "ProcessId=$($w.ParentProcessId)"
    if (-not $pp) { Stop-Process -Id $w.ProcessId -Force -ErrorAction SilentlyContinue }
  }
}

$after = FreeMB
"free after : $after MB   (delta $($after - $before) MB)"
"note: freed pages land in the standby cache first, so 'free' may lag while reuse improves."
