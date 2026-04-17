##############################################################################
# stop-hook.ps1 — Copilot Chat Completion Gate
##############################################################################
#
# PURPOSE
# -------
# Runs a configurable sequence of verification commands after a Copilot Chat
# response appears to be complete. This is the enforceable side of the optional
# "stop hook" feature: instead of pretending VS Code exposes a hard stop API,
# the notifier runs local checks, records the result inside the workspace, and
# tells the watcher whether the task should be treated as complete.
#
# WHAT IT WRITES
# --------------
# <workspace>/.copilot-stop-hook/last-result.json
#   Structured result for the most recent stop-hook run.
#
# <workspace>/.copilot-stop-hook/last-run.log
#   Combined stdout/stderr and status information for each command.
#
# <workspace>/.copilot-stop-hook/continue-required.md
#   Present only when checks fail. This gives Copilot Chat and the user a
#   simple, local artifact that says completion is not yet accepted.
#
# EXIT CODES
# ----------
# 0 = checks passed or feature disabled
# 1 = configuration/runtime error prevented a reliable result
# 2 = checks failed or timed out
#
##############################################################################

param(
    [string]$ConfigPath = "",
    [string]$SessionFile = ""
)

$ErrorActionPreference = "Stop"

function Get-DefaultConfigCandidates {
    $candidates = @()
    if ($IsWindows -and $env:APPDATA) {
        $candidates += (Join-Path $env:APPDATA "CopilotEmailNotifier\config.json")
    }
    elseif ($IsMacOS) {
        $candidates += "$HOME/Library/Application Support/CopilotEmailNotifier/config.json"
    }
    else {
        $candidates += "$HOME/.config/copilot-email-notifier/config.json"
    }
    $candidates += (Join-Path $PSScriptRoot "config.json")
    return $candidates
}

function Get-StopHookConfig {
    param(
        [psobject]$Config
    )

    $hook = $null
    if ($Config -and ($Config.PSObject.Properties.Name -contains 'stopHook')) {
        $hook = $Config.stopHook
    }

    $commands = @()
    if ($hook -and $hook.commands) {
        $commands = @($hook.commands | ForEach-Object {
            if ($null -ne $_) { "$($_)".Trim() }
        } | Where-Object { $_ })
    }

    return [PSCustomObject]@{
        enabled         = [bool]($hook -and $hook.enabled)
        workspacePath   = if ($hook -and $hook.workspacePath) { "$($hook.workspacePath)" } else { "" }
        commands        = $commands
        timeoutSeconds  = if ($hook -and $hook.timeoutSeconds) { [int]$hook.timeoutSeconds } else { 900 }
        notifyOnFailure = if ($hook -and $null -ne $hook.notifyOnFailure) { [bool]$hook.notifyOnFailure } else { $true }
        instructionFile = if ($hook -and $hook.instructionFile) { "$($hook.instructionFile)" } else { "" }
    }
}

function Get-PwshExecutablePath {
    if ($IsWindows) {
        return (Join-Path $PSHOME "pwsh.exe")
    }
    return (Join-Path $PSHOME "pwsh")
}

