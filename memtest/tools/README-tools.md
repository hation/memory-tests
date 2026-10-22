# tools 目录说明

## ipmitool.exe（已内置，免联网）

离线包 **已内置 Windows 版 ipmitool**，位于 `tools\ipmitool\`，**无需任何下载或安装**：

```
tools\ipmitool\
├── ipmitool.exe          # 主程序（Cygwin 版 ipmitool 1.8.18）
├── cygwin1.dll           # 运行依赖 DLL（须与 exe 同目录）
├── cygcrypto-1.0.0.dll
└── cygz.dll
```

- 版本：`ipmitool 1.8.18`（`tools\ipmitool\ipmitool.exe -V` 验证）
- 来源：社区发布的 Windows 构建（ipmitool 官方仅发源码，不提供 Windows 二进制）
- SHA256（ipmitool.exe）：`2EF7D24E2E5CFD674AD1FCC694DEA6ED79A026C9F17D584DAA745A106F11EEC3`
- 版权：BSD-3-Clause（ipmitool 项目），随附 Cygwin 运行时 DLL（GPL 例外许可）

## 使用

编排脚本 `scripts\Run-MemtestSuite.ps1` 会自动发现本内置 ipmitool（`<包根>\tools\ipmitool\ipmitool.exe`），**开箱即用，无需加 PATH、无需 -IpmiTool 参数**。

如需显式指定也可：

```powershell
.\scripts\Run-MemtestSuite.ps1 -BootMethod SOL -IpmiTool .\tools\ipmitool\ipmitool.exe -BmcHost <IP> ...
```

> 注意：ipmitool.exe 依赖同目录的 3 个 DLL，请勿单独移动 exe；整个 `tools\ipmitool\` 文件夹保持完整。
