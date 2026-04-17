##############################################################################
# cleanup.ps1 — Copilot Chat Email Notifier : Email Cleanup Script
##############################################################################
#
# PURPOSE
# -------
# Connects to Gmail via IMAP (SSL, port 993) and deletes notification emails
# that are older than a configurable age (default 24 hours).  This prevents
# your inbox from accumulating stale notifications while protecting older mail.
#
# HOW IT WORKS
# ------------
# 1. Reads config from a user-private path first, then local config.json.
# 2. Retrieves the Gmail App Password from the platform-secure store.
# 3. Opens a raw TCP → SSL connection to imap.gmail.com:993.
# 4. Authenticates with IMAP LOGIN command.
# 5. SELECTs INBOX.
# 6. Searches for messages matching:
#      SUBJECT contains BOTH "Copilot" and "Complete"
#      SINCE 04/01/2026 and BEFORE <cutoff-date>
# 7. Marks matching messages with the \Deleted flag.
# 8. Issues EXPUNGE to permanently remove flagged messages.
# 9. Logs out and closes the connection.
#
# SCHEDULING
# ----------
# install.ps1 registers this script to run hourly via:
#   WINDOWS : Scheduled Task "CopilotEmailCleanup"
#   macOS   : launchd agent com.copilot-notifier.cleanup (StartInterval 3600)
#   Linux   : systemd timer copilot-notifier-cleanup.timer (OnUnitActiveSec=1h)
#
# MANUAL USE
# ----------
#   pwsh -File cleanup.ps1
#   pwsh -File cleanup.ps1 -ConfigPath /path/to/config.json
#
# PLATFORM SUPPORT
# ----------------
# Works identically on Windows, macOS, and Linux.  Uses only .NET Standard
# types (TcpClient, SslStream, StreamReader, StreamWriter) available in all
# PowerShell 7+ runtimes.  No platform-specific code needed.
# The cleanup path is also self-contained: it does not use Meerkat or any
# external mail-processing service, only direct IMAP commands to Gmail.
#
# PREREQUISITES
# - Gmail account with IMAP enabled (enabled by default on most accounts)
# - GMAIL_APP_PASSWORD environment variable set
# - config.json with valid email and IMAP settings
#
##############################################################################

# ============================================================================
# PARAMETER: optional path to config.json (defaults to user-private path first,
# then falls back to same folder as script)
# ============================================================================
param(
    [string]$ConfigPath = ""   # Override: pwsh -File cleanup.ps1 -ConfigPath /path/to/config.json
)

# Stop on terminating errors — important for IMAP operations where partial
# execution could leave the connection in a bad state
$ErrorActionPreference = "Stop"

# ============================================================================
# CONFIGURATION LOADING
# ============================================================================
# Same config.json as watch.ps1.  We read:
#   email              — Gmail address for IMAP login
#   cleanupMaxAgeHours — delete emails older than this (default 24)
#   imapServer         — "imap.gmail.com"
#   imapPort           — 993 (implicit SSL/TLS)
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
    Write-Error "Config not found: $ConfigPath"
    exit 1
}
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$Email       = $cfg.email                # Gmail address
$MaxAgeHours = $cfg.cleanupMaxAgeHours   # Hours before deletion (default 24)
$imapServer  = $cfg.imapServer           # "imap.gmail.com"
$imapPort    = $cfg.imapPort             # 993

# Guard against un-edited config
if ($Email -eq '[EMAIL]') {
    Write-Error "Edit config.json first — replace [EMAIL] with your Gmail address."
    exit 1
}

# ============================================================================
# APP PASSWORD RESOLUTION (cross-platform)
# ============================================================================
# Same logic as watch.ps1:
#   WINDOWS : $env:GMAIL_APP_PASSWORD → fallback to User-level env var
#   macOS   : $env:GMAIL_APP_PASSWORD (populated from Keychain via shell rc)
#   Linux   : $env:GMAIL_APP_PASSWORD (populated from ~/.copilot-notifier-env)
# ============================================================================
$appPassword = $env:GMAIL_APP_PASSWORD
if (-not $appPassword -and $IsWindows) {
    # Read from the persistent User-level environment variable in the registry
    $appPassword = [System.Environment]::GetEnvironmentVariable("GMAIL_APP_PASSWORD", "User")
}
if (-not $appPassword) {
    Write-Error "GMAIL_APP_PASSWORD not set."
    exit 1
}

# ============================================================================
# IMAP COMMAND HELPER
# ============================================================================
# IMAP is a text-line protocol.  Each command is prefixed with a unique tag
# (e.g. "a1", "a2") so the client can match responses to commands.
# The server responds with zero or more untagged lines (starting with "* ")
# followed by one tagged line (e.g. "a1 OK LOGIN completed").
#
# This helper sends a tagged command and reads response lines until it
# encounters the matching tag, then returns all collected lines.
# ============================================================================
function Send-Imap {
    param(
        $Writer,            # StreamWriter wrapping the SSL stream
        $Reader,            # StreamReader wrapping the SSL stream
        [string]$Tag,       # Unique command tag, e.g. "a1"
        [string]$Command    # IMAP command text, e.g. "LOGIN user pass"
    )
    # Send the tagged command (Writer.AutoFlush is enabled)
    $Writer.WriteLine("$Tag $Command")

    # Collect response lines until we see our tag at the start of a line
    $lines = @()
    while ($true) {
        $line = $Reader.ReadLine()
        $lines += $line
        # When the server sends "a1 OK ..." or "a1 NO ...", we're done
        if ($line -match "^$Tag ") { break }
    }
    return $lines
}

