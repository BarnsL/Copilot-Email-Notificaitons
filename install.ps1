##############################################################################
# install.ps1 — Copilot Chat Email Notifier : Cross-Platform Setup Wizard
##############################################################################
#
# PURPOSE
# -------
# Interactive installer that configures the Copilot Chat Email Notifier on
# Windows, macOS, or Linux.  Performs all first-time setup in one command:
#   pwsh -File install.ps1
#
# WHAT IT DOES (in order)
# -----------------------
# 1. Prompts for Gmail address (if config.json has placeholder)
# 2. Prompts for computer name (defaults to hostname)
# 3. Prompts for Gmail App Password and stores it securely per-platform
# 4. Sends a test email to verify credentials work
# 5. Registers the watcher (watch.ps1) to auto-start on login
# 6. Registers the cleanup (cleanup.ps1) to run hourly
# 7. Creates a VS Code tasks.json for manual launch within VS Code
#
# PLATFORM-SPECIFIC BEHAVIOR
# --------------------------
# ┌──────────┬────────────────────────┬────────────────────────┬─────────────────────┐
# │          │ Password Storage       │ Watcher Auto-Start     │ Cleanup Scheduler   │
# ├──────────┼────────────────────────┼────────────────────────┼─────────────────────┤
# │ Windows  │ User env var (registry)│ Startup folder shortcut│ Scheduled Task      │
# │ macOS    │ macOS Keychain         │ launchd LaunchAgent    │ launchd (hourly)    │
# │ Linux    │ ~/.copilot-notifier-env│ systemd user service   │ systemd timer       │
# └──────────┴────────────────────────┴────────────────────────┴─────────────────────┘
#
# PREREQUISITES
# - PowerShell 7+ (pwsh)
# - Gmail account with 2-Step Verification enabled
# - Gmail App Password generated (https://myaccount.google.com/apppasswords)
#
# PARAMETERS
# - -Unattended : skip all prompts (requires config.json + env var pre-set)
#
##############################################################################

# ============================================================================
# PARAMETER
# ============================================================================
param(
    [switch]$Unattended   # If set, skip interactive prompts (CI/automation use)
)

# Fail fast on any error
$ErrorActionPreference = "Stop"

# $PSScriptRoot = the directory containing this .ps1 file
$root = $PSScriptRoot

# ============================================================================
# BANNER
# ============================================================================
Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  Copilot Chat Email Notifier — Setup" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# STEP 1: LOAD AND UPDATE CONFIG (stored in a user-private path)
# ============================================================================
# The project config.json is treated as a template with placeholders.
# User-specific values are stored in a private OS config path:
#   Windows: %APPDATA%\CopilotEmailNotifier\config.json
#   macOS  : ~/Library/Application Support/CopilotEmailNotifier/config.json
#   Linux  : ~/.config/copilot-email-notifier/config.json
#
# Template placeholders:
#   "email": "[EMAIL]"
#   "computerName": "[PC Name]"
#
# If these haven't been edited, prompt the user interactively.
# After prompting, write the updated config to the private path (not source).
# ============================================================================
function Get-PrivateConfigPath {
    if ($IsWindows -and $env:APPDATA) {
        return (Join-Path $env:APPDATA "CopilotEmailNotifier\config.json")
    }
    elseif ($IsMacOS) {
        return "$HOME/Library/Application Support/CopilotEmailNotifier/config.json"
    }
    return "$HOME/.config/copilot-email-notifier/config.json"
}

$templateConfigPath = Join-Path $root "config.json"
$configPath = Get-PrivateConfigPath

if (Test-Path $configPath) {
    $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
}
else {
    $cfg = Get-Content $templateConfigPath -Raw | ConvertFrom-Json
}

# ---- Email address ----
if ($cfg.email -eq '[EMAIL]') {
    $email = Read-Host "Enter your Gmail address"
    # Basic validation: must contain '@'
    if (-not $email -or $email -notmatch '@') {
        Write-Error "Invalid email."
        exit 1
    }
    $cfg.email = $email
}

