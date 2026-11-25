---
name: windows-lag-triage
description: 诊断并修复 Windows 卡顿/一顿一顿/鼠标凝滞。用事件日志与性能计数器定位真实瓶颈（SATA 控制器复位、内存超卖、可见控制台窗口任务、应用栈过多），再按证据施加可回滚的修复并前后对比验收。当用户说"电脑好卡""电脑变慢""一顿一顿""风扇一直转""开机会弹黑框"或要求体检/优化 Windows 性能时使用。
whenToUse: 用户抱怨 Windows 整体卡顿、间歇性冻结、开机慢、进程多、风扇常转，需要先定位原因再动手，且要求不破坏现有功能区时。
---

# Windows 卡顿取证与修复

核心纪律：**先取证，再动手，最后用同一套计数器自证**。没有基线数字的"优化"不算优化；
"重装系统/换杀软/清注册表"属于无证据猜测，不在流程里。

## 0. 铁律（违反任意一条，这份诊断就作废）

1. **先量化"卡"是哪一类**：CPU / 内存换页 / 存储复位 / 可见窗口打扰。四类的修法完全不同。
2. **瞬时值不是常态**。`Pages/sec` 5000+ 可能只是编译那 30 秒；必须用多次采样 + `Page Writes/sec`、pagefile 实际占用交叉验证。
3. **不采信进程级 IO 计数器**做归因：Chromium/Electron 的渲染进程与 GPU 进程通过共享内存互传，`IO Write Bytes/sec` 会报出 150MB/s 的假象。归因要落到物理磁盘计数器 + 文件级证据。
4. **PowerShell 5.1 按 GBK 解析无 BOM 的 .ps1**。脚本里带中文注释就会解析失败（`UnexpectedToken`），且**不写日志、不报错**，只留一个 exit 1。脚本要省事就**全 ASCII**，否则必须存成 UTF-8 **带 BOM**。
5. **提权走 `Start-Process -Verb RunAs` + 日志文件轮询**，不要 `-Wait` 阻塞在 UAC 上；跑完回读日志确认，而不是相信"启动成功"。
6. 每一步都要能回滚；回滚命令写进同一份报告。

## 1. 十分钟取证（只读，不改任何设置）

```powershell
# 1) 控制器复位与磁盘错误（最关键的一条线索）
Get-WinEvent -FilterHashtable @{LogName='System'; Id=129,153,7,11,51; StartTime=(Get-Date).AddDays(-3)} |
  Group-Object ProviderName,Id | Sort-Object Count -Descending |
  Select-Object Count,Name | Format-Table -AutoSize

# 2) 硬件与负载底数
$os = Get-CimInstance Win32_OperatingSystem
"uptime={0:N1}h procs={1} freeGB={2:N2} usedPct={3:N1}" -f `
  ((Get-Date)-$os.LastBootUpTime).TotalHours, (Get-Process).Count,
  ($os.FreePhysicalMemory/1MB), (($os.TotalVisibleMemorySize-$os.FreePhysicalMemory)/$os.TotalVisibleMemorySize*100)
Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors,LoadPercentage
Get-PhysicalDisk | Select-Object FriendlyName,MediaType,BusType,HealthStatus,FirmwareVersion

# 3) 内存是否真的在换页（三者要一起看）
Get-Counter '\Memory\Pages/sec','\Memory\Page Writes/sec','\Memory\Committed Bytes','\Memory\Available MBytes' -SampleInterval 1 -MaxSamples 10
Get-CimInstance Win32_PageFileUsage | Select-Object Name,@{n='NowGB';e={[math]::Round($_.CurrentUsage/1024,2)}},@{n='PeakGB';e={[math]::Round($_.PeakUsage/1024,2)}}

# 4) 磁盘延迟与队列（判"突发卡死"而非"持续满载"）
Get-Counter '\PhysicalDisk(_Total)\Avg. Disk sec/Read','\PhysicalDisk(_Total)\Avg. Disk sec/Write','\PhysicalDisk(_Total)\Current Disk Queue Length' -SampleInterval 1 -MaxSamples 10

