# 12 · 离线部署与 SOL 测试手册

> 本机 BMC：IP `10.0.0.10` / 用户名 `root`（密码运行中提示输入）；换机器只改这一处。
> 每条命令给两行：**原格式**（通用占位符）+ **本机版**（已填好，复制即用）。

> 状态：[当前有效]（2026-10-22）
> 变更记录：2026-10-22 创建
> 目标读者：机房现场操作员。目标场景：**无网环境**，拿离线包从零把服务器内存验收跑起来。
> 三块内容一条链路：**① 离线部署 → ② 验证服务器能测哪些 → ③ SOL 方式开测**。

---

## 一、离线部署

> 参考 disk-tests `deploy/0-离线部署说明.md`：**固定部署目录、拷贝即用、免安装免联网免依赖**，脚本用 `$PSScriptRoot` 相对定位，目录拷到哪都能跑（推荐固定 `C:\memtest\`）。

### 1.1 拷贝步骤（固定目录）

1. 将整个离线包（`memtest\`）拷贝到目标机，固定为：

   ```
   C:\memtest\
   ├── scripts\         7 个脚本（含 check_env 环境自检）
   ├── boot\            Memtest86+ v9 ISO（memtest.iso）+ EFI binaries
   ├── tools\ipmitool\  Windows 版 ipmitool 1.8.18（含依赖 DLL，已内置）
   ├── db\              SQLite 历史库（可选，需 Python 3）
   ├── conf\ / config\  配置文件与批次/预期清单模板
   ├── docs\            文档（01-13）
   ├── results\  结果目录（首次运行自动创建）
   └── VERSION / CHECKSUM.txt / README.md
   ```

   （U 盘 / 共享拷贝均可，务必整目录拷贝，别漏 `tools\ipmitool\`、`boot\`）

2. **完整性校验**：对照 `CHECKSUM.txt` 核对文件数量与 SHA256，抽查关键文件：
   ```powershell
   (Get-ChildItem C:\memtest -Recurse -File).Count      # 应与 CHECKSUM.txt 条目数一致
   (Get-FileHash C:\memtest\tools\ipmitool\ipmitool.exe -Algorithm SHA256).Hash
   ```

### 1.2 环境要求

| 项 | 要求 | 说明 |
| --- | --- | --- |
| 编排机 | Windows 10 / Server 2016+ | PowerShell 5.1 系统自带，**免装任何软件** |
| 环境变量 | **不需要配置** | 脚本 `$PSScriptRoot` 自动定位自身，工具均相对路径调用 |
| 网络 | 编排机可 ping 通服务器 BMC 管理 IP | 端口 623；无需互联网 |
| 被测服务器 | 带 BMC/IPMI + 内存槽 | SOL 通道前提 |

### 1.3 首次运行（一次性 + 每台机器）

```powershell
# ① 用【管理员身份】打开 PowerShell

# ② 放开脚本执行限制（只需设置一次，永久生效；以后新窗口不用再设）
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force

# ③ 进入工具目录
cd C:\memtest\scripts

# ④ 环境自检：首行"工具版本: vN"应与交付包版本一致；确认脚本/ipmitool/ISO 齐全
.\check_env.ps1

