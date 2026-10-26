# 服务器能力评估 · 角色自动识别 + 断电循环真实验证 — 设计文档

日期：2026-10-26
状态：设计（待评审）

## 1. 背景与目标

现状（已确认事实）：

- 被测服务器本机到 BMC 管理网**不通**（服务器离线，无网络路径）；编排机在管理网，**可达** BMC。
- 因此 17 项评估里：带内项（1,2,3,4,15,16）只能**服务器本机**测（CIM）；带外项（5,10）只能**编排机**测（IPMI）。
- 现有 `Check-ServerCapabilities.ps1` 对断电循环只做只读探测（`chassis status` 能返回即判"命令可用"），从不真发 `chassis power cycle`，用户测完还得**单独手动实测一次**确认服务器真重启。
- 文档示例的评估命令缺 `-BmcHost`，导致带外探测整段跳过、第 10 项恒显示"需 BMC"。
- 现有脚本把"BMC 连不上"与"服务器不支持"混为一谈，误导判断。

目标：

1. **统一入口**：`Run-ServerAssessment.ps1` 一条命令，先自动判定本机角色（编排机 / 被测服务器），再只跑该角色对应的检查，产出带角色标记的 cap CSV。
2. **断电循环真实验证**：编排机模式加 `-VerifyPowerCycle` 开关，真发一次 `chassis power cycle` 并自动确认重启成功，消除人工实测环节。
3. **两段合并**：服务器 cap + 编排机 cap 合并成完整 17 项支持矩阵（每项取更决定性状态）。
4. **失败三态化**：BMC 不可达 / 凭据或权限失败 / 命令不支持，明确区分，不再与"不支持"混淆。
5. **文档修正**：评估示例改为"两台机器各跑一次 + 合并"写法。

## 2. 需求（用户已确认）

1. 角色判据 = **能否与 BMC 建立 IPMI 会话**（不是"能否上网"）：能连上 → 编排机（只跑带外）；连不上（网络不可达）→ 被测服务器（只跑带内）；未提供 `-BmcHost` → 按被测服务器处理。
2. 假设成立：被测服务器一定到不了 BMC、编排机一定能到，判定不会误判。
3. 真实验证开关控制（`-VerifyPowerCycle`），默认不重启服务器。
4. 合并独立成一步（服务器 CSV + 编排机 CSV → 完整报告）。

## 3. 设计决策

### 3.1 角色判定（核心新增逻辑）

新增共享函数 `Test-BmcRole`（放 `lib_common.ps1`）：

```
输入：IpmiTool, 基础 IPMI 参数（-I lanplus -H <ip> -U <u> -P <p>）
过程：依次尝试 mc info（默认套件 → -C 3 → -C 17），同现有 Diag-Bmc 逻辑
判定（按优先级）：
  1) 任一尝试 Code=0 且有输出       → Role = Orchestrator，返回生效的 -C 参数供后续复用
  2) 错误文本命中连接级特征
     （Could not open socket / Unable to connect / Connection refused /
       Network is unreachable / Timed out / timeout / No route）
                                   → Role = Server，Detail = "BMC 不可达: <原因>"
  3) 错误文本命中凭据/权限特征
     （Invalid password / Unauthorized / Authentication type ... not supported /
       Unable to establish / Insufficient privilege / RAKP）
                                   → Role = AuthError，Detail = "BMC 可达但凭据/权限失败: <原因>"
  4) 其它失败                       → Role = Server（保守兜底），Detail = 原始错误
输出：[PSCustomObject]@{ Role; Detail; CipherArgs }
```

角色与执行的对应：

| Role | 执行内容 | 带内项(1,2,3,4,15,16) | 带外项(5,10) |
|---|---|---|---|
| Orchestrator | 只跑带外 IPMI | "需带内(服务器本机跑)" | 正常探测 |
| Server | 只跑带内 CIM | 正常探测 | "需编排机(BMC 不可达/未提供 -BmcHost)" |
| AuthError | 只跑带外（全部会失败） | "需带内(服务器本机跑)" | "BMC 可达但凭据/权限失败，无法判定" |

