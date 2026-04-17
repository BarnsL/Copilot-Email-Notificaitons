##############################################################################
# watch.ps1 — Copilot Chat Email Notifier : Main Watcher Script
##############################################################################
#
# PURPOSE
# -------
# Monitors VS Code's internal Copilot Chat session files (chatSessions/*.jsonl)
# for filesystem write activity.  When Copilot is streaming a response, the
# .jsonl file is written to rapidly.  Once writes stop for a configurable
# "quiet" threshold (default 8 seconds), the script considers the response
# complete, optionally runs the stop-hook verification gate, and then sends an
# email notification via Gmail SMTP.
#
# THREE-LAYER DUPLICATE PREVENTION
# --------------------------------
# 1. Line-count check — if the JSONL line count did not increase since activity
#    was first detected, the write was metadata-only; skip email.
# 2. Per-file cooldown — after sending an email for a file, a 60-second
#    cooldown prevents re-triggering on the same session file.
# 3. Idle check — if the user has been physically interacting with the machine
#    for less than the idle threshold, the email is skipped (they're watching
#    the response live, so they don't need a notification).
#
# PLATFORM SUPPORT
# ----------------
# • Windows  — PowerShell 7+ (pwsh.exe)
# • macOS    — PowerShell 7+ (brew install --cask powershell)
# • Linux    — PowerShell 7+ (snap install powershell / apt install)
#
# Each platform differs in:
# - Where VS Code stores chatSessions (auto-discovered below)
# - How the Gmail App Password is retrieved (env var / Keychain / file)
# - How user idle time is measured (Win32 API / ioreg / xprintidle)
#
# PREREQUISITES
# - Gmail account with 2-Step Verification + App Password generated
# - GMAIL_APP_PASSWORD environment variable set (see install.ps1 / README)
# - VS Code with GitHub Copilot Chat extension (at least one chat session)
# - No Meerkat dependency: notification delivery is implemented directly in
#   this script via built-in .NET SMTP classes
#
##############################################################################

# ============================================================================
# PARAMETER: optional path to config.json (defaults to user-private path first,
# then falls back to same folder as script)
# ============================================================================
param(
    [string]$ConfigPath = ""   # Override: pwsh -File watch.ps1 -ConfigPath /path/to/config.json
)

# Stop on any terminating error — fail loudly so the user knows something broke
$ErrorActionPreference = "Stop"

# ============================================================================
# CONFIGURATION LOADING
# ============================================================================
# Config is loaded from a user-private path first, then local config.json.
# It holds:
#   email            — Gmail address (both the sender and recipient)
#   computerName     — human-friendly name shown in the email subject
#   quietSeconds     — seconds of silence after last write before sending
#   idleMinutes      — if user idle > this, email IS sent (they're away)
#   smtpServer/Port  — Gmail SMTP endpoint (smtp.gmail.com:587)
#   imapServer/Port  — Gmail IMAP endpoint (used by cleanup.ps1, not here)
#   stopHook         — optional completion gate config (workspace + commands)
# ============================================================================
# Prefer user-private config outside the project folder to avoid embedding
# personal data in source-controlled files.
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

if (-not $ConfigPath) {
    $ConfigPath = Get-DefaultConfigCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $ConfigPath) {
        $ConfigPath = Get-DefaultConfigCandidates | Select-Object -First 1
    }
}
if (-not (Test-Path $ConfigPath)) {
    Write-Error "Config not found: $ConfigPath — copy config.json and fill in your values."
    exit 1
}
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

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

# Unpack config into script-level variables for readability
$To            = $cfg.email           # Recipient email address
$From          = $cfg.email           # Sender address (same Gmail account)
$QuietSeconds  = $cfg.quietSeconds    # Silence threshold (default 8)
# idleMinutes may be absent in older config files — default to 5 minutes
$IdleMinutes   = if ($cfg.idleMinutes) { $cfg.idleMinutes } else { 5 }
$computerName  = $cfg.computerName    # e.g. "Workstation-01"
$smtpServer    = $cfg.smtpServer      # "smtp.gmail.com"
$smtpPort      = $cfg.smtpPort        # 587 (STARTTLS)
$ProjectRepoUrl = "https://github.com/BarnsL/Copilot-Email-Notificaitons"
$stopHookConfig = Get-StopHookConfig -Config $cfg

# Guard: if the user hasn't edited the placeholder values, refuse to run
if ($To -eq '[EMAIL]' -or $computerName -eq '[PC Name]') {
    Write-Error "Edit config.json first — replace [EMAIL] and [PC Name] with your values."
    exit 1
}

