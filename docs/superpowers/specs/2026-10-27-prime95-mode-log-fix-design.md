# Run-Prime95Stress 修复（v2）：-Mode 完整配置生效 + CPU 活跃判定 —— 设计文档

> 日期：2026-10-27 ｜ 状态：待执行 ｜ 关联：[2026-10-26-prime95-mix-stress-design.md](./2026-10-26-prime95-mix-stress-design.md)（原设计）
> 变更记录：
> - 2026-10-27 v1 初稿：-Mode 写 WorkPreference + 无日志判 FAIL（已实施并打包 v14）。
> - 2026-10-27 v2 修正：实机（服务器 10 分钟）与本机实验证明 **v1 两个假设均错**：① 仅写 WorkPreference 不足以让 Blend 生效（缺 StressTester 等完整键）；② v30.19 torture 正常运行**不写 results.txt**（CPU 满载+大内存分配但 360s 无任何结果文件）→ "无日志判 FAIL" 误判正常运行的测试。本规格按实验事实修正。

## 1. 背景与意图（why）

服务器 `-Minutes 10 -Mode Blend`（v14）报告 FAIL"未生成 results.txt"。本机实验（temp 目录 + prime95 v30.19b20）证实：

1. **-Mode 需完整 torture 配置键**：仅写 `WorkPreference=2` 时内存不增长（≈647MB，未按 Blend 分配大内存）；补写 `StressTester=1` + `MinTortureFFT=4` + `MaxTortureFFT=8192` + `TortureMem` 后内存升至 **5.4GB**（Blend 大内存分配生效）。**Torture 完整配置键**（从本机 tools\prime95 残留 prime.txt 实测取得）：`StressTester=1`、`UsePrimenet=0`、`TortureHyperthreading=1`、`MinTortureFFT`、`MaxTortureFFT`、`TortureMem`、`WorkPreference`。
2. **v30.19 torture 不写 results.txt**：360s 实验（CPU=3410s 满载、内存 5.4GB）目录中 **无 results.txt / results.json.txt / screen.log**。whatsnew L1120 确认 torture 的错误计数写 results.txt（**出错时才写**）；常规进度只在 worker 窗口（GUI）显示。→ 原"无日志判 FAIL"把**正常运行的测试误判为 FAIL**。
3. 脚本旧判定"进程存活+0 错误"实际可正确放行（Prime95 出错时写 results.txt 可被扫描到），只是**缺少"测试是否真正开始"的防呆**（若卡在 GUI 对话框则 CPU 无活动）。

目标：让 `-Mode Blend|Large` 通过**完整配置键**真正生效；判定改为 **进程存活 + CPU 活跃（在跑）+ 错误扫描**；**废弃"无日志 FAIL"**；新增 **CPU 无活动（疑似卡对话框）判 FAIL**。

## 2. 目标 / 非目标 / 反目标

**目标**
1. `-Mode` 生效：启动前写完整 torture 配置键（§4.1），Blend 分配大内存、Large 跑大 FFT；报告 Mode 与实际一致。
2. 判定重构：PASS = 到点 + 未提前退出 + 无错误 + CPU 活跃；FAIL = 提前退出 / 错误 / 时长不足 / **CPU 无活动（进程活着但 CPU 时间不增长，疑似卡对话框）**。
3. 错误检测保留：轮询 results.txt，出现 FATAL ERROR / Self-test failed / FAILED → 提前停 FAIL（torture 出错时写 results.txt）。
4. 单元测试覆盖新判定分支（CpuInactive）；`test-prime95.ps1` 全绿。
5. 文档/帮助同步（-Help、docs/20）。
6. 重新打包 v14 供服务器实机验证。

**非目标（不做）**
- 不做 GUI 弹窗自动化点击（本机/服务器诊断均未发现"需点击的对话框"；torture 实际已自动开始）。
- 不实现 `-W` 目录隔离（维持现状）。
- 不改 memtest / ORT / 打包流程。
- 不新增报告列。

