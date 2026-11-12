# Third-Party Notices

Redistributed binaries in this repository and their sources/licenses:

## inpoutx64.sys / inpoutx64.dll

- Source: official [InpOut32 / InpOut Binaries](https://www.highrez.co.uk/downloads/inpout32/) package
  (`InpOutBinaries`, https://www.highrez.co.uk/scripts/download.asp?package=InpOutBinaries)
- Author/copyright: Phil Gibbons / Red Fox UK Limited
- `inpoutx64.sys` was extracted from the embedded resources of the official
  `inpoutx64.dll` (resource `BIN/#104`) and its Authenticode signature verified:
  CN=Red Fox UK Limited (Digital ID Class 3 - Microsoft Software Validation v2).
- The InpOut binaries are distributed by their author as a free driver package
  ("free to use", redistribution bundled with attribution). Per the package's
  `license.txt`: the software is provided "as is" without warranty. See the
  upstream package for the full license text.

## WinRing0x64.sys (debug-tools only, not required at runtime)

- Source: [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor)
  v0.9.3 release (`LibreHardwareMonitor-net472.zip`), embedded resource
  `LibreHardwareMonitor.Resources.WinRing0x64.gz` (gzip, 0xFF prefix byte).
- Upstream driver: WinRing0 v1.2.0 (OpenLibSys), bundled by LibreHardwareMonitor.
- LibreHardwareMonitor is licensed under MPL-2.0; the bundled WinRing0 driver is
  copyright its original authors (OpenLibSys). Provided here unmodified for
  debugging convenience; see upstream projects for license details.

## Design references (no code copied)

- [wayyoungboy/fnos-ha500-led](https://github.com/wayyoungboy/fnos-ha500-led) —
  mapping and behavior reference (fnOS implementation, Python; this repository
  is an independent Windows implementation).
- Linux kernel `drivers/pinctrl/intel/pinctrl-jasperlake.c` (GPL-2.0) — register
  layout knowledge only; no kernel code used or copied into the shipped binaries.
- coreboot `src/soc/intel/jasperlake` (GPL-2.0) — PCR port IDs / PAD_CFG_BASE
  constants as documentation reference.

All original PowerShell scripts in `payload/` and `install.ps1`/`uninstall.ps1`
were written for this project.
