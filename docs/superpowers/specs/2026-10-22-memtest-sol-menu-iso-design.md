# Memtest SOL 菜单引导 ISO 工具 — 设计规格

> 状态：[当前有效]（2026-10-22；2026-10-22 集成验证修正：El Torito EFI 引导项、GRUB 2.06、冒烟判据）
> 关联：`docs/09-SOL使用指南.md`、`docs/10-Serial物理串口线使用指南.md`、`memtest/boot/memtest.iso`

---

## 1. 意图与 Why

现状：SOL 全自动验收依赖引导参数 `log=ttyS0,115200 maxpasses=4`。但当前内置的
`memtest/boot/memtest.iso` 是 Memtest86+ v9.00 官方 ISO，参数**必须由引导加载器
在内核命令行传入**（官方 readme 明确：`log=`/`maxpasses=` 只能通过引导加载器
GRUB/syslinux 传入；Memtest86+ 的 F1 配置菜单改不了轮数与串口日志参数）。
BMC 虚拟介质挂载的 ISO 是只读的，挂载后无法改参数。

因此：
- 直接烤死 `maxpasses=4` 进 ISO → 想跑 2/3 轮必须重制，不灵活；
- 每次引导时能"选轮数" → 不用重制、不用改文件，最贴合无人值守+灵活的诉求。

本工具的目标：**产出一个带 GRUB 引导菜单的 ISO（`memtest-sol.iso`），开机时在
屏幕上选预设（4 轮验收 / 2 轮 / 1 轮快速筛选 / 交互），超时自动选默认项**，并把
"重制/改预设"固化为本项目的一个可复用工具，而非一次性手工操作。

## 2. 目标 / 非目标 / 反目标

### 目标
- 产出一个可引导 ISO（**纯 UEFI x86_64**），引导即出现 GRUB 菜单，含多个
  Memtest86+ 引导参数预设；超时（默认 20s）自动进入默认项，保证无人值守可用。
- 预设可编辑：改轮数/测试项 = 改一个配置文件，重跑工具即可，不手改二进制。
- 工具作为本项目正式工具入仓库：`scripts/New-MemtestSolIso.ps1` + 预设配置
  `config/memtest-presets.conf` + ISO 组装辅助 + QEMU 冒烟脚本 + 文档更新。
- 产物 ISO 自包含、离线可用，能直接挂到 BMC 虚拟介质。
- **首个执行任务 = QEMU/OVMF 冒烟门禁**：验证 GRUB 能真实引导该内核、参数生效、
  串口能收到 MTLOG、maxpasses 跑满自动重启（弥补"静态读头不等于真能引导"的风险）。

### 非目标
- **不支持 Legacy BIOS**（用户已拍板纯 UEFI）：不写 Legacy 的 El Torito 软盘模拟、
  不复制/重建 `floppy.img`。现代被测服务器（EPYC/Xeon）默认 UEFI、多数已关 CSM。
  注：为兼容 OVMF 等 UEFI 固件，仍写**一条 El Torito no-emulation EFI 引导项**
  （指向 FAT16 ESP 镜像，内含 `EFI\BOOT\BOOTX64.EFI`）——这属于 UEFI 引导范畴，
  非 Legacy 支持。
- 不改动现有 `Run-MemtestSuite.ps1` / `Run-BatchScheduler.ps1` 等脚本行为。
- 不做通用 ISO 重制工具，只做 Memtest86+ SOL 场景。

### 反目标（做了就算失败）
- 让现有无人值守流程变复杂或需人工按键（菜单必须带超时默认项）。
- 产物 ISO 依赖网络/依赖本机安装项才能引导。
- 破坏原 `memtest.iso` 的文件或使其不可引导。
- 不经过真实引导验证就交付（GRUB 引导该内核存在未实测风险，必须以冒烟结果为准）。

## 3. 约束

- Windows PowerShell 5.1（编排），Python 3（ISO 组装，仅构建机需要；产物 ISO 运行
  时不依赖 Python）。
