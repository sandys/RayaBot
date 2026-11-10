<#
.SYNOPSIS
  Show the Windows sleep settings and, optionally, hold the PC awake for N hours
  without changing any of them.

.DESCRIPTION
  Called from WSL by scripts/04-keep-awake.sh.

  Long unattended jobs (firmware builds, flash dumps, overnight device tests) die
  if the laptop idles into sleep: WSL is frozen and the USB port is powered down.

  This script asks Windows to stay awake the same way a video player does:
  SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED). The request lives
  only as long as this process. When it exits (time is up, Ctrl-C, killed) the
  normal power plan applies again by itself. Nothing is written to the power plan,
  no admin rights are needed.

  It does NOT prevent: closing the lid, pressing the power button, hibernation on
  critical battery. The display is still allowed to turn off.

.PARAMETER Hours
  How long to hold the request (default 10).

.PARAMETER ShowOnly
  Print the power source and sleep timeouts, then exit without holding anything.
#>
param(
  [double]$Hours = 10,
  [switch]$ShowOnly
)
$ErrorActionPreference = 'Continue'

function Show-PowerState {
  Write-Output '=== power source ==='
  $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($bat) {
    # BatteryStatus: 1 = discharging (on battery), 2 = on AC, 3..9 = charging/other AC states
    $src = if ($bat.BatteryStatus -eq 1) { 'BATTERY (discharging)' } else { 'AC (status ' + $bat.BatteryStatus + ')' }
    Write-Output ("  {0}, charge {1}%" -f $src, $bat.EstimatedChargeRemaining)
  } else {
    Write-Output '  no battery reported (desktop or AC only)'
  }

  Write-Output ''
  Write-Output '=== idle timeouts in the active power plan (seconds, 0 = never) ==='
  foreach ($item in @(
      @{ n = 'sleep after   '; sub = 'SUB_SLEEP'; set = 'STANDBYIDLE' },
      @{ n = 'hibernate after'; sub = 'SUB_SLEEP'; set = 'HIBERNATEIDLE' },
      @{ n = 'display off    '; sub = 'SUB_VIDEO'; set = 'VIDEOIDLE' })) {
    $q = powercfg /query SCHEME_CURRENT $item.sub $item.set 2>$null
    $ac = Get-PowerIndex $q 'AC'
    $dc = Get-PowerIndex $q 'DC'
    Write-Output ("  {0}  on AC: {1,6}   on battery: {2,6}" -f $item.n, $(if ($null -ne $ac) { $ac } else { '?' }), $(if ($null -ne $dc) { $dc } else { '?' }))
  }
  # The lid setting is hidden on some machines (Modern Standby); then powercfg prints nothing.
  $lid = powercfg /query SCHEME_CURRENT SUB_BUTTONS LIDACTION 2>$null
  $lidAc = Get-PowerIndex $lid 'AC'
  $lidName = @{ 0 = 'do nothing'; 1 = 'sleep'; 2 = 'hibernate'; 3 = 'shut down' }
  if ($null -ne $lidAc) { Write-Output ("  lid close on AC: {0}" -f $lidName[[int]$lidAc]) }
  else { Write-Output '  lid close on AC: not exposed by this power plan (assume it sleeps - keep the lid open)' }
}

# Pull "Current AC|DC Power Setting Index: 0x..." out of powercfg /query output; $null if absent.
function Get-PowerIndex($text, [string]$kind) {
  if (-not $text) { return $null }
  $m = $text | Select-String ("Current {0} Power Setting Index:\s*(0x[0-9a-fA-F]+)" -f $kind) | Select-Object -First 1
  if ($m) { return [Convert]::ToInt32($m.Matches[0].Groups[1].Value, 16) }
  return $null
}

Show-PowerState
if ($ShowOnly) { exit 0 }

$sig = '[DllImport("kernel32.dll", SetLastError = true)] public static extern uint SetThreadExecutionState(uint esFlags);'
$api = Add-Type -MemberDefinition $sig -Name 'Power' -Namespace 'XzKeepAwake' -PassThru
$ES_CONTINUOUS_SYSTEM = [uint32]2147483649   # 0x80000000 ES_CONTINUOUS | 0x1 ES_SYSTEM_REQUIRED
$ES_CONTINUOUS_ONLY = [uint32]2147483648     # clears the request

$prev = $api::SetThreadExecutionState($ES_CONTINUOUS_SYSTEM)
if ($prev -eq 0) {
  Write-Output 'ERROR: SetThreadExecutionState failed; the PC may still go to sleep'
  exit 1
}

$until = (Get-Date).AddHours($Hours)
Write-Output ''
Write-Output ("=== holding the PC awake until {0} ({1} h) - pid {2} ===" -f $until.ToString('yyyy-MM-dd HH:mm'), $Hours, $PID)
Write-Output '  (stop this process to release the request early)'
try {
  $n = 0
  while ((Get-Date) -lt $until) {
    Start-Sleep -Seconds 60
    $n++
    if (($n % 60) -eq 0) { Write-Output ("  still holding... {0}" -f (Get-Date).ToString('HH:mm')) }
  }
} finally {
  $null = $api::SetThreadExecutionState($ES_CONTINUOUS_ONLY)
  Write-Output ("released at {0}" -f (Get-Date).ToString('HH:mm'))
}
