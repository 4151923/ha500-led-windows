# Remote: clean LED test v2 - proper uint32 bit ops, per-bay on/verify/off.
$ErrorActionPreference = 'Continue'
$wd = 'C:\zcode-ha500'
& sc.exe create inpoutx64 type= kernel start= demand binPath= "$wd\inpoutx64.sys" 2>&1 | Out-Null
& sc.exe start inpoutx64 2>&1 | Out-Null

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class InpOut2 {
  [DllImport("kernel32.dll", CharSet=CharSet.Ansi, SetLastError=true)]
  public static extern IntPtr LoadLibraryEx(string name, IntPtr h, uint flags);
  [DllImport("kernel32.dll", CharSet=CharSet.Ansi, SetLastError=true)]
  public static extern IntPtr GetProcAddress(IntPtr h, string name);
  public delegate IntPtr MapFn(IntPtr phys, uint size, ref IntPtr handle);
  public delegate bool UnmapFn(IntPtr handle);
  public static MapFn mapPhys;
  public static UnmapFn unmapPhys;
  public static bool Load(string path) {
    IntPtr lib = LoadLibraryEx(path, IntPtr.Zero, 0);
    if (lib == IntPtr.Zero) return false;
    mapPhys = (MapFn)Marshal.GetDelegateForFunctionPointer(GetProcAddress(lib, "MapPhysToLin"), typeof(MapFn));
    unmapPhys = (UnmapFn)Marshal.GetDelegateForFunctionPointer(GetProcAddress(lib, "UnmapPhysicalMemory"), typeof(UnmapFn));
    return true;
  }
}
'@

if (-not [InpOut2]::Load("$wd\inpoutx64.dll")) { Write-Output 'DLL_LOAD_FAIL'; exit 2 }

function U64([string]$hex) { return [Convert]::ToUInt64($hex, 16) }
$hh0 = [IntPtr]::Zero
$hh1 = [IntPtr]::Zero
$m0 = [InpOut2]::mapPhys.Invoke([IntPtr][uint32](U64 'FD6E0000'), 0x10000, [ref]$hh0).ToInt64()
$m1 = [InpOut2]::mapPhys.Invoke([IntPtr][uint32](U64 'FD6D0000'), 0x10000, [ref]$hh1).ToInt64()
if ($m0 -eq 0 -or $m1 -eq 0) { Write-Output 'MAP_FAIL'; exit 3 }

$R = { param($ptr, $off) [Runtime.InteropServices.Marshal]::ReadInt32($ptr + $off) }
$W = { param($ptr, $off, [uint32]$val) [Runtime.InteropServices.Marshal]::WriteInt32($ptr + $off, $val) }

function Get-Dw0($m, $rel) { return & $R $m (0x600 + $rel * 16) }
function Set-Led($m, $rel, [bool]$on) {
  $addr = 0x600 + $rel * 16
  $cur = & $R $m $addr
  # clear TXDIS (bit9)
  $new = [uint32]([uint64]$cur -band 0xFFFFFFFFFFFFFDFF)
  if ($on) {
    $new = [uint32]([uint64]$new -band 0xFFFFFFFFFFFFFFFE)   # TXSTATE=0 -> LED on (active low)
  } else {
    $new = [uint32]([uint64]$new -bor 1)                     # TXSTATE=1 -> LED off
  }
  & $W $m $addr $new
  Start-Sleep -Milliseconds 30
  return (& $R $m $addr)
}

$bays = @(
  @{ n = 1; m = $m0; rel = 66;  name = 'off75/pin66' },
  @{ n = 2; m = $m1; rel = 84;  name = 'off261/pin176' },
  @{ n = 3; m = $m0; rel = 80;  name = 'off100/pin80' },
  @{ n = 4; m = $m1; rel = 83;  name = 'off260/pin175' },
  @{ n = 5; m = $m1; rel = 79;  name = 'off256/pin171' }
)

Write-Output '=== initial DW0 ==='
foreach ($b in $bays) { Write-Output ('  bay{0}: DW0={1:X8}' -f $b.n, (Get-Dw0 $b.m $b.rel)) }

Write-Output '=== ensure all OFF (TXDIS=0, TXSTATE=1) ==='
foreach ($b in $bays) {
  $after = Set-Led $b.m $b.rel $false
  Write-Output ('  bay{0} -> DW0={1:X8}' -f $b.n, $after)
}
Start-Sleep -Seconds 1

Write-Output '=== per-bay test: ON 4s -> OFF (watch panel!) ==='
foreach ($b in $bays) {
  $t0 = Get-Date
  $onv = Set-Led $b.m $b.rel $true
  Write-Output ('>>> STEP {0}: LIGHTING {1} (DW0={2:X8})' -f $b.n, $b.name, $onv)
  Start-Sleep -Seconds 4
  $persist = Get-Dw0 $b.m $b.rel
  $offv = Set-Led $b.m $b.rel $false
  Write-Output ('    STEP {0} done: persisted DW0={1:X8} still-on={2}; off DW0={3:X8}' -f $b.n, $persist, (($persist -band 1) -eq 0), $offv)
  Start-Sleep -Seconds 2
}
Write-Output '=== final state ==='
foreach ($b in $bays) { Write-Output ('  bay{0}: DW0={1:X8}' -f $b.n, (Get-Dw0 $b.m $b.rel)) }
Write-Output '=== DONE ==='
