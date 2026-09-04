<#
.SYNOPSIS
  Arul on-device regression pass: install, drive the release build with Maestro, and assert the
  things only adb can see. One command, both accounts, a table at the end.

.DESCRIPTION
  Maestro drives the UI; this wrapper owns everything Maestro cannot observe - the wallpaper the OS
  actually holds, the ringtone rows, the audio focus stack, armed alarms, the crash buffer, the
  feed's re-open log and the bytes a browse costs. It also RECORDS the phone's state up front and
  puts the ringtone rows, permissions and airplane mode back. The wallpaper is left as applied; the
  owner sets it back.

  Never `pm clear` (that would sign the phone out and burn a fresh-install funnel) and never
  `adb install -d` (a downgrade over the fielded 20xx versionCode is refused anyway, and -d hides
  the refusal). Nothing here prints a token, an email body or a logcat line - counts only.

.EXAMPLE
  .\run.ps1 -Apk ..\..\build\app\outputs\flutter-apk\app-arm64-v8a-release.apk `
            -Free free@example.com -Premium premium@example.com
#>
[CmdletBinding()]
param(
    # The split-per-abi release APK to install. Omit with -SkipInstall to test what is on the phone.
    [string]$Apk,

    # Google account that is NOT premium. The pass starts and ENDS signed in as this one.
    [Parameter(Mandatory = $true)][string]$Free,

    # Google account that IS premium. Both must already exist on the phone; the rig never adds one.
    [Parameter(Mandatory = $true)][string]$Premium,

    # adb serial. Defaults to the only connected device.
    [string]$Serial = '',

    # Path to maestro.bat, if it is not on PATH.
    [string]$MaestroBin = '',

    [switch]$SkipInstall,

    # Parse and syntax-check the flows without touching a device, then exit.
    [switch]$NoDevice
)

$ErrorActionPreference = 'Continue'
$PkgId = 'com.hsrutility.arul'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$FlowDir = Join-Path $Root 'maestro'
$Results = New-Object System.Collections.ArrayList
$StartedAt = Get-Date

# Maestro phones home and prints a banner otherwise; neither belongs in a regression log.
$env:MAESTRO_CLI_NO_ANALYTICS = '1'
$env:MAESTRO_CLI_ANALYSIS_NOTIFICATION_DISABLED = 'true'

# ---------------------------------------------------------------- plumbing

function Resolve-Maestro {
    if ($MaestroBin) { return $MaestroBin }
    $c = Get-Command 'maestro.bat' -ErrorAction SilentlyContinue
    if ($null -ne $c) { return $c.Source }
    $c = Get-Command 'maestro' -ErrorAction SilentlyContinue
    if ($null -ne $c) { return $c.Source }
    $guess = 'C:\Users\{0}\maestro-cli\maestro\bin\maestro.bat' -f $env:USERNAME
    if (Test-Path $guess) { return $guess }
    throw 'maestro not found. Install it (see README) or pass -MaestroBin.'
}
$Maestro = Resolve-Maestro

function Adb {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$AdbArgs)
    $a = @()
    if ($Serial) { $a += @('-s', $Serial) }
    $a += $AdbArgs
    & adb @a
}

# One shell line. Quoting is the caller's job - the phone's shell eats `&` and splits on spaces.
function Sh { param([string]$Cmd) Adb 'shell' $Cmd }

function Note {
    param([string]$Check, [string]$Result, [string]$Detail = '')
    $null = $Results.Add([pscustomobject]@{ Check = $Check; Result = $Result; Detail = $Detail })
    $colour = 'Gray'
    if ($Result -eq 'PASS') { $colour = 'Green' }
    if ($Result -eq 'FAIL') { $colour = 'Red' }
    if ($Result -eq 'MANUAL') { $colour = 'Yellow' }
    Write-Host ('{0,-30} {1,-7} {2}' -f $Check, $Result, $Detail) -ForegroundColor $colour
}

function Invoke-Flow {
    param([string]$Name, [hashtable]$FlowEnv = @{})
    $a = @('test')
    if ($Serial) { $a += @('--device', $Serial) }
    foreach ($k in $FlowEnv.Keys) { $a += @('-e', ('{0}={1}' -f $k, $FlowEnv[$k])) }
    $a += (Join-Path $FlowDir ($Name + '.yaml'))
    $t0 = Get-Date
    & $Maestro @a | Out-Host
    $code = $LASTEXITCODE
    $secs = [int]((Get-Date) - $t0).TotalSeconds
    if ($code -eq 0) { Note ('flow ' + $Name) 'PASS' ("{0}s" -f $secs) }
    else { Note ('flow ' + $Name) 'FAIL' ("exit {0} after {1}s" -f $code, $secs) }
    return ($code -eq 0)
}

function Check-Syntax {
    $bad = 0
    Get-ChildItem (Join-Path $FlowDir '*.yaml') | ForEach-Object {
        $out = & $Maestro check-syntax $_.FullName
        if ($LASTEXITCODE -ne 0) { $bad++; Write-Host ('FAIL ' + $_.Name) -ForegroundColor Red; Write-Host $out }
    }
    if ($bad -eq 0) { Note 'flow syntax' 'PASS' ('{0} files' -f (Get-ChildItem (Join-Path $FlowDir '*.yaml')).Count) }
    else { Note 'flow syntax' 'FAIL' ("$bad files") }
    return ($bad -eq 0)
}

if ($NoDevice) {
    $ok = Check-Syntax
    $Results | Format-Table -AutoSize
    if ($ok) { exit 0 } else { exit 1 }
}

# ---------------------------------------------------------------- device probes

function Get-WallpaperState {
    $d = (Sh 'dumpsys wallpaper') -join "`n"
    # mWallpaperId bumps on every commit; the component tells a live service from the image one.
    $ids = [regex]::Matches($d, 'mWallpaperId=\s*(-?\d+)') | ForEach-Object { $_.Groups[1].Value }
    $cmp = [regex]::Matches($d, 'ComponentInfo\{([^}]+)\}') | ForEach-Object { $_.Groups[1].Value }
    return [pscustomobject]@{
        Ids       = ($ids -join ',')
        Component = (($cmp | Select-Object -Unique) -join ',')
    }
}