function Invoke-StopHookCommand {
    param(
        [string]$Command,
        [string]$WorkspacePath,
        [int]$TimeoutSeconds
    )

    $tempScript = Join-Path ([System.IO.Path]::GetTempPath()) ("copilot-stop-hook-" + [guid]::NewGuid().ToString() + ".ps1")
    $stdoutPath = Join-Path ([System.IO.Path]::GetTempPath()) ("copilot-stop-hook-stdout-" + [guid]::NewGuid().ToString() + ".log")
    $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ("copilot-stop-hook-stderr-" + [guid]::NewGuid().ToString() + ".log")
    $escapedWorkspacePath = $WorkspacePath.Replace("'", "''")
    $commandScript = @"
Set-Location -LiteralPath '$escapedWorkspacePath'
`$ErrorActionPreference = 'Continue'

try {
$Command
    if (`$LASTEXITCODE -is [int] -and `$LASTEXITCODE -ne 0) {
        exit `$LASTEXITCODE
    }
    if (`$?) {
        exit 0
    }
    exit 1
}
catch {
    Write-Error `$_
    exit 1
}
"@

    Set-Content -Path $tempScript -Value $commandScript -Encoding UTF8
    $startTime = Get-Date

    try {
        $process = Start-Process -FilePath (Get-PwshExecutablePath) -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $tempScript) `
            -WorkingDirectory $WorkspacePath -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        $completed = $process.WaitForExit($TimeoutSeconds * 1000)
        if (-not $completed) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }

        $stdout = if (Test-Path $stdoutPath) { Get-Content $stdoutPath -Raw } else { "" }
        $stderr = if (Test-Path $stderrPath) { Get-Content $stderrPath -Raw } else { "" }
        $combinedOutput = @($stdout, $stderr | Where-Object { $_ }) -join [Environment]::NewLine

        return [PSCustomObject]@{
            command         = $Command
            passed          = ($completed -and $process.ExitCode -eq 0)
            exitCode        = if ($completed) { [int]$process.ExitCode } else { -1 }
            timedOut        = (-not $completed)
            durationSeconds = [Math]::Round(((Get-Date) - $startTime).TotalSeconds, 2)
            output          = $combinedOutput.Trim()
        }
    }
    finally {
        Remove-Item $tempScript, $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

$stateDir = $null
$resultFile = $null
$continueFile = $null
$logFile = $null
$configuredWorkspacePath = ""

try {
    if (-not $ConfigPath) {
        $ConfigPath = Get-DefaultConfigCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $ConfigPath) {
            $ConfigPath = Get-DefaultConfigCandidates | Select-Object -First 1
        }
    }
    if (-not (Test-Path $ConfigPath)) {
        throw "Config not found: $ConfigPath"
    }

    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $stopHook = Get-StopHookConfig -Config $cfg
    $configuredWorkspacePath = $stopHook.workspacePath
    if (-not $stopHook.enabled) {
        [PSCustomObject]@{
            enabled     = $false
            passed      = $true
            skipped     = $true
            timestamp   = (Get-Date).ToString('o')
            sessionFile = $SessionFile
            summary     = 'Stop hook disabled.'
        } | ConvertTo-Json -Depth 6
        exit 0
    }

    if (-not $stopHook.workspacePath) {
        throw "Stop hook is enabled but no workspacePath is configured."
    }
    if (-not (Test-Path $stopHook.workspacePath -PathType Container)) {
        throw "Stop hook workspace path must be an existing directory: $($stopHook.workspacePath)"
    }
    if (@($stopHook.commands).Count -eq 0) {
        throw "Stop hook is enabled but no commands are configured."
    }
    if ($stopHook.timeoutSeconds -le 0) {
        throw "Stop hook timeoutSeconds must be greater than zero."
    }

    $workspacePath = (Resolve-Path $stopHook.workspacePath).Path
    $stateDir = Join-Path $workspacePath ".copilot-stop-hook"
    if (-not (Test-Path $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }

    $resultFile = Join-Path $stateDir "last-result.json"
    $continueFile = Join-Path $stateDir "continue-required.md"
    $logFile = Join-Path $stateDir "last-run.log"

    $commandResults = @()
    $logSections = @(
        "Stop hook timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "Workspace: $workspacePath",
        "Session file: $SessionFile",
        "Timeout seconds: $($stopHook.timeoutSeconds)",
        ""
    )

    foreach ($command in $stopHook.commands) {
        $result = Invoke-StopHookCommand -Command $command -WorkspacePath $workspacePath -TimeoutSeconds $stopHook.timeoutSeconds
        $commandResults += $result

        $logSections += "Command: $($result.command)"
        $logSections += "Passed: $($result.passed)"
        $logSections += "Exit code: $($result.exitCode)"
        $logSections += "Timed out: $($result.timedOut)"
        $logSections += "Duration seconds: $($result.durationSeconds)"
        $logSections += "Output:"
        $logSections += if ($result.output) { $result.output } else { "(no output)" }
        $logSections += ""

        if (-not $result.passed) {
            break
        }
    }

    Set-Content -Path $logFile -Value ($logSections -join [Environment]::NewLine) -Encoding UTF8

    $failedCommand = $commandResults | Where-Object { -not $_.passed } | Select-Object -First 1
    $passed = ($null -eq $failedCommand)
    $resultObject = [PSCustomObject]@{
        enabled         = $true
        passed          = $passed
        timestamp       = (Get-Date).ToString('o')
        sessionFile     = $SessionFile
        workspacePath   = $workspacePath
        timeoutSeconds  = $stopHook.timeoutSeconds
        notifyOnFailure = $stopHook.notifyOnFailure
        instructionFile = $stopHook.instructionFile
        stateDir        = $stateDir
        resultFile      = $resultFile
        continueFile    = $continueFile
        logFile         = $logFile
        commands        = $commandResults
        summary         = if ($passed) {
            "All stop-hook commands passed."
        }
        elseif ($failedCommand.timedOut) {
            "Stop-hook command timed out: $($failedCommand.command)"
        }
        else {
            "Stop-hook command failed: $($failedCommand.command)"
        }
    }

    $resultObject | ConvertTo-Json -Depth 6 | Set-Content -Path $resultFile -Encoding UTF8

    if ($passed) {
        Remove-Item $continueFile -Force -ErrorAction SilentlyContinue
        $resultObject | ConvertTo-Json -Depth 6
        exit 0
    }

    $continueBody = @"
# Continue Required

Copilot Chat reached its quiet window, but the configured stop-hook checks did not pass.

- Workspace: $workspacePath
- Failed check: $($failedCommand.command)
- Result file: $resultFile
- Log file: $logFile

Do not mark the task complete until the stop-hook passes and `.copilot-stop-hook/last-result.json` reports `"passed": true`.
"@
    Set-Content -Path $continueFile -Value $continueBody -Encoding UTF8

    $resultObject | ConvertTo-Json -Depth 6
    exit 2
}
catch {
    $errorMessage = $_.Exception.Message
    $resultObject = [PSCustomObject]@{
        enabled       = $true
        passed        = $false
        timestamp     = (Get-Date).ToString('o')
        sessionFile   = $SessionFile
        workspacePath = if ($stateDir) { Split-Path $stateDir -Parent } elseif ($configuredWorkspacePath) { $configuredWorkspacePath } else { "" }
        resultFile    = $resultFile
        continueFile  = $continueFile
        logFile       = $logFile
        commands      = @()
        summary       = $errorMessage
    }

    if ($logFile) {
        Set-Content -Path $logFile -Value $errorMessage -Encoding UTF8
    }
    if ($resultFile) {
        $resultObject | ConvertTo-Json -Depth 6 | Set-Content -Path $resultFile -Encoding UTF8
    }
    if ($continueFile) {
        Set-Content -Path $continueFile -Value "# Continue Required`n`n$errorMessage" -Encoding UTF8
    }

    $resultObject | ConvertTo-Json -Depth 6
    exit 1
}