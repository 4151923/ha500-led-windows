# HA500 disk-bay LED control for Windows Server (fnOS HA500 hardware).
# Mirrors the fnOS fnos-ha500-led project: 5 blue bay LEDs on Intel JSL PCH GPIO
# (INT34C8), active-low, driven per SATA disk presence on the ASM1166 (1b21:1166).
#
# Bay -> pad mapping (verified on real hardware):
#   DISK1 = JSL GPIO pin 66  (offset 75)  COM0 @ 0xFD6E0000
#   DISK2 = JSL GPIO pin 176 (offset 261) COM1 @ 0xFD6D0000
#   DISK3 = JSL GPIO pin 80  (offset 100) COM0
#   DISK4 = JSL GPIO pin 175 (offset 260) COM1
#   DISK5 = JSL GPIO pin 171 (offset 256) COM1
# Pad DW0 register = community base + 0x600 + relPin*16.
# LED on  = TXSTATE(bit0)=0 (active low), TXDIS(bit9)=0
# LED off = TXSTATE(bit0)=1, TXDIS(bit9)=0
#
# Disk presence: MSFT_PhysicalDisk PhysicalLocation "... : Port N" where N is the
# 0-based AHCI port index on the ASM1166; bay = port + 1 (HA500 default mapping).
#
# Modes:
#   -Auto        poll loop (scheduled-task mode)
#   -AllOff      one-shot: all LEDs off
#   -Status      print current disk/LED state and exit
#   -Test        light each bay in sequence (visual mapping test)
param(
  [switch]$Auto,
  [switch]$AllOff,
  [switch]$Status,
  [switch]$Test,
  [int]$IntervalSec = 2
)
$ErrorActionPreference = 'Continue'
$wd = 'C:\zcode-ha500'
$logPath = Join-Path $wd 'ha500-led.log'

function Log([string]$msg) {
  $line = ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg)
  Write-Output $line
  try { Add-Content -Path $logPath -Value $line -ErrorAction SilentlyContinue } catch { }
}

& sc.exe create inpoutx64 type= kernel start= demand binPath= "$wd\inpoutx64.sys" 2>&1 | Out-Null
& sc.exe start inpoutx64 2>&1 | Out-Null