# Loose on the name, per ringtones.md: OEM skins carry oplus_/vivo_ per-SIM rows next to the AOSP
# one, and only the provider knows their names.
function Get-RingtoneRows {
    $rows = Sh 'settings list system'
    $out = @{}
    foreach ($line in $rows) {
        if ($line -match '^([A-Za-z0-9_.]*[Rr]ingtone[A-Za-z0-9_.]*)=(.*)$') {
            $out[$Matches[1]] = $Matches[2]
        }
    }
    return $out
}

function Get-NotificationPermission {
    $d = (Sh ('dumpsys package ' + $PkgId)) -join "`n"
    if ($d -match 'android\.permission\.POST_NOTIFICATIONS:\s*granted=true') { return 'granted' }
    return 'denied'
}

function Get-WriteSettingsOp {
    $d = (Sh ('appops get ' + $PkgId + ' WRITE_SETTINGS')) -join ' '
    if ($d -match 'allow') { return 'allow' }
    if ($d -match 'ignore') { return 'ignore' }
    if ($d -match 'deny') { return 'deny' }
    return 'default'
}

function Get-AirplaneMode { return ((Sh 'settings get global airplane_mode_on') -join '').Trim() }

function Get-RxBytes {
    $v = (Sh 'cat /sys/class/net/wlan0/statistics/rx_bytes') -join ''
    if ($v -match '^\d+$') { return [int64]$v }
    return -1
}

function Get-AlarmCount {
    $d = Sh 'dumpsys alarm'
    return (($d | Select-String -SimpleMatch $PkgId) | Measure-Object).Count
}

function Get-AudioFocusForApp {
    $d = Sh 'dumpsys audio'
    return ($d | Select-String -SimpleMatch $PkgId | ForEach-Object { $_.Line.Trim() })
}

# ---------------------------------------------------------------- preflight

