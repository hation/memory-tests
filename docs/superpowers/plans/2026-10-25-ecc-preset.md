# 实施计划 · ECC 服务器侧检测（方案 A）

> 状态：[当前有效]（2026-10-25）
> 规格：`docs/superpowers/specs/2026-10-25-ecc-preset.md`
> 执行方式：subagent-driven development

## 任务总览

| # | 任务 | 产出 | 验证 |
| --- | --- | --- | --- |
| 1 | 预设加 `ecc` + 重制 ISO | memtest-presets.conf / memtest-sol.iso | 菜单含 ecc 且 7 项 |
| 2 | 解析器 EccErrors 累加 | lib_common.ps1 | 合成日志验证 |
| 3 | 回归测试更新 | test-presets.ps1（若需） | ALL PASS |
| 4 | 文档更新（16/20/19） | 3 个文档 | grep |
| 5 | 全量回归 + build -Zip + 提交推送 | zip + commits | 全部 PASS |

## 任务 1：预设加 ecc + 重制 ISO

**改动**：`config/memtest-presets.conf`，6 个 SOL 预设 cmdline 末尾追加 `ecc`（交互预设 `nomch` 不变）：
- `preset.4轮全项.cmdline=log=ttyS0,115200 maxpasses=4 ecc`
- `preset.4轮快筛.cmdline=log=ttyS0,115200 maxpasses=4 testlist=0,1,2,3,4,5,6,7,8 ecc`
- `preset.2轮全项.cmdline=log=ttyS0,115200 maxpasses=2 ecc`
- `preset.2轮快筛.cmdline=log=ttyS0,115200 maxpasses=2 testlist=0,1,2,3,4,5,6,7,8 ecc`
- `preset.1轮全项.cmdline=log=ttyS0,115200 maxpasses=1 ecc`
- `preset.1轮快筛.cmdline=log=ttyS0,115200 maxpasses=1 testlist=0,1,2,3,4,5,6,7,8 ecc`

**重制 ISO**（仓库根执行，GRUB/Python 已内置，离线）：
`powershell -NoProfile -ExecutionPolicy Bypass -File scripts\New-MemtestSolIso.ps1`

**验证**：
1. `powershell -NoProfile -Command ". scripts\lib_common.ps1; (Get-MemtestPresets -Path 'config\memtest-presets.conf').Presets | % { \"$($_.Key)=$($_.Cmdline)\" }"` 输出 6 个 SOL 预设均含 `ecc`。
2. ISO 内 grub.cfg：解压/挂载 ISO 或 `Mount-DiskImage` 后 grep `ecc` 出现 ≥6 次、菜单项仍 7 个（`menuentry` 计数）。

## 任务 2：解析器 EccErrors 累加

**改动**：`scripts/lib_common.ps1` `Invoke-MtlogParser` 的 switch 中：

```powershell
"uecc" { $summary.ErrorDetails += [PSCustomObject]@{ Type = $event; Fields = $fields }; $summary.EccErrors++ }
"ecc"  { $summary.ErrorDetails += [PSCustomObject]@{ Type = $event; Fields = $fields }; $summary.EccErrors++ }
```

（保持 UTF-8 with BOM；只改这两行，其余不动。）

**验证**（合成日志）：
```powershell
$log = "$env:TEMP\_ecc_test.mtlog"
@"
MTLOG ts=1.0 ev=start
MTLOG ts=2.0 ev=ecc count=1
MTLOG ts=3.0 ev=uecc addr=0x1234
MTLOG ts=4.0 ev=done passes=1 status=pass
"@ | Set-Content -Path $log -Encoding UTF8
powershell -NoProfile -Command ". scripts\lib_common.ps1; \$s = Invoke-MtlogParser -LogFile '$log'; \"EccErrors=\$(\$s.EccErrors) Details=\$(\$s.ErrorDetails.Count)\""
```
期望输出：`EccErrors=2 Details=2`。完成后删除临时文件。

## 任务 3：回归测试

`tests\test-presets.ps1` 若断言 cmdline 字面值，需同步更新（含 `ecc`）。检查后更新。
验证：`powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-presets.ps1` → ALL PASS。

## 任务 4：文档更新

- `docs/16-新工具压力测试使用指南.md`：预设表 cmdline 加 `ecc`（标注"ECC 轮询默认开启"）。
- `docs/20-纯命令行压测手册.md`：流程 2 加注"全项/快筛预设已带 ECC，测完报告 EccErrors 列直接反映服务器 ECC"；流程 4（ECC）改为"测完直接看报告 EccErrors / mtlog ev=ecc；服务器本机 WHEA 仅作交叉验证"。
- `docs/19-测试项执行清单.md`：第 4 项"怎么做"改为全项预设已带 ecc + 看报告 EccErrors；WHEA/mcelog 作补充。

## 任务 5：全量回归 + 打包 + 提交推送

1. 全量回归：test-presets / test-suite-config / test-cmdlog / test-lib / test-args / test-gating / test-iso-build / test-smoke 全部 PASS。
2. `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build.ps1 -Zip`（先删旧包再建新包）。
3. 提交：
   - `feat: enable ECC polling in all SOL presets (ecc param) + parser EccErrors accumulation`
   - `docs: ECC server-side verification (16/20/19) + kit sync`
4. `git -c http.postBuffer=524288000 push origin main`
