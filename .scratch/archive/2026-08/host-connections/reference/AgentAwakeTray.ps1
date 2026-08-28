$ErrorActionPreference = 'Stop'

function Write-TrayLog([string]$Message) {
    "$((Get-Date).ToString('s')) [tray] $Message" |
        Add-Content -LiteralPath (Join-Path $PSScriptRoot 'agent-awake.log') -Encoding utf8
}

# Single-instance guard: a second launch (e.g. WezTerm restart) exits silently.
$script:TrayMutex = New-Object System.Threading.Mutex($false, 'Local\AgentAwakeTray')
if (-not $script:TrayMutex.WaitOne(0)) { exit 0 }

# Any terminating error anywhere in the script lands in the log — the tray
# runs with a hidden window, so an unlogged crash would be invisible.
trap {
    $stack = ($_.ScriptStackTrace -split "`r?`n") -join ' <- '
    Write-TrayLog "Tray CRASHED: $($_.Exception.Message) | $stack"
    break
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$Port = 17777

function New-CircleIcon([System.Drawing.Color]$Color) {
    $bitmap = New-Object System.Drawing.Bitmap 32, 32
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush $Color
    $outline = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(80, 80, 80)), 2
    $graphics.FillEllipse($brush, 4, 4, 24, 24)
    $graphics.DrawEllipse($outline, 4, 4, 24, 24)
    $graphics.Dispose(); $brush.Dispose(); $outline.Dispose()
    return [System.Drawing.Icon]::FromHandle($bitmap.GetHicon())
}

function Get-ActiveAgents {
    try {
        $body = (Invoke-WebRequest -Uri "http://localhost:$Port/status" -UseBasicParsing -TimeoutSec 2).Content
        return @(($body | ConvertFrom-Json).activeAgents)
    } catch { return @() }
}

$form = New-Object System.Windows.Forms.Form
$form.WindowState = 'Minimized'
$form.ShowInTaskbar = $false
$form.Visible = $false

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Visible = $true
$idleIcon = New-CircleIcon ([System.Drawing.Color]::SlateGray)
$activeIcon = New-CircleIcon ([System.Drawing.Color]::LimeGreen)
$tray.Icon = $idleIcon

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$exit = $menu.Items.Add('Ukončit indikátor')
$exit.add_Click({ $tray.Visible = $false; $form.Close() })
$tray.ContextMenuStrip = $menu

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.add_Tick({
    $active = @(Get-ActiveAgents)
    if ($active.Count -gt 0) {
        $tray.Text = "Agent Awake: system awake - " + ($active -join ', ')
        $tray.Icon = $activeIcon
    } else {
        $tray.Text = 'Agent Awake: normal sleep allowed'
        $tray.Icon = $idleIcon
    }
})
$timer.Start()
Write-TrayLog 'Tray started.'
[System.Windows.Forms.Application]::Run($form)
Write-TrayLog 'Tray exited normally.'
