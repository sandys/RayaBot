<#
.SYNOPSIS
  List USB devices and serial (COM) ports on the Windows host and flag anything
  that looks like an ESP32 board or a USB-serial bridge.

.DESCRIPTION
  Called from WSL by scripts/02-list-usb.sh. Read-only.

  An ESP32 board shows up on USB in one of these ways:
    303A:1001  Espressif "USB JTAG/serial debug unit"  - native USB of ESP32-S3/C3/C6
                                                         (used by both the running app and the ROM bootloader)
    303A:0009  ESP32-S3 ROM download mode over USB-OTG
    303A:0002  ESP32-S2 ROM download mode
    1A86:xxxx  WCH CH340 / CH343 / CH9102 USB-serial bridge chip
    10C4:EA60  Silicon Labs CP210x bridge chip
    0403:xxxx  FTDI bridge chip
  Any of them gets a COM port. If none is present the device is either not
  enumerating (charge-only cable, powered off, USB pins repurposed by firmware)
  or failed enumeration (shows as VID_0000&PID_0002 "Unknown USB Device").

.PARAMETER All
  Also list devices Windows remembers but which are not plugged in right now.
  Useful to learn whether the board was EVER seen by this PC.

.PARAMETER Watch
  Poll for this many seconds and print every arrival (+) and removal (-).
  Use it while (re)plugging the cable, or to catch a board that is boot-looping.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File list-usb.ps1
  powershell -ExecutionPolicy Bypass -File list-usb.ps1 -All
  powershell -ExecutionPolicy Bypass -File list-usb.ps1 -Watch 30
#>
param(
  [switch]$All,
  [int]$Watch = 0
)
$ErrorActionPreference = 'Continue'

$Known = @{
  '303A:1001' = 'ESP32 native USB-Serial/JTAG (S3/C3/C6) <-- flashable'
  '303A:0009' = 'ESP32-S3 ROM download mode (USB-OTG) <-- flashable'
  '303A:0002' = 'ESP32-S2 ROM download mode <-- flashable'
  '303A:4001' = 'Espressif TinyUSB device (firmware-defined)'
  '1A86:7523' = 'WCH CH340/CH341 USB-serial bridge <-- likely ESP32 board'
  '1A86:7522' = 'WCH CH340K USB-serial bridge <-- likely ESP32 board'
  '1A86:55D3' = 'WCH CH343 USB-serial bridge <-- likely ESP32 board'
  '1A86:55D4' = 'WCH CH9102 USB-serial bridge <-- likely ESP32 board'
  '10C4:EA60' = 'Silicon Labs CP210x USB-serial bridge <-- likely ESP32 board'
  '0403:6001' = 'FTDI FT232 USB-serial bridge'
  '0403:6010' = 'FTDI FT2232 dual serial/JTAG'
  '0403:6014' = 'FTDI FT232H'
  '0403:6015' = 'FTDI FT231X USB-serial bridge'
  '067B:2303' = 'Prolific PL2303 USB-serial bridge'
  '0000:0002' = 'FAILED USB ENUMERATION (cable / port / device not answering)'
}

function Get-Hint([string]$key, [string]$vid) {
  if ($key -and $Known.ContainsKey($key)) { return $Known[$key] }
  if ($vid -eq '303A') { return 'Espressif device (unlisted PID) <-- likely ESP32' }
  return ''
}

function Get-Arrival([string]$id) {
  try { (Get-PnpDeviceProperty -InstanceId $id -KeyName 'DEVPKEY_Device_LastArrivalDate' -ErrorAction Stop).Data }
  catch { $null }
}

function Get-Snapshot([bool]$includeAbsent, [bool]$withArrival) {
  $devs = if ($includeAbsent) { Get-PnpDevice } else { Get-PnpDevice -PresentOnly }
  $devs | Where-Object { $_.InstanceId -match '^USB\\' -or $_.Class -eq 'Ports' } | ForEach-Object {
    $vid = ''; $prod = ''
    if ($_.InstanceId -match 'VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})') {
      $vid = $Matches[1].ToUpper(); $prod = $Matches[2].ToUpper()
    }
    $key = if ($vid) { "${vid}:${prod}" } else { '' }
    $com = ''
    if ($_.FriendlyName -match '\((COM\d+)\)') { $com = $Matches[1] }
    [pscustomobject]@{
      Arrived    = if ($withArrival) { Get-Arrival $_.InstanceId } else { $null }
      VidPid     = $key
      COM        = $com
      Class      = $_.Class
      Status     = $_.Status
      Present    = $_.Present
      Name       = $_.FriendlyName
      Hint       = Get-Hint $key $vid
      InstanceId = $_.InstanceId
    }
  }
}