# ⑤ 预览一次（可选）：确认编排器参数
.\Run-MemtestSuite.ps1 -Help
```

> **版本核对**：`check_env.ps1` 首行 `工具版本: vN` 与交付 zip 的版本（如 `memtest-v5.zip`）**不一致 = 没拷到最新**，按 1.6 更新。

### 1.4 服务器一次性配置（详见 [09-SOL使用指南.md](09-SOL使用指南.md) 第 3 节）

1. **BMC 开启 SOL**（按厂商）：Dell iDRAC → Console/Media → Serial Over LAN；Supermicro → BIOS Console Redirection → COM2/SOL；浪潮/华硕类 AMI → 同理 Enable
2. **BIOS 串口重定向**：Enable + 波特率 **115200**（与 Memtest86+ `log=ttyS0,115200` 一致）
3. **引导介质**：BMC 虚拟介质挂载 `C:\memtest\boot\memtest.iso`（或 Rufus 写 U 盘）
4. **Secure Boot**：如引导失败，关闭 Secure Boot 或导入 Memtest86+ 证书

> 判据：配置正确后，`tools\ipmitool\ipmitool.exe ... sol activate` 能看到 BIOS 启动输出。

### 1.5 结果在哪

```
C:\memtest\results\
├── reports\<批次>-report.csv     # 单批逐根 pass/fail
├── master_manifest.csv           # 累计总表
├── assessment\<机名>-assessment.csv/.txt   # 能力评估
└── raw\<批次>.mtlog.txt          # 原始 MTLOG
```

### 1.6 如何确保已用上最新版（防"缓存"）

```powershell
# ① 确保没有脚本进程在跑（关掉相关 PowerShell 窗口）
# ② 删除旧 scripts（全量替换，不要单文件覆盖）
Remove-Item C:\memtest\scripts -Recurse -Force
# ③ 拷贝新离线包的 scripts 到 C:\memtest\
# ④ 新开管理员 PowerShell，自检并核对版本号
cd C:\memtest\scripts
.\check_env.ps1        # 首行"工具版本: vN"应与发布版本一致
```

> 版本不一致 = 没拷到最新；一致 = 已是最新。运行日志开头也会打印版本号。

### 1.7 常见问题

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 报"禁止运行脚本" | 执行策略限制 | 1.3 第②步 |
| check_env 版本与交付包不符 | 没拷到最新 | 1.6 更新流程 |
| 预览/识别看不到内存 | 脚本在错误目录运行 | 必须 `cd C:\memtest\scripts` |
| SOL 无输出 | BMC/BIOS 未配置 | 1.4 + 09 指南排查 |

---

## 二、验证服务器能测哪些（能力评估）

### 2.1 一键评估

```powershell
# ① 服务器本机（已进 Windows）：带内 + 带外合并
# 原格式（通用）
.\scripts\Run-ServerAssessment.ps1 -Local -BmcHost <BMC_IP> -BmcUser <账号> -BmcPass <密码> -MachineName srv01
# 👉 本机版（复制即用，密码运行中提示）
.\scripts\Run-ServerAssessment.ps1 -Local -BmcHost 10.0.0.10 -BmcUser root -MachineName srv01

# ② 编排机远程（服务器还没进系统时，先做带外部分）
# 原格式（通用）
.\scripts\Run-ServerAssessment.ps1 -BmcHost <BMC_IP> -BmcUser <账号> -BmcPass <密码>
# 👉 本机版（复制即用，密码运行中提示）
.\scripts\Run-ServerAssessment.ps1 -BmcHost 10.0.0.10 -BmcUser root
```

自动完成：带内 CIM（内存槽/ECC/类型/频率/CPU/SecureBoot）+ 带外 BMC/IPMI（SOL/断电循环/测温）→ 输出 17 项可行性 + 建议动作。

### 2.2 判读 17 项

| 判读 | 含义 | 行动 |
| --- | --- | --- |
| **可测** | 服务器侧直接能做 | 直接进入第三章 SOL 测试 |
| **条件** | 缺特定前提 | 补齐再测：如 ECC 平台、插满 ≥2 根 |
| **需补探测** | 没连 BMC 或没进系统 | 补 2.1 的另一步骤 |
| **外包** | 与服务器无关 | 项 6-9、11-14 送检（02 方案 L3） |

### 2.3 产物

`results\assessment\`：
- `srv01-assessment.csv` —— Item/Name/Status/建议动作
- `srv01-assessment.txt` —— 汇总 + 下一步 SOL 命令

### 2.4 常见情形

- **非 ECC 内存** → 项 4 自动判"不可行"，其余不受影响
- **只插了 1 根** → 项 16 判"条件"，插满 ≥2 根重测
- **无 BMC** → 项 5/10 不可行，SOL 通道无 → 改用 USB 方式（[10-Serial物理串口线使用指南](10-Serial物理串口线使用指南.md) / USB）

---

## 三、SOL 方式测试

### 3.1 前置确认

第一章配置完成 + 第二章评估确认 `SOL=True`、断电循环可用。

### 3.2 引导 Memtest86+（内置 ISO）

BMC 虚拟介质挂 `boot\memtest.iso`，引导参数加（关键，log 模式才会自动重启）：

```
log=ttyS0,115200 maxpasses=4
```

### 3.3 单批 SOL 全自动验收

```powershell
# 原格式（通用）
.\scripts\Run-MemtestSuite.ps1 -BatchName srv01-a1 -BootMethod SOL `
  -BmcHost <BMC_IP> -BmcUser <账号> -BmcPass <密码> -MaxPasses 4 -ConfirmSwitch
# 👉 本机版（复制即用，密码运行中提示）
.\scripts\Run-MemtestSuite.ps1 -BatchName srv01-a1 -BootMethod SOL `
  -BmcHost 10.0.0.10 -BmcUser root -MaxPasses 4 -ConfirmSwitch
