# ============================================================================
# Setup-Tools.ps1
# 一次性获取 ipmitool.exe（Windows 版）到本目录 tools\。
# 说明：ipmitool 官方（Codeberg/SourceForge）不发布 Windows 二进制，故离线包
#       不预置第三方 exe；本脚本从文档化来源尝试下载，并校验是否为合法 PE 文件。
#       获取后整个离线包即可完全离线运行。
#
# 用法：.\Setup-Tools.ps1          # 下载 ipmitool.exe 到本目录
#        .\Setup-Tools.ps1 -Force   # 覆盖已存在文件
# ============================================================================

param([switch]$Force)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$destDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$dest = Join-Path $destDir "ipmitool.exe"

if ((Test-Path $dest) -and -not $Force) {
    Write-Host "ipmitool.exe 已存在: $dest（加 -Force 覆盖）"
    exit 0
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 候选下载地址（按序尝试；部分可能失效，逐个跳过）
$candidates = @(
    # 1. Dell 官方 IPMI 工具（需登录，注释掉以免静默失败）
    # "https://www.dell.com/support/home/drivers/driversdetails?driverid=m63f3"
    # 2. 社区镜像（请自行核实来源与校验和）
)

if ($candidates.Count -eq 0) {
    Write-Host @"

无法自动确定 ipmitool.exe 的可靠下载地址（官方不发布 Windows 版）。
请手动获取 ipmitool.exe 后放入本目录（tools\）：

  方式 A（推荐）：从你的服务器厂商获取
    - Dell：Dell 官网 iDRAC 工具 / OpenManage 中的 ipmitool（需 Dell 账号）
    - Supermicro：SMCIPMITool（官方，含 SOL）
    - 浪潮/华硕等：BMC 工具包中通常自带 ipmitool.exe

  方式 B：从任一台装有 ipmitool 的 Linux 服务器拷贝
    - which ipmitool 找到路径（如 /usr/bin/ipmitool），拷贝到 Windows（Linux ELF 不可用！）
    - 需用 Windows 编译版，不能用 Linux 二进制

  方式 C：使用其他 Windows IPMI/SOL 客户端，并在编排脚本用 -IpmiTool <路径> 指定
    - 编排脚本支持：.\scripts\Run-MemtestSuite.ps1 -IpmiTool <你工具的路径>

获取后运行：
  .\Run-MemtestSuite.ps1 -BootMethod SOL -BmcHost ... -IpmiTool <ipmitool.exe 路径>
"@
    exit 1
}

$ok = $false
foreach ($url in $candidates) {
    Write-Host "尝试下载: $url"
    try {
        $tmp = Join-Path $env:TEMP ("ipmitool_" + [guid]::NewGuid().ToString("N") + ".exe")
        Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 120
        $bytes = [System.IO.File]::ReadAllBytes($tmp)
        # 校验：PE 文件以 MZ 开头，且大小合理
        if ($bytes.Length -gt 200000 -and $bytes[0] -eq 0x4D -and $bytes[1] -eq 0x5A) {
            Copy-Item $tmp $dest -Force
            Remove-Item $tmp -Force
            Write-Host "OK 已保存: $dest（$($bytes.Length) 字节）"
            $ok = $true
            break
        } else {
            Write-Warning "下载文件不是合法 PE 可执行文件，跳过该来源。"
            Remove-Item $tmp -Force
        }
    } catch {
        Write-Warning "下载失败: $($_.Exception.Message)"
    }
}

if (-not $ok) {
    Write-Host "所有候选源均失败，请按上面提示手动获取 ipmitool.exe 放入 tools\ 目录。"
    exit 1
}