# ---- Computer name ----
if ($cfg.computerName -eq '[PC Name]') {
    # Default to the OS hostname if available
    # $env:COMPUTERNAME exists on Windows; `hostname` works on all platforms
    $defaultName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { (hostname) }
    $pcName = Read-Host "Enter a name for this computer [$defaultName]"
    if (-not $pcName) { $pcName = $defaultName }
    $cfg.computerName = $pcName
}

# Write updated config to user-private location
$cfgDir = Split-Path $configPath -Parent
if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Force $cfgDir | Out-Null }
$cfg | ConvertTo-Json -Depth 5 | Set-Content $configPath -Encoding UTF8
Write-Host "Config saved to private path: $configPath" -ForegroundColor Green

# ============================================================================
# STEP 2: ACQUIRE AND STORE GMAIL APP PASSWORD (cross-platform)
# ============================================================================
# First check if the password is already available in the environment.
# If not, prompt the user and store it in the platform-appropriate secure store.
#
# SECURITY NOTE: The password is read as a SecureString (masked input) and
# immediately converted to plaintext only for storage.  It is never written
# to any script file or config file.
# ============================================================================

# Check environment first (may already be set from a previous install)
$appPassword = $env:GMAIL_APP_PASSWORD
if (-not $appPassword -and $IsWindows) {
    # On Windows, also check the User-level registry env var
    $appPassword = [System.Environment]::GetEnvironmentVariable("GMAIL_APP_PASSWORD", "User")
}

if (-not $appPassword) {
    Write-Host ""
    Write-Host "Gmail App Password is required." -ForegroundColor Yellow
    Write-Host "Generate one at: https://myaccount.google.com/apppasswords"
    Write-Host "(Requires 2-Step Verification enabled on your Google account)"
    Write-Host ""

    # Read as SecureString — terminal shows asterisks instead of characters
    $securePass = Read-Host "Enter Gmail App Password" -AsSecureString

    # Convert SecureString to plaintext for SMTP/IMAP use
    # Marshal.SecureStringToBSTR allocates an unmanaged BSTR; PtrToStringAuto
    # copies it to a managed string.  The BSTR should ideally be freed with
    # ZeroFreeBSTR but PowerShell's GC handles it on script exit.
    $appPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass)
    )
    if (-not $appPassword) {
        Write-Error "No password provided."
        exit 1
    }
}

# ---- Store the password per-platform ----

if ($IsWindows) {
    # WINDOWS: User-scoped environment variable
    # Stored in HKCU:\Environment, survives reboots, not visible to other users.
    # SetEnvironmentVariable with "User" scope writes to the registry.
    [System.Environment]::SetEnvironmentVariable("GMAIL_APP_PASSWORD", $appPassword, "User")
    Write-Host "Password stored in Windows User environment." -ForegroundColor Green
}
elseif ($IsMacOS) {
    # macOS: Keychain Services
    # `security add-generic-password` adds an entry to the login keychain.
    #   -a "copilot-notifier"   = account name (used to look it up later)
    #   -s "GMAIL_APP_PASSWORD" = service name (also used for lookup)
    #   -w $appPassword         = the password value
    #   -U                      = update if entry already exists (upsert)
    & security add-generic-password -a "copilot-notifier" -s "GMAIL_APP_PASSWORD" -w $appPassword -U 2>$null

    # Also add a line to ~/.zshrc that exports the password from Keychain
    # at shell login, so pwsh (launched from the shell) inherits the env var.
    # `security find-generic-password -w` outputs just the password value.
    $profileLine = "export GMAIL_APP_PASSWORD=`$(security find-generic-password -a 'copilot-notifier' -s 'GMAIL_APP_PASSWORD' -w 2>/dev/null)"
    $shellRc = "$HOME/.zshrc"
    # Only add if not already present (idempotent)
    if (-not (Test-Path $shellRc) -or -not (Select-String -Path $shellRc -Pattern 'GMAIL_APP_PASSWORD' -Quiet)) {
        Add-Content $shellRc "`n# Copilot Email Notifier`n$profileLine"
    }
    # Set in current process too so the test email below works
    $env:GMAIL_APP_PASSWORD = $appPassword
    Write-Host "Password stored in macOS Keychain." -ForegroundColor Green
}
else {
    # LINUX: File-based storage with restricted permissions
    # Stored in ~/.copilot-notifier-env as a plain KEY=VALUE line.
    # chmod 600 = owner read/write only (no group, no other).
    $envFile = "$HOME/.copilot-notifier-env"
    "GMAIL_APP_PASSWORD=$appPassword" | Set-Content $envFile
    if (Get-Command chmod -ErrorAction SilentlyContinue) {
        & chmod 600 $envFile   # Restrict to owner-only access
    }

    # Add a line to the shell RC file that sources the env file at login.
    # `cat ... | xargs` converts KEY=VALUE lines into shell-compatible exports.
    $shellRc = if (Test-Path "$HOME/.bashrc") { "$HOME/.bashrc" }
               elseif (Test-Path "$HOME/.zshrc") { "$HOME/.zshrc" }
               else { "$HOME/.bashrc" }
    $sourceLine = "[ -f ~/.copilot-notifier-env ] && export `$(cat ~/.copilot-notifier-env | xargs)"
    if (-not (Test-Path $shellRc) -or -not (Select-String -Path $shellRc -Pattern 'copilot-notifier-env' -Quiet)) {
        Add-Content $shellRc "`n# Copilot Email Notifier`n$sourceLine"
    }
    $env:GMAIL_APP_PASSWORD = $appPassword
    Write-Host "Password stored in $envFile (chmod 600)." -ForegroundColor Green
}

