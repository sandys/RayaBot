<#
.SYNOPSIS
  Block until an ESP32-like USB device shows up on the Windows host, print what
  it is, and exit. Used to resume work automatically when the board is plugged in.

.DESCRIPTION
  Called from WSL by scripts/03-wait-for-device.sh.

  Two detectors run in a loop:
    fast (every poll)   HKLM\HARDWARE\DEVICEMAP\SERIALCOMM - the live list of serial
                        ports. A registry read, so it is nearly free. Bluetooth
                        ports (\Device\BthModem*) are ignored.
    slow (every ~10 s)  Get-PnpDevice scan for Espressif / WCH / SiLabs / FTDI /
                        Prolific vendor IDs, which also catches a board that is
                        present but has NO driver (so no COM port), and a board
                        that fails enumeration (VID_0000&PID_0002).

  Output (one line, machine-parsable, on success):
    FOUND   <VID:PID> <COMx> <status> <friendly name>
    NODRIVER <VID:PID> -    <status> <friendly name>     (device present, no COM port)
    ENUMFAIL 0000:0002 -    <status> <instance id>       (only with -ReportEnumFail)

  Exit codes: 0 found, 2 timeout.

.PARAMETER TimeoutSec
  Give up after this many seconds (default 3600).

.PARAMETER PollMs
  Fast-detector period in milliseconds (default 2000).

.PARAMETER ReportEnumFail
  Also stop when a device fails USB enumeration. Off by default because a
  flaky cable would otherwise end the wait before the board really works.
#>
param(
  [int]$TimeoutSec = 3600,
  [int]$PollMs = 2000,
  [switch]$ReportEnumFail
)
$ErrorActionPreference = 'SilentlyContinue'
$vendorRx = 'VID_(303A|1A86|10C4|0403|067B)&PID_([0-9A-Fa-f]{4})'

function Get-UsbSerialPorts {
  # name = kernel device (\Device\USBSER000, \Device\Serial2, \Device\Silabser0, \Device\VCP0 ...), value = COMx
  $out = @()
  $k = Get-Item 'HKLM:\HARDWARE\DEVICEMAP\SERIALCOMM'
  if ($k) {
    foreach ($n in $k.GetValueNames()) {
      if ($n -notmatch 'BthModem') { $out += [pscustomobject]@{ Kernel = $n; COM = $k.GetValue($n) } }
    }
  }
  $out
}

function Find-Candidates {
  Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match $vendorRx } | ForEach-Object {
    $null = $_.InstanceId -match 'VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})'
    $key = ($Matches[1] + ':' + $Matches[2]).ToUpper()
    $com = '-'
    if ($_.FriendlyName -match '\((COM\d+)\)') { $com = $Matches[1] }
    [pscustomobject]@{ Key = $key; COM = $com; Status = $_.Status; Name = $_.FriendlyName; Class = $_.Class; Id = $_.InstanceId }
  }
}

function Report-And-Exit($cands) {
  # Prefer the entry that owns a COM port (composite devices list several nodes).
  $withCom = @($cands | Where-Object { $_.COM -ne '-' })
  if ($withCom.Count) {
    foreach ($c in $withCom) { Write-Output ("FOUND {0} {1} {2} {3}" -f $c.Key, $c.COM, $c.Status, $c.Name) }
  } else {
    foreach ($c in $cands) { Write-Output ("NODRIVER {0} - {1} {2}" -f $c.Key, $c.Status, $c.Name) }
  }
  exit 0
}

$start = Get-Date
$deadline = $start.AddSeconds($TimeoutSec)
$slowEvery = [Math]::Max(1, [int](10000 / $PollMs))
$i = 0
Write-Output ("waiting up to {0}s for an ESP32-like USB device (started {1})" -f $TimeoutSec, $start.ToString('HH:mm:ss'))

while ((Get-Date) -lt $deadline) {
  $ports = @(Get-UsbSerialPorts)
  if ($ports.Count -or ($i % $slowEvery) -eq 0) {
    $cands = @(Find-Candidates)
    if ($cands.Count) {
      # Give Windows a moment to finish binding the driver so the COM name is present.
      Start-Sleep -Milliseconds 1500
      $again = @(Find-Candidates)
      if ($again.Count) { Report-And-Exit $again } else { Report-And-Exit $cands }
    }
    if ($ports.Count) {
      # A non-Bluetooth serial port exists but with an unknown vendor: report it anyway.
      foreach ($p in $ports) { Write-Output ("FOUND ????:???? {0} OK unknown-vendor serial port ({1})" -f $p.COM, $p.Kernel) }
      exit 0
    }
    if ($ReportEnumFail) {
      $bad = @(Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match 'VID_0000&PID_0002' })
      if ($bad.Count) {
        foreach ($b in $bad) { Write-Output ("ENUMFAIL 0000:0002 - {0} {1}" -f $b.Status, $b.InstanceId) }
        exit 0
      }
    }
  }
  if (($i % 150) -eq 0 -and $i -gt 0) {
    Write-Output ("  still waiting... {0}" -f (Get-Date).ToString('HH:mm:ss'))
  }
  $i++
  Start-Sleep -Milliseconds $PollMs
}
Write-Output ("TIMEOUT after {0}s - no ESP32-like device appeared" -f $TimeoutSec)
exit 2
