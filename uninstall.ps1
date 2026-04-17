##############################################################################
# uninstall.ps1 — Copilot Chat Email Notifier : Clean Removal Script
##############################################################################
#
# PURPOSE
# -------
# Reverses everything install.ps1 did — removes auto-start entries, scheduled
# tasks/timers, and optionally the stored password.  Does NOT delete the
# project folder itself (left to the user for safety).
#
# WHAT IT REMOVES PER PLATFORM
# ┌──────────┬──────────────────────────────────────────────────────────────┐
# │ Windows  │ Startup shortcut (CopilotNotifier.lnk)                     │
# │          │ Scheduled Task "CopilotEmailCleanup"                       │
# │          │ (optional) GMAIL_APP_PASSWORD User environment variable     │
# ├──────────┼──────────────────────────────────────────────────────────────┤
# │ macOS    │ launchd agents: com.copilot-notifier.watch                 │
# │          │                 com.copilot-notifier.cleanup               │
# │          │ (optional) Keychain entry for copilot-notifier             │
# │          │ Log files: ~/.copilot-notifier-watch.log                   │
# │          │            ~/.copilot-notifier-cleanup.log                 │
# │          │ Note: does NOT auto-remove lines added to ~/.zshrc         │
# ├──────────┼──────────────────────────────────────────────────────────────┤
# │ Linux    │ systemd user service: copilot-notifier.service             │
# │          │ systemd timer: copilot-notifier-cleanup.timer              │
# │          │ systemd service: copilot-notifier-cleanup.service          │
# │          │ (optional) ~/.copilot-notifier-env password file           │
# │          │ Note: does NOT auto-remove lines added to shell RC files   │
# ├──────────┼──────────────────────────────────────────────────────────────┤
# │ All      │ .vscode/tasks.json created by install.ps1                  │
# │          │ (optional) managed stop-hook instruction block             │
# │          │ (optional) .copilot-stop-hook workspace state folder       │
# └──────────┴──────────────────────────────────────────────────────────────┘
#
# USAGE
# -----
#   pwsh -File uninstall.ps1
#
##############################################################################

# Fail fast on errors
$ErrorActionPreference = "Stop"

# $PSScriptRoot = the directory containing this .ps1 file
$root = $PSScriptRoot

function Get-PrivateConfigPath {
    if ($IsWindows -and $env:APPDATA) {
        return (Join-Path $env:APPDATA "CopilotEmailNotifier\config.json")
    }
    elseif ($IsMacOS) {
        return "$HOME/Library/Application Support/CopilotEmailNotifier/config.json"
    }
    return "$HOME/.config/copilot-email-notifier/config.json"
}

function Prompt-YesNo {
    param(
        [string]$Prompt,
        [bool]$Default = $false
    )

    $suffix = if ($Default) { "[Y/n]" } else { "[y/N]" }
    while ($true) {
        $response = Read-Host "$Prompt $suffix"
        if (-not $response) {
            return $Default
        }

        switch ($response.Trim().ToLowerInvariant()) {
            'y' { return $true }
            'yes' { return $true }
            'n' { return $false }
            'no' { return $false }
        }

        Write-Host "Please enter y or n." -ForegroundColor Yellow
    }
}

function Remove-ManagedTextBlock {
    param(
        [string]$Path,
        [string]$BeginMarker,
        [string]$EndMarker
    )

    if (-not (Test-Path $Path)) {
        return $false
    }

    $content = Get-Content $Path -Raw
    $pattern = "(?s)\s*" + [regex]::Escape($BeginMarker) + ".*?" + [regex]::Escape($EndMarker) + "\s*"
    $updated = [regex]::Replace($content, $pattern, [Environment]::NewLine, 1)

    if ($updated.Trim()) {
        Set-Content -Path $Path -Value ($updated.Trim() + [Environment]::NewLine) -Encoding UTF8
    }
    else {
        Remove-Item $Path -Force
    }

    return $true
}

function Remove-StopHookGitExclude {
    param(
        [string]$WorkspacePath
    )

    $excludePath = Join-Path (Join-Path $WorkspacePath ".git") "info\exclude"
    if (-not (Test-Path $excludePath)) {
        return $false
    }

    $lines = Get-Content $excludePath
    $filtered = @($lines | Where-Object { $_.Trim() -ne '.copilot-stop-hook/' })
    if ($filtered.Count -eq $lines.Count) {
        return $false
    }

    Set-Content -Path $excludePath -Value $filtered -Encoding UTF8
    return $true
}

