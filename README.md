# Session Recovery

**Reopen the apps, Explorer folders and browser tabs that were open before a crash, power cut or unexpected restart.**

Session Recovery is a local Windows utility with a native desktop Studio. It snapshots your desktop every few minutes and offers to restore it after an unexpected shutdown. No external modules, no browser extension, no telemetry.

> **Important:** It reopens applications and tabs. It cannot recover unsaved document contents, passwords or form data.

- Windows 10/11 with Windows PowerShell 5.1.
- Chrome, Edge, Brave, Vivaldi, Opera, Opera GX, Chromium and Firefox.
- Native `SessionRecovery.exe` host: no visible `cmd` or PowerShell windows.
- Everything stays on your PC.

## Features

- Modern **Session Recovery Studio** with Dashboard, Snapshots, Exclusions, Settings, Diagnostics and About pages, in a dark **Aurora** and a light **Daylight** theme.
- Automatic snapshots every 3 minutes, plus one at logon.
- Native tray app with Studio, restore, snapshot-now, pause, pause-for-1-hour, folders, settings, diagnostics and exit actions.
- Snapshot timeline with previews and one-click restore.
- Restored apps return to their captured **position, size and maximized state**, clamped to the current monitors so nothing lands off-screen.
- Crash-aware restore prompt, manual restore window, and unattended command-line restore.
- The restore window shows **live progress** and a per-item results list instead of a pop-up.
- Apps, File Explorer folders and grouped browser tabs are restored together, with app icons in the restore list.
- **VLC playback restore**: the playing video reopens at (or within one snapshot interval of) the moment it was playing.
- Chrome/Chromium capture uses structured session files first, then UI Automation and local browser history as a safe fallback. Approximate tabs are marked in the snapshot and in the Studio.
- Duplicate tabs and browser window groups are preserved.
- Capture exclusions keep chosen apps, folders and URLs out of new snapshots.
- Selective restore by app, folder or browser, with wildcard include/exclude filters.
- **Pin** snapshots you care about; retention never deletes a pinned file.
- **Export** any snapshot to a JSON file and **import** snapshots back in, for backup or another PC.
- Snapshot **search across content**: app names, folder paths, browser names, tab titles and URLs, not just dates.
- Shell and terminal windows are skipped during capture and restore, so restoration does not flash command prompts.
- Logon tasks left by older releases are handed to the native host, avoiding their PowerShell windows.
- In-app update checks with SHA256-verified MSI downloads in **About**.
- Snapshot listing, age-based cleanup, health checks and a diagnostics report.
- Optional desktop shortcut, startup protection and notification controls.
- Local snapshots, logs and settings only; nothing is uploaded.

## Quick start

### Install from the MSI

Download `SessionRecovery-<version>.msi` from the GitHub **Releases** page and run it. The MSI installs per-user without a UAC prompt and keeps your snapshots and settings when you upgrade.

The setup wizard includes a **Custom Setup** page where you can:

- choose the install folder (the default is `%LOCALAPPDATA%\SessionRecovery\app`);
- keep or clear the optional **Desktop shortcut** feature.

By default it creates a **Session Recovery** desktop icon, Start Menu shortcuts, a Startup entry that launches the native background app after the next sign-in, and a Startup entry for the crash restore prompt. The desktop icon and **Session Recovery** Start Menu item open the Studio directly.

The MSI is not code-signed. If Windows SmartScreen appears, choose **More info → Run anyway** after verifying the SHA256 published with the release.

### Install with the PowerShell installer

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-SessionRecovery.ps1
```

Windows shows a UAC prompt once and registers two scheduled tasks:

- `SessionRecovery-Snapshot` — snapshots at logon and every 3 minutes.
- `SessionRecovery-RestorePrompt` — checks for a crash at logon.

Both tasks run the native `SessionRecovery.exe`, so no console windows appear. The tray app also starts at sign-in in monitor-only mode, so you still get the notification-area controls.

To install without administrator rights:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-SessionRecovery.ps1 -NoTasks
```

This creates a background tray app and restore prompt in the Startup folder instead. The tray app owns the snapshot timer.

The installer creates:

- Program files in `%LOCALAPPDATA%\SessionRecovery\app`.
- Data in `%LOCALAPPDATA%\SessionRecovery` (`snapshots`, `logs`, `config.json`).
- Start Menu shortcuts: **Session Recovery**, **Restore Session**, **Take Snapshot Now**, **Run in Background**, **Run Diagnostics** and **Uninstall Session Recovery**.
- A desktop **Session Recovery** shortcut.
- A **Session Recovery - Background** Startup entry. The MSI and `-NoTasks` mode also add a **Session Recovery - Restore Prompt** Startup entry.

