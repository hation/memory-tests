# Memtest SOL 菜单引导 ISO 工具 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 产出带 GRUB 引导菜单的 `memtest-sol.iso`（纯 UEFI），开机可选预设轮数（4/2/1/交互），并固化为仓库可复用工具（PS 编排 + Python 组装 + QEMU 冒烟）。

**Architecture:** PowerShell 编排器（`New-MemtestSolIso.ps1`）读取预设配置 → 生成 grub.cfg → 用 grub-mkimage 生成 GRUB EFI 引导镜像 → 用 Python 手写 ISO9660 Level-1 组装器生成大写 8.3 文件名 ISO → QEMU/OVMF 冒烟门禁验证 GRUB 真实引导并传参。

**Tech Stack:** PowerShell 5.1、Python 3（标准库）、GRUB2（grub-mkimage x86_64-efi）、QEMU + OVMF。

**Spec:** `docs/superpowers/specs/2026-10-22-memtest-sol-menu-iso-design.md`（本计划从该规格论证，执行者需同时阅读两者）

## Global Constraints

- 纯 UEFI x86_64，无 Legacy/El Torito/floppy.img/boot.catalog（用户拍板）。
- ISO 文件名全部大写 8.3（`BOOTX64.EFI`、`GRUB.CFG`、`MT86PLUS.BIN`、`*.MOD`），无 Joliet/RockRidge。
- grub.cfg 路径统一大写，开头必须含 `search --no-floppy --set=root --file /BOOT/MT86PLUS.BIN` 兜底。
- 预设默认：`default=4轮验收`，`timeout=10`；`default` 缺失或 timeout 非法 → 工具报错退出。
- 产物 ISO 自包含离线可用；GRUB/QEMU 首次联网下载缓存到 `tools/grub/`、`tools/qemu/`，之后离线。
- 不修改 `Run-MemtestSuite.ps1` / `Run-BatchScheduler.ps1` / 现有脚本行为；lib_common.ps1 只增函数不改既有函数。
- 构建机需 Python 3；产物运行不需要 Python。

## Review Focus

1. **GRUB 大小写敏感**：grub.cfg 里路径必须与 ISO 存储名（大写 8.3）逐字节一致，否则 GRUB 找不到内核/配置 → Task 3 测试断言 grub.cfg 中路径为大写且与布局文件名一致。
2. **预设 cmdline 含空格与逗号**（`log=ttyS0,115200 maxpasses=1 testlist=0,1,2,3`）：解析不得截断/串行 → Task 1 测试含 `testlist` 预设的完整解析。
3. **中文菜单标题编码**：grub.cfg 含中文 title，ISO 以 UTF-8 写入；PS 写文件与 Python 读文件编码必须一致 → Task 1 测试断言生成文本含 UTF-8 中文；Task 3 冒烟为最终兜底。
4. **工具缺失要报错而非静默**：grub-mkimage / python / qemu 找不到 → 明确报错并提示下载方式 → Task 3/4 测试。
5. **输出 ISO 覆盖安全**：`-OutIso` 已存在时先写临时文件再原子替换，失败不残留半截 ISO → Task 3 测试。

---

### Task 1: 预设解析 + grub.cfg 生成（lib_common.ps1）

**Files:**
- Create: `config/memtest-presets.conf`
- Modify: `scripts/lib_common.ps1`（末尾追加两函数，不改既有函数）
- Test: `tests/test-presets.ps1`

**Interfaces:**
- Consumes: 无（首个任务）。
- Produces:
  - `Get-MemtestPresets -Path <conf> -> [PSCustomObject]@{ Timeout=[int]; Default=[string]; Presets=[array of @{ Key; Title; Cmdline }] }`（Presets 按 conf 出现顺序）
  - `ConvertTo-GrubCfg -Presets <obj> [-TimeoutSeconds=-1][-DefaultIndex=-1][-KernelPath="/BOOT/MT86PLUS.BIN"] -> [string]`（grub.cfg 全文；两参数为 -1 时用 Presets 值）

- [ ] **Step 1: 创建 `config/memtest-presets.conf`**