# ============================================================================
# APP PASSWORD RESOLUTION (cross-platform)
# ============================================================================
# The Gmail App Password is NEVER stored in any script or config file.
# It is retrieved from the platform-appropriate secure store.
#
# WINDOWS : User-scoped environment variable set by install.ps1 or manually.
#           Two lookups: first $env:GMAIL_APP_PASSWORD (process-inherited),
#           then [System.Environment]::GetEnvironmentVariable(..., "User")
#           for the persisted User-level registry value.
#
# macOS   : install.ps1 stores it in macOS Keychain; the shell profile line
#           added by install.ps1 exports it into the environment at login.
#           Here we just read $env:GMAIL_APP_PASSWORD.
#
# Linux   : install.ps1 stores it in ~/.copilot-notifier-env (chmod 600);
#           the shell profile sources it.  Same env var read here.
# ============================================================================
$appPassword = $env:GMAIL_APP_PASSWORD
if (-not $appPassword -and $IsWindows) {
    # Fallback: read the persisted User-level env var from the Windows registry.
    # This covers the case where the watcher was launched from a session that
    # did not inherit the variable (e.g. Task Scheduler, Startup shortcut).
    $appPassword = [System.Environment]::GetEnvironmentVariable("GMAIL_APP_PASSWORD", "User")
}
if (-not $appPassword) {
    Write-Error "GMAIL_APP_PASSWORD env var not set. See README.md for setup."
    exit 1
}

# ============================================================================
# AUTO-DISCOVER VS CODE chatSessions DIRECTORY (cross-platform)
# ============================================================================
# VS Code stores Copilot Chat conversations as .jsonl files inside
# <workspaceStorage>/<hash>/chatSessions/.  The workspace storage root
# differs by OS:
#
# WINDOWS : %APPDATA%\Code\User\workspaceStorage
# macOS   : ~/Library/Application Support/Code/User/workspaceStorage
# Linux   : ~/.config/Code/User/workspaceStorage
#
# Inside workspaceStorage there are many hash-named folders (one per
# workspace).  We scan all of them for a "chatSessions" subfolder, then
# pick the one whose most-recently-modified file is newest — that's the
# active workspace's chat sessions.
# ============================================================================
function Find-ChatSessionsDir {
    $paths = @()

    # Build list of candidate workspaceStorage roots based on current OS
    if ($IsWindows) {
        # %APPDATA% = C:\Users\<user>\AppData\Roaming
        $paths += "$env:APPDATA\Code\User\workspaceStorage"
    }
    elseif ($IsMacOS) {
        # macOS standard Application Support location
        $paths += "$HOME/Library/Application Support/Code/User/workspaceStorage"
    }
    else {
        # Linux XDG convention — VS Code uses ~/.config/Code/
        $paths += "$HOME/.config/Code/User/workspaceStorage"
    }

    foreach ($wsRoot in $paths) {
        if (-not (Test-Path $wsRoot)) { continue }

        # Enumerate every hash folder, check for a chatSessions subfolder
        $candidates = Get-ChildItem $wsRoot -Directory | ForEach-Object {
            $cs = Join-Path $_.FullName "chatSessions"
            if (Test-Path $cs) { $cs }
        }
        if ($candidates) {
            # Among all chatSessions dirs, find the one with the most recently
            # written file — that's the workspace you're actively chatting in.
            $best = $candidates | ForEach-Object {
                $latest = Get-ChildItem $_ -File -ErrorAction SilentlyContinue |
                          Sort-Object LastWriteTime -Descending | Select-Object -First 1
                [PSCustomObject]@{
                    Path = $_
                    Time = if ($latest) { $latest.LastWriteTime } else { [DateTime]::MinValue }
                }
            } | Sort-Object Time -Descending | Select-Object -First 1 -ExpandProperty Path
            return $best
        }
    }
    return $null
}

$SessionDir = Find-ChatSessionsDir
if (-not $SessionDir) {
    Write-Error "No VS Code chatSessions directory found. Is VS Code installed and has Copilot Chat been used?"
    exit 1
}

# ============================================================================
# STARTUP BANNER
# ============================================================================
# safeComputerName is a sanitized lowercase version used in email headers
# (List-ID) — only a-z, 0-9, and hyphens, to comply with RFC 2919.
$safeComputerName = $computerName.ToLower() -replace '[^a-z0-9\-]', ''
Write-Host "=== Copilot Chat Email Notifier ===" -ForegroundColor Cyan
Write-Host "Computer : $computerName"
Write-Host "Watching : $SessionDir"
Write-Host "Email to : $To"
Write-Host "Quiet threshold: ${QuietSeconds}s after last write"
Write-Host "Idle threshold : ${IdleMinutes}min (skip email if user is active)"
if ($stopHookConfig.enabled) {
    Write-Host "Stop hook      : enabled"
    Write-Host "  Workspace    : $($stopHookConfig.workspacePath)"
    Write-Host "  Commands     : $(@($stopHookConfig.commands).Count)"
    Write-Host "  Failure email: $($stopHookConfig.notifyOnFailure)"
}
else {
    Write-Host "Stop hook      : disabled"
}
Write-Host "Press Ctrl+C to stop." -ForegroundColor Yellow
Write-Host ""

