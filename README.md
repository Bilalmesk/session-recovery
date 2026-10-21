# Session Recovery

**Reopen the apps, Explorer folders and browser tabs that were open before a crash, power cut or unexpected restart.**

Session Recovery is a local Windows utility. It snapshots your desktop every few minutes and offers to restore it after an unexpected shutdown. No external modules, no browser extension, no telemetry.

> **Important:** It reopens applications and tabs. It cannot recover unsaved document contents, passwords or form data.

- Windows 10/11 with Windows PowerShell 5.1.
- Chrome, Edge, Brave, Vivaldi, Opera and Firefox.
- Uses Task Scheduler (one UAC prompt) or a Startup-folder watcher with no administrator rights.
- Everything stays on your PC.

## Features

- Automatic snapshots every 3 minutes, plus one at logon.
- Crash-aware restore prompt, manual restore window, and unattended command-line restore.
- Apps, File Explorer folders and grouped browser tabs are restored together.
- Duplicate tabs and browser window groups are preserved.
- Capture exclusions keep chosen apps, folders and URLs out of new snapshots.
- Selective restore by app, folder or browser, with wildcard include/exclude filters.
- Snapshot listing, age-based cleanup and a diagnostics report.
- Local snapshots, logs and settings only; nothing is uploaded.

## Quick start

### Install

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-SessionRecovery.ps1
```

Windows shows a UAC prompt once and registers two scheduled tasks:

- `SessionRecovery-Snapshot` — snapshots at logon and every 3 minutes.
- `SessionRecovery-RestorePrompt` — checks for a crash at logon.

To install without administrator rights:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-SessionRecovery.ps1 -NoTasks
```

This creates a hidden watcher and restore prompt in the Startup folder instead.

The installer creates:

- Program files in `%LOCALAPPDATA%\SessionRecovery\app`.
- Data in `%LOCALAPPDATA%\SessionRecovery` (`snapshots`, `logs`, `config.json`).
- Start Menu shortcuts: **Restore Session**, **Take Snapshot Now**, **Run Diagnostics** and **Uninstall Session Recovery**.
- A desktop **Restore Session** shortcut.

### Check that it works

Open **Start Menu → Session Recovery → Take Snapshot Now**, then check the log:

```powershell
Get-Content "$env:LOCALAPPDATA\SessionRecovery\logs\session-recovery.log" -Tail 10
```

You should see `Snapshot saved`. Snapshots are stored in:

```text
%LOCALAPPDATA%\SessionRecovery\snapshots
```

Open **Restore Session** to confirm the window lists your current apps and folders. If something looks wrong, open **Run Diagnostics**.

## Installation options

| Option | Default | Meaning |
| --- | --- | --- |
| `-NoTasks` | off | Use the Startup-folder watcher instead of scheduled tasks. No administrator rights. |
| `-IntervalMinutes <n>` | `3` | Minutes between snapshots. |
| `-KeepSnapshots <n>` | `48` | Maximum number of snapshot files. |
| `-KeepSnapshotDays <n>` | `0` | Delete snapshots older than this many days. `0` disables age cleanup. |
| `-PromptOnLogon <mode>` | `CrashOnly` | `CrashOnly`, `Always` or `Never`. |
| `-DefaultTabMode <mode>` | `Smart` | `Smart`, `Captured`, `Native` or `None`. |
| `-NoDesktopShortcut` | off | Skip the desktop shortcut. |
| `-NoInitialSnapshot` | off | Skip the snapshot taken during installation. |
| `-InstallDirectory <path>` | `%LOCALAPPDATA%\SessionRecovery\app` | Install program files elsewhere. |

Examples:

```powershell
# Snapshot every 5 minutes and keep 96 files
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-SessionRecovery.ps1 -IntervalMinutes 5 -KeepSnapshots 96

# Keep nothing older than 30 days
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-SessionRecovery.ps1 -KeepSnapshotDays 30

# No UAC prompt, and prompt after every logon
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-SessionRecovery.ps1 -NoTasks -PromptOnLogon Always
```

Re-running the installer replaces program files, stops an old watcher and preserves snapshots and most settings.

## How it works

1. **Capture.** Visible top-level windows, executable paths, File Explorer folders and browser session files are read. Configured exclusions are applied before the snapshot is written.
2. **Rotate.** Snapshots are deleted when they exceed `keepSnapshots` or, if enabled, `keepSnapshotDays`.
3. **Detect.** At logon, the tool compares recent crash and clean-shutdown events.
4. **Restore.** After a crash (or when configured), the restore window opens. Selected apps, folders and browser windows are started.

Captured: app executable and simple file arguments, window titles, minimized state, Explorer folder paths, browser profiles and tabs.

Not captured: unsaved work, passwords, cookies/form data, exact window positions, or Microsoft Store/UWP apps.

