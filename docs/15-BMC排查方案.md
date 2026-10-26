# 15 · BMC 连通与 SOL 排查方案

> 本机 BMC：IP `10.0.0.10` / 用户名 `root`（密码运行中提示输入）；换机器只改这一处。
> 每条命令给两行：**原格式**（通用占位符）+ **本机版**（已填好，复制即用）。

> 状态：[当前有效]（2026-10-22）
> 变更记录：2026-10-22 创建（依据服务器评估"需 BMC"实测问题沉淀）
> 适用：能力评估显示「需 BMC」、SOL 收不到日志、乱码、不自动重启等。
> 前置：内置 ipmitool 位于 `<包根>\tools\ipmitool\ipmitool.exe`。

---

## 1. 症状总览表（现象 → 最可能原因 → 处理）

| 症状 | 最可能原因 | 处理 |
| --- | --- | --- |
| 评估 5/10 显示「需 BMC」 | `mc info` 连不上 BMC | 见第 2 节（三大原因：套件/网络/账号） |
| SOL 收不到任何输出 | BMC 未开 SOL / 未引导进 Memtest86+ | 见第 3 节 |
| SOL 输出乱码 | 波特率三处不一致 | 统一 115200 |
| 跑完不自动重启/不停 | 引导参数没用 `log=` 模式 | `log=ttyS0,115200 maxpasses=4` |
| `sol activate` 报错 | 会话被占用 / 账号权限不足 | 关其他会话；权限提 Operator/Admin |

---

## 2. 「需 BMC」排查（连不上 BMC）

### 2.1 判断依据

评估脚本用 `ipmitool mc info` 判定 BMC 是否连通：
- **通了** → 才有资格判断断电/测温/SOL 单项 → 5/10 可测或条件
- **没通** → 直接判「需 BMC」（5 和 10 一起挂，就是这个信号）

> 你的 5 和 10 同时「需 BMC」= `mc info` 没通，**与账号是否管理员无关**。

### 2.2 诊断命令序列（一键跑，看真实输出）

```powershell
# 原格式（通用）
.\scripts\Diag-Bmc.ps1 -BmcHost <BMC_IP> -BmcUser <用户>
# 👉 本机版（复制即用，密码运行中提示）
.\scripts\Diag-Bmc.ps1 -BmcHost 10.0.0.10 -BmcUser root
```

> Diag-Bmc 四步：① `mc info`（加密套件自动回退 -C 3/-C 17）② `chassis status`（断电循环能力）③ `sdr elist`（温度传感器）④ `sol activate`（短探测）。任一步失败对照 §2.3 三大原因排查。

### 2.3 三大原因对照表

| # | 原因 | 报错特征 | 解决 |
| --- | --- | --- | --- |
| 1 | **加密套件不匹配**（最常见） | `Unable to get...` / `Authentication type ... not supported` | 加 `-C 3`（或 `-C 17`） |
| 2 | **网络路径不对** | `Unable to connect` / 卡住超时 | 改到**编排机**（连管理网）跑，别在服务器本机跑带外；确认 BMC IP 与网段 |
| 3 | **账号/密码错误** | `Invalid password` / `Unauthorized name` | BMC 界面确认密码；试 `-a` 交互输入 |

> 补充（能力评估/一键评估）：已自动按 BMC 可达性分类角色——`Could not open socket` / `Unable to connect` 会判为**被测服务器**角色，并提示换到**编排机**（管理网）跑带外；凭据失败单独标为 **"条件: BMC 可达但凭据/权限失败"**。

### 2.4 判断流程

```
跑 Diag-Bmc 四步（① mc info 有输出即 BMC 通）
  ├─ 是 → BMC 通了 → 看 ②③④：
  │      ├─ ② 通过 → item 10 转「可测」
  │      ├─ ③ 通过 → item 5 转「可测」
  │      └─ 单项仍失败 → 查 BMC 对应功能是否启用（SOL 见第 3 节）
  └─ 否 → 按 2.3 三大原因逐个排查
```

---

## 3. SOL 排查

### 3.1 前置三件套（缺一不可）

1. **BMC 开启 SOL**：Dell iDRAC → Console/Media → Serial Over LAN = Enable；Supermicro/AMI → BIOS Console Redirection → COM2/SOL = Enable
2. **BIOS 串口重定向**：Enable + 波特率 **115200**（与 Memtest86+ `log=ttyS0,115200` 一致）
3. **引导参数用 `log=` 模式**：`log=ttyS0,115200 maxpasses=4`（console 模式下 `maxpasses` 不生效，不会自动停）

### 3.2 现象-处理表

| 现象 | 处理 |
| --- | --- |
| 无任何输出 | 查 3.1 第 1/2 项；确认已引导进 Memtest86+（虚拟介质挂载是否正确） |
| 乱码 | 三处波特率统一 115200 |
| 有输出但不自动重启 | 确认引导参数含 `log=` + `maxpasses=4` |
| `sol activate` 报 "session already active" | 有残留 SOL 会话：`sol deactivate` 或重启 BMC |
| `sol activate` 报权限错误 | BMC 账号需 Operator/Admin |

---

## 4. 快速验证清单（排查用）

```powershell
# 原格式（通用）
.\scripts\Diag-Bmc.ps1 -BmcHost <BMC_IP> -BmcUser <用户>
# 👉 本机版（复制即用，密码运行中提示）
.\scripts\Diag-Bmc.ps1 -BmcHost 10.0.0.10 -BmcUser root
```

- [ ] Diag-Bmc ① `mc info` 有输出（必要时自动 `-C 3`）
- [ ] ② `chassis status` 有输出（item 10 前提）
- [ ] ③ `sdr elist` 含 `degrees C` 条目（item 5 前提）
- [ ] ④ `sol activate` 能看到 BIOS 启动输出
- [ ] 重跑评估：`.\scripts\Run-ServerAssessment.ps1 -Local -BmcHost <BMC_IP> -BmcUser root -BmcPass <密码>` → 5/10 转「可测」
  - 👉 本机版：`.\scripts\Run-ServerAssessment.ps1 -Local -BmcHost 10.0.0.10 -BmcUser root`（密码运行中提示）

---

## 5. 关联文档

- [09-SOL使用指南.md](09-SOL使用指南.md) —— SOL 原理/配置/流程/排查（详版）
- [14-术语解释.md](14-术语解释.md) —— BMC/IPMI/SOL/带内带外 术语
- [12-离线部署与SOL测试手册.md](12-离线部署与SOL测试手册.md) —— 部署三步走
