# Run-Prime95Stress 修复实施计划：-Mode 生效 + 无日志校验

> 日期：2026-10-27 ｜ 状态：待执行 ｜ 规格：[2026-10-27-prime95-mode-log-fix-design.md](../specs/2026-10-27-prime95-mode-log-fix-design.md)
> 执行方式：Subagent-driven（每任务独立 subagent 实现，主 agent 审查后进下一个；结尾整支复查）。

**Architecture:** 改动集中在 3 个文件 + 文档同步。判定函数 `Get-Prime95Verdict` 增加 `-NoLogFile` 参数（默认 `$false`，不破坏既有调用）；`Run-Prime95Stress.ps1` 在启动前预写 `prime.txt`（`WorkPreference=<模式编码>` + `OutputJSON=0`）使 `-Mode` 生效，轮询期跟踪 results.txt 出现并传 `NoLogFile` 判定；`tests/test-prime95.ps1` 补两例；脚本 `-Help` 与 `docs/20` 同步口径。

---

## Task 1: lib_common.ps1 —— Get-Prime95Verdict 加 -NoLogFile

**改动**：`scripts/lib_common.ps1` `Get-Prime95Verdict`（约 L954-L982）：

- 参数表加 `[bool]$NoLogFile = $false`。
- 判定链在 `ErrorCount>0` 之后、PASS 之前插入：
  ```powershell
  elseif ($NoLogFile) {
      $status = 'FAIL'
      $reason = '未生成 results.txt(Prime95 未实际运行或时长过短未完成首轮)'
  }
  ```
- PASS 结论文案不变（`-f` 格式化保持）。既有调用不传该参数 → 行为不变。

**验证**：
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-prime95.ps1
```

**提交信息**：`fix(prime95): Get-Prime95Verdict 支持 -NoLogFile 判定（无 results.txt 判 FAIL）`

---

## Task 2: Run-Prime95Stress.ps1 —— 预写模式键 + 无日志跟踪

**改动**：`scripts/Run-Prime95Stress.ps1`

1. **A：预写 prime.txt（清空旧产物之后、启动 `-t` 之前，约 L104-107 之后）**：
   ```powershell
   # 预写 prime.txt 使 -Mode 生效：WorkPreference 为 torture 类型社区编码
   # （0=Small FFTs / 1=In-place large FFTs / 2=Blend / 3=Custom，官方文档未记载，实机冒烟确认）
   $modeKey = if ($Mode -eq 'Blend') { 2 } elseif ($Mode -eq 'Large') { 1 } else { throw "未知 Mode: $Mode" }
   $primeTxt = Join-Path $prime95Dir 'prime.txt'
   @("WorkPreference=$modeKey", 'OutputJSON=0') |
       [System.IO.File]::WriteAllLines($primeTxt, [string[]]@("WorkPreference=$modeKey", 'OutputJSON=0'), (New-Object System.Text.UTF8Encoding($false)))
   ```
   （注意：`WriteAllLines` 需显式 UTF8 无 BOM；实现时可用一行 `[System.IO.File]::WriteAllText($primeTxt, "WorkPreference=$modeKey`nOutputJSON=0`n", utf8NoBom)` 更稳。）

2. **B：轮询跟踪 results.txt 出现**（循环内，L120-129）：
   ```powershell
   $resultsSeen = $false
   do {
       Start-Sleep -Seconds 30
       ...
       $stats = Get-Prime95LogStats -LogFile (Join-Path $prime95Dir 'results.txt')
       if ($stats.LastWriteTime -or (Test-Path -LiteralPath (Join-Path $prime95Dir 'results.txt'))) { $resultsSeen = $true }
       ...
   } while (...)
   ```

3. **C：判定传参**（L139）：
   ```powershell
   $noLog = (-not $exitedEarly) -and (-not $resultsSeen)
   $verdict = Get-Prime95Verdict -ActualMinutes $actualMin -TargetMinutes $Minutes -ErrorCount $finalStats.ErrorCount -ExitedEarly $exitedEarly -NoLogFile $noLog
   ```

4. **D：日志提示**（循环内，`$stats.LastWriteTime` 提示块附近）：运行过半仍未出现 results.txt 时提示：
   ```powershell
   if (-not $resultsSeen -and ((Get-Date) - $startTime).TotalMinutes -gt ($Minutes / 2)) {
       Write-Host "提示：尚未生成 results.txt（写入间隔约 300s，首轮大 FFT 未完成属正常；继续观察）"
   }
   ```

5. **E：`-Help` 文案补充**（说明节）：
   - `-Mode` 说明加：`经 prime.txt WorkPreference 键生效（社区编码，实机冒烟确认后回填）`
   - 判定说明加：`运行结束未生成 results.txt 判 FAIL（Prime95 未实际运行或时长过短）`

**验证**（静态语法 + 回归）：
```powershell
powershell -NoProfile -Command "[scriptblock]::Create((Get-Content -Raw 'scripts\Run-Prime95Stress.ps1')) | Out-Null; 'SYNTAX OK'"
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-prime95.ps1
```

**提交信息**：`fix(prime95): -Mode 经 prime.txt WorkPreference 生效；未生成 results.txt 判 FAIL 防假 PASS`

---

## Task 3: tests/test-prime95.ps1 —— 新增 NoLog 用例

**改动**：`tests/test-prime95.ps1` 在 Get-Prime95Verdict 用例区追加：

```powershell
$v = Get-Prime95Verdict -ActualMinutes 185 -TargetMinutes 180 -ErrorCount 0 -ExitedEarly $false -NoLogFile $true
Assert ($v.Status -eq 'FAIL' -and $v.Conclusion -match '未生成 results.txt') "FAIL 无日志(NoLogFile)"
$v = Get-Prime95Verdict -ActualMinutes 185 -TargetMinutes 180 -ErrorCount 0 -ExitedEarly $false -NoLogFile $false
Assert ($v.Status -eq 'PASS') "PASS 无日志参数为 false 不破坏既有行为"
```

**验证**：
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-prime95.ps1
```

