# =============================================================================
# Graceful Docker shutdown — runs as Windows shutdown script
# =============================================================================
# Stops all running Docker containers before Windows terminates WSL2.
# Without this, WSL2 VM is killed abruptly and containers exit with code 255.
#
# Install: Run install-shutdown-hook.ps1 as Administrator
# Log:     C:\Scripts\boxa\shutdown.log

$ErrorActionPreference = 'Continue'
$StopTimeout = 15

$logDir = 'C:\Scripts\boxa'
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$logFile = Join-Path $logDir 'shutdown.log'

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "$ts  $Message"
    Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue
}

Write-Log '--- Shutdown hook started ---'

# Use docker.exe directly (Docker Desktop provides it on Windows PATH).
# This works under the SYSTEM account unlike wsl.exe which is per-user.
$docker = Get-Command docker.exe -ErrorAction SilentlyContinue
if (-not $docker) {
    # Try common install locations
    $candidates = @(
        "$env:ProgramFiles\Docker\Docker\resources\bin\docker.exe",
        "${env:ProgramFiles(x86)}\Docker\Docker\resources\bin\docker.exe"
    )
    foreach ($path in $candidates) {
        if (Test-Path $path) {
            $docker = Get-Item $path
            break
        }
    }
}

if (-not $docker) {
    Write-Log 'ERROR: docker.exe not found, cannot stop containers.'
    exit 1
}

$dockerPath = $docker.Source
if (-not $dockerPath) { $dockerPath = $docker.FullName }
Write-Log "Using docker: $dockerPath"

# Get list of running containers
$containerIds = & $dockerPath ps -q 2>$null
if (-not $containerIds) {
    Write-Log 'No running containers found.'
    Write-Log '--- Shutdown hook finished ---'
    exit 0
}

$ids = @($containerIds | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
$count = $ids.Count
Write-Log "Found $count running container(s), stopping with ${StopTimeout}s timeout..."

# Log container names for reference
foreach ($id in $ids) {
    $name = & $dockerPath inspect --format '{{.Name}}' $id 2>$null
    if ($name) { $name = $name.Trim().TrimStart('/') } else { $name = '?' }
    Write-Log "  Container: $name ($id)"
}

# Stop all containers in parallel with a single command.
# docker stop sends SIGTERM to all listed containers simultaneously,
# then waits up to $StopTimeout seconds before sending SIGKILL.
& $dockerPath stop -t $StopTimeout @ids 2>$null

if ($LASTEXITCODE -eq 0) {
    Write-Log "All $count container(s) stopped successfully."
} else {
    Write-Log "WARNING: docker stop exited with code $LASTEXITCODE (some containers may not have stopped cleanly)."
}
Write-Log '--- Shutdown hook finished ---'
