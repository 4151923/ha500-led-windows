# ha500-led-windows

本项目为 **[wayyoungboy/fnos-ha500-led](https://github.com/wayyoungboy/fnos-ha500-led)** 的 Windows 移植版，喜欢的话可以去给原作者点个Stars

在 ORICO HA500 五盘位 NAS 安装 **Windows** 后，恢复前面板 5 个蓝色盘位指示灯的原厂行为：

- 灯随盘位有无自动亮灭（低电平点亮），2 秒轮询，热插拔即时跟灯
- 开机自启（计划任务 SYSTEM 权限），断电重启自动恢复
- 附带 `-Test` 逐盘点灯校验、`-Status` 状态查询、`-AllOff` 一键全灭

适配硬件：**ORICO HA500**（Intel Jasper Lake N5105 + ASM1166 SATA，同主板同 BIOS）。
GPIO 映射已在实机验证：5 盘位依次点亮确认、双盘（DISK2/DISK4）自动联动确认。

## 快速开始

详细说明见 **[INSTALL.md](INSTALL.md)**。目标机上管理员 PowerShell 三步：

```powershell
.\install.ps1                                          # 安装驱动 + 计划任务
powershell -File C:\zcode-ha500\ha500-led.ps1 -Test    # 目视校验盘位映射
Start-ScheduledTask -TaskName HA500LedControl          # 启动自动模式
```

硬性前提：关闭"内核隔离/内存完整性"（HVCI）——签名的旧版内核驱动无法在 HVCI 下加载，安装脚本会自动检测。**安全须知**：底层驱动 inpoutx64 属于公开收录的"易滥用驱动"类别（任意物理内存读写是其功能本身），本包已默认将其设备对象收紧为仅 SYSTEM/Administrators 可打开（每次启动自动重施），风险模型与残余风险详见 [INSTALL.md 安全说明](INSTALL.md#六安全说明必读)。

## 工作原理（简述）

5 个蓝灯接在 Intel Jasper Lake PCH GPIO 控制器（ACPI `INT34C8`）上，不走 ASM1166 enclosure management。本工具通过签名的 inpoutx64 驱动把 GPIO community MMIO 窗口映射进用户态，直接读写 pad 的 PadCfg DW0 寄存器（TXSTATE/TXDIS 位）：

```
物理地址 = 0xFD000000 (PCR base) + (community PID << 16) + 0x600 (PAD_CFG_BASE) + 相对pad号 × 16
  DISK1 = pin 66  (offset 75)  COM0 (PID 0x6E)  DW0 @ 0xFD6E0A20
  DISK2 = pin 176 (offset 261) COM1 (PID 0x6D)  DW0 @ 0xFD6D0B40
  DISK3 = pin 80  (offset 100) COM0             DW0 @ 0xFD6E0B00
  DISK4 = pin 175 (offset 260) COM1             DW0 @ 0xFD6D0B30
  DISK5 = pin 171 (offset 256) COM1             DW0 @ 0xFD6D0AF0
```

盘位检测用 `MSFT_PhysicalDisk.PhysicalLocation`（`Port N` = ASM1166 的 0 基 AHCI 端口号，已与 AHCI 寄存器交叉验证），盘位 = 端口号 + 1。

完整技术细节（寄存器语义、映射三方交叉验证、为何选 inpoutx64、故障排查）见 [INSTALL.md](INSTALL.md) 技术附录。

## ⚠️ 免责声明

GPIO 接线是**板级定义**：仅适用于与本项目同主板同 BIOS 的 ORICO HA500；"同为 N5105 + ASM1166"的其他设备不可直接套用（参考 [fnos-ha500-led 文档第 6 节](docs/how-it-works.md)）。使用造成的任何硬件/数据问题由使用者自行承担。直接操作硬件寄存器属于高危操作，请先跑 `-Test` 确认映射再上自动模式。

## 致谢与来源

- **[wayyoungboy/fnos-ha500-led](https://github.com/wayyoungboy/fnos-ha500-led)** — 本项目为其 Windows 移植版：盘位↔GPIO offset 映射（75/261/100/260/256）、低电平点亮语义、盘位检测设计均依据其[工作原理文档](https://github.com/wayyoungboy/fnos-ha500-led/blob/main/docs/how-it-works.md)。
- **[InpOut32 / inpoutx64](https://www.highrez.co.uk/downloads/inpout32/)** — Phil Gibbons（Red Fox UK Limited）的 InpOut 驱动/接口库，本仓库 `payload/inpoutx64.sys` 与 `inpoutx64.dll` 提取自官方发布的 `inpoutx64.dll` 内嵌资源，按其许可证自由分发，提供物理内存映射读写通道。
- **[LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor)** — `debug-tools/WinRing0x64.sys` 提取自其 v0.9.3 发行包（仅调试用，主工具不依赖）。
- GPIO 映射的技术依据：[Linux pinctrl-jasperlake](https://github.com/torvalds/linux/blob/master/drivers/pinctrl/intel/pinctrl-jasperlake.c)、[coreboot jasperlake](https://review.coreboot.org/plugins/gitiles/coreboot/+/refs/heads/main/src/soc/intel/jasperlake/)（PCR PID / PAD_CFG_BASE），并与该机 BIOS DSDT 内厂商 GPIO 方法（SGOV/GADR/GINF）交叉验证。
- 本项目使用GLM-5.3-Flash进行移植和提交