**提交信息**：`test(prime95): 覆盖 NoLogFile 判定分支`

---

## Task 4: 文档同步

**改动**：
- `scripts/Run-Prime95Stress.ps1` `-Help`（Task 2 已含，如未做在此补）。
- `docs/20-纯命令行压测手册.md`：
  - L168/L170/L227 判定口径行补"且 已生成 results.txt（未生成判 FAIL）"。
  - L162 注释"（脚本自动启动内置 tools\prime95\ 无人值守跑 Blend 模式…）"可补"经 prime.txt WorkPreference 键生效"。
- `memtest/docs/20-纯命令行压测手册.md`（若存在同文件，同步相同行）。

**验证**：grep 确认改动行：
```powershell
Select-String -Path 'docs\20-纯命令行压测手册.md' -Pattern '未生成 results.txt'
```

**提交信息**：`docs(prime95): 同步模式键与无日志判定口径`

---

## Task 5: 整支验证（主 agent 执行）

- 跑 `tests\test-prime95.ps1`（全 PASS，含新用例）。
- 静态检查两个脚本语法。
- 复核：`Get-Prime95Verdict` 不传 NoLogFile 的旧行为不变（test-prime95 既有 4 例覆盖）。
- 打包（与 ISO 顺序修复一并）：`build.ps1 -Zip`，校验 zip 时间戳与包内关键文件 hash（若用户确认）。

---

## 备注
- 实机冒烟（服务器 `-Minutes 5 -Mode Blend`）为前置验收：确认归档 `prime.txt` 含 `WorkPreference=2` 且 `results.txt` 生成 → 模式编码确认；若 Prime95 忽略/改写该键，回填规格 §5 修正。