# 5) 按应用聚合提交内存（找内存主要占用者）
Get-Process | Group-Object ProcessName | ForEach-Object {
  [pscustomobject]@{ App=$_.Name; Procs=$_.Count
    CommitMB=[math]::Round((($_.Group|Measure-Object PrivateMemorySize64 -Sum).Sum/1MB),0) }
} | Sort-Object CommitMB -Descending | Select-Object -First 15
```

判读口径：

| 观察 | 指向 | 下一步 |
|---|---|---|
| `storahci` 129 有记录（尤其几小时内多次） | **SATA 控制器复位**，I/O 冻结数秒 | 第 2 节 A |
| `Pages/sec` 高 **且** `Page Writes/sec` > 0 **且** pagefile 实际占用在涨 | 真的换页 | 第 2 节 B |
| `Pages/sec` 高但 pagefile 只占几百 MB、`Page Writes/sec` = 0 | **假警报**，别动内存 | 转 CPU / 存储 |
| `Avg. Disk sec/Read` > 10ms 或队列长度常态 > 2 | 盘撑不住 | 第 2 节 A + 查写入源 |
| CPU 高但无可归因进程，`System`/`MsMpEng` 高 | 杀软实时扫描 / 索引 | 查 Defender 排除项、索引范围 |
| 每隔几分钟屏幕闪一下黑框 | **可见控制台窗口的任务** | 第 2 节 C |

补充取证（当"卡"是间歇性的）：

```powershell
# 显示器驱动复位（TDR）/ 异常关机，排除显卡与电源
Get-WinEvent -FilterHashtable @{LogName='System'; Id=4101,41,1001; StartTime=(Get-Date).AddDays(-7)}
# 计划任务里高频触发的项（含隐藏窗口的）
Get-ScheduledTask | ForEach-Object { $t=$_; foreach ($tr in $t.Triggers) {
  if ($tr.Repetition.Interval) { [pscustomobject]@{ Task=$t.TaskName; State=$t.State
    Interval=$tr.Repetition.Interval; Exec=(($t.Actions|%{ $_.Execute }) -join ';') } } } }
# 开机自启（Run 键 + 启动文件夹 + 启动审批）
```

## 2. 按证据修复

### A. SATA 控制器复位（事件 129）

先做零风险的两件，再谈硬件：

```powershell
# 关掉 AHCI 链路电源管理 + PCIe ASPM + 硬盘空闲超时，并对系统盘 TRIM
# 需要管理员；用 scripts/Apply-SafeFixes.ps1 一步到位（脚本自己提权）
powershell -ExecutionPolicy Bypass -File .\scripts\Apply-SafeFixes.ps1 -SkipDefenderExclusions
```

原理：低成本无 DRAM 缓存的 SATA SSD 在随机小 I/O 突发下，LPM 唤醒抖动会触发控制器复位；
关闭 LPM/ASPM 是最常见的软件侧缓解，回读应为 `0x00000000`。

若无改善（事件 129 继续增长）：这是固件/主控问题，**换一块带 DRAM 缓存的盘**是唯一彻底解。
不要用"换数据线/重装系统"来赌。

### B. 内存超卖

只在第 1 节三项指标同时成立时才动手：

1. 找出可牺牲的进程（聊天软件的小程序进程、输入法更新器、旧版残留），只杀**明确可重启**的；
2. 分不清就只报告不杀——杀窗口有数据丢失风险；
3. 提交内存降到物理内存以下即停手，继续压只会换来更差的缓存命中。

常见可安全回收的对象（示例，按实际进程名判断）：

```powershell
# 微信小程序进程（重开小程序即恢复，不影响聊天）
Get-Process WeChatAppEx -ErrorAction SilentlyContinue | Stop-Process -Force
# 第三方输入法/更新器的 WebView 残留（父进程挂了才杀）
```

用 `scripts/Release-Memory.ps1` 可一键做上面两件事并打印回收量。

### C. 可见控制台窗口的任务

任务以 `LogonType=Interactive` 注册时，`.bat`/`powershell.exe` 动作会在用户桌面弹窗。
改成 `wscript.exe` + `WshShell.Run(cmd, 0, True)` 的静默包装：

```powershell
# 1) 写一个通用静默启动器 run-hidden.vbs
#    Dim c: c = WScript.Arguments(0)
#    WScript.Quit CreateObject("WScript.Shell").Run(c, 0, True)
# 2) 每个任务改成: wscript.exe //B //Nologo run-hidden.vbs "cmd /c D:\path\task.cmd"
#    包装体只写一行原始命令 + exit /b %ERRORLEVEL%，退出码才能传回任务历史
$act = New-ScheduledTaskAction -Execute 'C:\Windows\System32\wscript.exe' `
  -Argument '//B //Nologo "C:\path\run-hidden.vbs" "cmd /c D:\path\task.cmd"'
Set-ScheduledTask -TaskName 'YourTask' -Action $act
```