执行规则（评审决议，见 §8）：
- **带内跑**当且仅当：`-Local` 显式给出，或角色判为 Server（含未提供 `-BmcHost` 的默认服务器角色）。
- **带外跑**当且仅当：`-BmcHost` 给出，且角色 ∈ {Orchestrator, AuthError}（AuthError 时探测会失败但如实报告凭据问题）。
- Role 列取值 = 角色分类结果（`编排机` / `被测服务器`），与是否额外跑带内无关（`-Local -BmcHost` 在编排机上是"编排机角色 + 显式带内"，Role 仍记 `编排机`）。
- 仅 `-BmcHost`（不带 `-Local`）跑在编排机上：只跑带外，带内项标"需带内(服务器本机跑)"——CIM 读编排机自身硬件无意义，不跑。
- 仅 `-BmcHost` 跑在到不了 BMC 的机器上（角色=Server）：跑带内（读本机 CIM），并输出防护提示"若本机实为编排机且 BMC 应可达，请检查网络路径"。按用户环境假设此场景不发生。
- 密码提示时机：`-BmcHost` 给出且未提供密码时，在角色判定前提示一次（同现状）。服务器侧推荐**不带 `-BmcHost` 运行**（纯带内、免密码提示）；带上也不影响判定。

### 3.2 断电循环真实验证（编排机模式，`-VerifyPowerCycle`）

在 `chassis status` 可用（命令级 OK）之后、`-VerifyPowerCycle` 置位时执行：

```
1) chassis power status        取基线
2) 若基线为 off（服务器当前关机）→ 中止验证，不发 power cycle
3) chassis power cycle         检查退出码与输出含 "Cycle"
4) 轮询 chassis power status   每 1s 一次，窗口 30s，早退条件：观察到 off→on 跳变
5) 收尾 chassis power status   确认 BMC 仍响应且为 on
```

结果映射到第 10 项状态：

- 基线为 off → `条件: 服务器当前关机，无法验证断电循环（请先开机）`（不发 power cycle，避免意外开机/歧义；评审决议）
- 观察到 off→on 跳变 → `可测(已验证：实测断电重启成功)`
- 命令失败 → `条件: BMC 通但断电循环命令不可用(<原因>)`
- 未观察到跳变但 BMC 正常 → `可测(命令已接受，未观察到掉电跳变，断电窗口极短，建议人工确认一次)`（诚实兜底，罕见场景）
- 未置位开关 → `可测(命令可用，未实测)`（保持只读）

安全性：`-VerifyPowerCycle` 本身即明确授权，脚本不再二次确认（符合"不要单独确认"诉求）。文档显著标注其会真重启被测服务器。

### 3.3 两段合并

`Run-ServerAssessment.ps1` 新增合并模式：

```
Run-ServerAssessment.ps1 -MergeInband <服务器cap.csv> -MergeOob <编排机cap.csv> -MachineName srv01
```

- 两个参数必须成对给；只给一个报错退出。
- 输入校验（评审决议）：两文件必须存在、可读、含 `Item/Name/Status` 三列；若含 `Role` 列且与预期不符（Inband 非"被测服务器"、Oob 非"编排机"），**警告**而非失败（防传反；警告文案示例：`警告：-MergeInband 文件 Role=编排机，确认未传反？`）；无 `Role` 列的旧版 CSV 照常接受（优先级合并不依赖 Role 列，向后兼容）。
- 每项取两段中"更决定性"状态，优先级：`已验证/可测* (3) > 外包/条件* (2) > 需* (1) > 其它 (0)`；同优先级取非空、再取 A（A=服务器 CSV）。
  - 外包特例：两段均为"外包"，直接取"外包"。
  - 关键效果：编排机侧的具体结论（`条件*`/`可测*`）压过服务器侧笼统的"需编排机"，合并后第 10 项不会丢决定性信息。