function Show-Table($rows) {
  $rows | Sort-Object @{ Expression = { $_.Arrived }; Descending = $true }, VidPid |
    Format-Table @{ n = 'Arrived'; e = { if ($_.Arrived) { $_.Arrived.ToString('MM-dd HH:mm:ss') } else { '' } } },
                 VidPid, COM, Class, Status, Present, Name, Hint -AutoSize |
    Out-String -Width 260 | ForEach-Object { $_.TrimEnd() } | Write-Output
}

if ($Watch -gt 0) {
  Write-Output "=== watching USB arrivals/removals for $Watch s (plug / unplug / press reset now) ==="
  $prev = @{}
  Get-Snapshot $false $false | ForEach-Object { $prev[$_.InstanceId] = $_ }
  Write-Output ("  baseline: {0} devices present" -f $prev.Count)
  $deadline = (Get-Date).AddSeconds($Watch)
  $events = 0
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 700
    $cur = @{}
    Get-Snapshot $false $false | ForEach-Object { $cur[$_.InstanceId] = $_ }
    foreach ($k in $cur.Keys) {
      if (-not $prev.ContainsKey($k)) {
        $d = $cur[$k]; $events++
        Write-Output ("  {0} + {1} {2} [{3}] {4} {5}" -f (Get-Date).ToString('HH:mm:ss'), $d.VidPid, $d.COM, $d.Status, $d.Name, $d.Hint)
      }
    }
    foreach ($k in $prev.Keys) {
      if (-not $cur.ContainsKey($k)) {
        $d = $prev[$k]; $events++
        Write-Output ("  {0} - {1} {2} {3}" -f (Get-Date).ToString('HH:mm:ss'), $d.VidPid, $d.COM, $d.Name)
      }
    }
    $prev = $cur
  }
  Write-Output ("  done: {0} hot-plug event(s) seen" -f $events)
  exit 0
}

$rows = @(Get-Snapshot $All.IsPresent $true)

Write-Output '=== serial (COM) ports ==='
$ports = @($rows | Where-Object { $_.Class -eq 'Ports' -and ($_.Present -or $All) })
if ($ports.Count) { Show-Table $ports } else { Write-Output '  none' }

Write-Output ''
$label = if ($All) { 'USB devices (present AND remembered)' } else { 'USB devices currently present' }
Write-Output "=== $label, newest arrival first ==="
$usb = @($rows | Where-Object { $_.InstanceId -match '^USB\\' })
if ($usb.Count) { Show-Table $usb } else { Write-Output '  none' }

if ($All) {
  Write-Output ''
  Write-Output '=== ESP32-like devices Windows REMEMBERS but that are not plugged in now ==='
  $old = @($rows | Where-Object { $_.Hint -match '<--' -and -not $_.Present })
  if ($old.Count) {
    Show-Table $old
    Write-Output '  => this PC has talked to such a device before; "Arrived" is the last time it enumerated.'
  } else {
    Write-Output '  none => no Espressif / CH34x / CP210x / FTDI device has EVER enumerated on this PC.'
    Write-Output '          (so the board has never completed a USB handshake here: cable, power or wiring)'
  }
}

Write-Output ''
Write-Output '=== verdict ==='
$cand = @($rows | Where-Object { $_.Hint -match '<--' -and $_.Present })
$failed = @($rows | Where-Object { $_.VidPid -eq '0000:0002' -and $_.Present })
$usbCom = @($rows | Where-Object { $_.Class -eq 'Ports' -and $_.Present -and $_.InstanceId -match '^USB\\' })
if ($cand.Count) {
  foreach ($c in $cand) { Write-Output ("  CANDIDATE: {0} {1} [{2}] {3} -- {4}" -f $c.VidPid, $c.COM, $c.Status, $c.Name, $c.Hint) }
} elseif ($usbCom.Count) {
  foreach ($c in $usbCom) { Write-Output ("  USB serial port with unrecognised bridge: {0} {1} {2}" -f $c.VidPid, $c.COM, $c.Name) }
} else {
  Write-Output '  NO ESP32-like USB device is visible to Windows right now.'
  if ($failed.Count) {
    Write-Output '  BUT a device is failing USB enumeration (VID_0000&PID_0002) - that is probably the board:'
    foreach ($f in $failed) { Write-Output ("    " + $f.InstanceId + "  status=" + $f.Status) }
  }
  Write-Output '  Things to check, in order:'
  Write-Output '    1. Cable: many USB-C cables are charge-only. Use one known to carry data.'
  Write-Output '    2. Power: slide the power switch on / make sure the battery board is awake.'
  Write-Output '    3. Port: plug straight into the PC, not through a hub or dock.'
  Write-Output '    4. Download mode: hold BOOT (GPIO0), tap RESET (or replug while holding BOOT).'
  Write-Output '    5. Re-run with -All to see whether Windows has EVER seen the board,'
  Write-Output '       and with -Watch 30 while replugging to see whether anything enumerates at all.'
}
