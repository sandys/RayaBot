<#
.SYNOPSIS
  Read-only survey of the Windows host: who are we, are we elevated, and which
  tools that matter for ESP32 work are installed.

.DESCRIPTION
  Called from WSL by scripts/01-survey-windows.sh. Changes nothing.

  Reports
    - user, elevation (admin or not), Windows + WSL versions
    - usbipd-win (USB passthrough into WSL; needs admin to install/bind)
    - a real Python (the WindowsApps "python.exe" is only a Store stub)
    - esptool, winget, git
    - USB-serial drivers present in the driver store (CH34x, CP210x, FTDI, usbser)
#>
$ErrorActionPreference = 'Continue'

function Find-Cmd([string]$name) {
  $c = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c) { $c.Source } else { 'MISSING' }
}

Write-Output '=== identity ==='
Write-Output ("  user:        " + (whoami))
Write-Output ("  userprofile: " + $env:USERPROFILE)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Output ("  elevated:    " + $isAdmin + "   (False => cannot install drivers / usbipd without a UAC prompt)")
$os = Get-CimInstance Win32_OperatingSystem
Write-Output ("  windows:     " + $os.Caption + " build " + $os.BuildNumber)

Write-Output ''
Write-Output '=== tools ==='
foreach ($t in 'usbipd', 'python', 'py', 'pip', 'esptool', 'esptool.py', 'winget', 'git') {
  Write-Output ('  {0,-12} {1}' -f $t, (Find-Cmd $t))
}

# The Store alias python.exe exists even when Python is not installed. Detect that.
$py = Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1
if ($py) {
  $len = (Get-Item $py.Source -ErrorAction SilentlyContinue).Length
  if ($py.Source -like '*WindowsApps*' -and $len -eq 0) {
    Write-Output '  note: python.exe is the 0-byte Microsoft Store alias, NOT a real interpreter'
  } else {
    $v = & $py.Source --version 2>&1
    Write-Output ("  python version: " + $v)
  }
}

Write-Output ''
Write-Output '=== USB-serial drivers in the driver store ==='
$drv = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
  Where-Object { $_.InfName -and ($_.DeviceName -match 'CH34|CH91|CP210|FTDI|USB Serial|USB-SERIAL|JTAG' -or $_.DriverProviderName -match 'wch|Silicon Lab|FTDI|Espressif') } |
  Select-Object DeviceName, DriverProviderName, DriverVersion, InfName -Unique
if ($drv) { $drv | Format-Table -AutoSize | Out-String -Width 200 | Write-Output }
else { Write-Output '  none bound to a device right now (usbser.sys for native ESP32-S3/C3 USB ships with Windows and needs no install)' }

Write-Output '=== WSL ==='
(wsl.exe --version) -replace "`0", '' | Where-Object { $_.Trim() } | ForEach-Object { Write-Output ("  " + $_.Trim()) }