# 可选：-MonitorEcc -MonitorTemp -RestartLoop 2
```

脚本自动完成：识别建档 → `ipmitool sol activate` 抓流 → 等 `ev=done` → 关会话 → 解析 → 汇总报告。

### 3.4 结果判读

| 信号 | 含义 |
| --- | --- |
| `ev=done passes=4 status=pass` | 4 轮全过 → **PASS** |
| `status=fail` / `ev=data` | 有错误 → 进入排查（单条单槽隔离） |
| 超时无 `ev=done` | 检查引导/链路（见 3.7） |

### 3.5 报告位置

```
results\
├── reports\srv01-a1-report.csv    # 单批逐根 pass/fail
├── master_manifest.csv            # 累计总表
└── raw\srv01-a1.mtlog.txt         # 原始 MTLOG
```

字段说明见 [08-报表结构说明.md](08-报表结构说明.md)。

### 3.6 批量（可选）

填好 `config\batches.csv` 后：

```powershell
.\scripts\Run-BatchScheduler.ps1 -ManifestCsv .\config\batches.csv -DryRun   # 先预览
.\scripts\Run-BatchScheduler.ps1 -ManifestCsv .\config\batches.csv -ContinueOnError
```

### 3.7 常见问题速查（详见 [09-SOL使用指南.md](09-SOL使用指南.md) 第 7 节）

| 现象 | 处理 |
| --- | --- |
| SOL 无输出 | BMC 没开 SOL / BIOS 没开重定向 / 没引导进 Memtest86+ |
| 乱码 | 波特率三处统一 115200 |
| 不自动重启 | 引导参数必须用 `log=` 模式（console 模式 maxpasses 不生效） |
| `sol activate` 报错 | 会话被占用 / BMC 账号权限不足（Operator/Admin） |

---

## 四、参考文档索引

- [04-运行环境与依赖安装说明.md](04-运行环境与依赖安装说明.md) —— 环境与依赖
- [07-离线部署检查清单.md](07-离线部署检查清单.md) —— 部署前勾选表
- [09-SOL使用指南.md](09-SOL使用指南.md) —— SOL 原理/配置/排查（最全）
- [10-Serial物理串口线使用指南.md](10-Serial物理串口线使用指南.md) —— 无网+无 BMC 兜底
- [06-实践操作教程.md](06-实践操作教程.md) —— 分步演练（含阶段 0.5 能力评估）
- [05-使用手册.md](05-使用手册.md) —— 脚本全参数
- [02-批量压力测试方案.md](02-批量压力测试方案.md) —— 17 项总纲与外包项
