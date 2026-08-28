[CmdletBinding()]
param(
    [ValidateSet('service', 'busy', 'idle', 'status')]
    [string]$Action = 'service',
    [ValidateSet('claude', 'codex', 'pi')]
    [string]$Agent,
    [switch]$DryRun,
    [int]$StaleAfterSeconds = 900,
    [int]$Port = 17777
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$LogPath = Join-Path $Root 'agent-awake.log'

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class SleepGuard {
  [DllImport("kernel32.dll")]
  public static extern uint SetThreadExecutionState(uint flags);
}
'@

# 0x80000000 as a bare literal overflows to a negative Int32 in Windows PowerShell 5.1,
# which then fails the cast to the P/Invoke uint parameter.
$ES_CONTINUOUS = [uint32]2147483648
$ES_SYSTEM_REQUIRED = [uint32]1

function Write-Log([string]$Message) {
    "$((Get-Date).ToString('s')) $Message" | Add-Content -LiteralPath $LogPath -Encoding utf8
}

# --- CLI actions: thin HTTP clients against the running service ---

function Send-Signal([string]$Verb) {
    if ($Verb -ne 'status' -and -not $Agent) { throw 'Specify -Agent claude, codex, or pi.' }
    $path = if ($Verb -eq 'status') { 'status' } else { "$Verb/$Agent" }
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:$Port/$path" -UseBasicParsing -TimeoutSec 2
        return $response.Content
    } catch {
        Write-Warning "Agent Awake service is not reachable on port $Port ($($_.Exception.Message))."
        return $null
    }
}

switch ($Action) {
    'busy' { [void](Send-Signal 'busy'); exit 0 }
    'idle' { [void](Send-Signal 'idle'); exit 0 }
    'status' {
        $body = Send-Signal 'status'
        if ($null -ne $body) { $body }
        exit 0
    }
}

# --- Service: in-memory state + minimal HTTP endpoint, no disk writes ---

# name -> [datetime] last busy signal (UTC); absence means idle
$AgentState = @{}

function Get-ActiveAgents {
    $now = (Get-Date).ToUniversalTime()
    $active = @()
    foreach ($name in @($AgentState.Keys)) {
        if (($now - $AgentState[$name]).TotalSeconds -le $StaleAfterSeconds) { $active += $name }
        else { $AgentState.Remove($name) }
    }
    return $active
}

function Complete-Request($Client) {
    try {
        $Client.ReceiveTimeout = 1000
        $stream = $Client.GetStream()
        $reader = New-Object System.IO.StreamReader($stream)
        $line = $reader.ReadLine()
        $status = '404 Not Found'
        $body = 'unknown path'
        if ($line -match '^GET\s+/(busy|idle)/(claude|codex|pi)[\s/?]') {
            $verb = $Matches[1]
            $name = $Matches[2]
            $wasActive = (@(Get-ActiveAgents) -contains $name)
            if ($verb -eq 'busy') { $AgentState[$name] = (Get-Date).ToUniversalTime() }
            else { $AgentState.Remove($name) }
            if ($wasActive -ne ($verb -eq 'busy')) { Write-Log "$name => $verb" }
            $status = '200 OK'
            $body = 'ok'
        } elseif ($line -match '^GET\s+/status[\s/?]') {
            $active = @(Get-ActiveAgents)
            $status = '200 OK'
            $body = [pscustomobject]@{
                activeAgents = $active
                isPreventingSleep = ($active.Count -gt 0)
                dryRun = [bool]$DryRun
            } | ConvertTo-Json -Compress
        }
        $payload = [System.Text.Encoding]::UTF8.GetBytes($body)
        $header = [System.Text.Encoding]::ASCII.GetBytes(
            "HTTP/1.1 $status`r`nContent-Type: application/json`r`nContent-Length: $($payload.Length)`r`nConnection: close`r`n`r`n")
        $stream.Write($header, 0, $header.Length)
        $stream.Write($payload, 0, $payload.Length)
        $stream.Flush()
    } catch {
        # Ignore malformed or interrupted requests; the guard loop must survive anything.
    } finally {
        $Client.Close()
    }
}

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $Port)
try {
    $listener.Start()
} catch {
    Write-Log "Port $Port is already in use; assuming another Agent Awake service is running. Exiting."
    exit 0
}

$wasActive = $false
$powerTick = [System.Diagnostics.Stopwatch]::StartNew()
Write-Log "Service started on port $Port. DryRun=$DryRun; stale timeout=${StaleAfterSeconds}s"
try {
    while ($true) {
        while ($listener.Pending()) { Complete-Request $listener.AcceptTcpClient() }

        if ($powerTick.Elapsed.TotalSeconds -ge 5) {
            $powerTick.Restart()
            $active = @(Get-ActiveAgents)
            $isActive = $active.Count -gt 0
            if ($isActive -ne $wasActive) {
                Write-Log "System sleep $(if ($isActive) { 'blocked for ' + ($active -join ', ') } else { 'allowed' })"
                if (-not $isActive -and -not $DryRun) {
                    # A one-time non-continuous system request restarts only the
                    # system idle timer. It does not keep the display awake.
                    [void][SleepGuard]::SetThreadExecutionState($ES_SYSTEM_REQUIRED)
                    Write-Log 'System idle timer restarted after agent completion.'
                }
                $wasActive = $isActive
            }
            if (-not $DryRun) {
                $flags = if ($isActive) { $ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED } else { $ES_CONTINUOUS }
                [void][SleepGuard]::SetThreadExecutionState([uint32]$flags)
            }
        }
        Start-Sleep -Milliseconds 200
    }
} catch {
    $stack = ($_.ScriptStackTrace -split "`r?`n") -join ' <- '
    Write-Log "Service CRASHED: $($_.Exception.Message) | $stack"
    throw
} finally {
    if (-not $DryRun) { [void][SleepGuard]::SetThreadExecutionState($ES_CONTINUOUS) }
    $listener.Stop()
    Write-Log 'Service stopped; system sleep allowed.'
}
