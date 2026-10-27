# Run-Prime95Stress 修复：-Mode 真正生效 + 无日志假 PASS 校验 —— 设计文档

> 日期：2026-10-27 ｜ 状态：待执行 ｜ 关联：[2026-10-26-prime95-mix-stress-design.md](./2026-10-26-prime95-mix-stress-design.md)（原设计）
> 变更记录：2026-10-27 初稿。前置实机检查（srv01-a1-ort-p95，2026-09-28）暴露两个缺陷，本规格针对修复。

## 1. 背景与意图（why）

实机检查结果 `tmp/results-被测试服务器`（srv01-a1-ort-p95，`-Minutes 6 -Mode Blend`）发现两个缺陷：

1. **`-Mode` 参数未真正生效**：脚本启动 Prime95 只传 `-t`，不写任何模式配置（原设计 §4.1/§4.3 明确"模式键留待实机冒烟回填，首版仅写 OutputJSON=0"）。报告里的 `Blend` 只是参数透传。归档的 `prime.txt` 为 `WorkPreference=0` —— 按社区 torture 配置编码（GUI 顺序：0=Small FFTs / 1=In-place large FFTs / 2=Blend / 3=Custom）对应 **Small FFTs（纯 CPU 压，几乎不压内存）**，与"混插内存长压"验收意图不符。
2. **无日志假 PASS**：批次目录归档仅 `prime.txt`，**无 `results.txt` / `screen.log`**。`Get-Prime95LogStats` 对"文件不存在"返回 `ErrorCount=0/HasErrors=$false`，脚本把"整个运行期 Prime95 未写出任何日志"当作"0 错误"→ 判 PASS。6 分钟里 Prime95 未写一行 results.txt（官方 `ResultsFileTimestampInterval` 默认 300 秒，且 Blend 首轮大 FFT 可能未完成；也可能首次运行停在配置对话框未真正开测），**PASS 结论无运行数据支撑**。

目标：让 `-Mode Blend|Large` 真正写入 Prime95 配置并生效；运行结束若 `results.txt` 从未生成 → 判 FAIL（防假 PASS）。

## 2. 目标 / 非目标 / 反目标

**目标**
1. `-Mode` 生效：启动前向 Prime95 工作目录写 `prime.txt`，按模式写入 torture 类型键（社区编码，见 §3），使 Blend/Large 真正执行；报告 Mode 列与实际运行一致。
2. 无日志校验：轮询期跟踪 `results.txt` 是否出现过；运行结束时从未出现 → 判定 FAIL，结论注明"未生成 results.txt"。
3. 归档一致性：判定依赖的 results.txt 归档缺失时结论自洽（无日志→FAIL，不与 PASS 冲突）。
4. 单元测试覆盖新增判定分支；`test-prime95.ps1` 全绿。
5. 文档/帮助同步：脚本 `-Help` 说明模式键与无日志判定；docs/20 相关行同步。

**非目标（不做）**
- 不实现 `-W` 目录隔离（2026-10 实机冒烟结论：`-W` 命令行无效，结果落 exe 目录；维持现状"清 exe 目录旧产物 + 结束后归档"）。
- 不改 memtest / ORT / 打包流程。
- 不新增报告列（Status/Conclusion 已能表达无日志原因）。

**反目标（做了就算失败）**
- 报告 Mode 与实际运行模式不一致仍被当作"生效"。
- 无 results.txt 仍判 PASS（本次缺陷复发）。
- 破坏 `test-prime95.ps1` 既有用例、master_manifest 列结构。

## 3. 约束（已核实事实）