# ============================================================================
# STEP 3: SEND TEST EMAIL
# ============================================================================
# Verifies that the credentials are correct by sending a simple test message.
# Uses System.Net.Mail.SmtpClient (available in all .NET runtimes).
# SMTP connection: smtp.gmail.com:587 with STARTTLS.
# ============================================================================
Write-Host ""
Write-Host "Sending test email..." -ForegroundColor Cyan

try {
    $smtp = New-Object System.Net.Mail.SmtpClient($cfg.smtpServer, $cfg.smtpPort)
    $smtp.EnableSsl    = $true   # STARTTLS on port 587
    $smtp.Credentials  = New-Object System.Net.NetworkCredential($cfg.email, $appPassword)

    # Construct a simple test message
    $msg = New-Object System.Net.Mail.MailMessage(
        $cfg.email,                                                         # From
        $cfg.email,                                                         # To (same)
        "[$($cfg.computerName)] Copilot Notifier — Setup Complete",         # Subject
        # Body includes OS info for diagnostic purposes
        "Copilot Chat Email Notifier is installed on $($cfg.computerName).`n`nTime: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`nOS: $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)"
    )
    $smtp.Send($msg)
    $smtp.Dispose()
    $msg.Dispose()
    Write-Host "Test email sent to $($cfg.email)!" -ForegroundColor Green
}
catch {
    Write-Host "Test email failed: $_" -ForegroundColor Red
    Write-Host "Check your app password and try again." -ForegroundColor Yellow
    exit 1
}

# ============================================================================
# STEP 4: REGISTER AUTO-START AND SCHEDULED CLEANUP (cross-platform)
# ============================================================================
# Each platform has its own mechanism for:
#   A) Starting the watcher automatically on user login
#   B) Running the cleanup script periodically (hourly)
# ============================================================================
Write-Host ""
Write-Host "Registering auto-start..." -ForegroundColor Cyan

$watchScript   = Join-Path $root "watch.ps1"
$cleanupScript = Join-Path $root "cleanup.ps1"

