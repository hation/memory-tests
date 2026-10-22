# Memtest86+ Serial 物理串口线方式使用指南（Windows 编排器）

> 状态：[当前有效]（2026-10-22）
> 变更记录：2026-10-22 文档体系编号化（对齐 disk-tests）；工程基建优化更新

> 适用：**服务器完全不能联网、但想要无人值守全自动**的场景。用一根物理串口线（null-modem 交叉线）把服务器 COM 口连到 Windows 编排机，Memtest86+ 把机器可解析日志（MTLOG）打到串口，脚本自动读、自动汇总。零按键、零网络。
> 对应脚本：[Run-MemtestSuite.ps1](computer://c:\Users\ganxin01\Documents\trae-work\memory-tests\scripts\Run-MemtestSuite.ps1) 的 `-BootMethod Serial`。

---

## 1. 原理与适用场景

```
Memtest86+（服务器，UEFI 引导）
   │ log=ttyS0,115200 → 物理串口（COM）
   ▼
服务器 DB9 COM 口（BIOS 串口重定向）
   ▼
null-modem 交叉串口线
   ▼
Windows 编排机 COM 口（-SerialPort COMx）
   │ [System.IO.Ports.SerialPort] 读流 → 写文件
   ▼
解析 MTLOG → 汇总 master_manifest.csv
```

- **完全离线**：整条链路走物理串口线，不碰任何网络
- **零按键、全自动**：`log=` 模式下 `maxpasses=N` 跑完自动重启回系统，脚本全程无人工干预
- **vs SOL**：SOL 需要 BMC 管理网；Serial 只需一根线，适合"机房一点网都不通"的极端环境
- **代价**：每台服务器要拉一根串口线到编排机，多台并行时线多

---

## 2. 前置条件清单

| # | 条件 | 说明 |
| --- | --- | --- |
| 1 | 服务器有物理串口（DB9 或板载 COM 头） | 部分服务器无 DB9，需主板 COM 排针 + 转接线 |
| 2 | BIOS 开启串口重定向到该 COM | Advanced → Serial Port Console Redirection → Enable，端口、波特率 115200 |
| 3 | **null-modem（交叉）串口线** | Tx/Rx 交叉 + 共地；直通线不行 |
| 4 | Windows 编排机有 COM 口 | 笔记本通常需 USB-RS232 转接头，装好驱动 |
| 5 | 波特率三处统一 115200 | BIOS 重定向、Memtest86+ `log=ttyS0,115200`、脚本 `-BaudRate` |
| 6 | 引导 Memtest86+ 的方式 | 仍需 U 盘 / EFI 引导（Serial 只是取日志通道，见第 4 节） |

---

## 3. 接线与配置

### 3.1 接线（关键，错在物理层最隐蔽）

1. **必须用 null-modem 交叉线**：一方 Tx 接另一方 Rx，两线互换，GND 直连。判断方法：把线两端 DB9 对看，第 2 脚连到另一头第 3 脚（Tx↔Rx 交叉）就是交叉线
2. 服务器 DB9（或板载 COM 头经转接）→ 交叉线 → Windows 侧（DB9 或 USB-RS232 转接头）
3. Windows 设备管理器确认端口号：**端口 (COM 和 LPT)** 下看到 COM3 等；USB 转接头插拔后端口号可能变化

### 3.2 BIOS 串口重定向

1. BIOS → Advanced → Serial Port Console Redirection
2. **Enable Console Redirection**（选服务器接线的那个 COM）
3. 波特率 **115200**，数据位 8、停止位 1、无校验
4. 保存退出

> 提示：服务器侧 Memtest86+ 的 `ttyS0` 通常对应 BIOS 里开的第一个/重定向的那个串口；如果没输出，试着把重定向换到另一个 COM 或核对 BIOS 的 COM 编号。

### 3.3 确认链路通（手动）

Windows 侧用 PuTTY 开串口会话（Serial，端口 COMx，波特率 115200，8N1），或脚本开抓后看是否有 BIOS 自检/MTLOG 输出。看不到输出优先查：线交叉没、端口号对不对、BIOS 重定向开没开。

---

## 4. 引导 Memtest86+（Serial 需要配合引导方式）

Serial 只是取日志通道，**引导仍需 U 盘或 EFI**：

| 引导方式 | 做法 |
| --- | --- |
| U 盘 | 插引导 U 盘引导进 Memtest86+（人工插一次） |
| EFI 一次性引导 | 编排器 `-BootMethod EFI` 建一次性启动项，重启进 Memtest86+，日志走串口抓 |

**引导参数（U 盘引导配置里加，或 EFI 参数里加）**：
```
console=ttyS0,115200 log=ttyS0,115200 maxpasses=4
```
- `log=` 输出 MTLOG 到串口（与 `console=` 互斥，log 优先）
- `maxpasses=4` 跑完 4 轮输出 `ev=done` 自动重启（**必须 log 模式才生效**）
- `testlist=0,1,2,3` 可选

---

## 5. 使用流程（编排器全自动）

### 5.1 命令行

```powershell
# 标准 Serial 全自动验收（4 轮）
.\scripts\Run-MemtestSuite.ps1 -BatchName batch01 -BootMethod Serial `
  -SerialPort COM3 -BaudRate 115200 -MaxPasses 4

# 更明确的串口 + 校验
.\scripts\Run-MemtestSuite.ps1 -BatchName batch01 -BootMethod Serial `
  -SerialPort COM3 -BaudRate 115200 -MaxPasses 4 -ExpectedCsv expected.csv
```

### 5.2 脚本自动做的事

| 步骤 | 说明 |
| --- | --- |
| ① 识别建档 | 读当前槽位内存 → 批次清单 CSV |
| ② 打开串口 | `[System.IO.Ports.SerialPort]` 打开 COMx @ 115200 |
| ③ 读流写文件 | 逐行读 MTLOG 写入 raw 日志 |
| ④ 等待完成 | 读到 `ev=done` 停止（Memtest86+ 自动重启） |
| ⑤ 关闭串口 | 释放 COM 口 |
| ⑥ 解析汇总 | MTLOG → PASS/FAIL → 合并 `master_manifest.csv` |

> 脚本读串口用 3 秒读超时轮询，长时间无数据不报错，直到超时上限（默认 `MaxPasses×90+30` 分钟）才告警。

---

## 6. 结果判读

与 SOL 完全一致（同一套 MTLOG 解析器）：

| 信号 | 含义 |
| --- | --- |
| `ev=start` | Memtest86+ 启动，串口链路通 |
| `ev=pass_end ... status=pass` | 每轮通过 |
| `ev=done passes=4 status=pass` | 4 轮全过 → PASS |
| `ev=data addr=... expect=... actual=...` | 错误明细 |
| 一直无 `ev=done`（超时） | 见第 7 节 |

---

## 7. 常见问题排查

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 串口完全无输出 | 线没交叉 / COM 口错 / BIOS 重定向没开 / 没引导进 Memtest86+ | 换 null-modem 交叉线；核对设备管理器端口号；查 BIOS 重定向；确认引导介质参数带 `log=` |
| 乱码 | 波特率不一致 | 三处统一 115200（BIOS、Memtest86+ `log=ttyS0,115200`、脚本 `-BaudRate`） |
| 有输出但不是 MTLOG | 引导参数只配了 `console=` | 改用 `log=ttyS0,115200` |
| 编排器报"端口被占用" | COM 被其他程序（PuTTY/串口助手）占用 | 关掉占用程序，或换端口号 |
| 收不到 `ev=done`、不自动重启 | console 模式 `maxpasses` 不生效 | 必须 `log=` 模式 |
| USB-RS232 转接头不稳定 | 劣质转接芯片丢数据 | 换 FTDI/CP2102 芯片的转接头 |

---

## 8. 三种方式怎么选（总览）

| | USB | SOL | **Serial（物理线）** |
|---|---|---|---|
| 需要网络 | 否 | 需 BMC 管理网 | **否，完全离线** |
| 人工干预 | 半自动（插拔+按键） | 全自动 | **全自动零按键** |
| 无人值守 | 否 | 是 | **是** |
| 设备成本 | U 盘 | BMC（服务器自带） | **一根串口线（几十元）** |
| 批量 1000 根 | 累 | **最合适** | 线多时管理麻烦 |
| 无网 + 无人值守 | 不行 | 不行 | **唯一选择** |

---

## 参考来源

- Memtest86+ 引导参数说明（`log=` / `console=` / `maxpasses=` / `testlist=`）：<https://memtest.org/readme>
- Memtest86+ 串口控制台/日志支持（README 串口章节）：<https://memtest.org/readme>
