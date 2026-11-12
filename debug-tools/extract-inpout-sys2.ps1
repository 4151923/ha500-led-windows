# Enumerate ALL resource types+names in inpoutx64.dll and dump big ones.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class ResX2 {
  [DllImport("kernel32.dll", CharSet=CharSet.Ansi, SetLastError=true)]
  public static extern IntPtr LoadLibraryEx(string name, IntPtr h, uint flags);
  public delegate bool EnumResTypeProc(IntPtr h, IntPtr type, IntPtr param);
  public delegate bool EnumResNameProc(IntPtr h, IntPtr type, IntPtr name, IntPtr param);
  [DllImport("kernel32.dll", CharSet=CharSet.Ansi, SetLastError=true)]
  public static extern bool EnumResourceTypes(IntPtr h, EnumResTypeProc cb, IntPtr param);
  [DllImport("kernel32.dll", CharSet=CharSet.Ansi, SetLastError=true)]
  public static extern bool EnumResourceNames(IntPtr h, IntPtr type, EnumResNameProc cb, IntPtr param);
  [DllImport("kernel32.dll", CharSet=CharSet.Ansi, SetLastError=true)]
  public static extern IntPtr FindResource(IntPtr h, IntPtr name, IntPtr type);
  [DllImport("kernel32.dll", CharSet=CharSet.Ansi, SetLastError=true)]
  public static extern IntPtr LoadResource(IntPtr h, IntPtr res);
  [DllImport("kernel32.dll", CharSet=CharSet.Ansi, SetLastError=true)]
  public static extern IntPtr LockResource(IntPtr res);
  [DllImport("kernel32.dll", CharSet=CharSet.Ansi, SetLastError=true)]
  public static extern uint SizeofResource(IntPtr h, IntPtr res);
}
'@

$dll = Resolve-Path 'extracted/x64/inpoutx64.dll'
$h = [ResX2]::LoadLibraryEx($dll, [IntPtr]::Zero, 2)
if ($h -eq [IntPtr]::Zero) { Write-Output ('LOADLIB_FAIL ' + [Runtime.InteropServices.Marshal]::GetLastWin32Error()); exit 1 }

function NameOf([IntPtr]$p) {
  if ($p -eq [IntPtr]::Zero) { return '#NULL' }
  if ([long]$p -gt 0xFFFF) { return [Runtime.InteropServices.Marshal]::PtrToStringAnsi($p) }
  return ('#' + [int]$p)
}

$types = New-Object System.Collections.ArrayList
$cbt = [ResX2+EnumResTypeProc]{
  param($hh, $type, $param)
  [void]$script:types.Add((NameOf $type))
  return $true
}
[void][ResX2]::EnumResourceTypes($h, $cbt, [IntPtr]::Zero)
Write-Output ('types: ' + (($types | ForEach-Object { $_ }) -join ', '))

foreach ($t in $types) {
  Write-Output ('--- type ' + $t + ' ---')
  $names = New-Object System.Collections.ArrayList
  # find the type pointer again: for standard types numeric, custom = string ptr; approximate by reusing index
  $cbn = [ResX2+EnumResNameProc]{
    param($hh, $type, $name, $param)
    [void]$script:names.Add((NameOf $name))
    return $true
  }
  # EnumResourceNames with type: use IS_INTRESOURCE mapping
  $tint = 0
  if (-not [int]::TryParse($t.TrimStart('#'), [ref]$tint)) { $tint = -1 }
  if ($tint -ge 0) {
    [void][ResX2]::EnumResourceNames($h, [IntPtr]$tint, $cbn, [IntPtr]::Zero)
  } else {
    $ptr = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($t)
    [void][ResX2]::EnumResourceNames($h, $ptr, $cbn, [IntPtr]::Zero)
    [Runtime.InteropServices.Marshal]::FreeHGlobal($ptr)
  }
  foreach ($n in $names) {
    # dump via FindResource
    $tint2 = 0
    if ([int]::TryParse($t.TrimStart('#'), [ref]$tint2) -and $tint2 -ge 0) { $tp = [IntPtr]$tint2 } else { $tp = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($t) }
    $nint = 0
    if ([int]::TryParse($n.TrimStart('#'), [ref]$nint) -and $nint -ge 0) { $np = [IntPtr]$nint } else { $np = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($n) }
    $res = [ResX2]::FindResource($h, $np, $tp)
    if ($res -ne [IntPtr]::Zero) {
      $size = [ResX2]::SizeofResource($h, $res)
      $ptr = [ResX2]::LockResource([ResX2]::LoadResource($h, $res))
      $buf = New-Object byte[] $size
      [Runtime.InteropServices.Marshal]::Copy($ptr, $buf, 0, $size)
      $head = ($buf[0..([Math]::Min(3, $size-1))] | ForEach-Object { $_.ToString('X2') }) -join ' '
      if ($n -ne '#NULL' -and -not $n.StartsWith('#')) { $outPath = 'extracted/x64/embedded_' + $t + '_' + $n + '.bin' } else { $outPath = 'extracted/x64/embedded_' + $t + '_' + $n + '.bin' }
      [IO.File]::WriteAllBytes((Join-Path (Get-Location) $outPath), $buf)
      Write-Output ('  ' + $t + '/' + $n + ' size=' + $size + ' head=' + $head)
    }
  }
}