**反目标（做了就算失败）**
- 报告 Mode 与实际运行模式不一致（内存是否大分配可验证）。
- 正常运行的 torture 被误判 FAIL（v1 的 NoLog 判定必须移除）。
- 卡对话框/未开始的场景被误判 PASS（CpuInactive 防呆）。
- 破坏 test-prime95 既有用例、master_manifest 列结构。

## 3. 约束（已核实事实）

- PowerShell 5.1；脚本沿用既有约定（Write-CmdLog/Get-AppVersion/Export-Prime95Report）。
- Prime95 v30.19b20（内置 tools\prime95\）：
  - `-t` 启动 torture（readme L524 "Same as Options/Torture Test"）；诊断确认启动后主窗口 + N 个 "Worker #N - Torture Test" 窗口，**无独立参数对话框**（UIAutomation 0 按钮；Win32 枚举仅 MDIClient/Worker/statusbar）→ torture 自动开始。
  - **torture 完整配置键**（本机实测取得）：`StressTester=1`、`UsePrimenet=0`、`TortureHyperthreading=1`、`MinTortureFFT=4`、`MaxTortureFFT=8192`、`TortureMem=<MB>`、`WorkPreference=<0..3>`。GUI 顺序编码：0=Small / 1=In-place large / 2=Blend / 3=Custom。
  - **torture 常规不写 results.txt**（360s 满载+大内存仍无文件）；出错时写 results.txt（whatsnew L1120 错误计数）。
  - `BootDelay=90`（undoc L211）：进程启动约 90s 才开工（仅重启后场景；进程刚启动无此延迟）。
  - `ResultsFileTimestampInterval=300`：results.txt 时间戳间隔（GIMPS 计算任务用，torture 不适用）。
- 服务器（诊断）：32 个 worker 窗口（32 线程 CPU），无参数对话框，与"torture 自动开始"一致。
- 打包纪律：代码产物变更 → 打包（v14 内容更新重打）。

## 4. 方案设计（how）

### 4.1 `scripts/Run-Prime95Stress.ps1`

