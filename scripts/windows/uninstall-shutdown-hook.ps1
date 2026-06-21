# =============================================================================
# Uninstall Docker graceful shutdown hook
# =============================================================================
# Removes the shutdown script and registry entries created by install-shutdown-hook.ps1.
#
# Usage: Run as Administrator
#   powershell -ExecutionPolicy Bypass -File uninstall-shutdown-hook.ps1

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

$scriptDest = 'C:\Scripts\boxa\docker-graceful-shutdown.ps1'
$installDir = 'C:\Scripts\boxa'

$gpScripts = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\Scripts\Shutdown'
$gpState = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine\Scripts\Shutdown'

$found = $false

# --- Remove registry entries ---
foreach ($basePath in @($gpScripts, $gpState)) {
    if (-not (Test-Path $basePath)) {
        continue
    }
    $entries = Get-ChildItem $basePath -ErrorAction SilentlyContinue
    foreach ($entry in $entries) {
        $subKeys = Get-ChildItem $entry.PSPath -ErrorAction SilentlyContinue
        foreach ($sub in $subKeys) {
            $prop = Get-ItemProperty $sub.PSPath -Name 'Script' -ErrorAction SilentlyContinue
            if ($prop -and $prop.Script -eq $scriptDest) {
                Write-Host "Removing registry entry: $($entry.PSPath)"
                Remove-Item -Path $entry.PSPath -Recurse -Force
                $found = $true
                break
            }
        }
    }
}

# --- Remove script file ---
if (Test-Path $scriptDest) {
    Remove-Item -Path $scriptDest -Force
    Write-Host "Removed script: $scriptDest"
    $found = $true
}

if ((Test-Path $installDir) -and -not (Get-ChildItem $installDir)) {
    Remove-Item -Path $installDir -Force
    Write-Host "Removed empty directory: $installDir"
}

# --- Result ---
if ($found) {
    Write-Host ''
    Write-Host 'Shutdown hook uninstalled successfully.' -ForegroundColor Green
} else {
    Write-Host 'Shutdown hook was not installed (nothing to remove).' -ForegroundColor Yellow
}
