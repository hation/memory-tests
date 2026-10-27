# 结果归集（服务器 → 编排机）设计

> 日期：2026-10-26 ｜ 状态：待评审 ｜ 对应功能：把被测服务器 `C:\memtest\results\` 的结果经 U盘搬运到编排机归集，独立目录、不混编。

## 背景与 Why

被测服务器（Hygon，隔离断网）在 Windows 内产出的结果（建档 `<批次>.csv`、服务器 `master_manifest.csv`、Prime95 `reports\<批次>-prime95-report.csv`、`work\<批次>\` 原始日志、带内评估 `assessment\*-cap-被测服务器.csv`、服务器 `cmdlog\`）都落在**服务器** `C:\memtest\results\`，不会自动出现在编排机。现在排查要两头跑、手动拷贝容易漏/放错位。本功能让"服务器一键打包 → U盘搬运 → 编排机一键导入归集"，导入到独立目录，一眼区分来源机器。

## Goals

- 服务器侧一条命令：把应归集的结果（建档、服务器 master_manifest、Prime95 报告/日志、带内评估、**cmdlog**）打包成一个 zip。
- 编排机侧一条命令：把 zip 导入 `results\imported\<机器名>\`（独立目录，不混编、不覆盖编排机自己的 results）。
- 防重复导入（按 zip 名判断，可 `-Force` 重导）；导入历史可查（`imported\import-log.csv`）。
- 全程 cmdlog 记录；打包产物也在 `results\` 内（`results\export\`），符合"所有输出都在 results"约定。

## Non-goals（明确不做）

- 不做跨机网络同步/直连（服务器隔离断网，物理搬运 U盘）。
- 不做 master_manifest 合并进编排机主表（不混编原则）。
- 不做自动汇总清单（import-log 记录导入历史即够，保持最小）。
- 不自动探测/挂载 BMC 虚拟介质（BMC USB redirect 是否可用是另立验证项；脚本形态不依赖介质，U盘/虚拟盘都适用）。

## 约束（Global Constraints）

- PowerShell 5.1（`#requires -Version 5.1`）；沿用项目脚本风格（cmdlog `Write-CmdLog`、默认路径 `<包根>\results`）。
- 打包用 `Compress-Archive`（结果量小，无大文件性能问题；PS5.1 兼容）。
- 脚本命名：`Export-ServerResults.ps1`（服务器侧）、`Import-ServerResults.ps1`（编排机侧）。
- 打包文件名：`<机器名>-results-YYYYMMDD.zip`（机器名默认 `srv01`，可 `-MachineName` 覆盖）。
- 导出产物放服务器 `results\export\`；导入目标编排机 `results\imported\<机器名>\`。
- **目录语义（用户定）：累积式**——每次导入直接并入 `imported\<机器名>\`，不清理；同名文件被新导入覆盖，旧批次独有文件保留。目录反映"所有搬运过的结果"，历史 zip 仍可查。
- `import-log.csv` 字段：`ImportTime,MachineName,ZipName,FileCount,SourceDir,Note`。
- 防重复：`imported\import-log.csv` 已含相同 `ZipName` → 提示跳过；`-Force` = 允许重导该 zip（重新解压、覆盖同名文件、保留独有），import-log 追加一行 `Note=重导`。**不做目录清空**（累积式）。
- **zip 顶层含 `_export-meta.txt`（用户定）**：导出侧写入（MachineName、ServerResultsDir、ExportTime、ToolVersion），导入侧读它填 import-log 的 `SourceDir`（meta 缺失时留空）。zip 顶层共 7 项：6 项结果 + meta。
- 机器名从 zip 文件名正则解析（`^(.+)-results-\d{8}\.zip$`），显式 `-MachineName` 优先。
- build.ps1：`$scriptFiles` 加两个新脚本；`$keyFiles` 不变（无新增二进制）。
- 文档：手册 20 加"结果归集"小节（流程 10）+ 输出速查表加 export/import 行；docs/01、02 不涉及（归集是运维工具，非测试项）。
- 打包纪律：改动后 `build.ps1 -Zip`（不 bump 或按需）重打包。
- 测试：`tests\test-results-import.ps1` 用临时目录验证 导出→导入→目录结构→防重复→import-log 字段。

## 设计细节

### Export-ServerResults.ps1（服务器侧）

```
param(
    [string]$MachineName = "srv01",   # 用于 zip 文件名
    [string]$ResultsDir = "",         # 默认 <包根>\results
    [string]$OutDir = ""              # 默认 <包根>\results\export
)
```

流程：
1. `Write-CmdLog -Script 'Export-ServerResults' -State Start`。
2. 校验 `ResultsDir` 存在；`OutDir` 不存在则创建。
3. 建 staging：`<OutDir>\staging\<机器名>-<日期>\`，把以下内容复制进去（**顶层结构保持**，zip 内顶层即这 6 项）：
   - `master_manifest.csv`（若存在）
   - 建档 `*.csv`（`ResultsDir` 根下的 `<批次>.csv`，模式 `*.csv` 排除 `master_manifest.csv`）
   - `reports\`（整个目录，含 Prime95 报告等）
   - `work\`（整个目录，含 Prime95 原始日志）
   - `assessment\`（整个目录，含带内部分）
   - `cmdlog\`（整个目录）
   - 排除：`export\`（导出产物自身，防递归）、`raw\`（编排机产物，服务器上通常没有；若存在也不打包——raw 是 SOL 抓取的，属编排机侧）、`imported\`（若存在）。
4. `Compress-Archive staging 内容 → <OutDir>\<机器名>-results-<日期>.zip`；成功后删除 staging。
5. 写 `_export-meta.txt` 到 staging 根（随 zip 顶层带走）：内容 `MachineName=<机器名>` / `ServerResultsDir=<服务器源目录>` / `ExportTime=<导出时间>` / `ToolVersion=<Get-AppVersion>`。
6. `Write-CmdLog -State End -Result "Exported <路径> (<N> 文件)" -ExitCode 0`；exit 0。失败路径 cmdlog End + exit 1（try/catch 兜底，补 cmdlog End——吸取 Run-Prime95Stress 教训）。

### Import-ServerResults.ps1（编排机侧）

```
param(
    [string]$ZipPath,                # 必填，U盘里的 zip
    [string]$MachineName = "",       # 缺省从 zip 文件名解析
    [switch]$Force                   # 重导（同 zip 已导入过时覆盖）
)
```

流程：
1. `Write-CmdLog -Script 'Import-ServerResults' -State Start`。
2. 校验 `ZipPath` 存在且以 `.zip` 结尾；解析机器名（正则或 `-MachineName`）。
3. 目标 `results\imported\<机器名>\`；读 `imported\import-log.csv`（不存在则新建）判断该 `ZipName` 是否已导入：
   - 已导入且无 `-Force` → 提示跳过，cmdlog End `Result='Skip: 已导入过 <ZipName>'`，exit 0。
   - 已导入且有 `-Force` → 重新解压该 zip（覆盖同名文件、保留旧批次独有文件），import-log 追加一行 `Note=重导`。
   - 未导入 → 正常导入（并入目录）。
4. `Expand-Archive -Force` 到 `imported\<机器名>\`（zip 顶层即那 7 项：6 项结果 + `_export-meta.txt`，直接并入，**不清理旧内容**）。
5. 读 `_export-meta.txt` 的 `ServerResultsDir` 填 import-log 的 `SourceDir`（meta 缺失时留空）；统计解压文件数；写 `imported\import-log.csv`（追加一行 `ImportTime,MachineName,ZipName,FileCount,SourceDir,Note`；Note=`首次导入/重导`）。
6. `Write-CmdLog -State End -Result "Imported <N> 文件 → <目标>" -ExitCode 0`；exit 0。失败路径同 export（try/catch + cmdlog End + exit 1）。

### 一眼区分的结构

```
编排机 C:\memtest\results\
├─ raw\ reports\ assessment\ cmdlog\ …   ← 编排机自己的产物
├─ master_manifest.csv
├─ export\                               ← （编排机若也导出，可选）
└─ imported\
    ├─ import-log.csv                    ← 导入历史
    └─ srv01\                            ← 服务器归集结果（含 master_manifest.csv / reports\ / work\ / assessment\ / cmdlog\ / 建档 csv）
