# Run-Prime95Stress 修复 v2 实施计划：完整配置键 + CPU 活跃判定

> 日期：2026-10-27 ｜ 状态：待执行 ｜ 规格：[2026-10-27-prime95-mode-log-fix-design.md](../specs/2026-10-27-prime95-mode-log-fix-design.md)（v2）
> 执行方式：Subagent-driven（每任务独立 subagent 实现，主 agent 审查后进下一个；结尾整支复查）。

**Architecture:** v1（WorkPreference + NoLogFile 判定）经本机/实机实验证明方向有误，本次修正：
1. `Run-Prime95Stress.ps1` 预写**完整 torture 配置键**（StressTester/MinTortureFFT/MaxTortureFFT/TortureMem/WorkPreference 等）使 -Mode 真正生效；
2. 判定从"无 results.txt 判 FAIL"改为 **CPU 活跃判定**（进程活着但 CPU 时间不增长 ≥90s → 疑似卡对话框 → FAIL）；错误扫描保留；
3. `Get-Prime95Verdict` 参数 `NoLogFile` 改为 `CpuInactive`；测试与文档同步。

---

## Task 1: lib_common.ps1 —— NoLogFile → CpuInactive

**改动**：`scripts/lib_common.ps1` `Get-Prime95Verdict`（约 L954-L987）：
- `[bool]$NoLogFile = $false` → `[bool]$CpuInactive = $false`。
- 判定链分支（ErrorCount 之后）：
  ```powershell
  elseif ($CpuInactive) {
      $status = 'FAIL'
      $reason = 'CPU 无活动(疑似卡在 Torture 对话框或未开始)'
  }
  ```
  （原 NoLogFile 分支及其 reason 删除。）
- 其余（PASS 结论文案、返回结构）不变。