- 合并结果复用现有 Get-Recommendation / 汇总统计 / assessment CSV+TXT 输出逻辑。
- 合并模式不调用探测脚本、不写 cap CSV。

### 3.4 三态化归因

所有状态文案遵守前缀约定（`可测*` / `条件*` / `需*` / `外包*`），保证汇总统计与合并优先级直接可用（评审决议：凭据/命令不可用类结论统一归入 `条件*` 前缀）：

| 场景 | 第 5/10 项状态文案 |
|---|---|
| BMC 不可达（网络/路径） | `需编排机(BMC 不可达: <原因>)` |
| BMC 可达但凭据/权限失败 | `条件: BMC 可达但凭据/权限失败(<原因>)` |
| BMC 通但电源/温度命令不可用 | `条件: BMC 通但断电循环命令不可用(<原因>)`（或对应测温项） |
| 正常 | `可测(...)` |

控制台首行输出角色：`角色: 编排机(BMC <ip> 可达)` / `角色: 被测服务器(BMC 不可达/未提供 -BmcHost)`。

### 3.5 输出与 CSV 兼容

- cap CSV 增加 `Role` 列（`编排机` / `被测服务器`，取值=角色分类结果，见 §3.1）；`Item/Name/Status` 三列保持原样，兼容合并与既有消费方。合并模式不产出 cap CSV。
- 状态文案遵守前缀约定（`可测*` / `条件*` / `需*` / `外包*`），保证 Run-ServerAssessment 统计与合并优先级可用（§3.4）。
- 指令记录（Write-CmdLog）沿用；`-VerifyPowerCycle` 属布尔开关无敏感信息。

## 4. 文件改动清单

| 文件 | 改动 |
|---|---|
| `scripts/lib_common.ps1` | 新增 `Test-BmcRole`（角色判定 + 三态归因 + 生效套件返回） |
| `scripts/Check-ServerCapabilities.ps1` | ① 用 `Test-BmcRole` 重写入口：角色先行，按角色执行对应探测块；② 新增 `-VerifyPowerCycle` 与 `Confirm-PowerCycle` 验证逻辑；③ 第 5/10 项状态按三态化文案输出；④ 输出首行角色；⑤ cap CSV 加 Role 列；⑥ 头注释更新用法 |
| `scripts/Run-ServerAssessment.ps1` | ① 透传 `-VerifyPowerCycle`；② 新增 `-MergeInband/-MergeOob` 合并模式（含优先级合并 + 复用推荐/统计逻辑）；③ 汇总文本标注角色与合并来源；④ 头注释更新 |
| `tests/fixtures/fake-ipmitool.cmd` | 支持通过环境变量 `FAKE_IPMI_MODE` 模拟：`ok`（默认，全命令成功）/ `unreachable`（连接级失败）/ `auth`（凭据失败）/ `verify-transition`（power status 先 off 后 on）/ `verify-flat`（恒 on）；按子命令（mc/chassis/sdr/sol）分支输出 |
| `tests/test-assessment-role.ps1`（新增） | 用例：① 角色判定三态（ok→编排机 / unreachable→服务器 / auth→凭据失败）；② `-VerifyPowerCycle` 验证（transition→已验证 / flat→未观察跳变）；③ 合并优先级（带内项取服务器、带外项取编排机） |
| `tests/test-gating.ps1` | 用例 3（Check-ServerCapabilities 管道密码）适配：默认 fake 模式 `ok` 下输出仍含 BMC 主机、无明文密码，断言保持不变即可通过；如需，补断言角色行 |
| `docs/19-测试项执行清单.md` | ③ 能力评估步骤改为统一入口：服务器不带 `-BmcHost` 跑 + 编排机带 `-BmcHost`（可加 `-VerifyPowerCycle`）跑 + 合并命令 |
| `docs/20-纯命令行压测手册.md` | 流程 5 第一步"先实测一次 power cycle"改为：用 `-VerifyPowerCycle` 自动验证（已验证可跳过人工确认） |
| `docs/15-BMC排查方案.md` | 三大原因表后补一句：能力评估已自动按 BMC 可达性分类角色，`Could not open socket` 会判为服务器角色并提示换编排机 |
| 脚本头注释（Check-ServerCapabilities / Run-ServerAssessment） | 用法与示例同步更新 |