```

## 验收

- 单元测试 `test-results-import.ps1`：临时目录里 构造假服务器 results（建档 csv、master_manifest、reports\、work\、cmdlog\）→ 跑 Export 逻辑（调用脚本函数化部分或直接 Invoke 脚本）→ 得到 zip（含 `_export-meta.txt`）→ 跑 Import → 断言：
  - `imported\srv01\` 结构与文件数正确、meta 文件随包导入；
  - import-log 字段（ImportTime/MachineName/ZipName/FileCount/SourceDir=meta 值/Note）；
  - 同 zip 二次导入跳过（无 -Force）；
  - `-Force` 重导：同名覆盖、独有保留、log 追加 `Note=重导`；
  - **累积**：先后导入两个不同 zip → 两批文件都在（旧批次独有文件不丢）。
- 手动冒烟（编排机本机即可，无需服务器）：`Export-ServerResults.ps1 -MachineName demo`（对本机 results 打包）→ 模拟 U盘拷贝到别处 → `Import-ServerResults.ps1 -ZipPath <zip>` → 看 `results\imported\demo\`。
- 打包校验：`build.ps1 -Zip` 后 zip 内含两个新脚本、hash 一致。

## 交付物

- 脚本：`scripts\Export-ServerResults.ps1`、`scripts\Import-ServerResults.ps1`
- 测试：`tests\test-results-import.ps1`
- 文档：手册 20 加"结果归集"小节 + 输出速查表；build.ps1 纳入
- 重新打包 v13（不 bump，功能增量）→ 交 U盘