# ============================================================================
# BANNER
# ============================================================================
Write-Host ""
Write-Host "=========================================" -ForegroundColor Yellow
Write-Host "  Copilot Chat Email Notifier — Uninstall" -ForegroundColor Yellow
Write-Host "=========================================" -ForegroundColor Yellow
Write-Host ""

# ============================================================================
# WINDOWS UNINSTALL
# ============================================================================
if ($IsWindows) {
    # ---- Remove Startup shortcut ----
    # This .lnk file was created by install.ps1 in the user's Startup folder.
    # Deleting it prevents watch.ps1 from launching on login.
    $shortcut = Join-Path ([System.IO.Path]::Combine($env:APPDATA, "Microsoft\Windows\Start Menu\Programs\Startup")) "CopilotNotifier.lnk"
    if (Test-Path $shortcut) {
        Remove-Item $shortcut -Force
        Write-Host "Removed startup shortcut." -ForegroundColor Green
    }

    # ---- Remove Scheduled Task ----
    # The "CopilotEmailCleanup" task was registered to run cleanup.ps1 hourly.
    # Get-ScheduledTask checks if it exists; Unregister-ScheduledTask removes it.
    # -Confirm:$false = don't prompt for confirmation.
    $task = Get-ScheduledTask -TaskName "CopilotEmailCleanup" -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName "CopilotEmailCleanup" -Confirm:$false
        Write-Host "Removed scheduled task." -ForegroundColor Green
    }

    # ---- Optionally remove stored password ----
    # The User-level environment variable was set by install.ps1.
    # We ask before removing it because the user may have other tools using it.
    $existing = [System.Environment]::GetEnvironmentVariable("GMAIL_APP_PASSWORD", "User")
    if ($existing) {
        if (Prompt-YesNo -Prompt "Remove stored GMAIL_APP_PASSWORD from environment?" -Default $false) {
            # Setting to $null removes the variable from the User scope registry
            [System.Environment]::SetEnvironmentVariable("GMAIL_APP_PASSWORD", $null, "User")
            Write-Host "Environment variable removed." -ForegroundColor Green
        }
    }
}

# ============================================================================
# macOS UNINSTALL (launchd)
# ============================================================================
elseif ($IsMacOS) {
    # ---- Remove launchd agents ----
    # `launchctl unload` stops and unloads the agent from the current session.
    # Then we delete the .plist file so it won't be loaded again on next login.
    $plistDir = "$HOME/Library/LaunchAgents"
    foreach ($name in @("com.copilot-notifier.watch", "com.copilot-notifier.cleanup")) {
        $plist = Join-Path $plistDir "$name.plist"
        if (Test-Path $plist) {
            & launchctl unload $plist 2>$null        # Stop the agent
            Remove-Item $plist -Force                 # Delete the plist file
            Write-Host "Removed $name." -ForegroundColor Green
        }
    }

    # ---- Optionally remove Keychain entry ----
    # `security delete-generic-password` removes the stored app password
    # from the login keychain.
    if (Prompt-YesNo -Prompt "Remove stored password from macOS Keychain?" -Default $false) {
        & security delete-generic-password -a "copilot-notifier" -s "GMAIL_APP_PASSWORD" 2>$null
        Write-Host "Keychain entry removed." -ForegroundColor Green
    }

    # ---- Shell profile note ----
    # install.ps1 added an "export GMAIL_APP_PASSWORD=..." line to ~/.zshrc.
    # We don't auto-remove it because modifying shell RC files can be dangerous
    # (could accidentally delete an unrelated line).  Instead we inform the user.
    Write-Host "Note: Remove the 'Copilot Email Notifier' lines from ~/.zshrc manually if desired." -ForegroundColor Yellow

    # ---- Remove log files ----
    # Stdout/stderr from the launchd agents were directed to these log files.
    foreach ($log in @("$HOME/.copilot-notifier-watch.log", "$HOME/.copilot-notifier-cleanup.log")) {
        if (Test-Path $log) { Remove-Item $log -Force }
    }
}

