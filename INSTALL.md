# ORICO HA500 盘位灯控 — Windows 版

在 ORICO HA500（五盘位 NAS）安装 Windows 后，恢复前面板 5 个蓝色硬盘位指示灯的原厂行为：**灯随盘位有无自动亮灭，低电平点亮，2 秒轮询，热插拔即时响应**。

本项目是 GitHub 项目 [wayyoungboy/fnos-ha500-led](https://github.com/wayyoungboy/fnos-ha500-led)（fnOS 版）的 Windows 移植。GPIO 映射经该机实机验证（5 个盘位依次点亮确认、双盘自动联动确认）。

---

## 一、适用范围与硬性前提

| 项目 | 要求 |
|---|---|
| 硬件 | **必须与 ORICO HA500 同主板同 BIOS**（Jasper Lake N5105/N5095 + ASM1166 1b21:1166）。⚠️GPIO 接线是板级定义，同芯片不同板的接线可能不同，**不可**凭"同为 N5105"直接套用（参考[原项目文档第 6 节](https://github.com/wayyoungboy/fnos-ha500-led/blob/main/docs/how-it-works.md)） |
| 系统 | **x64** Windows，PowerShell 5.1+。理论可用：Win10/Server 2016 及以后；注意 Win11 22H2+ 与 Server 2025 默认启用"易受攻击的驱动阻止列表"/HVCI，需要额外关闭（见安全说明） |
| 权限 | 安装与运行均需管理员/SYSTEM |
| **HVCI** | **必须关闭"内存完整性"（内核隔离 HVCI）**，否则签名的旧版内核驱动被禁止加载（安装脚本会自动检测并拒绝） |
| SafeBoot | 无影响（驱动为正式签名，非测试签名） |
| 已验证环境 | Windows Server 2022 Standard 10.0.20348，实机通过 |

> 盘位灯不走 ASM1166 的 enclosure management，而是接在 Intel JSL PCH GPIO（ACPI `INT34C8`）上，所以系统里 INT34C8 显示"无驱动/错误"是正常现象，本工具直接操作其 MMIO 寄存器。

## 二、包内容

```
├── INSTALL.md            本文件
├── install.ps1           目标机安装脚本（管理员 PowerShell 运行）
├── uninstall.ps1         卸载脚本（-Purge 连工作目录一起删）
├── payload/              部署产物（install.ps1 复制到 C:\zcode-ha500）
│   ├── inpoutx64.sys     内核驱动（Authenticode 签名：Red Fox UK Limited，
│   │                     提取自官方 inpoutx64.dll 内嵌资源，已验签）
│   ├── inpoutx64.dll     驱动接口 DLL（MapPhysToLin 物理内存映射）
│   └── ha500-led.ps1     主工具（检测 + 轮询 + 灯控）
└── debug-tools/          调试/研究工具（部署非必需）
    ├── WinRing0x64.sys   PCI 配置空间读取驱动（LibreHardwareMonitor v0.9.3 内嵌提取）
    ├── ha500-inpout-probe.ps1   GPIO 寄存器 + AHCI 端口全量读取
    ├── wring0-read-probe2.ps1   PCI 扫描 + AHCI 读取（依赖 WinRing0x64.sys）
    ├── led-test2.ps1            逐盘位点灯测试（独立版）
    ├── deploy-auto.ps1          计划任务部署参考
    └── extract-inpout-sys2.ps1  从 inpoutx64.dll 提取内嵌驱动
```

## 三、安装步骤（目标机上）

1. 把整个包目录复制到目标机，例如放到 `C:\temp\ha500-led-windows-package`。
2. 打开**管理员 PowerShell**，`cd` 进包目录，运行：

   ```powershell
   .\install.ps1
   ```

   脚本会：检查管理员/HVCI → 复制文件到 `C:\zcode-ha500\` → 注册并启动 `inpoutx64` 内核驱动服务 → 驱动冒烟测试 → 注册计划任务 `HA500LedControl`（SYSTEM、开机自启、失败自动重启 3 次、无时限）。

3. **验证盘位映射（必做）**——盯着前面板运行：

   ```powershell
   powershell -File C:\zcode-ha500\ha500-led.ps1 -Test
   ```

   5 个灯应按 **DISK1→DISK5** 顺序依次点亮，每格 3 秒。若顺序与面板盘位不符，说明该机接线不同（修改 `ha500-led.ps1` 中 `$bays` 的 `rel` 字段）。

4. 启动自动模式：

   ```powershell
   Start-ScheduledTask -TaskName HA500LedControl
   ```

   或安装时直接带 `-StartNow` 参数。有盘的盘位灯亮，无盘的灭，2 秒轮询，热插拔即时跟灯。

## 四、日常使用

| 命令 | 作用 |
|---|---|
| `ha500-led.ps1`（无参） | 显示用法 |
| `ha500-led.ps1 -Status` | 打印每盘位：有无盘 / 灯态 / GPIO 寄存器值 |
| `ha500-led.ps1 -Test` | 逐盘位点灯 3 秒（目视验证映射） |
| `ha500-led.ps1 -AllOff` | 一键全灭 |
| `ha500-led.ps1 -Auto` | 前台轮询模式（一般由计划任务后台运行） |
| 停止自动模式 | `Stop-ScheduledTask -TaskName HA500LedControl`（退出时自动全灭） |
| 运行日志 | `C:\zcode-ha500\ha500-led.log` |

## 五、卸载

```powershell
.\uninstall.ps1          # 删任务+驱动服务，保留 C:\zcode-ha500（日志）
.\uninstall.ps1 -Purge   # 连 C:\zcode-ha500 一起删
```

## 六、安全说明（必读）

**inpoutx64 属于"易滥用驱动"（vulnerable driver）类别**，这是此类驱动的本质而非版本缺陷：它向用户态开放任意物理内存读写，这正是本工具需要的原语，也是攻击者滥用的原因。要点：

- 本仓库的 `inpoutx64.sys` 哈希已被 [LOLDrivers](https://www.loldrivers.io/) 收录为 vulnerable driver（T1068 提权类）；Win11 22H2+ / Server 2025 默认启用的"易受攻击的驱动阻止列表"很可能拦截它，杀毒软件也可能报 PUA/HackTool。
- **已实施的缓解**（本包内建）：
  1. 设备对象 DACL 限制为 **SYSTEM/Administrators**——非管理员进程打开 `\\.\inpoutx64` 被拒绝（已在实机用 LocalService 账户行为学验证：`OPEN_DENIED err=5`）。主工具每次启动、安装脚本在驱动启动后都会自动重施（设备 SD 在驱动重载后会重置）。
  2. 驱动服务为**按需启动**（demand），仅由本工具/安装脚本拉起。
  3. 计划任务以 SYSTEM 运行，不依赖任何可登录账户。
- **残余风险模型**：能以**管理员**身份在 NAS 上执行代码的进程本已完全控制系统，此驱动不额外降低安全边界；真正的风险窗口是"误装在多用户且存在低权限攻击面的机器上"——若你的 NAS 有其他登录用户或对外服务，请评估后使用。不需要时用 `uninstall.ps1` 移除最干净。
- `debug-tools/WinRing0x64.sys` 同为公开收录的 vulnerable driver（仅调试用，主工具不加载它），建议调试完删除。
- 替代方案评估结论：PawnIo 无任意 MMIO 模块、WinIo 无签名无法加载、自写驱动需测试签名模式（比现状更差）——在没有 EV 证书自签驱动的条件下，"签名旧驱动 + ACL 收紧"是当前最优解。

## 七、故障排查

| 症状 | 处理 |
|---|---|
| install.ps1 报 HVCI 运行中 | Windows 安全中心 → 设备安全性 → 内核隔离 → 关闭"内存完整性"→ 重启 |
| `IsInpOutDriverOpen = False` | `sc query inpoutx64` 看服务状态；`C:\Windows\INF\setupapi.dev.log` 查驱动加载失败原因 |
| -Test 灯不亮但寄存器有值 | 该机 pad 被 PADCFGLOCK 锁定（读 community+0x080 区），或接线不同——先用 debug-tools 里的 probe 脚本读寄存器回显确认写入是否生效 |
| 顺序不对 | 改 `ha500-led.ps1` 里 `$bays` 各项的 `rel`（community 内相对 pad 号），重跑 -Test |
| 有盘灯不亮 | 确认盘在 ASM1166 口上：`Get-PhysicalDisk | ft FriendlyName, PhysicalLocation`，PhysicalLocation 必须含 `: Port N`；NVMe/RAID 口的盘不参与 |
| 重启后灯不控 | 计划任务被禁用或失败：`Get-ScheduledTask HA500LedControl`，看 `ha500-led.log` |

## 八、技术原理（附录）

**硬件链路**：5 个蓝灯为**低电平点亮**（active-low），接在 Intel Jasper Lake PCH GPIO 控制器（ACPI HID `INT34C8:00`）上，不走 ASM1166 enclosure management。PCH GPIO 通过 P2SB PCR 侧带空间访问：`物理地址 = 0xFD000000 (PCR base) + (community PID << 16) + 0x600 (PAD_CFG_BASE) + 相对pad号 × 16`。

**实机验证的映射表**（pad DW0 寄存器地址）：

| 盘位 | Linux sysfs offset | JSL pin | community (PID) | DW0 地址 |
|---|---|---|---|---|
| DISK1 | 75 | 66 (GPP_A11) | COM0 (0x6E) | `0xFD6E0A20` |
| DISK2 | 261 | 176 (GPP_C5) | COM1 (0x6D) | `0xFD6D0B40` |
| DISK3 | 100 | 80 (GPP_S4) | COM0 (0x6E) | `0xFD6E0B00` |
| DISK4 | 260 | 175 (GPP_C4) | COM1 (0x6D) | `0xFD6D0B30` |
| DISK5 | 256 | 171 (GPP_C0) | COM1 (0x6D) | `0xFD6D0AF0` |

**寄存器语义**（PadCfg DW0）：bit0 = TXSTATE（输出电平），bit9 = TXDIS（输出禁用）。点亮 = `TXDIS=0, TXSTATE=0`；熄灭 = `TXDIS=0, TXSTATE=1`。写入采用读-改-写，只动 bit0/bit9，其余位保留。该机 pad 初始态 `0x84000200`（TXDIS=1 悬空不驱动）。

**盘位检测**：`MSFT_PhysicalDisk.PhysicalLocation` 形如 `PCI Slot 6 : Bus 2 : Device 0 : Function 0 : Adapter 0 : Port N`，其中 `Port N` 为 ASM1166 的 **0 基 AHCI 端口号**（已与 AHCI 寄存器 `PxCMD.START`/`PI` 交叉验证），HA500 默认盘位 = 端口号 + 1（端口 6 为备用口）。仅统计带 `Port` 的 SATA 盘，NVMe 忽略。

**映射来源三方交叉验证**：① fnos-ha500-led 项目文档（offset 75/261/100/260/256，低电平点亮）；② Linux `pinctrl-jasperlake.c`（gpio_base 相对编号→pin→community 换算）+ coreboot `pcr_ids.h`（PID 0x6E/0x6D）与 `PAD_CFG_BASE=0x600`；③ 该机 BIOS DSDT 内厂商 GPIO 方法库（SGOV/GADR/GINF，地址公式一致）。

**写通道说明**：LHM 0.9.6 的 PawnIo 无 MMIO 模块、WinRing0x64 v1.2.0 反汇编确认无物理内存**写**实现（读也被限制在 0xC0000-0xFFFFF），故选用带正式签名、经 HVCI 关闭环境实测可加载的 inpoutx64（MapPhysToLin 用户态映射 + 直接内存读写）。

**与原版差异**：不支持红色读写闪烁灯（原项目也未实现，其中四路在当前 ACPI 状态被锁定，盲写风险高）；`HOSTSW_OWN` 所有权写入在该机 COM1 上被固件拒绝，但 pad DW0 写入不受影响，故工具不依赖所有权。
