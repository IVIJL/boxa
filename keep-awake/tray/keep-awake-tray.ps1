$ErrorActionPreference = 'Stop'

function Write-TrayLog([string]$Message) {
    "$((Get-Date).ToString('s')) [tray] $Message" |
        Add-Content -LiteralPath (Join-Path $PSScriptRoot 'keep-awake-tray.log') -Encoding utf8
}

# A second logon task invocation exits without disturbing the existing tray.
$script:TrayMutex = New-Object System.Threading.Mutex($false, 'Local\BoxaKeepAwakeTray')
if (-not $script:TrayMutex.WaitOne(0)) { exit 0 }

# The tray has no visible console, so preserve every terminating failure nearby.
trap {
    $stack = ($_.ScriptStackTrace -split "`r?`n") -join ' <- '
    Write-TrayLog "Tray CRASHED: $($_.Exception.Message) | $stack"
    break
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$Port = if ($args.Count -gt 0) { [int]$args[0] } else { 17777 }
# Terminal mode passes the terminal's process name; the tray then lives only
# as long as that process (no icon once the terminal session ends).
$FollowProcess = if ($args.Count -gt 1) { [string]$args[1] } else { '' }

function New-CircleIcon([System.Drawing.Color]$Color) {
    $bitmap = New-Object System.Drawing.Bitmap 32, 32
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush $Color
    $outline = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(80, 80, 80)), 2
    $graphics.FillEllipse($brush, 4, 4, 24, 24)
    $graphics.DrawEllipse($outline, 4, 4, 24, 24)
    $graphics.Dispose()
    $brush.Dispose()
    $outline.Dispose()
    return [System.Drawing.Icon]::FromHandle($bitmap.GetHicon())
}

function Get-KeepAwakeStatus {
    try {
        $body = (Invoke-WebRequest -Uri "http://localhost:$Port/v1/status" -UseBasicParsing -TimeoutSec 2).Content
        return $body | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Get-HolderLabels($Status) {
    $labels = @()
    foreach ($holder in @($Status.activeHolders)) {
        $name = [string]$holder.agent
        if ($holder.session) { $name += "/$($holder.session)" }
        $labels += "$name ($($holder.remainingTTLSeconds)s)"
    }
    return $labels
}

function Set-TrayText([System.Windows.Forms.NotifyIcon]$Tray, [string]$Text) {
    # NotifyIcon.Text is limited to 63 characters on supported Windows versions.
    if ($Text.Length -gt 63) { $Text = $Text.Substring(0, 60) + '...' }
    $Tray.Text = $Text
}

$form = New-Object System.Windows.Forms.Form
$form.WindowState = 'Minimized'
$form.ShowInTaskbar = $false
$form.Visible = $false

$tray = New-Object System.Windows.Forms.NotifyIcon
$idleIcon = New-CircleIcon ([System.Drawing.Color]::SlateGray)
$busyIcon = New-CircleIcon ([System.Drawing.Color]::LimeGreen)
$tray.Icon = $idleIcon
$tray.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$quit = $menu.Items.Add('Quit Boxa keep-awake indicator')
$quit.add_Click({ $tray.Visible = $false; $form.Close() })
$tray.ContextMenuStrip = $menu

$update = {
    if ($FollowProcess -and -not (Get-Process -Name $FollowProcess -ErrorAction SilentlyContinue)) {
        Write-TrayLog "Followed process '$FollowProcess' exited; closing tray."
        $tray.Visible = $false
        $form.Close()
        return
    }
    $status = Get-KeepAwakeStatus
    if ($null -eq $status) {
        $tray.Icon = $idleIcon
        Set-TrayText $tray 'Boxa keep-awake: daemon unavailable'
    } elseif ([bool]$status.isInhibited) {
        $labels = @(Get-HolderLabels $status)
        $tray.Icon = $busyIcon
        Set-TrayText $tray ('Boxa keep-awake: busy - ' + ($labels -join ', '))
    } else {
        $tray.Icon = $idleIcon
        Set-TrayText $tray 'Boxa keep-awake: idle'
    }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.add_Tick($update)
& $update
$timer.Start()
Write-TrayLog 'Tray started.'
[System.Windows.Forms.Application]::Run($form)
$timer.Stop()
$tray.Visible = $false
Write-TrayLog 'Tray exited normally.'
$script:TrayMutex.ReleaseMutex()

