# Copilot-Email-Notificaitons

Standalone PowerShell tool for VS Code Copilot Chat notifications.

It provides three pieces of functionality:
- Chat-complete email notifications when a Copilot response finishes streaming
- A 5-minute idle monitor so emails are skipped while you are actively using the machine
- Hourly Gmail cleanup for notification emails, with subject/date safeguards

It also optionally provides a fourth workflow feature:
- A stop-hook completion gate that runs your own commands such as `npm test`, `npm run lint`, or `pytest` before the watcher treats a Copilot task as truly complete

This project is standalone and separate from any pentesting or hackathon tooling.

It also does not use Meerkat. Notification delivery is done directly with:
- Gmail SMTP for sending chat-complete emails
- Gmail IMAP for cleanup of old notification emails
- Native PowerShell/.NET APIs for the idle monitor and scheduler setup

## Prerequisites

- **PowerShell 7+** (`pwsh`) — [Install](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell)
- **VS Code** with **GitHub Copilot Chat**
- **Gmail account** with [2-Step Verification](https://myaccount.google.com/security) enabled

## Quick Start

```sh
# 1. Clone or download this folder
# 2. Run the installer
pwsh -File install.ps1
```

The installer will:
1. Ask for your **Gmail address**
2. Ask for a **name for this computer** (shown in email subject)
3. Optionally enable a **stop hook** for VS Code and Copilot Chat completion checks
4. Ask for a **Gmail App Password** (see below)
5. Send a test email to confirm it works
6. Register auto-start on login + hourly email cleanup

## Gmail App Password Setup

1. Go to [Google Security Settings](https://myaccount.google.com/security)
2. Enable **2-Step Verification** if not already on
3. Go to [App Passwords](https://myaccount.google.com/apppasswords)
4. Create a new app password (name it "VS Code" or similar)
5. Copy the 16-character password — the installer will ask for it

## How It Works

**Watcher** (`watch.ps1`):
- Monitors VS Code's `chatSessions/*.jsonl` files for write activity
- When writes stop for 8 seconds (configurable), the chat response is considered complete
- Three-layer duplicate prevention:
  1. **Line-count check** — skips metadata-only rewrites (no new JSONL lines)
  2. **Per-file cooldown** — 60-second cooldown per file after sending
  3. **Idle detection** — skips email if user is actively at the machine
- Sends mail directly with Gmail SMTP; no Meerkat dependency or relay tier
- Sends a presentable HTML email with the computer name, session title, timestamp, a repository link, and a `© Purple Industries` footer

**Stop hook** (`stop-hook.ps1`):
- Optional completion gate configured by `install.ps1`
- Runs your own verification commands inside a target workspace after Copilot Chat goes quiet
- Writes `.copilot-stop-hook/last-result.json` and `.copilot-stop-hook/last-run.log` in that workspace
- Writes `.copilot-stop-hook/continue-required.md` on failure so Copilot instructions and the user have a simple local "not done yet" signal
- Suppresses the normal success email when checks fail
- Can send a separate failure email if you are idle and `notifyOnFailure` is enabled
- Generates or updates `.github/copilot-instructions.md` on request so Copilot Chat treats the stop-hook artifacts as the completion gate for that workspace

**Important limitation**:
- VS Code and GitHub Copilot Chat do not expose a public hard stop-hook API that an external PowerShell tool can block. This project implements the practical version instead: local command checks, result artifacts, and optional Copilot instructions that keep the completion standard explicit.

**Cleanup** (`cleanup.ps1`):
- Connects to Gmail via IMAP (SSL, port 993)
- Searches for emails whose subject contains both "Copilot" and "Complete"
- Applies a protected floor date of 04/01/2026 (never deletes earlier mail)
- Deletes only items older than 24 hours
- Uses direct IMAP commands implemented in PowerShell; no Meerkat dependency
- Deletes them automatically via IMAP STORE + EXPUNGE

**Installer test email** (`install.ps1`):
- Sends a styled setup-confirmation email after configuration succeeds
- Uses the same repo link and `© Purple Industries` footer as the main notification emails

## Deprecated Dependency Check

This repository was audited for deprecated `meerkat` usage.

Result:
- No runtime or dependency usage of `meerkat` exists in the repository
- No Meerkat packages, services, wrappers, or relay code are used
- The active implementation is direct SMTP + IMAP + local idle detection only

## Files

| File | Purpose |
|------|---------|
| `config.json` | Template file (placeholders only, safe to share) |
| `watch.ps1` | The main watcher script (thoroughly annotated) |
| `stop-hook.ps1` | Optional completion gate for tests/lint/custom commands |
| `cleanup.ps1` | Email cleanup via IMAP (thoroughly annotated) |
| `install.ps1` | Cross-platform setup wizard (thoroughly annotated) |
| `uninstall.ps1` | Clean removal of all registered services (thoroughly annotated) |

## Manual Usage

```sh
# Start the watcher manually
pwsh -File watch.ps1

# Run the stop hook manually with the configured workspace/commands
pwsh -File stop-hook.ps1

# Run cleanup manually
pwsh -File cleanup.ps1

# Uninstall everything
pwsh -File uninstall.ps1
```

## Configuration

Edit `config.json`:

```json
{
  "email": "you@gmail.com",
  "computerName": "My-PC",
  "quietSeconds": 8,
  "idleMinutes": 5,
  "cleanupMaxAgeHours": 24,
  "smtpServer": "smtp.gmail.com",
  "smtpPort": 587,
  "imapServer": "imap.gmail.com",
  "imapPort": 993,
  "stopHook": {
    "enabled": false,
    "workspacePath": "C:/path/to/workspace",
    "commands": [
      "npm test",
      "npm run lint"
    ],
    "timeoutSeconds": 900,
    "notifyOnFailure": true,
    "instructionFile": "C:/path/to/workspace/.github/copilot-instructions.md"
  }
}
```

At runtime, scripts prefer a private user config path and fall back to project `config.json`:

| Platform | Private config path |
|----------|---------------------|
| **Windows** | `%APPDATA%\CopilotEmailNotifier\config.json` |
| **macOS** | `~/Library/Application Support/CopilotEmailNotifier/config.json` |
| **Linux** | `~/.config/copilot-email-notifier/config.json` |

| Key | Description | Default |
|-----|-------------|---------|
| `email` | Your Gmail address (sender AND recipient) | — |
| `computerName` | Shown in email subject line | — |
| `quietSeconds` | Seconds of write silence before sending email | 8 |
| `idleMinutes` | Skip email if user has been active within this many minutes | 5 |
| `cleanupMaxAgeHours` | Delete notification emails older than this | 24 |
| `smtpServer` | Gmail SMTP server | smtp.gmail.com |
| `smtpPort` | SMTP port (STARTTLS) | 587 |
| `imapServer` | Gmail IMAP server | imap.gmail.com |
| `imapPort` | IMAP port (implicit SSL) | 993 |
| `stopHook.enabled` | Enables the completion gate | false |
| `stopHook.workspacePath` | Repo/workspace where commands should run | empty |
| `stopHook.commands` | Commands run in order until one fails | empty |
| `stopHook.timeoutSeconds` | Per-command timeout in seconds | 900 |
| `stopHook.notifyOnFailure` | Send failure email when idle | true |
| `stopHook.instructionFile` | Records the `.github/copilot-instructions.md` path when the installer generates it | empty |

When stop hook is enabled:
- The watcher writes result artifacts into `<workspace>/.copilot-stop-hook/`
- The installer adds `.copilot-stop-hook/` to that workspace's local `.git/info/exclude` when it detects a Git repo
- The normal "Copilot Chat Complete" email is only sent after the stop-hook passes

## Platform Details

### Auto-Start Mechanism

| Platform | Watcher | Cleanup |
|----------|---------|---------|
| **Windows** | Startup folder shortcut (`CopilotNotifier.lnk`) | Scheduled Task (`CopilotEmailCleanup`, hourly) |
| **macOS** | launchd LaunchAgent (`com.copilot-notifier.watch`) | launchd (hourly, `com.copilot-notifier.cleanup`) |
| **Linux** | systemd user service (`copilot-notifier.service`) | systemd timer (`copilot-notifier-cleanup.timer`, hourly) |

### Password Storage

| Platform | Storage Method |
|----------|---------------|
| **Windows** | User-scoped environment variable (`HKCU\Environment`) |
| **macOS** | Keychain Services (`security add-generic-password`) |
| **Linux** | `~/.copilot-notifier-env` file with `chmod 600` |

### Idle Detection

| Platform | Method | Unit |
|----------|--------|------|
| **Windows** | Win32 `user32.dll!GetLastInputInfo` (P/Invoke via C# Add-Type) | Milliseconds |
| **macOS** | `ioreg -c IOHIDSystem` → `HIDIdleTime` | Nanoseconds |
| **Linux** | `xprintidle` (must be installed: `sudo apt install xprintidle`) | Milliseconds |

### VS Code chatSessions Path

| Platform | Path |
|----------|------|
| **Windows** | `%APPDATA%\Code\User\workspaceStorage\<hash>\chatSessions\` |
| **macOS** | `~/Library/Application Support/Code/User/workspaceStorage/<hash>/chatSessions/` |
| **Linux** | `~/.config/Code/User/workspaceStorage/<hash>/chatSessions/` |

## Gmail Categorization

Emails include these headers to push them into Gmail's **Updates** tab (not Primary):
- `List-ID` — RFC 2919 mailing list identifier
- `List-Unsubscribe` — RFC 2369 unsubscribe mechanism
- `Precedence: bulk` — traditional bulk mail header
- `Auto-Submitted: auto-generated` — RFC 3834 automated message
- `Feedback-ID` — Gmail-specific classifier hint

## Security

- **No secrets are stored in any script file.** The app password is stored via:
  - Windows: User-scoped environment variable
  - macOS: Keychain (`security` CLI)
  - Linux: `~/.copilot-notifier-env` with `chmod 600`
- The app password is a **limited-scope credential** — it can only send/read email, not change your Google account settings or password
- All SMTP/IMAP connections use **TLS encryption**
- No data is sent to any third party — only Gmail's own SMTP/IMAP servers
- `config.json` is a template — keep personal email/computer name in the private config path above

## Uninstall

```sh
pwsh -File uninstall.ps1
```

This removes all auto-start entries, scheduled tasks/timers, and optionally the stored password.
If you enabled stop hook, uninstall also offers to remove the managed Copilot instructions block, the workspace `.copilot-stop-hook` folder, and the local Git exclude entry.
The project folder itself is left intact for you to remove manually.