**A. 预写完整 torture 配置**（清空 exe 目录旧产物之后、启动前）：
```powershell
$modeKey = if ($Mode -eq 'Blend') { 2 } elseif ($Mode -eq 'Large') { 1 } else { throw "未知 Mode: $Mode" }
# TortureMem：本机物理内存的 70%（MB），下限 4096，避免 OOM 且保证 Blend 大内存压测
$memMB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB)
$tortureMem = [math]::Max(4096, [int]($memMB * 0.7))
$primeTxt = @(
    'StressTester=1',
    'UsePrimenet=0',
    "WorkPreference=$modeKey",
    'TortureHyperthreading=1',
    'MinTortureFFT=4',
    'MaxTortureFFT=8192',
    "TortureMem=$tortureMem",
    'OutputJSON=0'
) -join "`n"
[System.IO.File]::WriteAllText($primeTxtPath, $primeTxt + "`n", utf8NoBom)
```
- NumWorkers/CoresPerTest 不写（Prime95 自动探测，实测会自动补写）。
- 注释标注键来源（本机实测）与实机验证要求。

**B. CPU 活跃跟踪（防呆，替代 NoLog）**：
- 轮询循环内（每 30s）：`$p.Refresh(); $cpuNow = $p.CPU`；若 `$cpuNow -le $cpuPrev` 且进程活着 → `$cpuIdleCount++`；否则 `$cpuIdleCount = 0`；记录 `$cpuPrev = $cpuNow`。
- `$cpuIdleCount -ge 3`（≈90s 无 CPU 活动）且进程存活 → 判"疑似卡住"：记录 `$stuck = $true`，继续轮询到点（不提前杀，避免误杀慢启动；由最终判定兜底）。
- 首次轮询前 `$cpuPrev = 0`（Prime95 启动后很快有计算，90s 内应有 CPU 增长）。

**C. 判定传参**：
```powershell
$stuck = (-not $exitedEarly) -and ($cpuIdleCount -ge 3)
$verdict = Get-Prime95Verdict -ActualMinutes $actualMin -TargetMinutes $Minutes -ErrorCount $finalStats.ErrorCount -ExitedEarly $exitedEarly -CpuInactive $stuck
```
- 不再使用 NoLogFile（废弃）。
- results.txt 轮询错误扫描保留（出错时文件会出现错误行 → HasErrors → 提前停 FAIL）。

**D. 日志提示**：保留 10 分钟未更新提示；CPU 连续无活动 ≥90s 时提示"CPU 无活动，疑似卡在对话框/未开始"。

**E. `-Help` 文案**：-Mode 说明改为"经 prime.txt 完整 torture 配置键生效（StressTester/MinTortureFFT/MaxTortureFFT/TortureMem/WorkPreference，本机实测）"；判定说明改为"进程存活 + CPU 活跃 + 无错误 → PASS；CPU 无活动（疑似卡对话框）→ FAIL"。

### 4.2 `scripts/lib_common.ps1`

`Get-Prime95Verdict`：**参数 `[bool]$NoLogFile` 改为 `[bool]$CpuInactive = $false`**；判定链在 ErrorCount 之后：
```powershell
elseif ($CpuInactive) {
    $status = 'FAIL'
    $reason = 'CPU 无活动(疑似卡在 Torture 对话框或未开始)'
}
```
（v1 的 NoLogFile 分支删除。）

### 4.3 `tests/test-prime95.ps1`

- 原 NoLogFile 两例改为 CpuInactive：
  - `-CpuInactive $true` → FAIL 且 Conclusion 匹配 `CPU 无活动`。
  - `-CpuInactive $false` → PASS（默认值不破坏既有行为）。
- 其余用例不动。

### 4.4 文档同步

- `-Help`（§4.1 E）。
- `docs/20-纯命令行压测手册.md` 与 `memtest/docs/20-…`：判定口径行"…且 已生成 results.txt；未生成判 FAIL" 改为 "…且 CPU 活跃（未开始/卡对话框判 FAIL）"；"经 prime.txt WorkPreference 键生效" 改为 "经 prime.txt 完整 torture 配置键生效"。

## 5. 交给 builder 的决策点

- TortureMem 取物理内存 70%（下限 4096MB）——若实机 Blend 内存占用过高/过低可调；结论注明实际分配。
- CPU 无活动阈值 90s（3 次轮询）——若慢启动误判可放宽。
- MinTortureFFT/MaxTortureFFT=4/8192（Blend 典型范围，实测来源）；Large 模式也可同范围（大 FFT 为主）。

## 6. 验收口径

1. **单元**：`test-prime95.ps1` ALL PASS（CpuInactive 两例替换 NoLogFile 两例）。
2. **静态**：两脚本语法检查通过。
3. **本机行为回归**（可选）：temp 目录 + 完整配置键跑 60s：进程 CPU 增长、内存大分配（Blend）、报告逻辑不再因无 results.txt 判 FAIL。
4. **实机（前置，用户服务器）**：`-Minutes 5 -Mode Blend` 冒烟：
   - 运行期任务管理器 **CPU≈100% + 内存 ≥ 数 GB**（Blend 生效）；
   - 报告 `Status=PASS`（到点 + 无错误 + CPU 活跃），`Mode=Blend`；
   - 归档 `work\<批次>\` 含 `prime.txt`（含 StressTester=1/WorkPreference=2 等）。
5. 打包：`build.ps1 -Bump -Zip`（v14 内容更新）→ zip 校验。

## 7. 待办与已知风险

- TortureMem 70% 动态值需实机确认（内存大的服务器分配大；OOM 风险低，Prime95 分配失败会报错）。
- torture 错误写 results.txt 的时机未实机验证（错误检测依赖此）；若实机发现出错也不写，需增加窗口文本轮询（备选，复杂，暂不做）。
- v1 已提交/打包的内容（NoLogFile 判定）本次修正后需重新提交与打包。