内容（UTF-8 无 BOM）：
```
# Memtest SOL 引导菜单预设
timeout=10
default=4轮验收
preset.4轮验收.title=Memtest86+ 4轮完整验收（SOL）
preset.4轮验收.cmdline=log=ttyS0,115200 maxpasses=4
preset.2轮.title=Memtest86+ 2轮（SOL）
preset.2轮.cmdline=log=ttyS0,115200 maxpasses=2
preset.1轮快速筛选.title=Memtest86+ 1轮快速筛选（SOL）
preset.1轮快速筛选.cmdline=log=ttyS0,115200 maxpasses=1 testlist=0,1,2,3,4,5,6,7,8
preset.交互.title=Memtest86+ 交互界面（无串口日志）
preset.交互.cmdline=nomch
```

- [ ] **Step 2: 写失败测试 `tests/test-presets.ps1`**

沿用 `tests/test-lib.ps1` 风格（dot-source lib_common，`function Assert`，末尾 `Write-Host "test-presets: ALL PASS"`）。断言：
1. 正常 conf → Presets 4 个、顺序正确、`Presets[2].Cmdline` 含 `testlist=0,1,2,3,4,5,6,7,8` 完整值、Timeout=10、Default=4轮验收。
2. 生成 grub.cfg：开头 `set timeout=10`、`set default=0`、含 `search --no-floppy --set=root --file /BOOT/MT86PLUS.BIN`、4 个 `menuentry`、每个含 `/BOOT/MT86PLUS.BIN`、`-TimeoutSeconds 3` 覆盖生效、`-DefaultIndex 2` 生效、含 UTF-8 中文 title（`"4轮完整验收"` 出现在字符串中）。
3. 缺 `default` 的 conf → `Get-MemtestPresets` throw。
4. `timeout=abc` → throw。
5. 某 preset 缺 title 或 cmdline → throw。

- [ ] **Step 3: 运行测试确认失败**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-presets.ps1`
Expected: 抛错（函数未定义）

- [ ] **Step 4: 在 `scripts/lib_common.ps1` 末尾实现两函数**

`Get-MemtestPresets`：读 key=value（复用 `Get-Config` 风格解析，跳过注释/空行/非法键），收集 `preset.<key>.title`/`preset.<key>.cmdline` 成对，`default` 必须存在于 Presets key 中否则 throw，`timeout` 必须为整数否则 throw，preset 缺 title/cmdline 则 throw。
`ConvertTo-GrubCfg`：`set timeout=` / `set default=`（default 为 Presets 索引；`-DefaultIndex` 非 -1 则覆盖），`search` 兜底行，每 preset 生成一个 `menuentry "title" { linux <KernelPath> <cmdline>; boot }`；cmdline 为空则只 `linux <KernelPath>`。

- [ ] **Step 5: 运行测试确认通过**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-presets.ps1`
Expected: `test-presets: ALL PASS`

- [ ] **Step 6: Commit**

```bash
git add config/memtest-presets.conf scripts/lib_common.ps1 tests/test-presets.ps1
git commit -m "feat: add memtest SOL presets parsing and grub.cfg generation"
```

---

### Task 2: ISO9660 组装器（iso9660_build.py）

**Files:**
- Create: `scripts/iso9660_build.py`
- Test: `tests/test_iso9660_build.py`

**Interfaces:**
- Consumes: Task 3 提供 layout 目录（含 `EFI/BOOT/BOOTX64.EFI`、`GRUB/GRUB.CFG`、`GRUB/X86_64-EFI/*.MOD`、`BOOT/MT86PLUS.BIN`）。
- Produces: CLI `iso9660_build.py <layout_dir> <out.iso>`，退出码 0 成功；输出 ISO9660 Level-1（大写 8.3，无 Joliet/RockRidge/El Torito），PVD(LBA16)+路径表+目录记录。Task 3/4 依赖其输出为可挂载 ISO。

- [ ] **Step 1: 写失败测试 `tests/test_iso9660_build.py`**

沿用 `tests/test_db.py` 风格（unittest）。测试：
1. `test_build_and_structure`：临时 layout 写入 4 个文件（含子目录）→ 调 `iso9660_build.py` → 输出存在；读回 PVD（LBA 16，`\x01CD001`），断言无 Joliet SVD（SVD 转义区无 `\x25\x2f\x40`），路径表/目录记录中存在 `EFI`、`BOOT`、`GRUB`、`BOOTX64.EFI;1`、`GRUB.CFG;1`、`MT86PLUS.BIN;1`，文件名全大写。
2. `test_uppercase_8_3`：layout 中有小写文件名 → 输出 ISO 目录记录为大写。
3. `test_empty_layout`：空 layout → 退出码非 0。