### Check that it works

Open **Session Recovery** from the desktop or Start Menu, then click **Capture now** on the Dashboard. The Snapshots page should show the new snapshot immediately. You can also check the log:

```powershell
Get-Content "$env:LOCALAPPDATA\SessionRecovery\logs\session-recovery.log" -Tail 10
```

You should see `Snapshot saved`. Snapshots are stored in:

```text
%LOCALAPPDATA%\SessionRecovery\snapshots
```

Use **Restore Session** in the Studio or Start Menu to confirm the window lists your current apps and folders. If something looks wrong, open **Diagnostics** in the Studio.

## Updates

Open **Studio → About → Application updates** and choose **Check for updates**. When a newer release is available, **Download and install** fetches the MSI, verifies the published SHA256, asks for confirmation, and starts the per-user Windows installer. The Studio closes while the MSI updates it; snapshots, settings and exclusions are preserved.

The repository is private, so update checks need GitHub authentication. The app uses an authenticated GitHub CLI session (`gh auth login`) when available, then `SESSIONRECOVERY_UPDATE_TOKEN`, `GITHUB_TOKEN` or `GH_TOKEN`. No token or authentication data is stored by Session Recovery.

If you prefer to update manually, download the new MSI and its `.sha256` file from the GitHub **Releases** page, close the Studio, and run the MSI.

## Installation options

| Option | Default | Meaning |
| --- | --- | --- |
| `-NoTasks` | off | Use the background tray app instead of scheduled tasks. No administrator rights. |
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

Re-running the installer replaces program files, stops the old background app and preserves snapshots and most settings.

## Background tray

The native notification-area app makes the background state visible and gives you quick controls:

- **Left-click** the icon to open the Session Recovery Studio.
- **Right-click** for the menu: Open Session Recovery, restore, take a snapshot now, pause or resume automatic snapshots, pause for 1 hour, open the snapshots folder, settings, diagnostics, or exit.
- The tooltip and menu show the latest snapshot time and the current background mode.
- **Pause** is available when the tray app owns the snapshot timer. When Windows scheduled tasks are driving snapshots, the tray runs in monitor-only mode so snapshots are never duplicated.
- **Pause for 1 hour** suspends snapshots and resumes them automatically; the tooltip shows the resume time. Unchecking Pause also cancels a timed pause.
- The tray app starts from the Startup folder. The MSI and `-NoTasks` installer use it as the only background process; the scheduled-task installer uses it as a status and control surface.
- The tray app is the native `SessionRecovery.exe --tray`, so it never opens a console window.

If the tray icon is hidden by Windows, open the notification-area overflow (the `^` chevron) and drag **Session Recovery** onto the taskbar to keep it visible.

## How it works

1. **Capture.** Visible top-level windows, executable paths, window bounds, File Explorer folders and browser session files are read. Configured exclusions are applied before the snapshot is written.
2. **Rotate.** Snapshots are deleted when they exceed `keepSnapshots` or, if enabled, `keepSnapshotDays`. Pinned snapshots are never deleted and do not count against the limit.
3. **Detect.** At logon, the tool compares recent crash and clean-shutdown events.
4. **Restore.** After a crash (or when configured), the restore window opens. Selected apps, folders and browser windows are started, and each app's window is moved back to its captured position and size.

Captured: app executable and simple file arguments, window titles, window position/size/maximized state, minimized state, Explorer folder paths, browser profiles and tabs, and the file a media player (VLC) is playing with an estimated position.

Not captured: unsaved work, passwords, cookies/form data, window z-order, or Microsoft Store/UWP apps.

## Restoring

### Automatic prompt

With the default `CrashOnly`, a **Session Recovery** window appears after an unexpected shutdown, about 20–30 seconds after sign-in. It uses the newest snapshot taken before logon. Items are checked by default; uncheck what you do not want, choose a tab mode, and click **Restore selected**. Click **Skip** to leave the snapshot untouched.

The prompt does not appear after a clean shutdown, when `promptOnLogon` is `Never`, or when the latest snapshot is older than `maxRestoreAgeHours`.

### Manual restore window

Use **Start Menu → Session Recovery → Restore Session**, or open the Studio, select a snapshot on the **Snapshots** page and click **Restore selected**. The desktop **Session Recovery** icon opens the Studio, where the same restore action is one click away.

Manual restore:

- Always opens, even after a clean shutdown.
- Lets you pick any saved snapshot.
- Uses the same checkboxes, tab mode and force option.
- Shows live progress while items reopen, then a per-item results list (started or skipped) in place of a pop-up.
- Restores each application's window to the position, size and maximized state captured in the snapshot. Position restore can be turned off with `restoreWindowPositions`.

