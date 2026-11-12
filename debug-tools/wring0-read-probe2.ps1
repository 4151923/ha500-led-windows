# Remote: WinRing0 read probe v2 - scan PCI for ASM1166, read AHCI + GPIO pads.
$ErrorActionPreference = 'Continue'
$svcName = 'ZCodeWinRing0'
$sysPath = 'C:\zcode-ha500\WinRing0x64.sys'

& sc.exe create $svcName type= kernel start= demand binPath= "$sysPath" 2>&1 | Out-Null
& sc.exe start $svcName 2>&1 | Select-String 'STATE|FAILED' | ForEach-Object { Write-Output ('  ' + $_.ToString().Trim()) }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class Wr0 {
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Ansi)]
  public static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool DeviceIoControl(IntPtr h, uint code, byte[] inBuf, uint inSize, byte[] outBuf, uint outSize, out uint ret, IntPtr ov);
  [DllImport("kernel32.dll")]
  public static extern bool CloseHandle(IntPtr h);
  public static uint codeMemRead = 0x9C406104;
  public static uint codePciRead = 0x9C406144;
  public static int LastOk = 1;
  public static IntPtr Open() {
    return CreateFile(@"\\.\WinRing0_1_2_0", 0xC0000000, 0, IntPtr.Zero, 3, 0, IntPtr.Zero);
  }
  public static bool MemRead(IntPtr h, ulong addr, int count, byte[] output) {
    byte[] input = new byte[16];
    BitConverter.GetBytes(addr).CopyTo(input, 0);
    BitConverter.GetBytes((uint)1).CopyTo(input, 8);
    BitConverter.GetBytes((uint)count).CopyTo(input, 12);
    uint ret;
    LastOk = DeviceIoControl(h, codeMemRead, input, 16, output, (uint)count, out ret, IntPtr.Zero) ? 1 : 0;
    return LastOk == 1;
  }
  public static bool PciRead(IntPtr h, uint pciAddr, uint regAddr, int count, byte[] output) {
    byte[] input = new byte[8];
    BitConverter.GetBytes(pciAddr).CopyTo(input, 0);
    BitConverter.GetBytes(regAddr).CopyTo(input, 4);
    uint ret;
    LastOk = DeviceIoControl(h, codePciRead, input, 8, output, (uint)count, out ret, IntPtr.Zero) ? 1 : 0;
    return LastOk == 1;
  }
}
'@

$h = [Wr0]::Open()
if ($h -eq [IntPtr](-1) -or $h -eq [IntPtr]::Zero) {
  Write-Output ('DEVICE_OPEN_FAIL err=' + [Runtime.InteropServices.Marshal]::GetLastWin32Error())
  & sc.exe stop $svcName | Out-Null
  exit 3
}
Write-Output 'device opened'

function U64([string]$hex) { return [Convert]::ToUInt64($hex, 16) }

Write-Output '=== PCI scan for ASM1166 (1B21:1166) ==='
$found = $null
for ($bus = 0; $bus -le 7 -and -not $found; $bus++) {
  for ($dv = 0; $dv -le 31 -and -not $found; $dv++) {
    for ($fn = 0; $fn -le 7 -and -not $found; $fn++) {
      $paddr = [uint32]((($bus -shl 20) -bor ($dv -shl 15) -bor ($fn -shl 12)) -band 0xFFFFFFFF)
      $out = New-Object byte[] 4
      if ([Wr0]::PciRead($h, $paddr, 0, 4, $out)) {
        $vd = [BitConverter]::ToUInt32($out, 0)
        if ($vd -eq 0x11661B21) {
          $found = @{ bus = $bus; dev = $dv; fn = $fn; addr = $paddr }
          Write-Output ('  FOUND ASM1166 at bus={0} dev={1} fn={2}' -f $bus, $dv, $fn)
        }
      }
    }
  }
}
if (-not $found) { Write-Output '  ASM1166 NOT FOUND in buses 0-7' }

if ($found) {
  $out = New-Object byte[] 4
  if ([Wr0]::PciRead($h, $found.addr, 0x24, 4, $out)) {
    $bar5 = [BitConverter]::ToUInt32($out, 0) -band 0xFFFFF000
    Write-Output ('  BAR5 = {0:X8}' -f $bar5)
    if ($bar5 -ne 0) {
      $bar5s = '{0:X8}' -f $bar5
      Write-Output ('  AHCI CAP = ' + (Read-MemU32 (U64 $bar5s)))
      Write-Output ('  PI = ' + (Read-MemU32 (U64 $bar5s) 0)) 
    }
  }
}