- GRUB2 二进制来源：GNU 官方 **`grub-2.06-for-windows.zip`**（含 `grub-mkimage.exe` 与
  全量模块）。首次构建需联网下载一次，之后缓存到 `tools/grub/` 离线可用
  （用户已批准联网下载）。
  **注意：`grub-2.12-for-windows.zip` 的 x86_64-efi grub-mkimage 产物是已知坏包**
  （Savannah #65072/#64482，`_stack_chk_guard` 符号缺失导致 GRUB 启动中止），
  **不可用**；`-DownloadGrub` 已固定为 2.06。Ventoy U 盘 G: 分区 GRUB 模块不全
  （缺 `linux.mod`/`iso9660.mod`/`serial.mod`），也不可用。
- 冒烟验证：QEMU（`qemu-system-x86_64`）+ OVMF UEFI 固件，下载缓存到
  `tools/qemu/`，纯本机验证，不碰生产服务器（用户已批准）。
  QEMU 11.1.0 不接受 `-accel whpx:tcg` 组合语法；冒烟脚本默认 `-accel whpx`，
  启动即失败自动回退 `-accel tcg` 重试一次。
- memtest 内核 `memtest/boot/binaries/mt86p_900_x86_64` 为 bzImage 风格
  （MZ + HdrS + xloadflags 0x9，64 位入口位在位）。GRUB `linux` 命令理论上可引导
  并传参——**必须经 QEMU 冒烟实测确认**，不作为既定事实。

## 4. 方案（How）

### 4.1 产物结构（memtest-sol.iso，纯 UEFI）

```
memtest-sol.iso
├── EFI/BOOT/BOOTX64.EFI   ← GRUB EFI 引导镜像（grub-mkimage 生成，prefix=/GRUB）
├── EFI/BOOT/EFI.IMG       ← FAT16 ESP 镜像（内含 EFI\BOOT\BOOTX64.EFI，供 El Torito 引导）
├── GRUB/GRUB.CFG          ← 引导菜单（由预设配置生成，大写路径）
├── GRUB/X86_64-EFI/*.MOD  ← GRUB 模块（normal/linux/iso9660/serial 等）
└── BOOT/MT86PLUS.BIN      ← memtest 内核（重命名 8.3，GRUB 用 linux 命令引导并传参）
```

- **El Torito no-emulation EFI 引导项**（卷描述符序列 = PVD(LBA16) + Boot Record(LBA17,
  `EL TORITO SPECIFICATION`) + Terminator）：Boot Catalog 的 initial/default entry 为
  no-emulation（media 0x00、platform 0xEF），指向 FAT16 ESP 镜像（`EFI/BOOT/EFI.IMG`）。
  这是 grub-mkrescue 的标准做法，使 OVMF 及同类 UEFI 固件能从光盘引导
  （**已实证**：无 El Torito 时 OVMF 掉进 UEFI Shell，官方 memtest.iso 因有 El Torito
  引导目录而可引导）。
- **不写** Legacy 软盘模拟项、不复制 `floppy.img`。
- **全部大写 8.3 / ISO9660 Level 1 文件名**（目录标识符放宽到 Level-2 ≤31 字符）：
  GRUB2 的 iso9660 驱动不识别 Joliet 的小写名，按 ISO9660 存储名（大写）匹配；
  用大写路径即可自洽。构建器不写 Joliet SVD、不写 Rock Ridge。

### 4.2 grub.cfg 菜单（由预设生成）

```cfg
set timeout=20
set default=0
# 兜底：不依赖 BMC 虚拟介质设备路径推断，按文件定位根设备
search --no-floppy --set=root --file /BOOT/MT86PLUS.BIN
menuentry "Memtest86+ 4轮完整验收（SOL）" {
  linux /BOOT/MT86PLUS.BIN log=ttyS0,115200 maxpasses=4
  boot
}
menuentry "Memtest86+ 2轮（SOL）" {
  linux /BOOT/MT86PLUS.BIN log=ttyS0,115200 maxpasses=2
  boot
}
menuentry "Memtest86+ 1轮快速筛选（SOL）" {
  linux /BOOT/MT86PLUS.BIN log=ttyS0,115200 maxpasses=1 testlist=0,1,2,3,4,5,6,7,8
  boot
}
menuentry "Memtest86+ 交互界面（无串口日志）" {
  linux /BOOT/MT86PLUS.BIN
  boot
}
```