if (-not $Serial) {
    $devs = (& adb devices) | Select-String -Pattern '^\S+\s+device$'
    if ($devs.Count -eq 0) { throw 'no device. Plug the phone in and authorise adb.' }
    if ($devs.Count -gt 1) { throw 'more than one device; pass -Serial.' }
    $Serial = ($devs[0].Line -split '\s+')[0]
}
Write-Host ('device: {0}' -f $Serial) -ForegroundColor Cyan
$null = Check-Syntax

if (-not $SkipInstall) {
    if (-not $Apk) { throw 'pass -Apk, or -SkipInstall to run against what is on the phone.' }
    if (-not (Test-Path $Apk)) { throw ('no such APK: ' + $Apk) }
    Write-Host ('installing {0}' -f (Split-Path -Leaf $Apk)) -ForegroundColor Cyan
    # -r only. NEVER -d: a debug build's flat versionCode is a downgrade over the fielded 20xx one
    # and must be allowed to fail loudly rather than be forced through.
    $out = Adb 'install' '-r' $Apk
    if ($LASTEXITCODE -ne 0) { Note 'install' 'FAIL' (($out | Select-Object -Last 1) -join '') ; $Results | Format-Table -AutoSize; exit 1 }
    Note 'install' 'PASS' '-r'
}

# ---------------------------------------------------------------- record the phone's state

Write-Host 'recording device state' -ForegroundColor Cyan
$OrigWallpaper = Get-WallpaperState
$OrigRingtones = Get-RingtoneRows
$OrigNotif = Get-NotificationPermission
$OrigWriteSettings = Get-WriteSettingsOp
$OrigAirplane = Get-AirplaneMode
Write-Host ('  wallpaper: ids={0} component={1}' -f $OrigWallpaper.Ids, $OrigWallpaper.Component)
Write-Host ('  ringtone rows: {0}' -f $OrigRingtones.Count)
Write-Host ('  POST_NOTIFICATIONS={0}  WRITE_SETTINGS={1}  airplane={2}' -f $OrigNotif, $OrigWriteSettings, $OrigAirplane)

# Set is the thing under test, not the grant deep-link, so the appop goes in up front and comes
# back out at the end.
$null = Sh ('appops set ' + $PkgId + ' WRITE_SETTINGS allow')

# A crash buffer that already held yesterday's stack would fail this run for last week's bug.
$null = Adb 'logcat' '-b' 'crash' '-c'
$null = Adb 'logcat' '-b' 'main' '-c'

# ---------------------------------------------------------------- the pass

$AllOk = $true
function Step { param([string]$Name, [hashtable]$FlowEnv = @{})
    $ok = Invoke-Flow $Name $FlowEnv
    if (-not $ok) { $script:AllOk = $false }
    return $ok
}

# --- FREE account -------------------------------------------------------
# The rig assumes the phone is already signed in (any account) - it never signs in from cold,
# because the first sign-in on a fresh install is a funnel event, not a test fixture.
Write-Host "`n=== FREE: $Free ===" -ForegroundColor Cyan
$null = Step 'signout_signin' @{ ACCOUNT_EMAIL = $Free }
$null = Step 'launch'

# Bytes per card: the prefetch look-ahead is what regresses, so the number is the assertion.
$rx0 = Get-RxBytes
$null = Step 'feed_browse'
$rx1 = Get-RxBytes
if ($rx0 -ge 0 -and $rx1 -ge $rx0) {
    $perCard = [math]::Round((($rx1 - $rx0) / 8.0) / 1024.0, 1)
    Note 'wlan0 rx per card' 'INFO' ('{0} KiB over 8 cards' -f $perCard)
} else {
    Note 'wlan0 rx per card' 'MANUAL' 'no wlan0 counter (Wi-Fi off, or a non-wlan0 interface)'
}

# One re-open is a retried open; a stream of them is the pool disposing and recreating players.
$reopens = (Adb 'logcat' '-b' 'main' '-d' | Select-String -Pattern 'FeedVideo:.*re-open' | Measure-Object).Count
if ($reopens -eq 0) { Note 'FeedVideo re-open' 'PASS' '0' } else { Note 'FeedVideo re-open' 'FAIL' ("{0} re-opens" -f $reopens) }

$null = Step 'paywall_free'