**验证**：
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-prime95.ps1
```

**提交信息**：`fix(prime95): Get-Prime95Verdict 以 CpuInactive 替代 NoLogFile 判定`

---

## Task 2: Run-Prime95Stress.ps1 —— 完整配置键 + CPU 活跃跟踪

**改动**：`scripts/Run-Prime95Stress.ps1`

1. **A：预写完整 torture 配置**（替换当前"仅 WorkPreference+OutputJSON"的预写块，约 L110-115）：
   ```powershell
   # 预写 prime.txt 使 -Mode 生效：完整 torture 配置键（本机实测：缺 StressTester 等键时
   # Blend 不分配大内存；键名非官方文档，实机冒烟确认）
   $modeKey = if ($Mode -eq 'Blend') { 2 } elseif ($Mode -eq 'Large') { 1 } else { throw "未知 Mode: $Mode" }
   $memMB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB)
   $tortureMem = [math]::Max(4096, [int]($memMB * 0.7))
   $primeTxtPath = Join-Path $prime95Dir 'prime.txt'
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
   [System.IO.File]::WriteAllText($primeTxtPath, $primeTxt + "`n", (New-Object System.Text.UTF8Encoding($false)))
   Write-Host "==> 已预写 $primeTxtPath（$Mode，WorkPreference=$modeKey，TortureMem=${tortureMem}MB）"
   ```

2. **B：CPU 活跃跟踪**（do 循环，约 L126-142）：
   - 循环前：`$cpuPrev = 0; $cpuIdleCount = 0`
   - 循环内（Start-Sleep 30 后、检查 HasExited 之前或之后均可）：
     ```powershell
     $p.Refresh()
     $cpuNow = $p.CPU
     if ($cpuNow -le $cpuPrev -and -not $p.HasExited) { $cpuIdleCount++ } else { $cpuIdleCount = 0 }
     $cpuPrev = $cpuNow
     if (-not $p.HasExited -and $cpuIdleCount -ge 3) {
         Write-Host "提示：CPU 连续无活动（≥90s），疑似卡在对话框/未开始；继续观察至到点"
     }
     ```

3. **C：判定传参**（替换 NoLogFile 调用，约 L152-154）：
   ```powershell
   $stuck = (-not $exitedEarly) -and ($cpuIdleCount -ge 3)
   $verdict = Get-Prime95Verdict -ActualMinutes $actualMin -TargetMinutes $Minutes -ErrorCount $finalStats.ErrorCount -ExitedEarly $exitedEarly -CpuInactive $stuck
   ```
   - 删除 `$noLog` 相关行与结果提示行中的 `[未生成 results.txt]` 标记（可改为 `[CPU 无活动]`）。
   - `$resultsSeen` 跟踪**删除**（不再需要）。

4. **E：`-Help` 文案**：
   - `-Mode` 行改为："`-Mode Blend | Large（默认 Blend）（经 prime.txt 完整 torture 配置键生效：StressTester/MinTortureFFT/MaxTortureFFT/TortureMem/WorkPreference，本机实测）`"
   - 判定说明行"运行结束未生成 results.txt 判 FAIL…"改为："`- 进程存活且 CPU 活跃（在跑）且无错误 → PASS；CPU 无活动（疑似卡对话框/未开始）→ FAIL`"
   - 实机冒烟提示行（含"OutputJSON=0"描述）同步为完整配置键说明。

**验证**：
```powershell
powershell -NoProfile -Command "[scriptblock]::Create((Get-Content -Raw 'scripts\Run-Prime95Stress.ps1')) | Out-Null; 'SYNTAX OK'"
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-prime95.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Run-Prime95Stress.ps1 -Help
```

**提交信息**：`fix(prime95): 完整 torture 配置键生效 + CPU 活跃判定（废弃无日志 FAIL）`

---

## Task 3: tests/test-prime95.ps1 —— NoLogFile 用例改 CpuInactive

**改动**：`tests/test-prime95.ps1`（约 L12-15）：
```powershell
$v = Get-Prime95Verdict -ActualMinutes 185 -TargetMinutes 180 -ErrorCount 0 -ExitedEarly $false -CpuInactive $true
Assert ($v.Status -eq 'FAIL' -and $v.Conclusion -match 'CPU 无活动') "FAIL CPU 无活动(CpuInactive)"
$v = Get-Prime95Verdict -ActualMinutes 185 -TargetMinutes 180 -ErrorCount 0 -ExitedEarly $false -CpuInactive $false
Assert ($v.Status -eq 'PASS') "PASS CpuInactive=false 不破坏既有行为"
```

**验证**：`powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-prime95.ps1`

**提交信息**：`test(prime95): NoLogFile 用例改 CpuInactive`

---

## Task 4: 文档同步

**改动**：
- `docs/20-纯命令行压测手册.md` 与 `memtest/docs/20-纯命令行压测手册.md`（4 处 × 2）：
  - "（经 prime.txt WorkPreference 键生效）" → "（经 prime.txt 完整 torture 配置键生效）"
  - "…且 已生成 results.txt；未生成判 FAIL" → "…且 CPU 活跃（未开始/卡对话框判 FAIL）"

**验证**：grep 确认。

**提交信息**：`docs(prime95): 同步完整配置键与 CPU 活跃判定口径`

---

## Task 5: 整支验证（主 agent）

- `tests\test-prime95.ps1` ALL PASS（7 例，含 CpuInactive 两例）。
- 两脚本语法检查。
- 复核：Run-Prime95Stress 不再引用 NoLogFile/resultsSeen；预写块含 StressTester 等键。
- 打包：`build.ps1 -Bump -Zip`（v14 内容更新）→ 校验 zip 关键文件 hash。

---

## 备注
- 实机冒烟（服务器 `-Minutes 5 -Mode Blend`）：任务管理器 CPU≈100% + 内存 ≥ 数 GB + 报告 PASS（到点、无错误、CPU 活跃）→ 修复确认。
- 若实机发现 torture 出错也不写 results.txt，需后续增加 worker 窗口文本轮询（备选，本次不做）。