# ============================================================================
# SCRIPT-LEVEL STATE VARIABLES
# ============================================================================
$script:lastWriteTime    = [DateTime]::MinValue   # Timestamp of the most recent file write detected
$script:activityDetected = $false                  # True while we're inside an "active writing" window
$script:timerRunning     = $false                  # True once writes have stopped; we're counting quiet time
$script:emailCount       = 0                       # Running total of emails sent this session (shown in logs)
$script:cooldowns        = @{}                     # Hashtable: file path → DateTime when cooldown expires
$script:lineCountAtStart = 0                       # JSONL line count snapshot when activity first detected
$CooldownSeconds         = 60                      # Seconds to ignore re-triggers on the same file

# ============================================================================
# IDLE DETECTION (cross-platform)
# ============================================================================
# If the user has been idle (no keyboard/mouse input) for >= IdleMinutes,
# we DO send the email — they're away from the machine and won't see the
# Copilot response.  If they're actively using the machine, we skip the
# email because they're already watching the response stream.
#
# WINDOWS — Win32 API: user32.dll!GetLastInputInfo
#   Returns a LASTINPUTINFO struct with dwTime = the tick count of the last
#   input event.  We subtract from Environment.TickCount to get idle ms.
#   This is declared via Add-Type with a C# P/Invoke wrapper.
#
# macOS — ioreg (IO Registry)
#   The IOHIDSystem class reports HIDIdleTime in nanoseconds.  We parse it
#   from `ioreg -c IOHIDSystem` output with a regex.
#
# Linux — xprintidle
#   A small utility that prints idle time in milliseconds.  Must be installed
#   separately: `sudo apt install xprintidle` (X11 only; won't work on
#   headless / pure Wayland without xwayland).
#
# FALLBACK: if detection fails on any platform (missing xprintidle, ioreg
# error, etc.), we return [double]::MaxValue so the idle check always passes
# and the email is sent — better to over-notify than silently swallow.
# ============================================================================

if ($IsWindows) {
    # Define a C# helper class at runtime that calls the Win32 API.
    # Add-Type compiles this into an in-memory assembly.
    # LASTINPUTINFO.cbSize must be set to Marshal.SizeOf(typeof(LASTINPUTINFO))
    # before calling GetLastInputInfo — Windows uses it for versioning.
    Add-Type @"
    using System;
    using System.Runtime.InteropServices;

    // Struct expected by GetLastInputInfo — must match Win32 definition
    public struct LASTINPUTINFO {
        public uint cbSize;    // Size of this struct in bytes (8 on 32-bit, 8 on 64-bit)
        public uint dwTime;    // Tick count (ms since boot) of last keyboard/mouse event
    }

    public class IdleDetect {
        // P/Invoke: import GetLastInputInfo from user32.dll
        // This function fills a LASTINPUTINFO struct with the tick count
        // of the most recent user input (keyboard, mouse, touch, pen).
        [DllImport("user32.dll")]
        static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

        // Returns the number of milliseconds since the last user input event.
        // Environment.TickCount = current tick count; subtract dwTime = idle ms.
        public static uint GetIdleMs() {
            LASTINPUTINFO lii = new LASTINPUTINFO();
            lii.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
            GetLastInputInfo(ref lii);
            return (uint)Environment.TickCount - lii.dwTime;
        }
    }
"@
}

function Get-IdleMinutes {
    <#
    .SYNOPSIS
        Returns the number of minutes since the user last interacted with the
        machine (keyboard, mouse, touch).  Cross-platform.
    .OUTPUTS
        [double] — idle time in fractional minutes.
        Returns [double]::MaxValue if detection fails (ensures email is sent).
    #>
    try {
        if ($IsWindows) {
            # Call the C# wrapper defined above → returns milliseconds
            return [IdleDetect]::GetIdleMs() / 60000.0
        }
        elseif ($IsMacOS) {
            # ioreg (IO Registry Explorer) queries the IOKit hardware tree.
            # IOHIDSystem is the Human Interface Device subsystem.
            # HIDIdleTime is reported in NANOSECONDS (divide by 1e9 for seconds).
            $raw = & ioreg -c IOHIDSystem 2>$null | Select-String 'HIDIdleTime'
            if ($raw -match '"HIDIdleTime"\s*=\s*(\d+)') {
                return [double]$Matches[1] / 1e9 / 60.0
            }
        }
        else {
            # Linux: xprintidle returns idle time in MILLISECONDS on stdout.
            # Only works on X11 (uses XScreenSaver extension internally).
            # On Wayland-only setups without XWayland, this won't be available.
            if (Get-Command xprintidle -ErrorAction SilentlyContinue) {
                $ms = & xprintidle 2>$null
                if ($ms) { return [double]$ms / 60000.0 }
            }
        }
    } catch { }
    # Detection failed — assume idle so the email is sent (safe default)
    return [double]::MaxValue
}