## Restoring

### Automatic prompt

With the default `CrashOnly`, a **Session Recovery** window appears after an unexpected shutdown, about 20–30 seconds after sign-in. It uses the newest snapshot taken before logon. Items are checked by default; uncheck what you do not want, choose a tab mode, and click **Restore selected**. Click **Skip** to leave the snapshot untouched.

The prompt does not appear after a clean shutdown, when `promptOnLogon` is `Never`, or when the latest snapshot is older than `maxRestoreAgeHours`.

### Manual restore window

Use **Start Menu → Session Recovery → Restore Session** or the desktop shortcut. Manual restore:

- Always opens, even after a clean shutdown.
- Lets you pick any saved snapshot.
- Uses the same checkboxes, tab mode and force option.

### Command line

All scripts are in `%LOCALAPPDATA%\SessionRecovery\app`.

```powershell
$app = "$env:LOCALAPPDATA\SessionRecovery\app"

# List snapshots with age, counts and paths
powershell -NoProfile -ExecutionPolicy Bypass -File "$app\Restore-Session.ps1" -ListSnapshots

# Preview the latest snapshot without launching anything
powershell -NoProfile -ExecutionPolicy Bypass -File "$app\Restore-Session.ps1" -Manual -DryRun

# Restore a filtered selection without a window
powershell -NoProfile -ExecutionPolicy Bypass -File "$app\Restore-Session.ps1" -NoUI -IncludeApps 'OpenCode,ZCode' -IncludeBrowsers Brave

# Restore everything except selected apps, folders and browsers
powershell -NoProfile -ExecutionPolicy Bypass -File "$app\Restore-Session.ps1" -NoUI -ExcludeApps 'Game*' -ExcludeFolders 'D:\Private\*' -ExcludeBrowsers vivaldi
```

| Parameter | Meaning |
| --- | --- |
| `-Manual` | Show the restore window and list all saved snapshots. |
| `-NoUI` | Restore the newest eligible snapshot without a window. |
| `-DryRun` | Print what would be restored and exit. |
| `-Force` | Start apps even when already running. May create duplicates. |
| `-SnapshotPath <path>` | Use a specific snapshot JSON file. |
| `-TabMode <mode>` | Override the configured tab mode. |
| `-MaxAgeHours <n>` | Override `maxRestoreAgeHours`. |
| `-ListSnapshots` | Print saved snapshots and exit. |
| `-IncludeApps <patterns>` | Only apps matching name, path or executable leaf name. |
| `-IncludeFolders <patterns>` | Only folders matching the full path. |
| `-IncludeBrowsers <patterns>` | Only browsers matching key or display name. |
| `-ExcludeApps <patterns>` | Skip matching apps. |
| `-ExcludeFolders <patterns>` | Skip matching folders. |
| `-ExcludeBrowsers <patterns>` | Skip matching browsers. |

Include filters run first, then exclude filters. Patterns use PowerShell wildcards (`*`, `?`, `[abc]`) and are case-insensitive. For `powershell.exe -File`, pass multiple patterns as one comma-separated argument, such as `-IncludeApps 'OpenCode,ZCode'`.

Filters apply to `-NoUI` and `-DryRun`; the interactive window uses its checkboxes. If nothing matches, the script prints a message and exits without starting anything.

`-NoUI` still applies the automatic age and pre-logon filters. Use `-Manual` to include older snapshots, or `-SnapshotPath` to choose one explicitly.

### Browser tab modes

| CLI value | Window label | Behavior |
| --- | --- | --- |
| `Smart` | Smart - reopen captured tabs when available | Uses captured tabs when present; otherwise asks the browser to restore its own session. |
| `Captured` | Captured tabs - reopen the exact tabs | Opens URLs from the snapshot or current session; falls back to native restore. |
| `Native` | Browser session - use the browser's own restore | Starts with `--restore-last-session` (Chromium) or `-restore` (Firefox). |
| `None` | Do not reopen browsers or tabs | Skips browsers entirely. |

`Captured` preserves window grouping and duplicate tabs. Large windows are split into multiple launches to stay within command-line limits.

## Configuration

Settings live in `%LOCALAPPDATA%\SessionRecovery\config.json`.

```json
{
  "snapshotIntervalMinutes": 3,
  "keepSnapshots": 48,
  "keepSnapshotDays": 0,
  "promptOnLogon": "CrashOnly",
  "maxRestoreAgeHours": 72,
  "restoreBrowsers": true,
  "defaultTabMode": "Smart",
  "excludeApps": [],
  "excludeFolders": [],
  "excludeUrls": []
}
```