# Harden: restrict \\.\inpoutx64 to SYSTEM/Administrators. The driver creates its
# device with a permissive DACL; the SD resets on every driver reload, so re-apply
# at each startup. Anyone able to open this device gets kernel-memory R/W.
function Protect-DriverDevice {
  try {
    $fi = New-Object IO.FileInfo('\\.\inpoutx64')
    $acl = $fi.GetAccessControl()
    $acl.SetSecurityDescriptorSddlForm('D:P(A;;GA;;;SY)(A;;GA;;;BA)')
    $fi.SetAccessControl($acl)
    return $true
  } catch { return $false }
}
$devHardened = Protect-DriverDevice

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Ha500Io {
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
if (-not [Ha500Io]::Load("$wd\inpoutx64.dll")) { Log 'FATAL: inpoutx64.dll load failed'; exit 2 }
Log ('device ACL hardening applied: ' + $devHardened)

function U64([string]$hex) { return [Convert]::ToUInt64($hex, 16) }
$hh0 = [IntPtr]::Zero
$hh1 = [IntPtr]::Zero
$m0 = [Ha500Io]::mapPhys.Invoke([IntPtr][uint32](U64 'FD6E0000'), 0x10000, [ref]$hh0).ToInt64()
$m1 = [Ha500Io]::mapPhys.Invoke([IntPtr][uint32](U64 'FD6D0000'), 0x10000, [ref]$hh1).ToInt64()
if ($m0 -eq 0 -or $m1 -eq 0) { Log 'FATAL: GPIO MMIO map failed'; exit 3 }

function R32([long]$ptr, [int]$off) { [Runtime.InteropServices.Marshal]::ReadInt32($ptr + $off) }
function W32([long]$ptr, [int]$off, [uint32]$val) { [Runtime.InteropServices.Marshal]::WriteInt32($ptr + $off, $val) }

# bay -> mapped window + community-relative pad index
$bays = @(
  @{ n = 1; m = $m0; rel = 66 },
  @{ n = 2; m = $m1; rel = 84 },
  @{ n = 3; m = $m0; rel = 80 },
  @{ n = 4; m = $m1; rel = 83 },
  @{ n = 5; m = $m1; rel = 79 }
)

function Set-Led($m, [int]$rel, [bool]$on) {
  $addr = 0x600 + $rel * 16
  $cur = [uint32](R32 $m $addr)
  $new = [uint32]([uint64]$cur -band 0xFFFFFFFFFFFFFDFF)   # clear TXDIS
  if ($on) { $new = [uint32]([uint64]$new -band 0xFFFFFFFFFFFFFFFE) }   # TXSTATE=0
  else { $new = [uint32]([uint64]$new -bor 1) }             # TXSTATE=1
  W32 $m $addr $new
}

function Set-AllOff { foreach ($b in $bays) { Set-Led $b.m $b.rel $false } }

function Get-OccupiedBays {
  $occ = @{}
  try {
    Get-CimInstance -Namespace root\Microsoft\Windows\Storage -ClassName MSFT_PhysicalDisk -ErrorAction Stop |
      Where-Object { $_.PhysicalLocation -match ': Port (\d+)' } |
      ForEach-Object { $occ[[int]$Matches[1] + 1] = $true }
  } catch { Log ('WARN: disk query failed: ' + $_.Exception.Message) }
  return $occ
}

if ($AllOff) { Set-AllOff; Log 'all LEDs off'; exit 0 }

if ($Test) {
  Log 'LED test sequence start'
  Set-AllOff
  Start-Sleep -Seconds 1
  foreach ($b in $bays) {
    foreach ($x in $bays) { Set-Led $x.m $x.rel $false }
    Set-Led $b.m $b.rel $true
    Log ('test: bay ' + $b.n + ' on')
    Start-Sleep -Seconds 3
    Set-Led $b.m $b.rel $false
    Start-Sleep -Milliseconds 500
  }
  Log 'LED test sequence end'
  exit 0
}

if ($Status) {
  $occ = Get-OccupiedBays
  foreach ($b in $bays) {
    $dw0 = [uint32](R32 $b.m (0x600 + $b.rel * 16))
    $ledOn = ((($dw0 -shr 9) -band 1) -eq 0) -and ((($dw0 -shr 0) -band 1) -eq 0)
    $disk = $occ.ContainsKey($b.n)
    Write-Output ('bay {0}: disk={1} ledOn={2} DW0={3:X8}' -f $b.n, $disk, $ledOn, $dw0)
  }
  exit 0
}

if (-not $Auto) {
  Write-Output 'Usage: ha500-led.ps1 -Auto | -AllOff | -Status | -Test'
  exit 1
}

# --- Auto loop ---
$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Global\HA500LedControl', [ref]$created)
if (-not $created) { Log 'another instance running, exit'; exit 4 }

Log ('auto mode start, interval ' + $IntervalSec + 's')
Set-AllOff
$lastState = $null
try {
  while ($true) {
    $occ = Get-OccupiedBays
    $stateKey = (($bays | ForEach-Object { if ($occ.ContainsKey($_.n)) { '1' } else { '0' } }) -join '')
    if ($stateKey -ne $lastState) {
      Log ('disk state: bays [' + $stateKey + '] occupied=' + (($occ.Keys | Sort-Object) -join ','))
      $lastState = $stateKey
    }
    foreach ($b in $bays) { Set-Led $b.m $b.rel $occ.ContainsKey($b.n) }
    Start-Sleep -Seconds $IntervalSec
  }
} finally {
  Set-AllOff
  Log 'auto mode stop, LEDs off'
  $mutex.ReleaseMutex()
  $mutex.Dispose()
}
