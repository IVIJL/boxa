# =============================================================================
# Install Docker graceful shutdown hook for Windows
# =============================================================================
# Registers docker-graceful-shutdown.ps1 as a Windows shutdown script via
# registry (works on Windows Home without gpedit.msc).
#
# Usage: Run as Administrator
#   powershell -ExecutionPolicy Bypass -File install-shutdown-hook.ps1

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

$scriptName = 'docker-graceful-shutdown.ps1'
$scriptSource = Join-Path $PSScriptRoot $scriptName
$installDir = 'C:\Scripts\boxa'
$scriptDest = Join-Path $installDir $scriptName

# Registry paths for shutdown scripts (equivalent to Group Policy)
$gpScripts = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\Scripts\Shutdown'
$gpState = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine\Scripts\Shutdown'

# Shutdown timeout registry (seconds) — gives shutdown scripts enough time
$shutdownTimeoutPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\gpsvc'
$maxWaitKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'

# --- Validate source ---
if (-not (Test-Path $scriptSource)) {
    Write-Error "Source script not found: $scriptSource"
    exit 1
}

# --- Install script file ---
Write-Host "Installing shutdown script to $installDir ..."
if (-not (Test-Path $installDir)) {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
}
Copy-Item -Path $scriptSource -Destination $scriptDest -Force
Write-Host "  Copied: $scriptDest"

# --- Find next available shutdown script slot ---
# Check existing entries and find next free index
$slotIndex = 0
if (Test-Path $gpScripts) {
    $existing = Get-ChildItem $gpScripts -ErrorAction SilentlyContinue
    if ($existing) {
        # Check if we already have our script installed
        foreach ($entry in $existing) {
            $subKeys = Get-ChildItem $entry.PSPath -ErrorAction SilentlyContinue
            foreach ($sub in $subKeys) {
                $existingScript = Get-ItemProperty $sub.PSPath -Name 'Script' -ErrorAction SilentlyContinue
                if ($existingScript -and $existingScript.Script -eq $scriptDest) {
                    Write-Host "`nShutdown hook is already installed." -ForegroundColor Yellow
                    Write-Host "  Script: $scriptDest"
                    Write-Host "  Registry: $($entry.PSPath)"
                    Write-Host "`nTo reinstall, run uninstall-shutdown-hook.ps1 first."
                    exit 0
                }
            }
        }
        $slotIndex = $existing.Count
    }
}

# --- Register in Group Policy Scripts registry ---
Write-Host "Registering shutdown script in registry (slot $slotIndex) ..."

$paths = @(
    "$gpScripts\$slotIndex",
    "$gpState\$slotIndex"
)

foreach ($basePath in $paths) {
    # Create the script group entry
    if (-not (Test-Path $basePath)) {
        New-Item -Path $basePath -Force | Out-Null
    }
    Set-ItemProperty -Path $basePath -Name 'GPO-ID' -Value 'LocalGPO' -Type String
    Set-ItemProperty -Path $basePath -Name 'SOM-ID' -Value 'Local' -Type String
    Set-ItemProperty -Path $basePath -Name 'FileSysPath' -Value "$env:SystemRoot\System32\GroupPolicy\Machine" -Type String
    Set-ItemProperty -Path $basePath -Name 'DisplayName' -Value 'Local Group Policy' -Type String
    Set-ItemProperty -Path $basePath -Name 'GPOName' -Value 'Local Group Policy' -Type String
    Set-ItemProperty -Path $basePath -Name 'PSScriptOrder' -Value 1 -Type DWord

    # Create the individual script entry (index 0 within this group)
    $scriptEntry = "$basePath\0"
    if (-not (Test-Path $scriptEntry)) {
        New-Item -Path $scriptEntry -Force | Out-Null
    }
    Set-ItemProperty -Path $scriptEntry -Name 'Script' -Value $scriptDest -Type String
    Set-ItemProperty -Path $scriptEntry -Name 'Parameters' -Value '' -Type String
    Set-ItemProperty -Path $scriptEntry -Name 'IsPowershell' -Value 1 -Type DWord
    Set-ItemProperty -Path $scriptEntry -Name 'ExecTime' -Value 0 -Type QWord
}

# --- Ensure shutdown timeout is sufficient ---
# WaitToKillServiceTimeout: time Windows waits for services during shutdown (ms)
# Default is 5000ms (5s), we set 30000ms (30s) to give the 15s docker stop + overhead
Write-Host 'Setting shutdown timeout to 30 seconds ...'
if (-not (Test-Path $maxWaitKey)) {
    New-Item -Path $maxWaitKey -Force | Out-Null
}

$svcTimeoutPath = 'HKLM:\SYSTEM\CurrentControlSet\Control'
$currentTimeout = Get-ItemProperty -Path $svcTimeoutPath -Name 'WaitToKillServiceTimeout' -ErrorAction SilentlyContinue
if (-not $currentTimeout -or [int]$currentTimeout.WaitToKillServiceTimeout -lt 30000) {
    Set-ItemProperty -Path $svcTimeoutPath -Name 'WaitToKillServiceTimeout' -Value '30000' -Type String
    Write-Host '  WaitToKillServiceTimeout set to 30000ms'
} else {
    Write-Host "  WaitToKillServiceTimeout already sufficient: $($currentTimeout.WaitToKillServiceTimeout)ms"
}

# --- Done ---
Write-Host ''
Write-Host 'Shutdown hook installed successfully!' -ForegroundColor Green
Write-Host ''
Write-Host 'What happens now:'
Write-Host '  - When Windows shuts down or restarts, the script will automatically'
Write-Host '    stop all running Docker containers gracefully before WSL2 terminates.'
Write-Host '  - Logs are written to: C:\Scripts\boxa\shutdown.log'
Write-Host ''
Write-Host 'To uninstall: Run uninstall-shutdown-hook.ps1 as Administrator'