| Setting | Default | Meaning |
| --- | --- | --- |
| `snapshotIntervalMinutes` | `3` | Minutes between snapshots. |
| `keepSnapshots` | `48` | Maximum snapshot files. At 3-minute intervals this is about 2.4 hours. |
| `keepSnapshotDays` | `0` | Delete snapshots older than this many days. `0` disables age cleanup. |
| `promptOnLogon` | `CrashOnly` | `CrashOnly`, `Always` or `Never`. |
| `maxRestoreAgeHours` | `72` | Ignore older snapshots in the automatic prompt. Manual restore still lists them. |
| `restoreBrowsers` | `true` | Set `false` to remove browsers entirely from restore. |
| `defaultTabMode` | `Smart` | Initial tab mode: `Smart`, `Captured`, `Native` or `None`. |
| `excludeApps` | `[]` | Wildcards matched against app display name and executable path. |
| `excludeFolders` | `[]` | Wildcards matched against full Explorer folder paths. |
| `excludeUrls` | `[]` | Wildcards matched against captured browser URLs. |

### Exclusions

Add patterns inside the existing JSON object:

```json
{
  "excludeApps": ["KeePass*", "*\\1Password.exe"],
  "excludeFolders": ["C:\\Users\\bilal\\Private*", "D:\\Taxes"],
  "excludeUrls": ["*bank*", "*mail.google.com*"]
}
```

Patterns are case-insensitive. If every tab in a browser profile is excluded, that profile is omitted so native restore cannot reopen the excluded pages.

Watcher mode and one-shot snapshots read exclusions on every capture; no restart is needed. Scheduled-task mode also reads them at runtime. **Only new snapshots are affected.** Existing JSON files still contain anything captured earlier.

To verify, take a snapshot and inspect it:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\SessionRecovery\app\Save-Session.ps1"
Get-ChildItem "$env:LOCALAPPDATA\SessionRecovery\snapshots" -Filter 'session-*.json' |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1 |
    Get-Content -Raw | ConvertFrom-Json | Select-Object apps, explorer, browsers
```

### Applying changes

- **Watcher mode (`-NoTasks`):** interval, retention and exclusions are read every cycle.
- **Scheduled-task mode:** retention, exclusions and restore settings are read at runtime. Re-run the installer to change the snapshot interval.
- **Reinstalling:** install-time options are applied, while snapshots, exclusions and other settings are preserved.
- Both retention limits apply: a file is deleted when it is beyond the count or older than `keepSnapshotDays`.

## Diagnostics

Open **Start Menu → Session Recovery → Run Diagnostics**, or run:

```powershell
$diagnostics = "$env:LOCALAPPDATA\SessionRecovery\app\Diagnostics.ps1"