# AHCI reads via a resolved address variable (avoid string conversions mid-loop)
if ($found) {
  $out = New-Object byte[] 4
  [void][Wr0]::PciRead($h, $found.addr, 0x24, 4, $out)
  $bar5 = [BitConverter]::ToUInt32($out, 0) -band 0xFFFFF000
  if ($bar5 -ne 0) {
    $cap = New-Object byte[] 4
    $pi  = New-Object byte[] 4
    [void][Wr0]::MemRead($h, [uint64]$bar5, 4, $cap)
    [void][Wr0]::MemRead($h, ([uint64]$bar5 + 0x0C), 4, $pi)
    Write-Output ('  AHCI CAP = {0:X8}  PI = {1:X8}' -f [BitConverter]::ToUInt32($cap, 0), [BitConverter]::ToUInt32($pi, 0))
    for ($p = 0; $p -lt 6; $p++) {
      $ssts = New-Object byte[] 4
      $sig  = New-Object byte[] 4
      [void][Wr0]::MemRead($h, ([uint64]($bar5 + 0x100 + $p * 0x80)), 4, $ssts)
      [void][Wr0]::MemRead($h, ([uint64]($bar5 + 0x124 + $p * 0x80)), 4, $sig)
      Write-Output ('  Port{0}: PxSSTS={1:X8} PxSIG={2:X8}' -f $p, [BitConverter]::ToUInt32($ssts, 0), [BitConverter]::ToUInt32($sig, 0))
    }
  }
}

Write-Output '=== GPIO LED pad registers ==='
$pads = @(
  @{ bay = 1; off = 75;  pin = 66;  dw0s = 'FD6E0A20'; com = 'COM0(6E)' },
  @{ bay = 2; off = 100; pin = 80;  dw0s = 'FD6E0B00'; com = 'COM0(6E)' },
  @{ bay = 3; off = 256; pin = 171; dw0s = 'FD6D0AF0'; com = 'COM1(6D)' },
  @{ bay = 4; off = 260; pin = 175; dw0s = 'FD6D0B30'; com = 'COM1(6D)' },
  @{ bay = 5; off = 261; pin = 176; dw0s = 'FD6D0B40'; com = 'COM1(6D)' }
)
foreach ($p in $pads) {
  $a = U64 $p.dw0s
  $o0 = New-Object byte[] 4
  $o1 = New-Object byte[] 4
  [void][Wr0]::MemRead($h, $a, 4, $o0)
  [void][Wr0]::MemRead($h, ($a + 4), 4, $o1)
  Write-Output ('  bay{0} off{1} pin{2} {3}: DW0={4:X8} DW1={5:X8}' -f $p.bay, $p.off, $p.pin, $p.com, [BitConverter]::ToUInt32($o0, 0), [BitConverter]::ToUInt32($o1, 0))
}

Write-Output '=== HOSTSW_OWN + community sanity ==='
foreach ($c in @(@{ n = 'COM0'; b = 'FD6E0000' }, @{ n = 'COM1'; b = 'FD6D0000' })) {
  $cb = U64 $c.b
  $o = New-Object byte[] 4
  [void][Wr0]::MemRead($h, ($cb + 0x00), 4, $o)
  $reg00 = [BitConverter]::ToUInt32($o, 0)
  [void][Wr0]::MemRead($h, ($cb + 0xC0), 4, $o)
  $hsw0 = [BitConverter]::ToUInt32($o, 0)
  [void][Wr0]::MemRead($h, ($cb + 0xC4), 4, $o)
  $hsw1 = [BitConverter]::ToUInt32($o, 0)
  [void][Wr0]::MemRead($h, ($cb + 0xC8), 4, $o)
  $hsw2 = [BitConverter]::ToUInt32($o, 0)
  [void][Wr0]::MemRead($h, ($cb + 0x080), 4, $o)
  $lock = [BitConverter]::ToUInt32($o, 0)
  Write-Output ('  {0}: [00]={1:X8} PADCFGLOCK={2:X8} HOSTSW(0)={3:X8} (1)={4:X8} (2)={5:X8}' -f $c.n, $reg00, $lock, $hsw0, $hsw1, $hsw2)
}

[Wr0]::CloseHandle($h) | Out-Null
& sc.exe stop $svcName | Out-Null
Write-Output '=== DONE ==='