不改动：`Diag-Bmc.ps1`（四步诊断 + 三原因表已覆盖归因）、`Run-MemtestSuite.ps1` 及其 `RESTART_LOOP` 循环逻辑。

## 5. 兼容性与假设

- 向后兼容：`-Local` 单独用（纯带内）、`-BmcHost` 单独用（原只跑带外，现多一步角色判定；编排机场景结果不变）、`-Local -BmcHost`（双通道，Role 记分类结果）均保留，行为见 §3.1 执行规则。
- 已知假设（用户确认）：被测服务器到不了 BMC、编排机能到；BMC 可达性为角色判据。
- 边界：某台机器既能到 BMC 又是被测机 OS 时，按规则判为编排机、只跑带外——用户环境中不发生，文档标注此假设。
- 真实验证开关不触发时，行为与现状只读探测一致（除文案更明确外）。

## 6. 测试策略

- 全部用 `fake-ipmitool.cmd` 模拟，不碰真实 BMC；沿用 tests 现有 `Assert` + `Start-Process -RedirectStandard*` 约定。
- fake-ipmitool.cmd 通过环境变量 `FAKE_IPMI_MODE` 分支（评审决议新增 `verify-off`）：`ok` / `unreachable` / `auth` / `verify-transition` / `verify-flat` / `verify-off`。
- 新增 `tests/test-assessment-role.ps1` 用例：① 角色判定三态（ok→编排机 / unreachable→服务器 / auth→凭据失败）；② `-VerifyPowerCycle` 验证（transition→已验证 / flat→未观察跳变 / off→关机中止）；③ 合并优先级（带内项取服务器、带外项取编排机）+ 合并 Role 传反警告 + 旧版无 Role 列 CSV 兼容。
- `tests/test-gating.ps1` 用例 3 适配：默认 fake 模式 `ok` 下输出仍含 BMC 主机、无明文密码；如需要补断言角色行。
- 运行：`powershell -NoProfile -File tests\test-assessment-role.ps1` 与 `tests\test-gating.ps1`。
- 交付纪律（AGENTS.md）：改动后 `scripts\build.ps1 -Zip` 重新打包，校验 zip 时间戳与包内 hash。

## 7. 不在本次范围

- `Diag-Bmc.ps1`、`Run-MemtestSuite.ps1`、`RESTART_LOOP` 循环、历史库 db/。
- 真实验证不做 SOL 证据关联（当前以电源状态跳变为主判据；SOL 探测仍按原样输出可用性）。

## 8. 评审决议（builder-check 四个问题的拍板）

1. **三态文案前缀**：凭据/权限失败、命令不可用类结论统一归入 `条件*` 前缀（`条件: BMC 可达但凭据/权限失败(...)`、`条件: BMC 通但断电循环命令不可用(...)`），保证统计与合并优先级（条件=2 > 需=1）正确，编排机侧具体结论压过服务器侧"需编排机"。
2. **合并输入校验**：校验文件存在/可读/三列齐全；`Role` 列与预期不符仅**警告**（防传反）不失败；无 Role 列旧版 CSV 接受（向后兼容）。
3. **验证基线 off**：基线电源状态为 off 时中止验证、不发 `power cycle`，第 10 项输出 `条件: 服务器当前关机，无法验证断电循环（请先开机）`。
4. **`-Local` 与角色执行规则**：带内跑 ⇔ `-Local` 给出或角色=Server；带外跑 ⇔ `-BmcHost` 给出且角色∈{Orchestrator,AuthError}；Role 列取值=角色分类结果（与是否额外跑带内无关）。