注意：
- 保持 `LogonType=Interactive`（改成 S4U 会让依赖桌面的自动化失效），静默只靠窗口样式 0。
- 改前 `Export-ScheduledTask` 备份 XML，改后 `Get-ScheduledTaskInfo` 看 `LastTaskResult` 是否仍是 0/1（说明退出码链路没断）。
- 这些任务常常由安装器**自我重建**：禁用后要复查 `State`，被重建就说明得从应用自身的设置里关。

### D. 启动项与后台噪音

```powershell
# 只删明显无用的自启（如浏览器 --win-session-start），删前把值记下来
$k='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
(Get-ItemProperty $k).PSObject.Properties | Where-Object Name -notmatch '^PS' | ForEach-Object { "  $($_.Name)" }
# Game DVR 关掉（后台录屏与合成开销）
Set-ItemProperty 'HKCU:\System\GameConfigStore' -Name GameDVR_Enabled -Value 0 -Type DWord
```

## 3. 验收（必须前后同口径对比）

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Verify-Fixes.ps1
```

合格线（本类机器的经验值，按硬件调整）：

| 指标 | 修复前典型 | 修复后应达 |
|---|---|---|
| `storahci` 129 新增 | 数小时 1–3 次 | 观察期内 **0 次** |
| `Avg. Disk sec/Read` | 2–15 ms | < 1.5 ms |
| `Current Disk Queue Length` | 峰值 5–15 | 常态 0–2 |
| `Page Writes/sec` | 有持续写入 | 0（未换页） |
| AHCI HIPM/DIPM、ASPM | 默认值 | 回读 `0x0` |

**观察窗口**：事件 129 是突发性的，至少观察 1–2 小时或一次"原本必卡"的操作（批量安装/编译）。
未观察到复发才能说修好了。

## 4. 何时该说"这不是软件能修的"

出现以下情形，直接给硬件结论，不要含糊其辞：

- 事件 129 在关闭 LPM/ASPM 后仍复发 → 盘的主控/固件问题，换盘。
- 提交内存已顶到物理内存、且用户拒绝关任何应用 → 加内存，或接受"同时开几个 Electron 栈就是会卡"。
- CPU 是低线程数（如 6 核 6 线程）而用户坚持同时跑多个 Agent/浏览器 → 这是容量问题，不是配置问题。
- **重装系统只在"顺手换盘"或"系统文件确实损坏（sfc/DISM 报错）"时才有意义**；否则装完还是同一批应用、同一块盘。

## 5. 输出给用户的报告结构

1. 一句话结论（瓶颈在哪一类，几条）；
2. 证据表（事件/计数器/进程，带时间点与数值）；
3. 已做的修复（每条带"回读确认"）；
4. 前后对比表；
5. 剩下的、需要用户决策的项（关哪个应用、加多少内存）；
6. 回滚命令 + 观察窗口。

不要写"已优化，应该会更快"这种无法验证的话。

## 6. 配套脚本

| 脚本 | 作用 | 是否需管理员 |
|---|---|---|
| `scripts/Collect-Diagnostics.ps1` | 只读取证，输出判读摘要 | 否 |
| `scripts/Apply-SafeFixes.ps1` | LPM/ASPM/磁盘超时/TRIM/Defender 排除/Game DVR | 是（自提权） |
| `scripts/Verify-Fixes.ps1` | 同口径计数器 + 设置回读 | 否 |
| `scripts/Release-Memory.ps1` | 回收小程序进程与更新器残留 | 否 |

脚本全部 ASCII、幂等、可重复执行；`Apply-SafeFixes.ps1` 头部有回滚说明。
