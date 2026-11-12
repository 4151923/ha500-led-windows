# Remote: inpoutx64 phys-mem probe - GPIO pads + AHCI ports. WinRing0 for PCI config.
$ErrorActionPreference = 'Continue'
$wd = 'C:\zcode-ha500'

Write-Output '=== services ==='
& sc.exe create inpoutx64 type= kernel start= demand binPath= "$wd\inpoutx64.sys" 2>&1 | Out-Null
& sc.exe start inpoutx64 2>&1 | Select-String 'STATE|FAILED' | ForEach-Object { Write-Output ('  inpoutx64: ' + $_.ToString().Trim()) }
& sc.exe create ZCodeWinRing0 type= kernel start= demand binPath= "$wd\WinRing0x64.sys" 2>&1 | Out-Null
& sc.exe start ZCodeWinRing0 2>&1 | Select-String 'STATE|FAILED' | ForEach-Object { Write-Output ('  ZCodeWinRing0: ' + $_.ToString().Trim()) }
Write-Output ('PS 64-bit process: ' + [Environment]::Is64BitProcess)

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class InpOut {
  [DllImport("kernel32.dll", CharSet=CharSet.Ansi, SetLastError=true)]
  public static extern IntPtr LoadLibraryEx(string name, IntPtr h, uint flags);
  [DllImport("kernel32.dll", CharSet=CharSet.Ansi, SetLastError=true)]
  public static extern IntPtr GetProcAddress(IntPtr h, string name);

  public delegate bool BoolFn();
  public delegate IntPtr MapFn(IntPtr phys, uint size, ref IntPtr handle);
  public delegate bool UnmapFn(IntPtr handle);
  public delegate bool GetLongFn(IntPtr addr, ref uint value);
  public delegate bool SetLongFn(IntPtr addr, uint value);

  public static IntPtr lib;
  public static BoolFn isOpen;
  public static MapFn mapPhys;
  public static UnmapFn unmapPhys;
  public static GetLongFn getLong;
  public static SetLongFn setLong;

  public static bool Load(string path) {
    lib = LoadLibraryEx(path, IntPtr.Zero, 0);
    if (lib == IntPtr.Zero) return false;
    isOpen = (BoolFn)Marshal.GetDelegateForFunctionPointer(GetProcAddress(lib, "IsInpOutDriverOpen"), typeof(BoolFn));
    mapPhys = (MapFn)Marshal.GetDelegateForFunctionPointer(GetProcAddress(lib, "MapPhysToLin"), typeof(MapFn));
    unmapPhys = (UnmapFn)Marshal.GetDelegateForFunctionPointer(GetProcAddress(lib, "UnmapPhysicalMemory"), typeof(UnmapFn));
    getLong = (GetLongFn)Marshal.GetDelegateForFunctionPointer(GetProcAddress(lib, "GetPhysLong"), typeof(GetLongFn));
    setLong = (SetLongFn)Marshal.GetDelegateForFunctionPointer(GetProcAddress(lib, "SetPhysLong"), typeof(SetLongFn));
    return true;
  }
}
public static class Wr0 {
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Ansi)]
  public static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool DeviceIoControl(IntPtr h, uint code, byte[] inBuf, uint inSize, byte[] outBuf, uint outSize, out uint ret, IntPtr ov);
  [DllImport("kernel32.dll")]
  public static extern bool CloseHandle(IntPtr h);
  public static uint codePciRead = 0x9C406144;
  public static IntPtr Open() {
    return CreateFile(@"\\.\WinRing0_1_2_0", 0xC0000000, 0, IntPtr.Zero, 3, 0, IntPtr.Zero);
  }
  public static bool PciRead(IntPtr h, uint pciAddr, uint regAddr, int count, byte[] output) {
    byte[] input = new byte[8];
    BitConverter.GetBytes(pciAddr).CopyTo(input, 0);
    BitConverter.GetBytes(regAddr).CopyTo(input, 4);
    uint ret;
    return DeviceIoControl(h, codePciRead, input, 8, output, (uint)count, out ret, IntPtr.Zero);
  }
}
'@

Write-Output '=== inpoutx64 open ==='
if (-not [InpOut]::Load("$wd\inpoutx64.dll")) { Write-Output ('DLL_LOAD_FAIL err=' + [Runtime.InteropServices.Marshal]::GetLastWin32Error()); exit 2 }
$opened = [InpOut]::isOpen.Invoke()
Write-Output ('IsInpOutDriverOpen = ' + $opened)
if (-not $opened) { exit 3 }

# --- WinRing0 open for PCI ---
$h = [Wr0]::Open()
$haveWring0 = ($h -ne [IntPtr](-1) -and $h -ne [IntPtr]::Zero)
Write-Output ('WinRing0 open = ' + $haveWring0)

function U64([string]$hex) { return [Convert]::ToUInt64($hex, 16) }