# ============================================================================
# WINDOWS AUTO-START
# ============================================================================
if ($IsWindows) {
    # ---- A) Watcher: Windows Startup Folder Shortcut ----
    # Files/shortcuts in this folder are launched automatically at user login.
    # Path: %APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup
    # We create a .lnk shortcut pointing to pwsh.exe with -File watch.ps1.
    # -WindowStyle Hidden hides the PowerShell console window.
    $startupDir    = [System.IO.Path]::Combine($env:APPDATA, "Microsoft\Windows\Start Menu\Programs\Startup")
    $shortcutPath  = Join-Path $startupDir "CopilotNotifier.lnk"
    $ws = New-Object -ComObject WScript.Shell           # COM object for shortcut creation
    $sc = $ws.CreateShortcut($shortcutPath)
    $sc.TargetPath       = "pwsh.exe"                    # PowerShell 7 executable
    $sc.Arguments        = "-NoProfile -WindowStyle Hidden -File `"$watchScript`""
    #                       -NoProfile     = skip loading $PROFILE (faster startup)
    #                       -WindowStyle Hidden = no visible console window
    #                       -File          = run this script file
    $sc.WorkingDirectory = $root                         # Set CWD to the project folder
    $sc.Description      = "Copilot Chat Email Notifier"
    $sc.Save()
    Write-Host "Startup shortcut created: $shortcutPath" -ForegroundColor Green

    # ---- B) Cleanup: Windows Scheduled Task ----
    # Task Scheduler runs cleanup.ps1 hourly.
    #
    # New-ScheduledTaskAction  — what to run (pwsh.exe -File cleanup.ps1)
    # New-ScheduledTaskTrigger — when (-Once -At midnight, repeating every 1h)
    # New-ScheduledTaskSettingsSet — behavior modifiers:
    #   -AllowStartIfOnBatteries    = run even on laptop battery
    #   -DontStopIfGoingOnBatteries = don't kill it if AC is unplugged
    #   -StartWhenAvailable         = run the missed instance if scheduled time was missed
    # Register-ScheduledTask -Force = create or overwrite the task
    $action  = New-ScheduledTaskAction -Execute "pwsh.exe" -Argument "-NoProfile -NonInteractive -File `"$cleanupScript`""
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Hours 1)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName "CopilotEmailCleanup" -Action $action -Trigger $trigger -Settings $settings `
        -Description "Deletes Copilot notification emails older than $($cfg.cleanupMaxAgeHours)h" -Force | Out-Null
    Write-Host "Scheduled task 'CopilotEmailCleanup' registered (hourly)." -ForegroundColor Green
}

# ============================================================================
# macOS AUTO-START (launchd)
# ============================================================================
elseif ($IsMacOS) {
    # launchd is macOS's init/service manager (like systemd on Linux).
    # User-scoped agents go in ~/Library/LaunchAgents/ as .plist XML files.
    # `launchctl load <plist>` activates the agent immediately.
    $plistDir = "$HOME/Library/LaunchAgents"
    if (-not (Test-Path $plistDir)) { New-Item -ItemType Directory -Force $plistDir | Out-Null }

    # ---- A) Watcher: launchd LaunchAgent (runs on login, auto-restarts) ----
    # RunAtLoad  = start immediately when loaded (and on login)
    # KeepAlive  = restart if the process exits (crash recovery)
    # Stdout/Stderr directed to a log file for debugging
    $watchPlist = Join-Path $plistDir "com.copilot-notifier.watch.plist"
    @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Unique label identifying this agent — used by launchctl to manage it -->
    <key>Label</key><string>com.copilot-notifier.watch</string>

    <!-- Command to execute: pwsh -NoProfile -File /path/to/watch.ps1 -->
    <key>ProgramArguments</key>
    <array>
        <string>pwsh</string>
        <string>-NoProfile</string>
        <string>-File</string>
        <string>$watchScript</string>
    </array>

    <!-- Start when the agent is loaded (on login or `launchctl load`) -->
    <key>RunAtLoad</key><true/>

    <!-- Automatically restart if the process exits (crash/error recovery) -->
    <key>KeepAlive</key><true/>

    <!-- Log stdout and stderr to a file for debugging -->
    <key>StandardOutPath</key><string>$HOME/.copilot-notifier-watch.log</string>
    <key>StandardErrorPath</key><string>$HOME/.copilot-notifier-watch.log</string>
</dict>
</plist>
"@ | Set-Content $watchPlist
    & launchctl load $watchPlist 2>$null
    Write-Host "launchd agent registered: $watchPlist" -ForegroundColor Green

    # ---- B) Cleanup: launchd LaunchAgent (runs every 3600 seconds = 1 hour) ----
    # StartInterval = run every N seconds (3600 = hourly)
    $cleanPlist = Join-Path $plistDir "com.copilot-notifier.cleanup.plist"
    @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.copilot-notifier.cleanup</string>
    <key>ProgramArguments</key>
    <array>
        <string>pwsh</string>
        <string>-NoProfile</string>
        <string>-File</string>
        <string>$cleanupScript</string>
    </array>

    <!-- Run every 3600 seconds (1 hour) -->
    <key>StartInterval</key><integer>3600</integer>

    <key>StandardOutPath</key><string>$HOME/.copilot-notifier-cleanup.log</string>
    <key>StandardErrorPath</key><string>$HOME/.copilot-notifier-cleanup.log</string>
</dict>
</plist>
"@ | Set-Content $cleanPlist
    & launchctl load $cleanPlist 2>$null
    Write-Host "launchd cleanup agent registered (hourly)." -ForegroundColor Green
}

# ============================================================================
# LINUX AUTO-START (systemd user units)
# ============================================================================
else {
    # systemd user units live in ~/.config/systemd/user/
    # `systemctl --user enable --now <unit>` starts and persists across reboots.
    $unitDir = "$HOME/.config/systemd/user"
    if (-not (Test-Path $unitDir)) { New-Item -ItemType Directory -Force $unitDir | Out-Null }

    # ---- A) Watcher: systemd user service ----
    # Restart=on-failure + RestartSec=10 = auto-restart after 10s on crash
    # WantedBy=default.target = start at user login
    @"
[Unit]
Description=Copilot Chat Email Notifier

[Service]
ExecStart=pwsh -NoProfile -File $watchScript
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
"@ | Set-Content "$unitDir/copilot-notifier.service"

    # ---- B) Cleanup: systemd timer (hourly) ----
    # OnBootSec=5min     = first run 5 minutes after boot
    # OnUnitActiveSec=1h = then every 1 hour after each run
    # Persistent=true    = catch up missed runs if the machine was off
    @"
[Unit]
Description=Copilot email cleanup timer

[Timer]
OnBootSec=5min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
"@ | Set-Content "$unitDir/copilot-notifier-cleanup.timer"

    # Timer triggers need a matching .service unit with the same base name
    @"
[Unit]
Description=Copilot email cleanup

[Service]
Type=oneshot
ExecStart=pwsh -NoProfile -File $cleanupScript
"@ | Set-Content "$unitDir/copilot-notifier-cleanup.service"

    # Reload systemd to pick up new unit files, then enable and start both
    & systemctl --user daemon-reload 2>$null
    & systemctl --user enable --now copilot-notifier.service 2>$null
    & systemctl --user enable --now copilot-notifier-cleanup.timer 2>$null
    Write-Host "systemd user services enabled." -ForegroundColor Green
}

# ============================================================================
# STEP 5: CREATE VS CODE TASKS.JSON (optional convenience)
# ============================================================================
# This creates a .vscode/tasks.json inside the project folder so you can
# start the watcher from VS Code's "Run Task" command.
# runOptions.runOn: "folderOpen" = auto-start when this folder is opened as
# a VS Code workspace (requires VS Code prompt approval on first use).
# ============================================================================
$vscodeTasks = Join-Path $root ".vscode" "tasks.json"
$vscodeDir   = Join-Path $root ".vscode"
if (-not (Test-Path $vscodeDir)) { New-Item -ItemType Directory -Force $vscodeDir | Out-Null }

@"
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "Start Copilot Chat Email Watcher",
      "type": "shell",
      "command": "pwsh -NoProfile -File \${workspaceFolder}/watch.ps1",
      "problemMatcher": [],
      "isBackground": true,
      "presentation": { "reveal": "always", "panel": "dedicated" },
      "runOptions": { "runOn": "folderOpen" },
      "group": "none"
    }
  ]
}
"@ | Set-Content $vscodeTasks -Encoding UTF8

# ============================================================================
# DONE
# ============================================================================
Write-Host ""
Write-Host "=========================================" -ForegroundColor Green
Write-Host "  Setup complete!" -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green
Write-Host ""
Write-Host "The watcher will auto-start on login."
Write-Host "Old notification emails are cleaned up hourly."
Write-Host ""
Write-Host "To start manually:  pwsh -File $watchScript"
Write-Host "To uninstall:       pwsh -File $(Join-Path $root 'uninstall.ps1')"
Write-Host ""