- [ ] **Step 2: 运行测试确认失败**

Run: `python -m unittest tests.test_iso9660_build -v`
Expected: ImportError / 断言失败

- [ ] **Step 3: 实现 `scripts/iso9660_build.py`**

标准库实现：收集 layout 文件 → 大写 8.3 映射（`BOOTX64.EFI`→`BOOTX64.EFI`、`MT86PLUS.BIN` 等；不合规名报错）→ 按 LBA 布局（引导区 16 扇区 + PVD + 路径表 + 目录记录 + 数据区）→ 写 `out.iso`。目录记录含 `;1` 版本号；不写 Joliet/RockRidge/El Torito。

- [ ] **Step 4: 运行测试确认通过**

Run: `python -m unittest tests.test_iso9660_build -v`
Expected: 全 PASS

- [ ] **Step 5: 真实可挂载冒烟（本机验证步骤）**

用 `memtest/boot/binaries/mt86p_900_x86_64` 与临时 grub.cfg 组装一个测试 ISO，`Mount-DiskImage` 后 `Get-ChildItem` 断言 4 个关键文件存在。若挂载失败（ISO9660 结构问题）→ 修 writer 后重跑本步。

- [ ] **Step 6: Commit**

```bash
git add scripts/iso9660_build.py tests/test_iso9660_build.py
git commit -m "feat: add ISO9660 Level-1 writer for memtest SOL ISO"
```

---

### Task 3: 编排器（New-MemtestSolIso.ps1）

**Files:**
- Create: `scripts/New-MemtestSolIso.ps1`
- Test: `tests/test-iso-build.ps1`

**Interfaces:**
- Consumes: Task 1 `Get-MemtestPresets`/`ConvertTo-GrubCfg`；Task 2 `iso9660_build.py`；`lib_common.ps1::Get-PythonExe`。
- Produces:
  - CLI `New-MemtestSolIso.ps1 [-Kernel][-PresetsConf][-OutIso][-GrubDir][-DownloadGrub][-TimeoutSeconds][-DefaultIndex][-Python][-SkipBuild][-Smoke][-DownloadQemu][-Help]`
  - `Get-GrubTool -GrubDir [-Force]`：下载 `https://ftp.gnu.org/gnu/grub/grub-2.12-for-windows.zip` 解压到 GrubDir（校验 `bin\grub-mkimage.exe` 与 `lib\grub\x86_64-efi\*.mod` 存在）。
  - 产物：`memtest/boot/memtest-sol.iso`。

- [ ] **Step 1: 写失败测试 `tests/test-iso-build.ps1`**

用 stub 隔离真实工具：临时 `fake-grub-mkimage.cmd`（把自身拷贝成目标文件即可，模拟"生成镜像"）、Python 用真实（本机有）。断言：
1. 正常构建（-GrubDir 指向含 stub + 假 .mod 的临时目录，-Kernel 用真实内核或假文件，-OutIso 指向 temp）→ 退出码 0，ISO 存在，挂载后含 `EFI\BOOT\BOOTX64.EFI`、`GRUB\GRUB.CFG`（内容含 4 个 menuentry 且路径大写）、`BOOT\MT86PLUS.BIN`。
2. 改预设轮数（改 conf 的 `preset.4轮验收.cmdline` 为 maxpasses=3）→ 重跑 → grub.cfg 含 `maxpasses=3`（"改轮数不用手改二进制"）。
3. 缺 default / timeout 非法 → 退出码 1 且不产出 OutIso。
4. GrubDir 无 grub-mkimage 且未 -DownloadGrub → 报错退出。
5. -OutIso 已存在 → 构建后为完整新 ISO（原子替换），无 `.tmp` 残留。