### Command line

The native host and the scripts are in `%LOCALAPPDATA%\SessionRecovery\app`.

```powershell
$app = "$env:LOCALAPPDATA\SessionRecovery\app"

# Native host: take a snapshot without a console window
& "$app\SessionRecovery.exe" --snapshot

# Native host: open the manual restore window
& "$app\SessionRecovery.exe" --restore-manual

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

Settings live in `%LOCALAPPDATA%\SessionRecovery\config.json`. The Studio **Settings** page edits the common options, applies the startup/desktop shortcuts immediately and saves the file; advanced users can edit the JSON directly.

```json
{
  "snapshotIntervalMinutes": 3,
  "keepSnapshots": 48,
  "keepSnapshotDays": 0,
  "promptOnLogon": "CrashOnly",
  "maxRestoreAgeHours": 72,
  "restoreBrowsers": true,
  "restoreWindowPositions": true,
  "defaultTabMode": "Smart",
  "captureBrowserTabs": true,
  "captureApproximateTabs": true,
  "tabHistoryLookbackHours": 24,
  "showNotifications": true,
  "startWithWindows": true,
  "desktopShortcut": true,
  "theme": "Aurora",
  "excludeApps": [],
  "excludeFolders": [],
  "excludeUrls": [],
  "pinnedSnapshots": []
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
| `restoreWindowPositions` | `true` | Move restored app windows back to their captured position, size and maximized state. |
| `defaultTabMode` | `Smart` | Initial tab mode: `Smart`, `Captured`, `Native` or `None`. |
| `captureBrowserTabs` | `true` | Capture browser tabs while taking snapshots. |
| `captureApproximateTabs` | `true` | Allow the UI Automation/history fallback when a Chromium session file has no tabs. Approximate tabs are marked in the snapshot. |
| `captureMediaPlayers` | `true` | Capture the file a media player (VLC) is playing, plus an estimated playback position. |
| `tabHistoryLookbackHours` | `24` | How far back the Chromium history fallback may look. |
| `showNotifications` | `true` | Show tray balloons and snapshot toasts. |
| `startWithWindows` | `true` | Create the **Session Recovery - Background** Startup shortcut. |
| `desktopShortcut` | `true` | Create the **Session Recovery** desktop shortcut. |
| `theme` | `Aurora` | Studio theme: `Aurora` (dark) or `Daylight` (light). Applied the next time the Studio opens. |
| `excludeApps` | `[]` | Wildcards matched against app display name and executable path. |
| `excludeFolders` | `[]` | Wildcards matched against full Explorer folder paths. |
| `excludeUrls` | `[]` | Wildcards matched against captured browser URLs. |
| `pinnedSnapshots` | `[]` | Snapshot file names that retention must never delete. Managed with **Pin** in the Studio. |

### Pinning, exporting and importing snapshots

On the **Snapshots** page:

- **Pin** keeps a snapshot forever. Pinned files are skipped by both count and age retention, and they do not consume the `keepSnapshots` budget. The timeline and the detail panel show a PINNED marker.
- **Export** copies the selected snapshot to any folder as a plain JSON file.
- **Import** copies a snapshot JSON file back into the timeline. The file is validated first; a random JSON file is rejected. Imported snapshots restore with `-SnapshotPath` or from the timeline like any other.

The **Search** box matches app names and paths, Explorer folders, browser names, tab titles and URLs, as well as dates — useful for finding the snapshot where a specific page or project was open.

### Media playback (VLC)

When VLC is playing a video, each snapshot records the file and the playback position. A restore reopens VLC with that file and seeks back to the captured moment.

- Positions are **estimated between snapshots**: VLC only writes an exact position when it closes cleanly, so after a crash the restore lands at most one snapshot interval (default 3 minutes) *before* the crash point — you rewatch a little, you never skip ahead.
- If VLC itself is configured to continue playback automatically, exact positions from clean stops are used to keep the estimate honest.
- The restore list shows what was playing and where (for example `Playing episode.mp4 at 27:24`); estimated positions are marked with `~` in the Studio.
- Media files inside excluded folders are never captured.
- If VLC is already running when a restore starts, it is skipped like any other running app.

Only local files are captured this way; discs, streams and playlists open the player without a seek.

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

Tray mode and one-shot snapshots read exclusions on every capture; no restart is needed. Scheduled-task mode also reads them at runtime. **Only new snapshots are affected.** Existing JSON files still contain anything captured earlier.

To verify, take a snapshot and inspect it:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\SessionRecovery\app\Save-Session.ps1"
Get-ChildItem "$env:LOCALAPPDATA\SessionRecovery\snapshots" -Filter 'session-*.json' |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1 |
    Get-Content -Raw | ConvertFrom-Json | Select-Object apps, explorer, browsers
```

### Applying changes

- **Tray mode (`-NoTasks` or MSI):** interval, retention and exclusions are read every cycle.
- **Scheduled-task mode:** retention, exclusions and restore settings are read at runtime. Re-run the installer to change the snapshot interval.
- **Reinstalling:** install-time options are applied, while snapshots, exclusions and other settings are preserved.
- Both retention limits apply: a file is deleted when it is beyond the count or older than `keepSnapshotDays`.

## Diagnostics

Open **Session Recovery → Diagnostics** in the Studio, or **Start Menu → Session Recovery → Run Diagnostics**. The Studio shows snapshot freshness, background mode, browser detection and recent errors in one place.

For a scripted report, run:

```powershell
$diagnostics = "$env:LOCALAPPDATA\SessionRecovery\app\Diagnostics.ps1"

powershell -NoProfile -ExecutionPolicy Bypass -File $diagnostics
powershell -NoProfile -ExecutionPolicy Bypass -File $diagnostics -Json
powershell -NoProfile -ExecutionPolicy Bypass -File $diagnostics -ReportPath "$env:TEMP\session-recovery-report.txt"
```

The report checks program files, config validity, snapshot count/size/age, tray or scheduled-task mode, browsers, settings, exclusions and recent log lines.

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
| `%LOCALAPPDATA%\SessionRecovery\media-state.json` | Media player tracking between snapshots (playing file, position anchor). |
| `%LOCALAPPDATA%\SessionRecovery\app` | Program files. |

- Snapshots contain executable paths, window titles, folder paths and browser URLs. Media snapshots additionally contain the playing video's path and an estimated position.
- The tool makes no network requests and uses no browser extension or debugging port.
- Snapshots and logs are not encrypted. Use Windows account permissions or BitLocker on shared devices.
- Exclusions only affect new snapshots; delete old files if you need to remove existing data today.
- To back up a session, copy its JSON file. Restore it elsewhere with `-SnapshotPath`.

## Troubleshooting

Start with **Run Diagnostics**. It usually shows whether the problem is config, snapshots, the tray app or a task.

For a manual check:

```powershell
$root = Join-Path $env:LOCALAPPDATA 'SessionRecovery'
Get-Content (Join-Path $root 'logs\session-recovery.log') -Tail 50
Get-ChildItem (Join-Path $root 'snapshots') -File | Sort-Object LastWriteTime -Descending | Select-Object -First 5 Name, Length, LastWriteTime
Get-ScheduledTask -TaskName 'SessionRecovery-*' -ErrorAction SilentlyContinue | Format-Table TaskName, State
Get-CimInstance Win32_Process -Filter "Name='SessionRecovery.exe'" | Select-Object ProcessId, CommandLine
```

| Problem | What to check |
| --- | --- |
| Installer blocked | Run it with `powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-SessionRecovery.ps1`; unblock downloaded files with `Unblock-File`. |
| No UAC or tasks missing | Install with `-NoTasks`, or re-run and approve UAC. Check Task Scheduler and Task Manager → Startup. |
| No snapshots | Open the Studio and click **Capture now**; check the log, snapshot folder permissions, free space, and whether the tray app or task is running. |
| No restore prompt after a crash | Check `promptOnLogon`, `maxRestoreAgeHours`, crash detection and whether the prompt was already skipped. Use **Restore Session**. |
| Prompt appears after a normal restart | Crash detection is heuristic. Set `promptOnLogon` to `Never` or click **Skip**. |
| Apps missing from a snapshot | Only visible top-level windows are captured. UWP apps, elevated apps, tray-only apps and apps that exited are skipped. |
| Excluded item still appears | Exclusions only affect new snapshots. Check the display name/path/URL pattern, then take a fresh snapshot. |
| Browser tabs missing or wrong | Use **Captured tabs**. Chromium session files can lag; when the fallback is used the Studio marks those tabs as approximate. Internal and extension URLs are skipped. |
| Extra blank browser window | Some Chromium builds do this. Close it, or use **Captured tabs** after starting the browser. |
| Apps do not start | The executable may have moved, need elevation, require a custom launcher, or already be running. |
| Apps start twice | Leave **Force** off and uncheck apps Windows already starts at logon. |
| Selective restore does nothing | Filters apply only to `-NoUI` and `-DryRun`; check `restoreBrowsers`, run with `-DryRun`, and confirm the snapshot contains the items. |
| Uninstall leaves files | MSI uninstall now remembers a custom install folder. If files remain from an older build, sign out and back in, then delete `%LOCALAPPDATA%\SessionRecovery`. Run the uninstaller elevated if tasks remain. |

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
- VLC playback positions are estimates between snapshots; after a crash the video resumes up to one snapshot interval early. Streams, discs and playlists reopen without a seek.
- Window position restore is best-effort: apps that hand off to an already-running instance, swap their main window while starting, or manage their own placement may not move. Windows are clamped to the current monitors.
- One launch per executable/argument group; multiple document windows may not be recreated individually.
- Microsoft Store/UWP apps, elevated apps, tray-only apps and hidden windows are skipped.
- Command-line switches are generally dropped; simple file paths and URLs may be kept.
- Pinned tabs reopen as normal tabs; browser internal/extension URLs are skipped.
- Private/incognito windows are not guaranteed to be captured.
- Chromium session files can lag; a readable current browser session can win over the snapshot.
- When a Chromium session file has no usable tabs, the fallback combines UI Automation titles and local history. Those tabs are marked approximate and may miss or add a tab.
- Exclusions do not rewrite existing snapshots.
- Selective filters are command-line only; the interactive window uses checkboxes.
- Age-based retention can delete history permanently, except for pinned snapshots.
- Snapshots and logs are not encrypted.
- The tool is per-user.

## Uninstall

If you installed from the MSI, use **Settings → Apps → Installed apps → Session Recovery → Uninstall**, or **Start Menu → Session Recovery → Uninstall Session Recovery**. The MSI removes program files and shortcuts but keeps your snapshots and settings.

For the PowerShell installer, use **Start Menu → Session Recovery → Uninstall Session Recovery**, or:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\SessionRecovery\app\Uninstall-SessionRecovery.ps1"
```

Add `-RemoveData` to delete snapshots, logs and config as well. Removing scheduled tasks may require UAC.

## Building the MSI

Prerequisites: .NET SDK 6 or newer and internet access for the WiX NuGet restore.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\installer\Build-MSI.ps1
```

The build compiles the native host first, then writes `dist\SessionRecovery-2.2.0.msi`, its `.sha256` file and a short release README. Use `-Version 2.2.1` for a later build. `dist\` is intentionally ignored by Git; publish the MSI as a GitHub Release asset rather than committing it.

The WiX package uses the per-user model (`ALLUSERS=2`, `MSIINSTALLPERUSER=1`), `WixUI_FeatureTree` for install-folder browsing and optional features, and a **Desktop shortcut** feature that is selected by default but can be cleared in Custom Setup. A registry search remembers a custom install folder so uninstall removes the same files.

## Running from source

```powershell
# Open the Studio without an installed copy
.\dist\SessionRecovery.exe

# Take a snapshot through the native host
.\dist\SessionRecovery.exe --snapshot

# Open the restore window, diagnostics or settings directly
.\dist\SessionRecovery.exe --restore-manual
.\dist\SessionRecovery.exe --diagnostics
.\dist\SessionRecovery.exe --settings

# Script-level equivalents
powershell -NoProfile -ExecutionPolicy Bypass -Command "Import-Module '.\src\SessionRecovery.psm1' -Force; Save-SRSnapshot"
powershell -NoProfile -ExecutionPolicy Bypass -File .\src\Restore-Session.ps1 -Manual
powershell -NoProfile -ExecutionPolicy Bypass -File .\src\Tray-SessionRecovery.ps1 -MonitorOnly
powershell -NoProfile -ExecutionPolicy Bypass -File .\src\Diagnostics.ps1
```

Build the host with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\installer\Build-Launcher.ps1 -Force
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
├── assets/                          Brand icon and installer artwork
├── installer/                       WiX MSI project, launcher and MSI build scripts
└── src/
    ├── SessionRecoveryLauncher.cs   Native winexe host (no console windows)
    ├── Studio-SessionRecovery.ps1   Studio UI and off-screen render mode
    ├── StudioControls.cs            Custom WinForms controls for the Studio
    ├── SessionRecovery.psm1         Capture, exclusions, browsers, diagnostics, restore engine
    ├── Save-Session.ps1             One-shot snapshot
    ├── Restore-Session.ps1          Restore UI, selective CLI restore, snapshot listing
    ├── Tray-SessionRecovery.ps1     Notification-area app and background snapshot timer
    ├── Diagnostics.ps1              Health report
    ├── Watch-Session.ps1            Legacy hidden watcher (compatibility)
    └── RunHidden.vbs                Legacy hidden launcher (compatibility)
```