# Audio focus: sampled WHILE a preview holds it, which is the only moment it is readable.
$null = Step 'preview_focus'
$focusPlaying = Get-AudioFocusForApp
$transient = ($focusPlaying | Select-String -SimpleMatch 'GAIN_TRANSIENT' | Measure-Object).Count
$permanent = ($focusPlaying | Select-String -Pattern 'GAIN(?!_TRANSIENT)' | Measure-Object).Count
if ($transient -gt 0 -and $permanent -eq 0) { Note 'audio focus (playing)' 'PASS' 'GAIN_TRANSIENT only' }
else { Note 'audio focus (playing)' 'FAIL' ("transient={0} other-gain={1}" -f $transient, $permanent) }

$null = Step 'preview_stop'
$focusIdle = Get-AudioFocusForApp
$stillHeld = ($focusIdle | Select-String -SimpleMatch 'GAIN' | Measure-Object).Count
if ($stillHeld -eq 0) { Note 'audio focus (idle)' 'PASS' 'abandoned' }
else { Note 'audio focus (idle)' 'FAIL' ("{0} entries still held" -f $stillHeld) }

$null = Step 'policy_offline'

$alarmsBefore = Get-AlarmCount
$null = Step 'reminders_permission'
$alarmsAfter = Get-AlarmCount
# The flow turns reminders on, then off again, so the pass must not leave alarms armed.
if ($alarmsAfter -le $alarmsBefore) { Note 'alarms disarmed' 'PASS' ("{0} -> {1}" -f $alarmsBefore, $alarmsAfter) }
else { Note 'alarms disarmed' 'FAIL' ("{0} -> {1}" -f $alarmsBefore, $alarmsAfter) }

$null = Step 'process_death'

# --- PREMIUM account ----------------------------------------------------
Write-Host "`n=== PREMIUM: $Premium ===" -ForegroundColor Cyan
$null = Step 'signout_signin' @{ ACCOUNT_EMAIL = $Premium }

$wpBefore = Get-WallpaperState
$null = Step 'apply_static'
$wpStatic = Get-WallpaperState
if ($wpStatic.Ids -ne $wpBefore.Ids) { Note 'wallpaper: static apply' 'PASS' ('ids {0} -> {1}' -f $wpBefore.Ids, $wpStatic.Ids) }
else { Note 'wallpaper: static apply' 'FAIL' ('ids unchanged: ' + $wpBefore.Ids) }

$null = Step 'apply_live'
$wpLive = Get-WallpaperState
if ($wpLive.Component -match [regex]::Escape($PkgId)) { Note 'wallpaper: live service' 'PASS' $wpLive.Component }
else { Note 'wallpaper: live service' 'FAIL' ('component=' + $wpLive.Component + ' (the chooser is a USER decision; a cancel lands here too)') }

$rtBefore = Get-RingtoneRows
$null = Step 'set_ringtone'
$rtAfter = Get-RingtoneRows
$changed = @()
foreach ($k in $rtAfter.Keys) {
    $was = ''
    if ($rtBefore.ContainsKey($k)) { $was = $rtBefore[$k] }
    if ($rtAfter[$k] -ne $was) { $changed += $k }
}
if ($changed.Count -gt 0) { Note 'ringtone rows changed' 'PASS' (($changed -join ', ')) }
else { Note 'ringtone rows changed' 'FAIL' 'no system ringtone row moved' }
if ($rtAfter.Count -eq $rtBefore.Count) { Note 'ringtone row count' 'PASS' ("{0}" -f $rtAfter.Count) }
else { Note 'ringtone row count' 'FAIL' ("{0} -> {1}; a set must never add or drop a row" -f $rtBefore.Count, $rtAfter.Count) }

$null = Step 'share'

# --- back to FREE, which is where the phone is left ----------------------
Write-Host "`n=== back to FREE ===" -ForegroundColor Cyan
$null = Step 'signout_signin' @{ ACCOUNT_EMAIL = $Free }
$null = Step 'launch'

# ---------------------------------------------------------------- restore

Write-Host "`nrestoring device state" -ForegroundColor Cyan