> 路径统一大写；`search --file` 兜底解决 BMC 虚拟介质设备路径识别问题（复核 Q5）。

### 4.3 预设配置 `config/memtest-presets.conf`（key=value，沿用 app.conf 风格）

```
# Memtest SOL 引导菜单预设
timeout=20
default=4轮全项
preset.4轮全项.title=Memtest86+ 4轮全项（SOL）
preset.4轮全项.cmdline=log=ttyS0,115200 maxpasses=4
preset.4轮快筛.title=Memtest86+ 4轮快筛（SOL）
preset.4轮快筛.cmdline=log=ttyS0,115200 maxpasses=4 testlist=0,1,2,3,4,5,6,7,8
preset.2轮全项.title=Memtest86+ 2轮全项（SOL）
preset.2轮全项.cmdline=log=ttyS0,115200 maxpasses=2
preset.2轮快筛.title=Memtest86+ 2轮快筛（SOL）
preset.2轮快筛.cmdline=log=ttyS0,115200 maxpasses=2 testlist=0,1,2,3,4,5,6,7,8
preset.1轮全项.title=Memtest86+ 1轮全项（SOL）
preset.1轮全项.cmdline=log=ttyS0,115200 maxpasses=1
preset.1轮快筛.title=Memtest86+ 1轮快筛（SOL）
preset.1轮快筛.cmdline=log=ttyS0,115200 maxpasses=1 testlist=0,1,2,3,4,5,6,7,8
preset.交互.title=Memtest86+ 交互界面（无串口日志）
preset.交互.cmdline=nomch
```

改轮数 = 编辑该文件对应行 → 重跑工具。默认预设 `default=` 必须存在，否则工具报错。

### 4.4 工具脚本 `scripts/New-MemtestSolIso.ps1`

参数（与项目现有脚本风格一致）：
- `-Kernel`       默认 `memtest/boot/binaries/mt86p_900_x86_64`
- `-PresetsConf`  默认 `config/memtest-presets.conf`
- `-OutIso`       默认 `memtest/boot/memtest-sol.iso`
- `-GrubDir`      默认 `tools/grub/`（不存在且未禁下载时报错提示或 `-DownloadGrub`）
- `-DownloadGrub` 开关：自动从 GNU 下载 `grub-2.12-for-windows.zip` 到 `tools/grub/`
- `-TimeoutSeconds`/`-DefaultIndex` 可覆盖 conf 的 timeout/default（默认以 conf 为准）
- `-Python`       默认取 `Get-PythonExe`（tools\python 优先，其次 PATH）
- `-SkipBuild`    只生成 grub.cfg/工作目录，不组装 ISO（调试用）
- `-Smoke`        构建后自动跑 QEMU 冒烟（依赖 `tools/qemu/`；`-DownloadQemu` 可自动下载）
- `-DownloadQemu` 开关：下载 QEMU + OVMF 到 `tools/qemu/`
- `-Help`

构建流水线：
1. 确保 GRUB：`-GrubDir` 下存在 `bin/grub-mkimage.exe` 与 `lib/grub/x86_64-efi/*.mod`；
   缺失时：有 `-DownloadGrub` 则下载解压，否则报错并提示。
2. 读取预设 conf → 校验 `default` 存在、`timeout` 数字 → 生成 `grub.cfg`。
3. 组装工作目录：`EFI/BOOT/BOOTX64.EFI`、`GRUB/GRUB.CFG`、`GRUB/X86_64-EFI/*.MOD`
   （精选模块集）、`BOOT/MT86PLUS.BIN`（内核复制并 8.3 改名）。