Write-Output '=== PCI scan (CF8 fmt) for ASM1166 ==='
$found = $null
for ($bus = 0; $bus -le 15 -and -not $found; $bus++) {
  for ($dv = 0; $dv -le 31 -and -not $found; $dv++) {
    for ($fn = 0; $fn -le 7 -and -not $found; $fn++) {
      $paddr = [uint32](((($bus -shl 8) -bor ($dv -shl 3) -bor $fn)) -band 0xFFFFFF)
      $out = New-Object byte[] 4
      if ($haveWring0 -and [Wr0]::PciRead($h, $paddr, 0, 4, $out)) {
        $vd = [BitConverter]::ToUInt32($out, 0)
        if ($vd -eq 0x11661B21) {
          $found = @{ bus = $bus; dev = $dv; fn = $fn; addr = $paddr }
          Write-Output ('  FOUND ASM1166 at bus={0} dev={1} fn={2}' -f $bus, $dv, $fn)
        }
      }
    }
  }
}
if (-not $found) { Write-Output '  ASM1166 not found' }

$bar5 = 0
if ($found) {
  $out = New-Object byte[] 4
  if ([Wr0]::PciRead($h, $found.addr, 0x24, 4, $out)) {
    $bar5 = [BitConverter]::ToUInt32($out, 0) -band 0xFFFFF000
    Write-Output ('  BAR5 = {0:X8}' -f $bar5)
  }
}

Write-Output '=== AHCI registers via MapPhysToLin ==='
if ($bar5 -ne 0) {
  $handle = [IntPtr]::Zero
  $p = [InpOut]::mapPhys.Invoke([IntPtr]$bar5, 4096, [ref]$handle)
  if ($p -ne [IntPtr]::Zero) {
    $pv = $p.ToInt64()
    Write-Output ('  mapped ptr = {0:X16}' -f $pv)
    Write-Output ('  AHCI+00(CAP) = {0:X8}  AHCI+0C(PI) = {1:X8}' -f [Runtime.InteropServices.Marshal]::ReadInt32($pv), [Runtime.InteropServices.Marshal]::ReadInt32($pv + 0x0C))
    for ($port = 0; $port -lt 6; $port++) {
      $base = 0x100 + $port * 0x80
      Write-Output ('  Port{0}: PxCMD={1:X8} PxSSTS={2:X8} PxSIG={3:X8}' -f $port, [Runtime.InteropServices.Marshal]::ReadInt32($pv + $base + 0x18), [Runtime.InteropServices.Marshal]::ReadInt32($pv + $base), [Runtime.InteropServices.Marshal]::ReadInt32($pv + $base + 4))
    }
    [void][InpOut]::unmapPhys.Invoke($handle)
  } else { Write-Output '  BAR5 MAP FAIL' }
}

Write-Output '=== GPIO community windows via MapPhysToLin ==='
foreach ($c in @(@{ n = 'COM0(6E)'; base = 'FD6E0000' }, @{ n = 'COM1(6D)'; base = 'FD6D0000' })) {
  $b = [uint32](U64 $c.base)
  $handle = [IntPtr]::Zero
  $p = [InpOut]::mapPhys.Invoke([IntPtr]$b, 0x10000, [ref]$handle)
  if ($p -eq [IntPtr]::Zero) { Write-Output ('  ' + $c.n + ' MAP FAIL'); continue }
  $pv = $p.ToInt64()
  Write-Output ('  ' + $c.n + ' mapped={0:X16}' -f $pv)
  Write-Output ('    [080]={0:X8} [0C0]={1:X8} [0C4]={2:X8} [0C8]={3:X8}' -f [Runtime.InteropServices.Marshal]::ReadInt32($pv + 0x080), [Runtime.InteropServices.Marshal]::ReadInt32($pv + 0x0C0), [Runtime.InteropServices.Marshal]::ReadInt32($pv + 0x0C4), [Runtime.InteropServices.Marshal]::ReadInt32($pv + 0x0C8))
  # LED pads within this community
  $padList = @()
  if ($c.n -like 'COM0*') { $padList = @(@(66, 'bay1-off75'), @(80, 'bay2-off100')) }
  else { $padList = @(@(79, 'bay3-off256'), @(83, 'bay4-off260'), @(84, 'bay5-off261')) }
  foreach ($pd in $padList) {
    $addr = 0x600 + $pd[0] * 16
    Write-Output ('    {0} rel{1}: DW0={2:X8} DW1={3:X8}' -f $pd[1], $pd[0], [Runtime.InteropServices.Marshal]::ReadInt32($pv + $addr), [Runtime.InteropServices.Marshal]::ReadInt32($pv + $addr + 4))
  }
  [void][InpOut]::unmapPhys.Invoke($handle)
}

if ($haveWring0) { [void][Wr0]::CloseHandle($h) }
Write-Output '=== DONE ==='