# Airplane off, always - a failed flow must never leave the phone dark.
if ((Get-AirplaneMode) -ne $OrigAirplane) {
    $null = Sh 'cmd connectivity airplane-mode disable'
    Start-Sleep -Seconds 3
}
if ((Get-AirplaneMode) -eq $OrigAirplane) { Note 'restore: airplane' 'PASS' ('=' + $OrigAirplane) }
else { Note 'restore: airplane' 'FAIL' ('wanted ' + $OrigAirplane) }

# Ringtone rows, every one that moved, by name - the names are OEM-private, so they are replayed
# rather than guessed.
$restored = 0
foreach ($k in $OrigRingtones.Keys) {
    $v = $OrigRingtones[$k]
    if ($rtAfter.ContainsKey($k) -and $rtAfter[$k] -eq $v) { continue }
    if ([string]::IsNullOrWhiteSpace($v) -or $v -eq 'null') { continue }
    $null = Sh ("settings put system {0} '{1}'" -f $k, $v)
    $restored++
}
$rtNow = Get-RingtoneRows
$stillOff = 0
foreach ($k in $OrigRingtones.Keys) {
    if (-not $rtNow.ContainsKey($k)) { $stillOff++; continue }
    if ($rtNow[$k] -ne $OrigRingtones[$k]) { $stillOff++ }
}
if ($stillOff -eq 0) { Note 'restore: ringtone' 'PASS' ("{0} rows put back" -f $restored) }
else { Note 'restore: ringtone' 'FAIL' ("{0} rows still differ" -f $stillOff) }

# Permissions.
if ($OrigNotif -eq 'granted') { $null = Sh ('pm grant ' + $PkgId + ' android.permission.POST_NOTIFICATIONS') }
else { $null = Sh ('pm revoke ' + $PkgId + ' android.permission.POST_NOTIFICATIONS') }
if ((Get-NotificationPermission) -eq $OrigNotif) { Note 'restore: notifications' 'PASS' $OrigNotif }
else { Note 'restore: notifications' 'FAIL' ('wanted ' + $OrigNotif) }

$null = Sh ('appops set ' + $PkgId + ' WRITE_SETTINGS ' + $OrigWriteSettings)
if ((Get-WriteSettingsOp) -eq $OrigWriteSettings) { Note 'restore: WRITE_SETTINGS' 'PASS' $OrigWriteSettings }
else { Note 'restore: WRITE_SETTINGS' 'FAIL' ('wanted ' + $OrigWriteSettings) }

# The wallpaper is left as applied; the owner sets it back. Recorded and printed so the
# before-state is not lost - never restored here, and never prompted for.
$wpNow = Get-WallpaperState
Note 'wallpaper' 'INFO' ('left as applied; was ids={0} component={1}' -f $OrigWallpaper.Ids, $OrigWallpaper.Component)

# ---------------------------------------------------------------- final assertions

$crash = Adb 'logcat' '-b' 'crash' '-d'
$crashLines = ($crash | Select-String -SimpleMatch $PkgId | Measure-Object).Count
if ($crashLines -eq 0) { Note 'logcat -b crash' 'PASS' 'empty for this package' }
else { Note 'logcat -b crash' 'FAIL' ("{0} lines - read them with: adb -s {1} logcat -b crash -d" -f $crashLines, $Serial) }

$alarmsEnd = Get-AlarmCount
Note 'dumpsys alarm entries' 'INFO' ("{0}" -f $alarmsEnd)

# ---------------------------------------------------------------- table

$elapsed = (Get-Date) - $StartedAt
Write-Host "`n================ RESULT ================" -ForegroundColor Cyan
$Results | Format-Table -AutoSize
$fails = ($Results | Where-Object { $_.Result -eq 'FAIL' }).Count
$manual = ($Results | Where-Object { $_.Result -eq 'MANUAL' }).Count
Write-Host ('wall clock: {0:hh\:mm\:ss}   FAIL={1}  MANUAL={2}' -f $elapsed, $fails, $manual) -ForegroundColor Cyan
Write-Host ('phone left: signed in as {0}, on the feed, Wi-Fi on, reminders off, wallpaper as applied.' -f $Free)

if ($fails -gt 0) { exit 1 }
exit 0