4. `grub-mkimage -O x86_64-efi -o <work>/EFI/BOOT/BOOTX64.EFI -p /GRUB <modules...>`
   生成 GRUB EFI 镜像（模块：normal iso9660 linux serial terminal configfile echo
   sleep search all_video gfxterm video font gfxmenu reboot halt 等精选集合，
   全部内嵌，运行时不 insmod）。
5. 调 ISO 组装器（见 4.5）生成 `-OutIso`。
6. 校验：挂载产物 ISO，断言关键文件存在；打印产物路径与菜单摘要。
7. （`-Smoke`）QEMU/OVMF 引导产物 ISO，串口重定向到文件，断言出现 `ev=start`、
   `ev=spd`、`ev=pass_end`，并可选 `maxpasses=1` 下出现 `ev=done` 后 `-no-reboot`
   退出。冒烟失败 → 工具报错并置产物为"未验证"。

### 4.5 ISO 组装器（Python 辅助）

`scripts/iso9660_build.py <layout_dir> <out.iso>`：手写最小 ISO9660（Level 1，
大写 8.3 文件名 + Level-2 目录标识符，无 RockRidge、无 Joliet）：
- PVD + 路径表 + 目录记录（单层目录树：EFI/BOOT、GRUB/X86_64-EFI、BOOT）。
- 若 layout 含 `EFI/BOOT/BOOTX64.EFI`，自动生成 FAT16 ESP 镜像（`EFI/BOOT/EFI.IMG`，
  内含 `EFI\BOOT\BOOTX64.EFI`）+ **El Torito Boot Record + Boot Catalog**
  （no-emulation EFI 项，platform 0xEF，校验和按规范 7.4.1 word-sum）；无该文件时
  保持纯 ISO9660。
- 文件名全部大写 8.3（`BOOTX64.EFI`、`EFI.IMG`、`GRUB.CFG`、`MT86PLUS.BIN`、
  `*.MOD`），与 GRUB iso9660 驱动的大小写匹配规则自洽。
- 纯标准库实现，零外部依赖（不依赖 pycdlib/pip）。

> 构建机需要 Python 3（项目 db/ 功能已要求 Python，属既有依赖）；产物 ISO 运行
> 时不需要 Python。

### 4.6 冒烟脚本（QEMU/OVMF）

`scripts/Smoke-MemtestIso.ps1 -Iso <path>`（或作为 `New-MemtestSolIso.ps1 -Smoke`
子流程）：
- 依赖 `tools/qemu/`（qemu-system-x86_64.exe + OVMF_CODE.fd + OVMF_VARS.fd）。
- 命令：`qemu-system-x86_64 -machine q35 -accel whpx -m 2048 -drive
  if=pflash,format=raw,readonly=on,file=OVMF_CODE.fd -drive
  if=pflash,format=raw,file=<vars副本> -cdrom <iso> -serial file:<mtlog.txt>
  -display none -no-reboot`（串口输出到文件，供断言 MTLOG；whpx 不可用自动回退 tcg）。
- 断言：**必需事件 `ev=start`、`ev=pass_end`、`ev=done`**；`ev=spd` 为**可选**
  （memtest86+ v9 在无 SPD 数据的 QEMU 环境不输出 spd，缺失不判失败）。
  `ev=done` 出现后等待 QEMU 自然退出（上限 30s）再判定，避免强杀竞态；仅超时无
  done 或 done 后超限才强杀（done 为完成权威信号）。

## 5. 交付物与验收

- `scripts/New-MemtestSolIso.ps1`（工具入口）
- `scripts/iso9660_build.py`（ISO 组装辅助）
- `scripts/Smoke-MemtestIso.ps1`（QEMU 冒烟）
- `config/memtest-presets.conf`（预设配置，含 4/2/1 轮 + 交互）
- `memtest/boot/memtest-sol.iso`（构建产物，随离线包分发）
- `tools/grub/`、`tools/qemu/`（构建/冒烟期依赖，缓存后离线可用；随包可选携带）
- 文档：`docs/09-SOL使用指南.md` 增补"菜单版 ISO"一节；`docs/05-使用手册.md`
  增补工具用法；`memtest/README.md` 更新组件清单
