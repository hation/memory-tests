# tools 目录说明（外部工具）

## ipmitool.exe（SOL 抓取必需）

离线包**不预置** ipmitool.exe，原因：ipmitool 官方（SourceForge 已停更并迁移 Codeberg，Codeberg 不发布 Windows 二进制）只发源码，不提供 Windows 版；为保证安全，包内不放置来源不明的第三方 exe。

### 获取方式

1. **自动**：运行 `.\tools\Setup-Tools.ps1`（需要一次联网，脚本会校验下载文件是否为合法 PE 可执行文件）
2. **手动**（自动失败时）：
   - 你的服务器厂商工具：Dell iDRAC 工具、Supermicro SMCIPMITool 等，通常自带 ipmitool.exe 或等效 SOL 工具
   - 已安装 ipmitool 的 Windows 环境拷贝 `ipmitool.exe`
   - 注意：必须是 **Windows 编译版**，Linux 的 ipmitool 二进制无法在 Windows 运行

### 校验

获取后建议核对来源的 SHA256 校验和，并把文件放在本 `tools\` 目录。

### 使用

编排脚本默认在 PATH 中找 `ipmitool`，也可显式指定：

```powershell
.\scripts\Run-MemtestSuite.ps1 -BootMethod SOL -IpmiTool .\tools\ipmitool.exe -BmcHost <IP> ...
```

## 备选方案

如果拿不到 ipmitool.exe，可用服务器厂商自己的 SOL 客户端（racadm / SMCIPMITool / XCC CLI 等）手动开 SOL 会话把输出存成文件，再用编排脚本的 `-ParseOnly` 解析：

```powershell
.\scripts\Run-MemtestSuite.ps1 -ParseOnly -LogFile <手动存的 MTLOG 文件>
```
