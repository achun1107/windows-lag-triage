# windows-lag-triage

一个 DSH（DeepSeek Harness）技能 + 一套独立 PowerShell 脚本：**用证据定位 Windows 卡顿，再动手修，最后用同一套计数器自证**。

不是"清理注册表/换杀软/重装系统"那种玄学优化。这里的每一条结论都对应一个可复现的证据源。

> A DSH skill plus standalone PowerShell scripts for triaging Windows stutter with evidence: event-log signatures, performance counters, per-app commit maps — then safe, reversible fixes and a before/after verification pass.

---

## 它解决什么

用户说"电脑好卡""一顿一顿""鼠标凝滞""风扇一直转""开机闪黑框"时，实际可能是完全不同的四类问题：

| 证据 | 真实原因 | 修法 |
|---|---|---|
| `System` 日志 `storahci` **事件 129**（设备复位） | SATA 控制器在随机小 I/O 突发下复位，I/O 冻结数秒 | 关闭 AHCI LPM / PCIe ASPM + TRIM，见 `Apply-SafeFixes.ps1` |
| `Pages/sec` 高 **且** `Page Writes/sec` > 0 **且** pagefile 实际占用在涨 | 真的在换页 | 降提交内存（关可重启的进程）/ 加内存 |
| 计划任务以 `LogonType=Interactive` 跑 `.bat`/`powershell.exe` | 每次触发在桌面弹控制台窗口 | 用 `wscript` + 窗口样式 0 静默包装 |
| CPU 高但无可归因进程 | 多个 Electron/Chromium 栈叠加 | 数量问题，不是配置问题 |

最容易踩的坑写在 `SKILL.md` 第 0 节：**`Pages/sec` 高不等于在换页**（可能只是那 30 秒编译），**进程级 IO 计数器不能用来归因**（Chromium 共享内存会让渲染进程报出 150MB/s 的假象），**PowerShell 5.1 会把无 BOM 的 .ps1 按 GBK 解析**（中文注释直接让脚本静默 exit 1）。

## 快速开始

```powershell
# 1) 只读取证（不改任何设置）
powershell -ExecutionPolicy Bypass -File .\scripts\Collect-Diagnostics.ps1 -Days 3

# 2) 按判读结果施加安全修复（脚本自己提权，写日志到 %TEMP%\windows-lag-triage\apply.log）
powershell -ExecutionPolicy Bypass -File .\scripts\Apply-SafeFixes.ps1

# 3) 同口径复核（重启后再跑一次）
powershell -ExecutionPolicy Bypass -File .\scripts\Verify-Fixes.ps1 -Hours 2

# 4) 卡的时候临时回收（只动微信小程序进程与输入法更新器残留）
powershell -ExecutionPolicy Bypass -File .\scripts\Release-Memory.ps1
```

## 脚本清单

| 脚本 | 作用 | 管理员 | 可回滚 |
|---|---|---|---|
| `scripts/Collect-Diagnostics.ps1` | 四类瓶颈取证 + 判读提示，可导出 CSV | 否 | 只读 |
| `scripts/Apply-SafeFixes.ps1` | AHCI LPM / PCIe ASPM / 磁盘空闲超时 / TRIM / Defender 排除 / Game DVR | 是（自提权） | 是，头部有回滚命令 |
| `scripts/Verify-Fixes.ps1` | 同口径计数器 + 设置回读 + PASS/WATCH 判定 | 否 | 只读 |
| `scripts/Release-Memory.ps1` | 回收微信小程序进程、更新器残留、孤儿 WebView2 | 否 | 重启即恢复 |

全部脚本为 **ASCII**、幂等、可重复执行。

## 一次真实案例（同一台机器，修复前后）

机器：i5-9400F（6 核 6 线程）/ 16GB DDR4-2667 / 低成本 SATA SSD（无 DRAM 缓存）/ Windows 10 22H2

修复前证据：`storahci` 事件 129 在 5 小时内出现 3 次（20:34、01:35、01:48）；磁盘读延迟 avg 2.71ms、峰值 13.94ms；密集操作时写入峰值 49,832 ops/s。

| 指标 | 修复前 | 修复后 |
|---|---|---|
| 事件 129 新增 | 5 小时 3 次 | 修复后 45 分钟 0 次，**第 50 分钟（03:00）复发 1 次**（未重启，LPM 变更尚未由驱动完全生效） |
| `Avg. Disk sec/Read` | 2.71 ms（max 13.94） | **0.81 ms（max 2.24）**，后续采样 0.12–1.0 ms |
| `Avg. Disk sec/Write` | 60–100 ms 峰值 | 1.3 ms |
| `Current Disk Queue Length` | 峰值 5–15 | 常态 **0** |
| `Page Writes/sec` | 有持续写入 | 0 |
| pagefile 实际占用 | 波动 | 0.17–0.28 GB（分配 30GB） |
| AHCI HIPM/DIPM | 默认 | 回读 **0x0** |
| PCIe ASPM | 默认 | 回读 **0x0** |

关于那次复发要如实记录：**LPM/ASPM 属于电源策略，存储驱动通常要重启后才真正按新值初始化**。因此判定口径必须是"重启后再观察 1–2 小时"；若重启后事件 129 仍在增长，结论就转向硬件——这块盘的主控/固件撑不住，换一块带 DRAM 缓存的 SSD 是唯一彻底解。

同时确认了两个"看起来像原因、其实不是"的方向：Defender 排除列表里早就有整盘排除（杀软不是瓶颈）；提交内存贴近上限但 pagefile 几乎不动（并不是常态换页）。

## 什么时候该说"这不是软件能修的"

- 关闭 LPM/ASPM 后事件 129 仍复发 → 盘的固件/主控问题，换一块带 DRAM 缓存的盘。
- 提交内存已顶到物理内存、用户又拒绝关任何应用 → 加内存，或接受"同时开几个 Electron 栈就是会卡"。
- 低线程数 CPU 上坚持以多个 Agent 客户端 + 双浏览器并行 → 容量问题。
- **重装系统只在"顺手换盘"或"系统文件确实损坏（`sfc`/`DISM` 报错）"时才有意义**；否则装完还是同一批应用、同一块盘。

## 作为 DSH 技能使用

把整个目录放到 `~/.dsh/skills/windows-lag-triage/`（Windows: `%USERPROFILE%\.dsh\skills\windows-lag-triage\`），DSH 会自动加载，技能名为 `windows-lag-triage`。`SKILL.md` 是给 agent 的执行说明，`scripts/` 是它调用的工具。

## 故障排查

| 现象 | 原因 | 处理 |
|---|---|---|
| `git push` 报 `Failed to connect to 127.0.0.1:7890` | git 全局配了 HTTP 代理但代理没启动 | `git -c http.proxy= -c https.proxy= push`（或临时清掉 `git config --global http.proxy`） |
| PowerShell 报 `UnexpectedToken` 且脚本"什么都没做" | `.ps1` 无 BOM 且含非 ASCII，PS 5.1 按 OEM 代码页解析 | 保持脚本纯 ASCII，或存成 UTF-8 **带 BOM** |
| `Apply-SafeFixes.ps1` 提权后没有输出 | 提权进程的输出不在当前控制台 | 看 `%TEMP%\windows-lag-triage\apply.log` |
| 修完仍然卡 | 事件 129 继续增长 / 提交内存顶到物理内存 | 换带 DRAM 缓存的盘 / 加内存，见上文 |

## 许可

MIT，见 `LICENSE`。