- 测试：`tests/` 新增 `test-iso-build.ps1`（用 fixtures 假内核/假 conf 做构建 +
  结构断言）

验收判据：
- **冒烟门禁通过**：QEMU/OVMF 引导产物 ISO，串口出现 `ev=start`/`ev=spd`/
  `ev=pass_end`；快速筛选预设下出现 `ev=done` 并自动重启/退出。
- 运行工具（无 `-DownloadGrub`、GRUB 已就位）离线产出 `memtest-sol.iso`，退出码 0。
- 挂载产物 ISO，存在 `EFI/BOOT/BOOTX64.EFI`、`GRUB/GRUB.CFG`（含 4 个菜单项）、
  `BOOT/MT86PLUS.BIN`。
- 改 conf 中某预设轮数 → 重跑 → 新 ISO 的 grub.cfg 反映新值（"改轮数不用手改
  二进制"成立）。
- `default` 缺失 / timeout 非法 → 工具报错退出，不产出损坏 ISO。

## 6. 留给实施者的决定（builder call）

- GRUB 精选模块集的精确清单（确保 grub-mkimage 生成镜像能在 UEFI 引导并加载
  grub.cfg；以冒烟实测最小集合为准）。
- ISO9660 路径表/目录记录实现细节（排序、扩展属性、SVD 填充以满足固件与 GRUB）。
- 下载 URL、版本与 SHA256 校验：GRUB `https://ftp.gnu.org/gnu/grub/grub-2.12-for-windows.zip`；
  QEMU（如 qemu.weilnetz.de Windows 构建）+ OVMF。
- QEMU 冒烟参数微调（ACCEL 选 whpx/tcg 视本机支持而定）。

## 7. 本规格中的既定决策（评审时可推翻）

- **纯 UEFI，不支持 Legacy BIOS**（用户拍板）：不写 Legacy 软盘模拟项、不复制
  floppy.img / boot.catalog；但写 **El Torito no-emulation EFI 引导项**（指向 FAT16
  ESP 镜像），已实证 OVMF 兼容（无 El Torito 时 OVMF 掉进 Shell）。
- **允许联网下载** GRUB2（2.06，2.12 为已知坏包）+ QEMU/OVMF 到 `tools/` 缓存
  （用户拍板），之后离线。
- 菜单默认项 = 4 轮验收，超时 20s（无人值守优先）。
- ISO9660 用**大写 8.3 文件名 + Level-2 目录标识符，无 Joliet/无 RockRidge**
  （复核 Q2：GRUB 不认 Joliet，大写路径自洽最简）。
- grub.cfg 开头加 `search --file /BOOT/MT86PLUS.BIN` 兜底（复核 Q5）。
- **GRUB 引导该内核以 QEMU/OVMF 冒烟实测为准**，不把静态读头当既定事实（复核 Q1）：
  **门禁已通过**——OVMF 引导 ISO → GRUB 加载大写 GRUB.CFG → `linux` 引导
  MT86PLUS.BIN 并传参 → memtest 快速测试 0 错误 → `ev=done`。
- 冒烟必需事件 = `ev=start/pass_end/done`，`ev=spd` 可选（QEMU 无 SPD 数据）。
- 工具形态 = PowerShell 编排 + Python 组装，与项目"PS 编排 + 可选 Python 辅助"
  的既有模式一致；构建机需 Python，产物运行不需要。
- 预设集 = 4 轮 / 2 轮 / 1 轮快速筛选 / 交互，均可通过 conf 增删改。

---

## 参考

- Memtest86+ 官方 readme（Boot Options：`log=`/`maxpasses=`/`console=`/`testlist=`，
  仅引导加载器命令行传入；F1 配置菜单不含轮数/串口参数）：https://memtest.org/readme
- GRUB2 GNU 下载：https://ftp.gnu.org/gnu/grub/
- QEMU Windows 构建：https://qemu.weilnetz.de/