# ============================================================================
# SESSION TITLE EXTRACTION
# ============================================================================
# VS Code stores chat sessions as JSONL (one JSON object per line).
# The session title can appear in two forms:
#
# 1. Standalone update line (kind:2):
#    {"k":["customTitle"],"v":"My Session Title","kind":2}
#    → $j.k is ["customTitle"] and $j.v is the title string
#
# 2. Embedded in initial session object (kind:0):
#    {"v":{"customTitle":"My Session Title",...},"kind":0}
#    → $j.v.customTitle is the title string
#
# We scan ALL lines (not just the first few) because the title can be set
# or changed at any point during the conversation.  The last match wins.
# If no title is found, we return "(untitled)".
# ============================================================================
function Get-SessionTitle {
    param(
        [string]$SessionFile   # Full path to the .jsonl session file
    )
    try {
        $title = $null
        $lines = Get-Content $SessionFile -ErrorAction SilentlyContinue
        foreach ($line in $lines) {
            # Quick string check before expensive JSON parse — skip lines
            # that can't possibly contain a title reference
            if ($line -match '"customTitle"') {
                $j = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
                # Form 1: standalone update  {"k":["customTitle"],"v":"..."}
                if ($j.k -and ($j.k -join '.') -eq 'customTitle' -and $j.v) {
                    $title = $j.v
                }
                # Form 2: embedded in session object  {"v":{"customTitle":"..."}}
                if ($j.v -and $j.v.customTitle) {
                    $title = $j.v.customTitle
                }
            }
        }
        if ($title) { return $title }
    } catch { }
    return "(untitled)"
}

