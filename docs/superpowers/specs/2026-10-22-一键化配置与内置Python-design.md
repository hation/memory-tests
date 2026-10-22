# 2026-10-22 · 一键化改造：内置 Python + BMC 本机命令双格式（design）

> 状态：[当前有效]（2026-10-22）
> 触发：用户反馈文档命令需大量手拼参数（`<BMC_IP>`/`<密码>`/`python` 命令），以及 `check_env` 提示"Python3 未装"；用户要求"直接复制就能跑"。
> 参考：disk-tests 的 `deploy\bin\python\` 便携 Python 做法（gitignored、不提交 git）。
> 决策（2026-10-22 用户拍板）：BMC 部分**不做配置文件/不读文件**，采用「命令双格式」——每条命令保留原格式（通用占位符模板）+ 增加"本机版"（真实值 10.0.0.10 / root 已填好，直接可复制）。
> 涉及包版本：v9 → v10（build -Bump 递增）。

---

## 1. 意图与 Why

现有文档（05/08/15/12 等）中大量命令需要用户**手工拼接**：
- ipmitool 直连命令要替换 `<BMC_IP>`、`<密码>`（如 15 文档第 2 节整段）；
- 脚本命令要带一长串 `-BmcHost -BmcUser -BmcPass`；
- db 历史库命令要 `python db\db_import.py ...`，依赖目标机装没装 Python（`check_env` 因此报"Python3 未装（该功能跳过）"）。

用户诉求：**复制粘贴一条命令即可完成任务，少拼接、零前置**。

## 2. 目标 / 非目标 / 反目标

### 目标
1. 离线包内置便携 Python（照搬 disk-tests 做法），db 5 个 .py 脚本以 PowerShell 封装提供"一条命令"入口，且用包内 python 运行。
2. `check_env` 第 [6] 项检测包内 python → 显示"可用"，不再"跳过"。
3. **BMC 命令双格式**（用户拍板）：文档中每条带 `<BMC_IP>` 占位的命令，保留"原格式"（通用模板），并另加一行"本机版"——`-BmcHost 10.0.0.10 -BmcUser root` 已填好，复制即用。
4. **密码手动添加**：脚本在需要密码且 `-BmcPass` 为空时，交互提示输入（`Read-Host -AsSecureString`），不在命令行/文档中明文拼。
5. 新增 `Diag-Bmc.ps1` 一键诊断（本机版一条命令），15 文档手拼 ipmitool 命令序列替换为它。
6. 文档（05/08/12/15 + 根 README + kit README）命令全部改为"双格式：原格式 + 本机版"。

### 非目标
- 不改 17 项验收判定逻辑、不改四种引导方式机制、不改报表结构。
- 不改 ipmitool 本身（仅按需自动补 `-C 3` 兜底，已有）。
- **不做**配置文件读取（无 `bmc.csv`、无 `Get-BmcConfig`、无环境变量方案）。

### 反目标（做砸就算失败）
- 把 21MB python 二进制提交进 git 仓库（disk-tests 是 gitignored 的，我们也必须 gitignored）。
- 破坏 PowerShell 5.1 兼容 / 中文 BOM 约定 / `results\` 输出目录分离约定 / VERSION 单一来源。
- 文档只给占位符命令、不给本机可用版（否则"复制即用"目标失败）。

## 3. 约束

- Windows PowerShell 5.1，中文脚本必须 UTF-8 BOM。
- `$PSScriptRoot` 相对定位；包根 = `Split-Path -Parent $PSScriptRoot`（scripts 上一级）。
- 现有约定：`Get-AppVersion` 读 VERSION；`results\` 独立输出；build.ps1 单源构建 + `-Bump/-Zip` + CHECKSUM 前置校验；db 为可选功能（可剥离）。
- 复用 lib_common 已有 `Read-CsvManifest`（.NET TextFieldParser，保留行尾空字段）读 CSV。
- disk-tests 的 python 位置：本地 `disk-tests\deploy\bin\python\`（35 文件 / 21.5MB，gitignored）。

## 4. 方案细节（已确认）

### A. 内置 Python 并保证 db 脚本可跑

1. **存放位置**：`<包根>\tools\python\`（与 `tools\ipmitool\` 同级、逻辑一致，且**与 ipmitool 同机制：在 kit 内原地维护**）。
2. **来源与入库策略**（对齐 disk-tests）：
   - `memtest\tools\python\` 加入 `.gitignore`（python.exe 等二进制不入库）；实际位置在 kit 内，不落在 repo 根。
   - build.ps1 新增 `-PythonSrc <dir>` 参数；若 kit 内 `tools\python\python.exe` 缺失（如全新克隆本地无 python），缺省探测顺序：① `-PythonSrc` 指定 → ② 兄弟项目 `disk-tests\deploy\bin\python`。找到则拷入 kit；找不到则打警告（"未内置 Python，db 历史库将回退系统 python"），不阻断构建。
   - 打包前 kit 里存在 `tools\python\python.exe` 时，将其文件纳入 CHECKSUM。
   - check_env 第 [2] 项脚本清单与 build.ps1 `$scriptFiles` 存在性校验：把新增 `Diag-Bmc.ps1` 一并纳入。
3. **`Get-PythonExe`（lib_common 新增）**：
   - 解析顺序：`<包根>\tools\python\python.exe` → PATH 上 `python` → 返回 `$null`。
4. **db PowerShell 封装（新增 4 个）**，放 `db\` 下与 .py 同级（build 的 Sync-Dir 会自动带入）：
   - `db\Db-Import.ps1` / `db\Db-Query.ps1` / `db\Db-Export.ps1` / `db\Db-Merge.ps1`
   - 各自：`$py = Get-PythonExe`；缺失则报错"未找到 python（包内 tools\python 或系统 PATH）"并退出 1；否则 `& $py <同目录对应 .py> @args`，透传全部命令行参数。
   - 文档命令从 `python db\db_import.py ...` 变为 `.\db\Db-Import.ps1 <报告.csv> --machine rack01`（可复制）。
5. **check_env 第 [6] 项**：改用 `Get-PythonExe`；命中打印 `Python <版本>（内置 tools\python）`；未命中打印原"未装（该功能跳过）"并计警告（不 fail，保持可选定位）。

### B. BMC 命令双格式 + 密码手动添加（用户拍板，不做读文件）

1. **命令双格式规则**（贯穿 05/08/12/15 + 两个 README）：
   - 每条需要 BMC 参数的命令，一律并列给两行：
     - **原格式**（通用模板，占位符保留）：`-BmcHost <BMC_IP> -BmcUser <用户> -BmcPass <密码>`
     - **本机版**（真实值已填，复制即用）：`-BmcHost 10.0.0.10 -BmcUser root`（不写密码，运行中提示输入）
   - 本机版统一省略 `-BmcPass`，依靠下方第 2 条的"密码空时交互提示"，实现零拼接。
2. **密码空时交互提示（脚本小改）**：
   - `Check-ServerCapabilities.ps1`：进入带外探测（`$BmcHost` 非空）且 `$BmcPass` 为空时，`Read-Host "BMC 密码" -AsSecureString` 提示输入一次，转明文后仅内存持有（不落命令行、不落日志）。
   - `Run-MemtestSuite.ps1`：**精确触发条件** = `-BootMethod SOL` 且 `$BmcHost -ne ""` 且 `$BmcPass -eq ""` 且非 `-ParseOnly`；提示点放在初始化段、任何 BMC 调用（SOL 抓日志 / `-MonitorTemp` / `-RestartLoop`）之前统一完成一次。Serial/USB/EFI 与 `-ParseOnly` 路径不受影响（不误触发）。
   - `Run-ServerAssessment.ps1`：其传给探测脚本前，若 `$BmcPass` 为空也提示一次（避免子脚本二次提示）。
   - `Run-BatchScheduler.ps1`：清单行内存在 `BmcHost` 非空且 `BmcPass` 为空的行时，**调度启动时提示一次**并注入所有空密码行（无人值守批量不会每批弹窗）；也可在 CSV 里直接填密码绕过提示。
   - 显式传了 `-BmcPass` 则直接使用，不提示（行为不变，向后兼容）。
3. **`Diag-Bmc.ps1`（scripts/ 新增，进入离线包）**：
   - 参数：`-BmcHost -BmcUser -BmcPass`（原格式/本机版都可用）；密码空同样提示输入。
   - 输出全套诊断，每步标注 PASS/FAIL：
     1. `mc info`（默认套件）→ 失败自动 `-C 3` → 再失败 `-C 17`；
     2. `chassis status`（断电循环能力）；
     3. `sdr elist | Select-String 'degrees C'`（测温/ORT 前提）；
     4. `sol activate` 短探测（~6s，有输出即可用）。
   - 结尾按失败步骤给三大原因提示（加密套件/网络路径/账号密码，对应 15 文档 2.3）。
4. **文档替换（覆盖面）**：
   - 文档双格式覆盖：`05 使用手册 / 06 实践操作教程 / 08 报表结构 / 09 SOL使用指南 / 12 离线部署与SOL测试手册 / 13 服务器信息识别指南 / 15 BMC排查方案` + 根 `README.md` + `memtest\README.md`。其中 09/06/13 是评审发现的手拼命令重灾区（09 有整段裸 ipmitool 命令），一并纳入，否则"复制即用"落空。
   - 02/04/07：仅在出现直接命令处补"本机版"一行（轻量）。
   - 15 文档第 2 节"诊断命令序列"整段替换为「原格式 + 本机版」两行：`.\scripts\Diag-Bmc.ps1 -BmcHost 10.0.0.10 -BmcUser root`；第 4 节"快速验证清单"里的命令同样双格式。
   - 本机 IP/用户名（10.0.0.10/root）以醒目标签标出；既有示例 IP（如 192.168.1.10/admin）保留不动，仅作通用示例；每文档页首注明"本机：10.0.0.10 / root，换机器改这一处"。

## 5. 交付物清单（builder 实现范围）

| 类别 | 文件 |
| --- | --- |
| 新增脚本 | `scripts\Diag-Bmc.ps1`；`db\Db-Import.ps1`/`Db-Query.ps1`/`Db-Export.ps1`/`Db-Merge.ps1` |
| 修改脚本 | `scripts\lib_common.ps1`（+`Get-PythonExe`/+`Read-BmcPass`）；`scripts\Check-ServerCapabilities.ps1`（密码空提示）；`scripts\Run-MemtestSuite.ps1`（SOL 密码空提示，精确门控）；`scripts\Run-ServerAssessment.ps1`（透传前密码空提示）；`scripts\Run-BatchScheduler.ps1`（调度级单次密码提示+注入）；`scripts\check_env.ps1`（第[2]项加 Diag-Bmc、第[6]项用 Get-PythonExe）；`scripts\build.ps1`（+`-PythonSrc` + python 缺失补拷/校验 + `$scriptFiles` 加 Diag-Bmc） |
| 配置 | 无新增（不做 bmc.csv）；`.gitignore` 增加 `memtest/tools/python/` 忽略 |
| 文档 | `docs\05/06/08/09/12/13/15`（命令双格式 + Diag/密码提示/db 封装说明）、`docs\02/04/07`（仅出现命令处补本机版）、根 `README.md`、`memtest\README.md` |
| 运行时 | 本地拷入 `memtest\tools\python\`（从 disk-tests `deploy\bin\python` 复制，gitignored，不进 git） |
| 打包 | `build.ps1 -Bump -Zip` → v10，CHECKSUM 含（若内置）python 文件；提交推送 GitHub |

## 6. 留给 builder 自行决策（我的倾向，可微调）

- `Diag-Bmc.ps1` / 编排脚本密码提示的实现：倾向在 lib_common 放一个共用函数 `Read-BmcPass`（空则 `Read-Host -AsSecureString`），三处脚本复用，避免重复代码。
- 本机版命令的标注方式：倾向文档用「👉 本机版」前缀行 + 页首注明"本机 IP 10.0.0.10 / 用户 root，换机器改这一处"。
- db 封装脚本 `-Help`：倾向各打印一句用法即退，保持轻量。

## 7. 验收标准

- `.\scripts\check_env.ps1` 第 [6] 项显示 python 可用（内置），不再"跳过"。
- `.\db\Db-Import.ps1 --help` / 实际导入一条 `results` 报表成功（用包内 python，不依赖系统安装）。
- `.\scripts\Diag-Bmc.ps1 -BmcHost 10.0.0.10 -BmcUser root` 可运行，密码为空时提示输入，输出四步 PASS/FAIL 与原因提示；未连上时给出真实报错。
- `.\scripts\Run-ServerAssessment.ps1 -Local -BmcHost 10.0.0.10 -BmcUser root`（不带 -BmcPass）运行时提示输入密码，密码不落终端/日志。
- `Run-BatchScheduler.ps1`（清单含空 BmcPass 行）启动时单次提示密码并注入，全批不二次弹窗。
- 文档 05/06/08/09/12/13/15 + 两个 README 中所有 BMC 相关命令均含「原格式 + 本机版」两行。
- 上述新增/修改 ps1 + 既有 6 个编排/共享脚本 `Parser::ParseFile` 全部通过。
- `build.ps1 -Bump -Zip` 产出 `memtest-v10.zip`；`tools\python\` 在 zip 内；git 无 python 二进制。