- [ ] **Step 2: 运行测试确认失败**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-iso-build.ps1`
Expected: 抛错（脚本不存在）

- [ ] **Step 3: 实现 `scripts/New-MemtestSolIso.ps1`**

按规格 §4.4 流水线：解析参数 → 确保 GRUB（缺失且无 -DownloadGrub 报错；有则 `Get-GrubTool`）→ `Get-MemtestPresets` + `ConvertTo-GrubCfg` → 组 layout（`EFI/BOOT`、`GRUB/GRUB.CFG`、`GRUB/X86_64-EFI/*.MOD` 精选集、`BOOT/MT86PLUS.BIN`）→ `grub-mkimage -O x86_64-efi -o <layout>/EFI/BOOT/BOOTX64.EFI -p /GRUB normal iso9660 linux serial terminal configfile echo sleep search all_video video gfxterm font reboot halt test boot`（模块清单实现者可按冒烟实测微调）→ `python iso9660_build.py` → 原子写 `-OutIso`（先 `.tmp` 后 Move）→ 挂载自检。`-Smoke` 行为见 Task 4（先以快速预设构建临时 ISO 冒烟，再构建正式 ISO）。

- [ ] **Step 4: 运行测试确认通过**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-iso-build.ps1`
Expected: `test-iso-build: ALL PASS`

- [ ] **Step 5: Commit**

```bash
git add scripts/New-MemtestSolIso.ps1 tests/test-iso-build.ps1
git commit -m "feat: add New-MemtestSolIso orchestrator"
```

---

### Task 4: QEMU 冒烟（Smoke-MemtestIso.ps1）

**Files:**
- Create: `scripts/Smoke-MemtestIso.ps1`
- Test: `tests/test-smoke.ps1`

**Interfaces:**
- Consumes: Task 3 的 `-Smoke` 流程（传入快速预设构建的临时 ISO）；`lib_common.ps1::Get-PythonExe`（不需要）。
- Produces:
  - CLI `Smoke-MemtestIso.ps1 [-Iso][-QemuDir][-TimeLimitSeconds=600][-DownloadQemu][-Help]`
  - `Get-QemuTool -QemuDir [-Force]`：下载 QEMU Windows 构建 + OVMF（qemu.weilnetz.de）解压到 QemuDir。
  - 返回 `[PSCustomObject]@{ Pass=[bool]; Mtlog=[path]; Reason=[string] }`。

- [ ] **Step 1: 写失败测试 `tests/test-smoke.ps1`**

用 stub qemu：临时 `fake-qemu.cmd` 接收参数并写出一份假 MTLOG 到 `-serial file:` 参数指定的路径（内含 `ev=start`/`ev=spd`/`ev=pass_end`/`ev=done`），退出码 0。断言：
1. 假 MTLOG 含 done → `Smoke-MemtestIso -QemuDir`（QemuDir 指向含 stub + 假 OVMF 文件）→ Pass=$true。
2. 假 MTLOG 无 `ev=done`（stub 只写 start/spd）→ Pass=$false 且 Reason 说明缺 done。
3. 假 MTLOG 无 `ev=start` → Pass=$false。
4. QemuDir 缺 qemu-system-x86_64.exe 且未 -DownloadQemu → 报错退出。
5. stub 退出码非 0 → Pass=$false。

- [ ] **Step 2: 运行测试确认失败**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-smoke.ps1`
Expected: 抛错

- [ ] **Step 3: 实现 `scripts/Smoke-MemtestIso.ps1`**

按规格 §4.6：`qemu-system-x86_64 -machine q35 -accel whpx:tcg -m 2048 -drive if=pflash,format=raw,readonly=on,file=<OVMF_CODE.fd> -drive if=pflash,format=raw,file=<vars 副本> -cdrom <iso> -serial file:<mtlog.txt> -display none -no-reboot`；轮询 mtlog 直到 `ev=done` 或超时；断言 `ev=start`/`ev=spd`/`ev=pass_end`/`ev=done` 出现；qemu 退出码非 0 且无 done → 失败。OVMF 文件名以实际下载包为准（builder call，如 `edk2-x86_64-code.fd`）。

- [ ] **Step 4: 运行测试确认通过**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-smoke.ps1`
Expected: `test-smoke: ALL PASS`

- [ ] **Step 5: 回接 `New-MemtestSolIso.ps1 -Smoke`**

将 `-Smoke` 流程接通：以 `-DefaultIndex <1轮快速筛选索引> -TimeoutSeconds 3` 构建临时 ISO → 调 `Smoke-MemtestIso -Iso <temp>` → 通过后构建正式 `-OutIso`；失败则输出警告并置产物"未验证"（仍产出，退出码 1）。

- [ ] **Step 6: Commit**

```bash
git add scripts/Smoke-MemtestIso.ps1 tests/test-smoke.ps1 scripts/New-MemtestSolIso.ps1
git commit -m "feat: add QEMU smoke test for memtest SOL ISO"
```

---

### Task 5: 真实构建 + 冒烟门禁（集成验证，本机执行）

**Files:**
- 产物：`memtest/boot/memtest-sol.iso`
- 依赖：`tools/grub/`、`tools/qemu/`（下载缓存）

**Interfaces:**
- Consumes: Task 1–4 全部产物。

- [ ] **Step 1: 下载 GRUB 并真实构建**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\New-MemtestSolIso.ps1 -DownloadGrub`
Expected: 退出码 0；`memtest/boot/memtest-sol.iso` 生成

- [ ] **Step 2: 挂载自检**

`Mount-DiskImage` 产物 ISO → 断言 4 个关键文件 → `Dismount-DiskImage`。

- [ ] **Step 3: 下载 QEMU 并真实冒烟（门禁）**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\New-MemtestSolIso.ps1 -OutIso <temp>\smoke.iso -DefaultIndex 2 -TimeoutSeconds 3 -Smoke -DownloadQemu`
Expected: 冒烟 Pass（mtlog 含 `ev=start`/`ev=spd`/`ev=pass_end`/`ev=done`）。
若 GRUB `linux` 引导该内核失败（GRUB 报错/黑屏/无 MTLOG）→ 这是规格预设的门禁风险：如实汇报并记录失败细节，暂停等待用户决策（不强行交付）。

- [ ] **Step 4: 修正产物并提交**

冒烟通过后重跑默认构建（Task 5 Step 1 命令）生成正式 `memtest/boot/memtest-sol.iso`，确认无 `.tmp` 残留。

```bash
git add memtest/boot/memtest-sol.iso
git commit -m "build: add memtest-sol menu ISO artifact"
```

---

### Task 6: 打包 + 文档 + 收尾

**Files:**
- Modify: `scripts/build.ps1`（`$scriptFiles` 增加 `New-MemtestSolIso.ps1`、`Smoke-MemtestIso.ps1`；新增 `scripts\iso9660_build.py` 存在性校验；tools 拷贝时排除 `qemu`）
- Modify: `.gitignore`（追加 `tools/grub/`、`tools/qemu/`）
- Modify: `docs/09-SOL使用指南.md`（增补"菜单版 ISO（memtest-sol.iso）"一节：产物说明、菜单预设、改轮数方法、与 Run-MemtestSuite 联动）
- Modify: `docs/05-使用手册.md`（增补 `New-MemtestSolIso.ps1` / `Smoke-MemtestIso.ps1` 参数手册）
- Modify: `memtest/README.md`（组件清单增补 memtest-sol.iso、新脚本；文档索引）

**Interfaces:**
- Consumes: Task 5 产物与脚本。

- [ ] **Step 1: 更新 `scripts/build.ps1`**

`$scriptFiles` 追加 `'New-MemtestSolIso.ps1'`、`'Smoke-MemtestIso.ps1'`；在校验段追加 `scripts\iso9660_build.py` 存在性检查；`tools` 拷贝循环对 `$d -eq 'tools'` 时 `Exclude @('qemu')`（grub 随包携带，qemu 仅构建机冒烟用不打包）。

- [ ] **Step 2: 更新 `.gitignore`**

追加两行：`tools/grub/`、`tools/qemu/`。

- [ ] **Step 3: 更新三处文档**

按规格 §5 增补内容（文档标记保持 `[当前有效]`；变更记录追加 2026-10-22 行）。注意 memtest/README.md 是独立文件（非 build 拷贝），直接改仓库内该文件即可。

- [ ] **Step 4: 回归验证**

Run:
```
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-lib.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-presets.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-iso-build.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-smoke.ps1
python -m unittest tests.test_iso9660_build -v
```
Expected: 全部 ALL PASS
并运行 `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build.ps1` 验证打包通过（不 -Zip，避免大文件）。

- [ ] **Step 5: Commit**

```bash
git add scripts/build.ps1 .gitignore docs/09-SOL使用指南.md docs/05-使用手册.md memtest/README.md
git commit -m "docs: add memtest-sol menu ISO tool usage and packaging"
```

---

### 收尾

- 全部任务完成后，主 agent 整体复核产物（运行全部测试 + 检查 memtest-sol.iso 存在 + build.ps1 通过），并向用户汇报：产物路径、冒烟结果、改轮数方法、GRUB/QEMU 下载缓存位置。
