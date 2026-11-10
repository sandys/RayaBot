<#
.SYNOPSIS
  Capture the ESP32's serial console for a fixed time (optionally resetting the
  chip first) and save it to a file. A non-interactive "serial monitor".

.DESCRIPTION
  Called from WSL by scripts/25-serial-capture.sh.

  Uses .NET's System.IO.Ports.SerialPort, which ships with Windows PowerShell, so
  nothing has to be installed.

  Reset handling (the board's USB port is the ESP32-S3's built-in USB-Serial/JTAG,
  which turns the virtual RTS line into the chip's reset):
    -Reset run    open the port FIRST, then pulse RTS with DTR low. The chip restarts
                  into the application while we are already listening, so the boot
                  log is captured from the ROM banner onward.
    -Reset none   just listen to whatever the running program prints.

  The loop tolerates the COM port vanishing and coming back (USB re-enumeration
  after a crash, a deep-sleep wake, or a firmware that restarts its USB stack):
  it closes, waits and reopens until the time is up.

  Output: every byte is written unchanged to -OutFile. A readable copy (ANSI colour
  codes removed) is echoed to stdout unless -Quiet is given.

.PARAMETER Port       COM port, e.g. COM11.
.PARAMETER Seconds    How long to capture (default 20).
.PARAMETER OutFile    Windows path of the raw capture file.
.PARAMETER Reset      'run' or 'none' (default 'none').
.PARAMETER Until      Regex; stop early once the captured text matches it.
.PARAMETER Baud       Baud rate (default 115200; ignored by USB-Serial/JTAG, matters for UART bridges).
.PARAMETER Send       Text to write to the port after -SendAfter seconds (a newline is appended).
.PARAMETER SendAfter  Seconds to wait before -Send (default 5).
.PARAMETER Quiet      Do not echo the console to stdout.

.OUTPUTS
  Exit code 0 = captured something, 3 = port could never be opened, 4 = nothing received.
#>
param(
  [Parameter(Mandatory = $true)][string]$Port,
  [int]$Seconds = 20,
  [Parameter(Mandatory = $true)][string]$OutFile,
  [ValidateSet('run', 'none')][string]$Reset = 'none',
  [string]$Until = '',
  [int]$Baud = 115200,
  [string]$Send = '',
  [int]$SendAfter = 5,
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'

function Open-Port {
  $p = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
  $p.ReadTimeout = 200
  $p.WriteTimeout = 1000
  $p.ReadBufferSize = 1048576
  $p.DtrEnable = $false
  $p.RtsEnable = $false
  $p.Open()
  return $p
}

function Reset-IntoApp($p) {
  # Same sequence esptool uses for "hard reset" over USB-Serial/JTAG:
  # DTR low (do not request download mode), RTS high = hold reset, RTS low = release.
  $p.DtrEnable = $false
  $p.RtsEnable = $true
  Start-Sleep -Milliseconds 200
  $p.RtsEnable = $false
  Start-Sleep -Milliseconds 200
}

$ansi = [regex]'\x1b\[[0-9;]*[A-Za-z]'
$fs = [System.IO.File]::Open($OutFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
$deadline = (Get-Date).AddSeconds($Seconds)
$started = Get-Date
$buf = New-Object byte[] 65536
$total = 0
$opened = $false
$didReset = $false
$didSend = $false
$reopens = 0
$text = New-Object System.Text.StringBuilder
$pending = ''
$sp = $null
$stopReason = 'time is up'

try {
  while ((Get-Date) -lt $deadline) {
    if ($null -eq $sp) {
      try {
        $sp = Open-Port
        if ($opened) { $reopens++; if (-not $Quiet) { Write-Output ("[capture] port reopened at +{0:n1}s" -f ((Get-Date) - $started).TotalSeconds) } }
        $opened = $true
        if ($Reset -eq 'run' -and -not $didReset) {
          Reset-IntoApp $sp
          $didReset = $true
          if (-not $Quiet) { Write-Output '[capture] reset pulse sent (RTS), listening...' }
        }
      } catch {
        $sp = $null
        Start-Sleep -Milliseconds 300
        continue
      }
    }

    try {
      if ($Send -and -not $didSend -and ((Get-Date) - $started).TotalSeconds -ge $SendAfter) {
        $sp.Write($Send + "`n")
        $didSend = $true
        if (-not $Quiet) { Write-Output ("[capture] sent: " + $Send) }
      }
      $n = 0
      if ($sp.BytesToRead -gt 0) {
        $n = $sp.Read($buf, 0, [Math]::Min($buf.Length, $sp.BytesToRead))
      } else {
        Start-Sleep -Milliseconds 40
      }
      if ($n -gt 0) {
        $fs.Write($buf, 0, $n)
        $total += $n
        $chunk = [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
        $clean = $ansi.Replace($chunk, '')
        [void]$text.Append($clean)
        if (-not $Quiet) {
          # Emit whole lines only, so stdout is not chopped mid-line.
          $pending += $clean
          $idx = $pending.LastIndexOf("`n")
          if ($idx -ge 0) {
            $out = $pending.Substring(0, $idx)
            $pending = $pending.Substring($idx + 1)
            foreach ($line in ($out -split "`n")) { Write-Output ($line.TrimEnd("`r")) }
          }
        }
        if ($Until -and $text.ToString() -match $Until) { $stopReason = "matched /$Until/"; break }
      }
    } catch [System.TimeoutException] {
      # nothing to read right now
    } catch {
      # Port went away (device reset its USB, unplugged, deep sleep). Close and retry.
      if (-not $Quiet) { Write-Output ("[capture] port error at +{0:n1}s: {1}" -f ((Get-Date) - $started).TotalSeconds, $_.Exception.Message) }
      try { $sp.Close() } catch {}
      $sp = $null
      Start-Sleep -Milliseconds 300
    }
  }
} finally {
  if ($sp) { try { $sp.Close() } catch {} }
  $fs.Flush(); $fs.Close()
}

if (-not $Quiet -and $pending) { Write-Output $pending.TrimEnd("`r") }
Write-Output ("[capture] {0} bytes in {1:n1}s, {2} reopen(s), stopped because {3}" -f $total, ((Get-Date) - $started).TotalSeconds, $reopens, $stopReason)
if (-not $opened) { Write-Output "[capture] ERROR: could not open $Port at any point"; exit 3 }
if ($total -eq 0) { exit 4 }
exit 0