- PowerShell 5.1；脚本沿用 `Write-CmdLog` / `Get-AppVersion` / `Export-Prime95Report` 既有约定。
- Prime95 v30.19b20 官方文档（内置 `tools\prime95\` readme/undoc/stress）：
  - `-t` 仅"Run the torture test. Same as Options/Torture Test"（readme L524）——**无命令行模式参数**；模式只能经 prime.txt 配置。
  - `TortureTest=` / `WorkPreference=` 键名与取值**官方文档未记载**（undoc.txt 全文无匹配）。
  - 社区共识编码（GUI Torture 对话框单选顺序）：`WorkPreference` 0=Small FFTs / 1=In-place large FFTs / 2=Blend / 3=Custom。`-Mode Large` 对应 1（In-place large FFTs，大 FFT 压内存）。**实机冒烟为前置验收，编码若有出入回填修正**。
  - `ResultsFileTimestampInterval=300`（undoc L171）：results.txt 默认 300 秒才写一次 → 短时（如 6 分钟）可能 0 次写入，必须靠"进程存活"+"无错误"+"无日志则 FAIL"组合判定。
  - `BootDelay=90`（undoc L211）：进程启动约 90 秒才开工 → 短压实际运行窗口更小，进一步强化无日志 FAIL 的必要性。
- 现有判定链：`Get-Prime95Verdict`（PASS ⇔ 足时长 且 0 错误 且 非提前退出）+ `Get-Prime95LogStats`（文件不存在→0 错误）+ `Export-Prime95Report`。测试 `tests/test-prime95.ps1` 覆盖 4 类 Verdict + LogStats + Report。
- 打包纪律：本次改动属逻辑代码调整，完成后需 `build.ps1 -Zip`（与 ISO 顺序修复一并打包）。

## 4. 方案设计（how）

### 4.1 `scripts/Run-Prime95Stress.ps1` 改动

**A. 预写 prime.txt 使 `-Mode` 生效**（当前"清空 exe 目录旧产物"之后、"启动 `-t`"之前）：

```
$modeKey = if ($Mode -eq 'Blend') { 2 } elseif ($Mode -eq 'Large') { 1 } else { throw }
# 写 <prime95Dir>\prime.txt：UTF-8 无 BOM；OutputJSON=0 保持文本日志，WorkPreference 为 torture 类型（社区编码）
```

- 仅写最小键 `WorkPreference=<n>` + `OutputJSON=0`；`NumWorkers`/`CoresPerTest` 不写（交由 Prime95 自动探测，避免写错）。
- 启动后 Prime95 首次运行会补齐其余键；结束时该 prime.txt 随既有流程 Move 归档（保留证据，供实机核对模式）。
- 模式映射写成小函数或内联注释；`-Mode` 仍为 `ValidateSet("Blend","Large")`。

**B. 无日志判定**：

- 轮询循环内记录 `$resultsSeen`（`Test-Path exe 目录\results.txt` 为真 或 `$stats.LastWriteTime` 非 null 即置位）。
- 运行结束（非提前退出、到点）时：`$noLog = -not $resultsSeen`。
- 传给 `Get-Prime95Verdict -NoLogFile $noLog`；PASS 条件增加"且 `NoLogFile=$false`"。
- 提前退出（`$exitedEarly`）场景已是 FAIL，不叠加 NoLog（结论以提前退出为准）。
- 归档：`Move-Item` 后若 `$noLog` 且 `Test-Path workDir\results.txt` 仍为假，判定已 FAIL，与归档一致，无需额外动作。

**C. 日志提示**：保留现有"results.txt 10 分钟未更新"提示；新增提示：运行过半仍未出现 results.txt 时输出"尚未生成 results.txt（写入间隔约 300s，首轮大 FFT 未完成属正常）"，仅提示不判定。

### 4.2 `scripts/lib_common.ps1` 改动

`Get-Prime95Verdict` 增加可选参数 `[bool]$NoLogFile = $false`：

- 判定顺序（保持现有）：提前退出 → 时长不足 → ErrorCount>0 → **NoLogFile** → PASS。
- NoLogFile 触发：`$status='FAIL'; $reason='未生成 results.txt(Prime95 未实际运行或时长过短未完成首轮)'`。
- 既有调用（不传 NoLogFile）行为不变；返回对象结构不变（Status/Conclusion）。

### 4.3 测试 `tests/test-prime95.ps1` 改动

新增用例（追加到 Get-Prime95Verdict 五类之后）：

- 足时长、0 错误、非提前退出、`NoLogFile=$true` → FAIL 且 Conclusion 匹配 `未生成 results.txt`。
- 足时长、0 错误、非提前退出、`NoLogFile=$false` → PASS（回归确认参数默认值不破坏既有行为）。

### 4.4 文档/帮助同步

- `Run-Prime95Stress.ps1 -Help`：说明 `-Mode` 经 prime.txt `WorkPreference` 键生效（社区编码，实机冒烟验证）；`results.txt 未生成 → FAIL`。
- `docs/20-纯命令行压测手册.md` 流程 3（若含 Prime95 表述）同步一句口径；文档标注本次冒烟验证结论后回填编码确认状态。
- 根 `docs/` 与 `memtest/docs/` 同步（如涉及时）。

## 5. 交给 builder 的决策点

- `WorkPreference` 编码若实机冒烟证实不符（如 Prime95 忽略该键），以冒烟结论回填修正；在脚本注释与文档中如实标注"待实机确认"。
- 轮询提示阈值沿用现有 10 分钟；"运行过半"提示的具体时机由实现自定。
- 归档 `screen.log` 缺失不参与判定（results.txt 为准）。

## 6. 验收口径

1. **单元验收**：`tests/test-prime95.ps1` 全 PASS（含新增 NoLog 两例）；`Get-Prime95Verdict` 不传 NoLogFile 时行为与修改前一致。
2. **静态检查**：`Run-Prime95Stress.ps1` 无语法错误（`powershell -NoProfile -Command "[scriptblock]::Create((Get-Content -Raw scripts\Run-Prime95Stress.ps1))"`）；改动行与规格一致。
3. **实机冒烟（前置验收，有服务器后执行）**：服务器跑 `-Minutes 5 -Mode Blend`：
   - `results\work\<批次>\` 含 `results.txt`（有实际测试进度）；
   - 归档 `prime.txt` 含 `WorkPreference=2`（Blend）——编码确认；若被 Prime95 改写则按 §5 回填；
   - 报告 `Mode=Blend`、Status=PASS（足时长+有日志+0 错误）。
4. 打包：`build.ps1 -Zip`（与 ISO 顺序修复一并），包内关键文件 hash 一致。

## 7. 待办与已知风险

- `WorkPreference` 编码无官方依据 → 实机冒烟为前置验收；未通过前报告 Mode 列语义为"目标模式"，结论注明"模式键待实机确认"。
- 短时（< 首轮完成）压测本就可能无 results.txt → 无日志 FAIL 会把这类短压判失败；这是预期行为（时长过短无法证明测试真实运行），帮助文案已说明。
- 冒烟需在服务器执行（本机无服务器），本次交付含冒烟操作手册片段，由用户实机执行。
