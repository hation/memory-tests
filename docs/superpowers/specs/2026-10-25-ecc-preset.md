# 设计规格 · ECC 服务器侧检测（方案 A：预设并入 ecc）

> 状态：[当前有效]（2026-10-25）
> 变更记录：2026-10-25 新建

## 1. 背景与目标

用户明确原则：**一切围绕被测服务器测试**。当前 MONITOR_ECC（`-MonitorEcc` / `MONITOR_ECC=1`）
读的是**编排机本机**的 Windows WHEA——在"编排机=PC、被测=服务器"的架构下，
读不到服务器的 ECC 事件，`whea.csv` 对服务器无意义。**这是设计缺陷。**

目标：ECC 检测改由**服务器自身**完成——memtest86+ 的 `ecc` 引导参数（官方 readme 已确认：
`ecc — Enable ECC polling`）在服务器跑 memtest 时**直接轮询服务器内存控制器的 ECC 计数器**，
错误以 `ev=ecc/ev=uecc` 事件进 MTLOG → 编排器解析 → 报告 `EccErrors` 列直接体现。整条链路在服务器侧。

## 2. 需求（用户已确认方向）

- **方案 A**：现有 6 个 SOL 预设的 cmdline **全部追加 `ecc`**（菜单项数不变，不膨胀）；
  非 ECC 机器无副作用（无计数器则无事件）。
- 顺带修复：SOL 解析器把 `ev=ecc` / `ev=uecc` 事件**累加到报告 `EccErrors` 列**
  （当前只进 ErrorDetails，报告列恒为 0）。

## 3. 设计

### 3.1 config/memtest-presets.conf（6 个 SOL 预设追加 `ecc`）

| 预设 | 修改后 cmdline |
| --- | --- |
| 4轮全项 | `log=ttyS0,115200 maxpasses=4 ecc` |
| 4轮快筛 | `log=ttyS0,115200 maxpasses=4 testlist=0,1,2,3,4,5,6,7,8 ecc` |
| 2轮全项 | `log=ttyS0,115200 maxpasses=2 ecc` |
| 2轮快筛 | `log=ttyS0,115200 maxpasses=2 testlist=0,1,2,3,4,5,6,7,8 ecc` |
| 1轮全项 | `log=ttyS0,115200 maxpasses=1 ecc` |
| 1轮快筛 | `log=ttyS0,115200 maxpasses=1 testlist=0,1,2,3,4,5,6,7,8 ecc` |
| 交互界面 | `nomch`（不变，手动调试用） |

### 3.2 解析器（scripts/lib_common.ps1 Invoke-MtlogParser）

在 switch 的 `"ecc"` / `"uecc"` 分支中，除现有 `ErrorDetails` 记录外，追加：

```powershell
"ecc"  { $summary.ErrorDetails += ...; $summary.EccErrors++ }
"uecc" { $summary.ErrorDetails += ...; $summary.EccErrors++ }
```

> 假设：memtest86+ 的 `ev=ecc/ev=uecc` 为错误事件（每事件 1 次计数），与解析器既有
> ErrorDetails 处理一致。若实际为周期性计数器事件（含 `count=` 字段），后续按字段调整。

### 3.3 重制 ISO

改完预设后跑 `New-MemtestSolIso.ps1` 重建 `memtest-sol.iso`；验证 ISO 内 grub.cfg
的 6 个 SOL 菜单项均含 `ecc`、菜单项数仍为 7。

### 3.4 输出

报告 `reports\<批次>-report.csv` 的 `EccErrors` 列：SOL 全项/快筛档位测完直接反映服务器
ECC 错误数（>0 即 ECC 检测到错误）；事件明细仍在 ErrorDetails（mtlog 可查）。

## 4. 边界与异常

| 场景 | 行为 |
| --- | --- |
| 非 ECC 机器跑 `ecc` | 无 ECC 计数器 → 无 ev=ecc 事件 → EccErrors=0，无副作用 |
| 服务器 ECC=True 且正常 | ECC 轮询有计数，ev=ecc 事件出现（可能 0 错误） |
| 服务器 ECC 纠错发生 | ev=ecc/ev=uecc 事件 → EccErrors 累加 → 报告可见 |
| 交互预设（nomch） | 不加 ecc（手动界面，保持原样） |
| MONITOR_ECC（编排机 WHEA） | 保留原功能（仍读编排机 WHEA），不作为服务器 ECC 依据 |

## 5. 测试策略

1. 预设解析：`Get-MemtestPresets` 读新 conf → 6 个 SOL 预设 cmdline 均含 `ecc`（回归 test-presets 覆盖）。
2. 解析器：合成 MTLOG（含 `ev=ecc` / `ev=uecc`）→ `Invoke-MtlogParser` → `EccErrors` 累加正确。
3. ISO：重制后 grub.cfg 含 `ecc` 且 7 项菜单（Mount-DiskImage 自检或 grep）。
4. 全量回归：test-presets / test-suite-config / test-cmdlog / test-lib / test-iso-build / test-smoke 等全部 PASS。

## 6. 文档更新

- `docs/16-新工具压力测试使用指南.md`：预设表 cmdline 列标注 `+ecc`（ECC 轮询默认开启）。
- `docs/20-纯命令行压测手册.md`：流程 2 说明"全项/快筛预设已带 ECC，测完报告直接含 EccErrors"；
  流程 4（ECC）改为"测完直接看报告 EccErrors 列 / mtlog ev=ecc；不再需要服务器手查 WHEA"。
- `docs/19-测试项执行清单.md`：第 4 项"怎么做"改为"全项预设已带 ecc，测完看报告 EccErrors + mtlog"；
  服务器 WHEA/mcelog 作为补充交叉验证。

## 7. 不做的事

- 不改 GRUB 菜单结构（方案 A，菜单仍 7 项）。
- 不动 MONITOR_TEMP / RESTART_LOOP（已通过 BMC 读/操作服务器，无需改动）。
- 不做 B 方案（GRUB ECC 开关）。