# ============================================================================
# LINUX UNINSTALL (systemd)
# ============================================================================
else {
    # ---- Disable and stop systemd user units ----
    # `systemctl --user disable --now` both stops the running instance and
    # removes the symlink that causes it to start on login.
    & systemctl --user disable --now copilot-notifier.service 2>$null
    & systemctl --user disable --now copilot-notifier-cleanup.timer 2>$null

    # ---- Remove unit files ----
    $unitDir = "$HOME/.config/systemd/user"
    foreach ($f in @("copilot-notifier.service", "copilot-notifier-cleanup.service", "copilot-notifier-cleanup.timer")) {
        $path = Join-Path $unitDir $f
        if (Test-Path $path) { Remove-Item $path -Force }
    }

    # Reload systemd so it forgets about the removed units
    & systemctl --user daemon-reload 2>$null
    Write-Host "Removed systemd services." -ForegroundColor Green

    # ---- Optionally remove password file ----
    # ~/.copilot-notifier-env contains the app password (chmod 600)
    $envFile = "$HOME/.copilot-notifier-env"
    if (Test-Path $envFile) {
        if (Prompt-YesNo -Prompt "Remove stored password from $envFile?" -Default $false) {
            Remove-Item $envFile -Force
            Write-Host "Env file removed." -ForegroundColor Green
        }
    }

    # ---- Shell profile note ----
    Write-Host "Note: Remove the 'copilot-notifier-env' lines from your shell rc file manually if desired." -ForegroundColor Yellow
}

# ============================================================================
# ALL PLATFORMS: Remove VS Code tasks.json created by install.ps1
# ============================================================================
# install.ps1 created a .vscode/tasks.json inside the project folder.
# Remove it.  If .vscode/ is then empty, remove the directory too.
$taskFile = Join-Path $root ".vscode" "tasks.json"
if (Test-Path $taskFile) { Remove-Item $taskFile -Force }
$vscodeDir = Join-Path $root ".vscode"
if ((Test-Path $vscodeDir) -and -not (Get-ChildItem $vscodeDir)) {
    Remove-Item $vscodeDir -Force
}

# ============================================================================
# OPTIONAL STOP-HOOK CLEANUP
# ============================================================================
$configPath = Get-PrivateConfigPath
if (Test-Path $configPath) {
    try {
        $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
        if ($cfg.stopHook) {
            $workspacePath = if ($cfg.stopHook.workspacePath) { "$($cfg.stopHook.workspacePath)" } else { "" }
            $instructionFile = if ($cfg.stopHook.instructionFile) { "$($cfg.stopHook.instructionFile)" } else { "" }

            if ($instructionFile -and (Test-Path $instructionFile)) {
                if (Prompt-YesNo -Prompt "Remove the managed stop-hook Copilot instructions block from $instructionFile?" -Default $false) {
                    if (Remove-ManagedTextBlock -Path $instructionFile -BeginMarker '<!-- Copilot Email Notifier Stop Hook: begin -->' -EndMarker '<!-- Copilot Email Notifier Stop Hook: end -->') {
                        Write-Host "Removed managed stop-hook instructions." -ForegroundColor Green
                    }
                }
            }

            if ($workspacePath) {
                $stateDir = Join-Path $workspacePath ".copilot-stop-hook"
                if (Test-Path $stateDir) {
                    if (Prompt-YesNo -Prompt "Remove stop-hook state folder $stateDir ?" -Default $false) {
                        Remove-Item $stateDir -Recurse -Force
                        Write-Host "Removed stop-hook state folder." -ForegroundColor Green
                    }
                }

                if (Prompt-YesNo -Prompt "Remove the local .copilot-stop-hook Git exclude entry from $workspacePath ?" -Default $false) {
                    if (Remove-StopHookGitExclude -WorkspacePath $workspacePath) {
                        Write-Host "Removed local Git exclude entry." -ForegroundColor Green
                    }
                }
            }
        }
    }
    catch {
        Write-Host "Skipped stop-hook cleanup prompts because the private config could not be read." -ForegroundColor Yellow
    }
}

# ============================================================================
# DONE
# ============================================================================
Write-Host ""
Write-Host "Uninstall complete." -ForegroundColor Green
Write-Host "The copilot-notifier folder itself was not deleted — remove it manually if desired."
Write-Host ""