# ============================================================================
# MAIN: CONNECT, SEARCH, DELETE, DISCONNECT
# ============================================================================
# Uses raw TCP + SSL rather than a library because PowerShell 7 doesn't ship
# with an IMAP client and adding a NuGet dependency for a single operation
# is overkill.  The IMAP command subset we need is tiny:
# LOGIN, SELECT, SEARCH, STORE, EXPUNGE, LOGOUT.
# This also keeps the implementation independent of deprecated intermediaries
# such as Meerkat: cleanup is performed by direct IMAP commands.
# ============================================================================
try {
    # ---- Step 1: TCP connection to IMAP server ----
    # Port 993 uses implicit SSL — the entire connection is wrapped in TLS
    # from the start (unlike port 143 + STARTTLS).
    $tcp = [System.Net.Sockets.TcpClient]::new($imapServer, $imapPort)

    # ---- Step 2: Wrap in SSL/TLS ----
    # SslStream handles the TLS handshake transparently.
    # Second param ($false) = don't leave inner stream open when SSL is disposed.
    $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(), $false)
    $ssl.AuthenticateAsClient($imapServer)   # Validates the server certificate

    # ---- Step 3: Create text readers/writers over the encrypted stream ----
    $reader = [System.IO.StreamReader]::new($ssl)
    $writer = [System.IO.StreamWriter]::new($ssl)
    $writer.AutoFlush = $true   # Flush after every Write/WriteLine

    # ---- Step 4: Read server greeting ----
    # IMAP servers send an untagged greeting line, e.g. "* OK Gimap ready"
    $null = $reader.ReadLine()

    # ---- Step 5: LOGIN ----
    # Command: a1 LOGIN <email> <app-password>
    # On success: "a1 OK ... authenticated (Success)"
    $resp = Send-Imap $writer $reader "a1" "LOGIN $Email $appPassword"
    if ($resp[-1] -notmatch "^a1 OK") {
        Write-Error "IMAP login failed: $($resp[-1])"
        exit 1
    }

    # ---- Step 6: SELECT INBOX ----
    # Opens INBOX in read-write mode (needed for STORE + EXPUNGE)
    $null = Send-Imap $writer $reader "a2" "SELECT INBOX"

    # ---- Step 7: SEARCH for old notification emails ----
    # Calculate the cutoff date: current time minus MaxAgeHours
    $cutoff = (Get-Date).AddHours(-$MaxAgeHours)
    # Safety floor: never delete anything dated before 04/01/2026.
    $minDeleteDate = [DateTime]::ParseExact("04/01/2026", "MM/dd/yyyy", [System.Globalization.CultureInfo]::InvariantCulture)

    if ($cutoff -le $minDeleteDate) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] No eligible emails: cutoff is at/before protected floor date (04/01/2026)."
        $null = Send-Imap $writer $reader "a6" "LOGOUT"
        return
    }

    # IMAP date format: DD-Mon-YYYY (e.g. "15-Jun-2025")
    # InvariantCulture ensures English month abbreviations regardless of locale.
    $beforeDate = $cutoff.ToString("dd-MMM-yyyy", [System.Globalization.CultureInfo]::InvariantCulture)
    $sinceDate  = $minDeleteDate.ToString("dd-MMM-yyyy", [System.Globalization.CultureInfo]::InvariantCulture)

    # Match ONLY notification-style subjects containing BOTH "Copilot" and "Complete",
    # and only within the date window [04/01/2026, cutoff).
    $searchResp = Send-Imap $writer $reader "a3" "SEARCH SUBJECT `"Copilot`" SUBJECT `"Complete`" SINCE $sinceDate BEFORE $beforeDate"

    # ---- Step 8: Parse search results ----
    # Untagged response: "* SEARCH 1 5 12 47" (space-separated message sequence numbers)
    # If no matches: "* SEARCH" with no numbers, or the line is absent entirely
    $uids = @()
    foreach ($line in $searchResp) {
        if ($line -match '^\* SEARCH (.+)') {
            $uids = $Matches[1].Trim() -split '\s+'
        }
    }

    if ($uids.Count -eq 0) {
        # Nothing to clean
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] No Copilot+Complete emails in the allowed date window older than ${MaxAgeHours}h."
    } else {
        # ---- Step 9: Flag messages for deletion ----
        # STORE command adds the \Deleted flag to all matched messages.
        # We join the UIDs with commas for a single bulk STORE command:
        # "a4 STORE 1,5,12,47 +FLAGS (\Deleted)"
        $uidList = $uids -join ','
        $null = Send-Imap $writer $reader "a4" "STORE $uidList +FLAGS (\Deleted)"

        # ---- Step 10: EXPUNGE — permanently remove flagged messages ----
        # EXPUNGE tells the server to immediately and irreversibly delete
        # all messages in the selected mailbox that have the \Deleted flag.
        $null = Send-Imap $writer $reader "a5" "EXPUNGE"

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Deleted $($uids.Count) Copilot+Complete notification email(s) older than ${MaxAgeHours}h (protected floor: 04/01/2026)."
    }

    # ---- Step 11: LOGOUT ----
    # Gracefully close the IMAP session
    $null = Send-Imap $writer $reader "a6" "LOGOUT"
}
catch {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Cleanup error: $_" -ForegroundColor Red
}
finally {
    # ---- Cleanup: dispose all I/O objects in reverse order ----
    # Even if an exception occurred, we always close the streams and socket
    # to prevent resource leaks and lingering connections.
    if ($reader) { $reader.Dispose() }    # StreamReader
    if ($writer) { $writer.Dispose() }    # StreamWriter
    if ($ssl)    { $ssl.Dispose() }       # SslStream (TLS layer)
    if ($tcp)    { $tcp.Dispose() }       # TcpClient (raw TCP socket)
}