powershell -NoProfile -ExecutionPolicy Bypass -File $diagnostics
powershell -NoProfile -ExecutionPolicy Bypass -File $diagnostics -Json
powershell -NoProfile -ExecutionPolicy Bypass -File $diagnostics -ReportPath "$env:TEMP\session-recovery-report.txt"
```

The report checks program files, config validity, snapshot count/size/age, watcher or scheduled-task mode, browsers, settings, exclusions and recent log lines.

You can also call the module directly:

```powershell
Import-Module "$env:LOCALAPPDATA\SessionRecovery\app\SessionRecovery.psm1" -Force
Get-SRDiagnostics | Format-List
```

Diagnostics are local-only. Reports contain paths, URLs and log messages, so review them before sharing.

## Data, logs and privacy

| Path | Contents |
| --- | --- |
| `%LOCALAPPDATA%\SessionRecovery\snapshots` | Snapshot JSON files. |
| `%LOCALAPPDATA%\SessionRecovery\logs\session-recovery.log` | Snapshot, restore and error messages. |
| `%LOCALAPPDATA%\SessionRecovery\config.json` | Settings. |
| `%LOCALAPPDATA%\SessionRecovery\app` | Program files. |

- Snapshots contain executable paths, window titles, folder paths and browser URLs.
- The tool makes no network requests and uses no browser extension or debugging port.
- Snapshots and logs are not encrypted. Use Windows account permissions or BitLocker on shared devices.
- Exclusions only affect new snapshots; delete old files if you need to remove existing data today.
- To back up a session, copy its JSON file. Restore it elsewhere with `-SnapshotPath`.

## Troubleshooting

Start with **Run Diagnostics**. It usually shows whether the problem is config, snapshots, the watcher or a task.

For a manual check:

```powershell
$root = Join-Path $env:LOCALAPPDATA 'SessionRecovery'
Get-Content (Join-Path $root 'logs\session-recovery.log') -Tail 50
Get-ChildItem (Join-Path $root 'snapshots') -File | Sort-Object LastWriteTime -Descending | Select-Object -First 5 Name, Length, LastWriteTime
Get-ScheduledTask -TaskName 'SessionRecovery-*' -ErrorAction SilentlyContinue | Format-Table TaskName, State
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*Watch-Session.ps1*' } | Select-Object ProcessId, CommandLine
```

| Problem | What to check |
| --- | --- |
| Installer blocked | Run it with `powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-SessionRecovery.ps1`; unblock downloaded files with `Unblock-File`. |
| No UAC or tasks missing | Install with `-NoTasks`, or re-run and approve UAC. Check Task Scheduler and Task Manager → Startup. |
| No snapshots | Run `Save-Session.ps1`; check the log, snapshot folder permissions, free space, and whether the watcher or task is running. |
| No restore prompt after a crash | Check `promptOnLogon`, `maxRestoreAgeHours`, crash detection and whether the prompt was already skipped. Use **Restore Session**. |
| Prompt appears after a normal restart | Crash detection is heuristic. Set `promptOnLogon` to `Never` or click **Skip**. |
| Apps missing from a snapshot | Only visible top-level windows are captured. UWP apps, elevated apps, tray-only apps and apps that exited are skipped. |
| Excluded item still appears | Exclusions only affect new snapshots. Check the display name/path/URL pattern, then take a fresh snapshot. |
| Browser tabs missing or wrong | Use **Captured tabs**. Chromium session files can lag a few minutes; internal and extension URLs are skipped. |
| Extra blank browser window | Some Chromium builds do this. Close it, or use **Captured tabs** after starting the browser. |
| Apps do not start | The executable may have moved, need elevation, require a custom launcher, or already be running. |
| Apps start twice | Leave **Force** off and uncheck apps Windows already starts at logon. |
| Selective restore does nothing | Filters apply only to `-NoUI` and `-DryRun`; check `restoreBrowsers`, run with `-DryRun`, and confirm the snapshot contains the items. |
| Uninstall leaves files | Sign out and back in, then delete `%LOCALAPPDATA%\SessionRecovery`. Run the uninstaller elevated if tasks remain. |

Crash detection is a heuristic. Inspect recent events with:

```powershell
Get-WinEvent -FilterHashtable @{
    LogName = 'System'
    Id = 41, 6008, 1001, 1074, 6006
    StartTime = (Get-Date).AddDays(-7)
} -ErrorAction SilentlyContinue | Sort-Object TimeCreated -Descending |
    Select-Object -First 15 TimeCreated, Id, ProviderName
```

## Known limitations

- Unsaved work is not recovered; only windows, folders and tabs are reopened.
- Exact window positions and monitor layout are not restored.
- One launch per executable/argument group; multiple document windows may not be recreated individually.
- Microsoft Store/UWP apps, elevated apps, tray-only apps and hidden windows are skipped.
- Command-line switches are generally dropped; simple file paths and URLs may be kept.
- Pinned tabs reopen as normal tabs; browser internal/extension URLs are skipped.
- Private/incognito windows are not guaranteed to be captured.
- Chromium session files can lag; a readable current browser session can win over the snapshot.
- Exclusions do not rewrite existing snapshots.
- Selective filters are command-line only; the interactive window uses checkboxes.
- Age-based retention can delete history permanently.
- Snapshots and logs are not encrypted.
- The tool is per-user.

## Uninstall

Use **Start Menu → Session Recovery → Uninstall Session Recovery**, or:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\SessionRecovery\app\Uninstall-SessionRecovery.ps1"
```

Add `-RemoveData` to delete snapshots, logs and config as well. Removing scheduled tasks may require UAC.

## Running from source

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "Import-Module '.\src\SessionRecovery.psm1' -Force; Save-SRSnapshot"
powershell -NoProfile -ExecutionPolicy Bypass -File .\src\Restore-Session.ps1 -Manual
powershell -NoProfile -ExecutionPolicy Bypass -File .\src\Diagnostics.ps1
```

To keep test data separate:

```powershell
$env:SESSIONRECOVERY_HOME = Join-Path $PWD 'test-data'
powershell -NoProfile -ExecutionPolicy Bypass -Command "Import-Module '.\src\SessionRecovery.psm1' -Force; Save-SRSnapshot"
```

`SESSIONRECOVERY_HOME` changes the root used for snapshots, logs and config.json.

## Project layout

```text
session-recovery/
├── Install-SessionRecovery.ps1      Installer and shortcuts
├── Uninstall-SessionRecovery.ps1    Uninstaller
├── README.md                        This guide
└── src/
    ├── SessionRecovery.psm1         Capture, exclusions, browsers, diagnostics, restore engine
    ├── Save-Session.ps1             One-shot snapshot
    ├── Restore-Session.ps1          Restore UI, selective CLI restore, snapshot listing
    ├── Diagnostics.ps1              Health report
    ├── Watch-Session.ps1            Hidden watcher
    └── RunHidden.vbs                Hidden launcher
```