# ============================================================================
# EMAIL SENDING
# ============================================================================
# Uses System.Net.Mail.SmtpClient to send via Gmail SMTP (TLS on port 587).
# This repo does not route notifications through Meerkat or any other relay
# layer; the watcher talks directly to Gmail using the configured account.
#
# EMAIL HEADERS FOR GMAIL CATEGORIZATION:
# By default, emails from yourself to yourself land in Gmail's "Primary" tab.
# We add several RFC-standard headers that signal "automated/bulk" to Gmail's
# classifier, pushing the email to the "Updates" tab instead:
#
#   List-ID           — RFC 2919: identifies a mailing list; triggers bulk UI
#   List-Unsubscribe  — RFC 2369: provides unsubscribe mechanism (mailto: link)
#   Precedence: bulk  — traditional Unix/Sendmail header for bulk mail
#   Auto-Submitted    — RFC 3834: "auto-generated" = sent by automated process
#   Feedback-ID       — Gmail-specific: used for Gmail Postmaster/FBL; also
#                        helps Gmail's ML classifier detect notification patterns
#
# These headers are the strongest signals Gmail uses to categorize self-sent
# email into Updates rather than Primary.
# ============================================================================
function Send-NotificationEmail {
    param(
        [string]$SessionFile,  # Full path to the .jsonl file that completed
        [psobject]$StopHookResult = $null
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    # Extract just the filename (minus extension) as a session identifier
    $sessionName  = [System.IO.Path]::GetFileNameWithoutExtension($SessionFile)
    $sessionTitle = Get-SessionTitle -SessionFile $SessionFile

    try {
        # Create SMTP client — System.Net.Mail is available in all .NET runtimes
        $smtp = New-Object System.Net.Mail.SmtpClient($smtpServer, $smtpPort)
        $smtp.EnableSsl    = $true   # STARTTLS on port 587
        $smtp.Credentials  = New-Object System.Net.NetworkCredential($From, $appPassword)

        $mail = New-Object System.Net.Mail.MailMessage
        $mail.From = $From
        $mail.To.Add($To)
        $mail.Subject = "[$computerName] Copilot Chat Complete"

        # ---- Gmail categorization headers ----
        # List-ID: <copilot-notify.workstation-01.local>  (RFC 2919)
        $mail.Headers.Add("List-ID", "<copilot-notify.$safeComputerName.local>")
        # List-Unsubscribe: mailto link (required by RFC 2369 for List-ID)
        $mail.Headers.Add("List-Unsubscribe", "<mailto:$($From)?subject=unsubscribe>")
        # Precedence: bulk — traditional bulk mail indicator
        $mail.Headers.Add("Precedence", "bulk")
        # Auto-Submitted: auto-generated — RFC 3834 automated message
        $mail.Headers.Add("Auto-Submitted", "auto-generated")
        # Feedback-ID: Gmail-specific, format is campaign:sender:category
        $mail.Headers.Add("Feedback-ID", "copilot-notify:$($safeComputerName):vscode")

                # Presentable HTML body with project link and footer branding.
                $mail.IsBodyHtml = $true
                $mail.SubjectEncoding = [System.Text.Encoding]::UTF8
                $mail.BodyEncoding = [System.Text.Encoding]::UTF8
                $safeSessionTitle = [System.Net.WebUtility]::HtmlEncode($sessionTitle)
                $safeComputerLabel = [System.Net.WebUtility]::HtmlEncode($computerName)
                $safeTimestamp = [System.Net.WebUtility]::HtmlEncode($ts)
                $safeSessionId = [System.Net.WebUtility]::HtmlEncode($sessionName)
                $stopHookRows = ""
                if ($StopHookResult -and $StopHookResult.enabled) {
                    $safeStopHookStatus = [System.Net.WebUtility]::HtmlEncode("Passed ($(@($StopHookResult.commands).Count) command(s))")
                    $safeWorkspacePath = [System.Net.WebUtility]::HtmlEncode([string]$StopHookResult.workspacePath)
                    $stopHookRows = @"
                <tr>
                    <td style="padding:10px 12px;border-top:1px solid #efe6d6;font-weight:600;color:#5b6470;">Stop Hook</td>
                    <td style="padding:10px 12px;border-top:1px solid #efe6d6;">$safeStopHookStatus</td>
                </tr>
                <tr>
                    <td style="padding:10px 12px;font-weight:600;color:#5b6470;">Workspace</td>
                    <td style="padding:10px 12px;">$safeWorkspacePath</td>
                </tr>
"@
                }
                $mail.Body = @"
<div style="background:#f4f1ea;padding:24px;font-family:Segoe UI,Arial,sans-serif;color:#1f2937;">
    <div style="max-width:680px;margin:0 auto;background:#fffdf8;border:1px solid #e7dcc7;border-radius:16px;overflow:hidden;box-shadow:0 8px 24px rgba(0,0,0,0.08);">
        <div style="background:#1f3a5f;color:#ffffff;padding:20px 24px;">
            <div style="font-size:12px;letter-spacing:0.12em;text-transform:uppercase;opacity:0.85;">Copilot Email Notifications</div>
            <h1 style="margin:8px 0 0;font-size:24px;line-height:1.2;">Copilot Chat Complete</h1>
        </div>
        <div style="padding:24px;">
            <p style="margin:0 0 16px;font-size:15px;line-height:1.6;">A Copilot Chat response finished streaming and the idle monitor determined you were away from the machine.</p>
            <table style="width:100%;border-collapse:collapse;font-size:14px;line-height:1.5;">
                <tr>
                    <td style="padding:10px 12px;border-bottom:1px solid #efe6d6;width:180px;font-weight:600;color:#5b6470;">Computer</td>
                    <td style="padding:10px 12px;border-bottom:1px solid #efe6d6;">$safeComputerLabel</td>
                </tr>
                <tr>
                    <td style="padding:10px 12px;border-bottom:1px solid #efe6d6;font-weight:600;color:#5b6470;">Session Title</td>
                    <td style="padding:10px 12px;border-bottom:1px solid #efe6d6;">$safeSessionTitle</td>
                </tr>
                <tr>
                    <td style="padding:10px 12px;border-bottom:1px solid #efe6d6;font-weight:600;color:#5b6470;">Time</td>
                    <td style="padding:10px 12px;border-bottom:1px solid #efe6d6;">$safeTimestamp</td>
                </tr>
                <tr>
                    <td style="padding:10px 12px;font-weight:600;color:#5b6470;">Session ID</td>
                    <td style="padding:10px 12px;">$safeSessionId</td>
                </tr>
                $stopHookRows
            </table>
            <div style="margin-top:20px;padding:16px;border:1px solid #efe6d6;border-radius:12px;background:#fcfaf5;">
                <div style="font-size:12px;letter-spacing:0.08em;text-transform:uppercase;color:#7b6d57;margin-bottom:6px;">Project Repository</div>
                <a href="$ProjectRepoUrl" style="color:#1f3a5f;text-decoration:none;font-weight:600;">$ProjectRepoUrl</a>
            </div>
        </div>
        <div style="padding:18px 24px;background:#f7f2e8;border-top:1px solid #e7dcc7;font-size:12px;color:#6b7280;">
            &copy; Purple Industries
        </div>
    </div>
</div>
"@
        $smtp.Send($mail)
        $smtp.Dispose()
        $mail.Dispose()
        $script:emailCount++
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Email #$($script:emailCount) sent to $To" -ForegroundColor Green
    }
    catch {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Email FAILED: $_" -ForegroundColor Red
    }
}

function Send-StopHookFailureEmail {
    param(
        [string]$SessionFile,
        [psobject]$StopHookResult
    )

    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $sessionName  = [System.IO.Path]::GetFileNameWithoutExtension($SessionFile)
    $sessionTitle = Get-SessionTitle -SessionFile $SessionFile
    $failedCommand = $StopHookResult.commands | Where-Object { -not $_.passed } | Select-Object -First 1
    $failedCommandText = if ($failedCommand) { $failedCommand.command } else { $StopHookResult.summary }

    try {
        $smtp = New-Object System.Net.Mail.SmtpClient($smtpServer, $smtpPort)
        $smtp.EnableSsl    = $true
        $smtp.Credentials  = New-Object System.Net.NetworkCredential($From, $appPassword)

        $mail = New-Object System.Net.Mail.MailMessage
        $mail.From = $From
        $mail.To.Add($To)
        $mail.Subject = "[$computerName] Copilot Stop Hook Failed"
        $mail.Headers.Add("List-ID", "<copilot-notify.$safeComputerName.local>")
        $mail.Headers.Add("List-Unsubscribe", "<mailto:$($From)?subject=unsubscribe>")
        $mail.Headers.Add("Precedence", "bulk")
        $mail.Headers.Add("Auto-Submitted", "auto-generated")
        $mail.Headers.Add("Feedback-ID", "copilot-stop-hook:$($safeComputerName):vscode")

        $mail.IsBodyHtml = $true
        $mail.SubjectEncoding = [System.Text.Encoding]::UTF8
        $mail.BodyEncoding = [System.Text.Encoding]::UTF8

        $safeSessionTitle = [System.Net.WebUtility]::HtmlEncode($sessionTitle)
        $safeComputerLabel = [System.Net.WebUtility]::HtmlEncode($computerName)
        $safeTimestamp = [System.Net.WebUtility]::HtmlEncode($ts)
        $safeSessionId = [System.Net.WebUtility]::HtmlEncode($sessionName)
        $safeSummary = [System.Net.WebUtility]::HtmlEncode([string]$StopHookResult.summary)
        $safeWorkspacePath = [System.Net.WebUtility]::HtmlEncode([string]$StopHookResult.workspacePath)
        $safeFailedCommand = [System.Net.WebUtility]::HtmlEncode([string]$failedCommandText)
        $safeResultFile = [System.Net.WebUtility]::HtmlEncode([string]$StopHookResult.resultFile)
        $safeLogFile = [System.Net.WebUtility]::HtmlEncode([string]$StopHookResult.logFile)
        $safeContinueFile = [System.Net.WebUtility]::HtmlEncode([string]$StopHookResult.continueFile)
        $mail.Body = @"
<div style="background:#f4f1ea;padding:24px;font-family:Segoe UI,Arial,sans-serif;color:#1f2937;">
    <div style="max-width:680px;margin:0 auto;background:#fffdf8;border:1px solid #e7dcc7;border-radius:16px;overflow:hidden;box-shadow:0 8px 24px rgba(0,0,0,0.08);">
        <div style="background:#7a2e1f;color:#ffffff;padding:20px 24px;">
            <div style="font-size:12px;letter-spacing:0.12em;text-transform:uppercase;opacity:0.85;">Copilot Email Notifications</div>
            <h1 style="margin:8px 0 0;font-size:24px;line-height:1.2;">Continue Required</h1>
        </div>
        <div style="padding:24px;">
            <p style="margin:0 0 16px;font-size:15px;line-height:1.6;">A Copilot Chat response reached the quiet window, but the configured stop-hook checks did not pass. External tooling cannot hard-block Copilot Chat from ending, so this is the failure signal to continue the task.</p>
            <table style="width:100%;border-collapse:collapse;font-size:14px;line-height:1.5;">
                <tr>
                    <td style="padding:10px 12px;border-bottom:1px solid #efe6d6;width:180px;font-weight:600;color:#5b6470;">Computer</td>
                    <td style="padding:10px 12px;border-bottom:1px solid #efe6d6;">$safeComputerLabel</td>
                </tr>
                <tr>
                    <td style="padding:10px 12px;border-bottom:1px solid #efe6d6;font-weight:600;color:#5b6470;">Session Title</td>
                    <td style="padding:10px 12px;border-bottom:1px solid #efe6d6;">$safeSessionTitle</td>
                </tr>
                <tr>
                    <td style="padding:10px 12px;border-bottom:1px solid #efe6d6;font-weight:600;color:#5b6470;">Failed Check</td>
                    <td style="padding:10px 12px;border-bottom:1px solid #efe6d6;">$safeFailedCommand</td>
                </tr>
                <tr>
                    <td style="padding:10px 12px;border-bottom:1px solid #efe6d6;font-weight:600;color:#5b6470;">Summary</td>
                    <td style="padding:10px 12px;border-bottom:1px solid #efe6d6;">$safeSummary</td>
                </tr>
                <tr>
                    <td style="padding:10px 12px;border-bottom:1px solid #efe6d6;font-weight:600;color:#5b6470;">Workspace</td>
                    <td style="padding:10px 12px;border-bottom:1px solid #efe6d6;">$safeWorkspacePath</td>
                </tr>
                <tr>
                    <td style="padding:10px 12px;border-bottom:1px solid #efe6d6;font-weight:600;color:#5b6470;">Time</td>
                    <td style="padding:10px 12px;border-bottom:1px solid #efe6d6;">$safeTimestamp</td>
                </tr>
                <tr>
                    <td style="padding:10px 12px;border-bottom:1px solid #efe6d6;font-weight:600;color:#5b6470;">Session ID</td>
                    <td style="padding:10px 12px;border-bottom:1px solid #efe6d6;">$safeSessionId</td>
                </tr>
                <tr>
                    <td style="padding:10px 12px;border-bottom:1px solid #efe6d6;font-weight:600;color:#5b6470;">Result File</td>
                    <td style="padding:10px 12px;border-bottom:1px solid #efe6d6;">$safeResultFile</td>
                </tr>
                <tr>
                    <td style="padding:10px 12px;border-bottom:1px solid #efe6d6;font-weight:600;color:#5b6470;">Log File</td>
                    <td style="padding:10px 12px;border-bottom:1px solid #efe6d6;">$safeLogFile</td>
                </tr>
                <tr>
                    <td style="padding:10px 12px;font-weight:600;color:#5b6470;">Continue File</td>
                    <td style="padding:10px 12px;">$safeContinueFile</td>
                </tr>
            </table>
            <div style="margin-top:20px;padding:16px;border:1px solid #efe6d6;border-radius:12px;background:#fcfaf5;">
                <div style="font-size:12px;letter-spacing:0.08em;text-transform:uppercase;color:#7b6d57;margin-bottom:6px;">Project Repository</div>
                <a href="$ProjectRepoUrl" style="color:#1f3a5f;text-decoration:none;font-weight:600;">$ProjectRepoUrl</a>
            </div>
        </div>
        <div style="padding:18px 24px;background:#f7f2e8;border-top:1px solid #e7dcc7;font-size:12px;color:#6b7280;">
            &copy; Purple Industries
        </div>
    </div>
</div>
"@
        $smtp.Send($mail)
        $smtp.Dispose()
        $mail.Dispose()
        $script:emailCount++
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Failure email #$($script:emailCount) sent to $To" -ForegroundColor Yellow
    }
    catch {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Failure email FAILED: $_" -ForegroundColor Red
    }
}

function Get-PwshExecutablePath {
    if ($IsWindows) {
        return (Join-Path $PSHOME "pwsh.exe")
    }
    return (Join-Path $PSHOME "pwsh")
}

function Invoke-StopHook {
    param(
        [string]$SessionFile
    )

    if (-not $stopHookConfig.enabled) {
        return [PSCustomObject]@{
            enabled = $false
            passed  = $true
            skipped = $true
            summary = 'Stop hook disabled.'
        }
    }

    $stopHookScript = Join-Path $PSScriptRoot "stop-hook.ps1"
    if (-not (Test-Path $stopHookScript)) {
        return [PSCustomObject]@{
            enabled       = $true
            passed        = $false
            workspacePath = $stopHookConfig.workspacePath
            commands      = @()
            resultFile    = ""
            continueFile  = ""
            logFile       = ""
            summary       = "stop-hook.ps1 not found next to watch.ps1."
        }
    }

    try {
        $output = & (Get-PwshExecutablePath) -NoProfile -ExecutionPolicy Bypass -File $stopHookScript -ConfigPath $ConfigPath -SessionFile $SessionFile
        $rawOutput = ($output | ForEach-Object { "$_" }) -join "`n"
        if (-not $rawOutput) {
            throw "Stop hook returned no JSON output."
        }

        $result = $rawOutput | ConvertFrom-Json -ErrorAction Stop
        if (-not ($result.PSObject.Properties.Name -contains 'enabled')) {
            $result | Add-Member -NotePropertyName enabled -NotePropertyValue $true -Force
        }
        if (-not ($result.PSObject.Properties.Name -contains 'summary')) {
            $result | Add-Member -NotePropertyName summary -NotePropertyValue "Stop hook completed." -Force
        }
        return $result
    }
    catch {
        return [PSCustomObject]@{
            enabled       = $true
            passed        = $false
            workspacePath = $stopHookConfig.workspacePath
            commands      = @()
            resultFile    = ""
            continueFile  = ""
            logFile       = ""
            summary       = $_.Exception.Message
        }
    }
}

# ============================================================================
# MAIN WATCH LOOP
# ============================================================================
# Uses System.IO.FileSystemWatcher (declared but event-driven features are
# not used — we poll manually for simplicity and cross-platform reliability).
#
# The loop runs every 500ms and:
#   1. Lists all *.jsonl files in the chatSessions directory
#   2. Finds the most recently written one
#   3. If its LastWriteTime is newer than what we've seen → activity detected
#   4. Once activity stops for $QuietSeconds → run the 3-layer dedup gate
#   5. If configured, run the stop-hook completion checks
#   6. If the remaining gates pass → send success or failure email as needed
#
# FileSystemWatcher is created primarily to keep the watcher handle alive
# and so the WatcherPath is monitored by the OS; the actual detection uses
# direct directory listing for maximum reliability across all platforms
# (FSW has known quirks on macOS/Linux in certain edge cases).
# ============================================================================

# Create a FileSystemWatcher pointed at the chatSessions directory
$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path                = $SessionDir
$watcher.Filter              = "*.jsonl"          # Only care about .jsonl files
# NotifyFilter: fire on LastWrite time changes and file Size changes
$watcher.NotifyFilter        = [System.IO.NotifyFilters]::LastWrite -bor [System.IO.NotifyFilters]::Size
$watcher.EnableRaisingEvents = $true               # Necessary for FSW to be active
$changedFile = ""                                   # Will hold the path of the most recently changed file

try {
    while ($true) {
        # ---- Step 1: Poll the directory for the most recently written .jsonl file ----
        $files = Get-ChildItem $SessionDir -Filter "*.jsonl" -ErrorAction SilentlyContinue
        $newest = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1

        if ($newest -and $newest.LastWriteTime -gt $script:lastWriteTime) {
            # A file has been written to since our last check

            # ---- Cooldown gate ----
            # If we recently sent an email for this exact file, don't re-trigger.
            # The cooldown hashtable maps file path → DateTime when the cooldown
            # expires.  If we're still within the cooldown window, silently
            # update lastWriteTime and skip.
            $cd = $script:cooldowns[$newest.FullName]
            if ($cd -and (Get-Date) -lt $cd) {
                # Within cooldown — just update the timestamp and move on
                $script:lastWriteTime = $newest.LastWriteTime
            }
            else {
                # ---- First detection of new activity ----
                if (-not $script:activityDetected) {
                    $script:activityDetected = $true
                    # Snapshot the current line count — we'll compare later to see
                    # if actual content was added (not just metadata rewrites)
                    $script:lineCountAtStart = (Get-Content $newest.FullName -ErrorAction SilentlyContinue | Measure-Object).Count
                    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Chat activity detected on $($newest.Name)..." -ForegroundColor DarkYellow
                }
                # Update tracking state
                $script:lastWriteTime = $newest.LastWriteTime
                $changedFile          = $newest.FullName
                $script:timerRunning  = $true
                $quietStart           = Get-Date   # Start the quiet-period timer
            }
        }
        elseif ($script:timerRunning) {
            # No new writes detected, but we're in the quiet-period counting phase
            $elapsed = (Get-Date) - $quietStart
            if ($elapsed.TotalSeconds -ge $QuietSeconds) {
                # ---- Quiet threshold reached — run dedup checks ----

                # DEDUP LAYER 1: Line count comparison
                # If the file has the same (or fewer) lines as when activity
                # started, it was just metadata rewriting, not a new response.
                $currentLines = (Get-Content $changedFile -ErrorAction SilentlyContinue | Measure-Object).Count
                if ($currentLines -le $script:lineCountAtStart) {
                    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] File updated but no new content. Skipping." -ForegroundColor DarkGray
                }
                else {
                    $stopHookResult = Invoke-StopHook -SessionFile $changedFile
                    if ($stopHookResult.enabled) {
                        if ($stopHookResult.passed) {
                            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Stop hook passed."
                        }
                        else {
                            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Stop hook failed: $($stopHookResult.summary)" -ForegroundColor Red
                            if ($stopHookResult.continueFile) {
                                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Continue file: $($stopHookResult.continueFile)" -ForegroundColor DarkYellow
                            }
                        }
                    }

                    # DEDUP LAYER 3: Idle detection
                    # If the user is actively at their machine (idle time < threshold),
                    # they are already present for the result and can inspect any
                    # stop-hook artifacts locally.
                    $idleMins = Get-IdleMinutes
                    if ($stopHookResult.enabled -and -not $stopHookResult.passed) {
                        if ($idleMins -ge $IdleMinutes) {
                            if ($stopHookConfig.notifyOnFailure) {
                                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Stop hook failed and user is idle ($([math]::Round($idleMins,1))min). Sending failure email..." -ForegroundColor Yellow
                                Send-StopHookFailureEmail -SessionFile $changedFile -StopHookResult $stopHookResult
                            }
                            else {
                                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Stop hook failed but failure emails are disabled." -ForegroundColor DarkGray
                            }
                        }
                        else {
                            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Stop hook failed but user active (idle $([math]::Round($idleMins,1))min < ${IdleMinutes}min). Skipping email." -ForegroundColor DarkGray
                        }
                    }
                    elseif ($idleMins -ge $IdleMinutes) {
                        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Chat complete (${QuietSeconds}s quiet, idle $([math]::Round($idleMins,1))min). Sending email..." -ForegroundColor Cyan
                        Send-NotificationEmail -SessionFile $changedFile -StopHookResult $stopHookResult
                    }
                    else {
                        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Chat complete but user active (idle $([math]::Round($idleMins,1))min < ${IdleMinutes}min). Skipping email." -ForegroundColor DarkGray
                    }
                }

                # DEDUP LAYER 2: Set per-file cooldown
                # Regardless of whether we sent an email or not, set a cooldown
                # on this file so that any immediate re-triggers are ignored.
                $script:cooldowns[$changedFile] = (Get-Date).AddSeconds($CooldownSeconds)

                # Reset state for the next detection cycle
                $script:activityDetected = $false
                $script:timerRunning     = $false
            }
        }

        # Poll interval: 500ms is frequent enough to catch file writes
        # without noticeable CPU overhead (the loop body is O(n) in the
        # number of .jsonl files, which is typically < 20).
        Start-Sleep -Milliseconds 500
    }
}
finally {
    # Cleanup: dispose the FileSystemWatcher when the script is stopped (Ctrl+C)
    $watcher.Dispose()
    Write-Host "Watcher stopped."
}
