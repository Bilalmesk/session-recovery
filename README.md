# Session Recovery

**Reopen the apps, Explorer folders and browser tabs that were open before a crash, power cut or unexpected restart.**

Session Recovery is a local Windows utility with a native desktop Studio. It snapshots your desktop every few minutes and offers to restore it after an unexpected shutdown. No external modules, no browser extension, no telemetry.

> **Important:** It reopens applications and tabs. It cannot recover unsaved document contents, passwords or form data.

- Windows 10/11 with Windows PowerShell 5.1.
- Chrome, Edge, Brave, Vivaldi, Opera, Opera GX, Chromium and Firefox.
- Native `SessionRecovery.exe` host: no visible `cmd` or PowerShell windows.
- Everything stays on your PC.

## Features

- Modern **Session Recovery Studio** with Dashboard, Snapshots, Exclusions, Settings, Diagnostics and About pages, **fourteen themes** and **nine languages** (English, Arabic, French, Spanish, German, Portuguese, Russian, Chinese, Turkish). Long translations wrap or ellipsize instead of running into other controls, and a CI audit renders every language at the minimum window size.
- Automatic snapshots every 3 minutes, plus event snapshots on **lock, sleep/resume and low battery**.
- **Change detection**: unchanged moments are skipped, so `keepSnapshots` covers hours of real changes instead of repeated identical states.
- Native tray app with Studio, restore, snapshot-now, pause, pause-for-1-hour, named workspaces, folders, settings, diagnostics and exit actions.
- Snapshot timeline with previews, per-snapshot "what changed" diff and one-click restore.
- **Window thumbnails (opt-in)**: a small JPEG of each window is stored next to the snapshot and shown on the timeline, so it shows what your screen looked like — not just a list of names. Excluded apps are never captured.
- Restored apps return to their captured **position, size and maximized state**. Windows from unplugged monitors are **mapped proportionally onto the current layout** instead of just clamped.
- **Virtual desktops**: each window remembers which Windows desktop it was on (documented `IVirtualDesktopManager`), and restore moves it back when that desktop still exists.
- **Dev workspace restore**: open folders and projects are read from VS Code / Cursor `storage.json`, JetBrains `recentProjects.xml` and Windows Terminal `state.json`, then reopened with `code <folder>`, the IDE, or `wt.exe -d <folder>`.
- **Remote sessions**: open PuTTY sessions and Remote Desktop targets are captured and reconnected directly (`putty -load`, `mstsc`).
- Crash-aware restore prompt with a **plain-language shutdown reason** (blue screen stop code, power loss, clean restart) parsed from Event IDs 41, 1001, 6008, 1074 and 6006.
- After a crash the restore window lists **Office AutoRecover files** (`%APPDATA%\Microsoft\Word` and friends) so unsaved work is one click away.
- **Named workspaces** ("Work", "Study", "Project X") saved from the tray and restorable in one click, separate from the rolling crash snapshots.
- **Restore preview**: the restore window and `-DryRun` show what is already running, what will start and what is missing.
- Media playback restore for **VLC, MPC-HC, MPC-BE, mpv and PotPlayer**; mpv reports exact positions through its JSON IPC pipe when enabled.
- Chrome/Chromium capture uses structured session files first, then UI Automation and local browser history as a safe fallback. Firefox sessions are parsed from `recovery.jsonlz4` with a built-in LZ4 decoder. Approximate tabs are marked in the snapshot and in the Studio.
- Duplicate tabs and browser window groups are preserved.
- Capture exclusions keep chosen apps, folders and URLs out of new snapshots.
- Selective restore by app, folder or browser, with wildcard include/exclude filters.
- **Pin** snapshots you care about; retention never deletes a pinned file — and now cleans up the matching thumbnails too.
- **Export** any snapshot to a JSON file and **import** snapshots back in, for backup or another PC.
- Snapshot **search across content**: app names, folder paths, browser names, tab titles and URLs, not just dates.
- Shell and terminal windows are skipped during capture and restore, so restoration does not flash command prompts.
- **Security options**: DPAPI snapshot encryption, gzip compression and URL query-string redaction (on by default).
- **Local control API**: a named pipe plus a CLI (`--control`) so other tools can trigger snapshots, restores and workspaces.
- In-app update checks with SHA256-verified MSI downloads in **About**.
- Pester tests and GitHub Actions CI verify every push and pull request.
- Local snapshots, logs and settings only; nothing is uploaded.

## Quick start

### Install from the MSI

Download `SessionRecovery-<version>.msi` from the GitHub **Releases** page and run it. The MSI installs per-user without a UAC prompt and keeps your snapshots and settings when you upgrade.

The setup wizard includes a **Custom Setup** page where you can:

- choose the install folder (the default is `%LOCALAPPDATA%\SessionRecovery\app`);
- keep or clear the optional **Desktop shortcut** feature.

By default it creates a **Session Recovery** desktop icon, Start Menu shortcuts, a Startup entry that launches the native background app after the next sign-in, and a Startup entry for the crash restore prompt. The desktop icon and **Session Recovery** Start Menu item open the Studio directly.

The MSI is not code-signed by default. CI signs it automatically when Trusted Signing secrets are configured (see *Building, testing and releasing*); otherwise, if Windows SmartScreen appears, choose **More info → Run anyway** after verifying the SHA256 published with the release.

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

Captured: app executable and simple file arguments, window titles, window position/size/maximized state, minimized state, the virtual desktop each window is on, the monitor layout, Explorer folder paths, browser profiles and tabs, dev workspace folders (VS Code/Cursor/JetBrains/Windows Terminal), open PuTTY sessions and Remote Desktop targets, and the file a media player is playing with its position (exact for mpv over IPC, estimated otherwise). Window thumbnails are captured only when enabled.

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

### Local control API (CLI and named pipe)

Other tools — scripts, Stream Deck buttons, automation — can drive Session
Recovery without touching its windows. The tray app listens on the
`SessionRecoveryControl` named pipe:

```powershell
$app = "$env:LOCALAPPDATA\SessionRecovery\app"

# Take a snapshot now (works even without the tray: falls back to a local capture)
& "$app\SessionRecovery.exe" --control -Command snapshot

# Ask the running tray app to pause/resume
& "$app\SessionRecovery.exe" --control -Command pause
& "$app\SessionRecovery.exe" --control -Command resume

# Status summary and named workspaces
& "$app\SessionRecovery.exe" --control -Command status
& "$app\SessionRecovery.exe" --control -Command workspaces
& "$app\SessionRecovery.exe" --control -Command workspace-save -Name Work
& "$app\SessionRecovery.exe" --control -Command workspace-restore -Name Work
```

The same pipe is available to any language through `Send-SRControl` in the
module (`Import-Module SessionRecovery.psm1; Send-SRControl -Command snapshot`).
Commands: `snapshot`, `pause`, `resume`, `status`, `restore-latest`,
`workspace-save <name>`, `workspace-restore <name>`.

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
  "restoreVirtualDesktops": true,
  "defaultTabMode": "Smart",
  "captureBrowserTabs": true,
  "captureApproximateTabs": true,
  "captureMediaPlayers": true,
  "captureDevWorkspaces": true,
  "captureThumbnails": false,
  "compressSnapshots": false,
  "encryptSnapshots": false,
  "redactUrls": true,
  "eventSnapshots": true,
  "launchOrder": [],
  "appLaunchDelays": {},
  "launchWaits": {},
  "tabHistoryLookbackHours": 24,
  "showNotifications": true,
  "startWithWindows": true,
  "desktopShortcut": true,
  "theme": "Aurora",
  "language": "en",
  "excludeApps": [],
  "excludeFolders": [],
  "excludeUrls": [],
  "pinnedSnapshots": []
}
```

| Setting | Default | Meaning |
| --- | --- | --- |
| `snapshotIntervalMinutes` | `3` | Minutes between snapshots. |
| `keepSnapshots` | `48` | Maximum snapshot files. Change detection skips unchanged states, so this budget covers real changes, not identical repeats. |
| `keepSnapshotDays` | `0` | Delete snapshots older than this many days. `0` disables age cleanup. |
| `promptOnLogon` | `CrashOnly` | `CrashOnly`, `Always` or `Never`. |
| `maxRestoreAgeHours` | `72` | Ignore older snapshots in the automatic prompt. Manual restore still lists them. |
| `restoreBrowsers` | `true` | Set `false` to remove browsers entirely from restore. |
| `restoreWindowPositions` | `true` | Move restored app windows back to their captured position, size and maximized state. |
| `restoreVirtualDesktops` | `true` | Remember which virtual desktop each window was on and move it back on restore (best-effort, documented API). |
| `defaultTabMode` | `Smart` | Initial tab mode: `Smart`, `Captured`, `Native` or `None`. |
| `captureBrowserTabs` | `true` | Capture browser tabs while taking snapshots. |
| `captureApproximateTabs` | `true` | Allow the UI Automation/history fallback when a Chromium session file has no tabs. Approximate tabs are marked in the snapshot. |
| `captureMediaPlayers` | `true` | Capture what media players (VLC, MPC-HC/BE, mpv, PotPlayer) are playing, plus the playback position. |
| `captureDevWorkspaces` | `true` | Read VS Code/Cursor/JetBrains/Windows Terminal state so restore can reopen the same folders. |
| `captureThumbnails` | `false` | Store a downscaled JPEG of each window next to the snapshot (opt-in; excluded apps are never captured). |
| `compressSnapshots` | `false` | Write snapshots as gzip files (`.json.gz`). |
| `encryptSnapshots` | `false` | Seal snapshots with DPAPI (your Windows user key). Encrypted files only restore for the same user on the same PC. |
| `redactUrls` | `true` | Strip `?query` strings and `#fragments` from captured URLs before they are written. |
| `eventSnapshots` | `true` | Extra snapshots on lock, sleep/resume and low battery. |
| `launchOrder` | `[]` | Process names that must start first, in order (for example a VPN before the apps that need it). |
| `appLaunchDelays` | `{}` | Map of process name to seconds to wait before starting it. |
| `launchWaits` | `{}` | Map of process name to a process it must wait for, e.g. `{"app": "vpnagent"}`. |
| `tabHistoryLookbackHours` | `24` | How far back the Chromium history fallback may look. |
| `showNotifications` | `true` | Show tray balloons and snapshot toasts. |
| `startWithWindows` | `true` | Create the **Session Recovery - Background** Startup shortcut. |
| `desktopShortcut` | `true` | Create the **Session Recovery** desktop shortcut. |
| `theme` | `Aurora` | Studio theme (14 available). Applied when saving in Settings. |
| `language` | `en` | Studio/restore/tray language (9 available). |
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

### Media playback (VLC, MPC-HC/BE, mpv, PotPlayer)

When a supported player is playing a video, each snapshot records the file and the playback position. A restore reopens the player with that file and seeks back to the captured moment.

- **mpv reports exact positions** when it runs with `--input-ipc-server=mpvsocket`; those snapshots are marked exact. Without the pipe, mpv falls back to the estimate like the others.
- Positions are **estimated between snapshots** for the other players: they only write an exact position when they close cleanly, so after a crash the restore lands at most one snapshot interval (default 3 minutes) *before* the crash point — you rewatch a little, you never skip ahead.
- If VLC itself is configured to continue playback automatically, exact positions from clean stops are used to keep the estimate honest.
- The restore list shows what was playing and where (for example `Playing episode.mp4 at 27:24`); estimated positions are marked with `~` in the Studio.
- Media files inside excluded folders are never captured.
- If the player is already running when a restore starts, it is skipped like any other running app.

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
| `%LOCALAPPDATA%\SessionRecovery\snapshots` | Snapshot files (plain JSON, gzip, or DPAPI-encrypted). |
| `%LOCALAPPDATA%\SessionRecovery\snapshots\thumbs` | Window thumbnails (only when enabled). |
| `%LOCALAPPDATA%\SessionRecovery\workspaces` | Named workspaces saved from the tray. |
| `%LOCALAPPDATA%\SessionRecovery\logs\session-recovery.log` | Snapshot, restore and error messages. |
| `%LOCALAPPDATA%\SessionRecovery\config.json` | Settings. |
| `%LOCALAPPDATA%\SessionRecovery\media-state.json` | Media player tracking between snapshots (playing file, position anchor). |
| `%LOCALAPPDATA%\SessionRecovery\app` | Program files. |

- Snapshots contain executable paths, window titles, folder paths and browser URLs. Media snapshots additionally contain the playing video's path and position. Thumbnails (when enabled) contain a small JPEG of each non-excluded window.
- The tool makes no network requests and uses no browser extension or debugging port.
- **Encryption:** turn on `encryptSnapshots` to seal every snapshot with DPAPI under your Windows user key. Encrypted snapshots (including auto-backup copies) can only be read by the same user on the same PC — exactly what you want on a shared or stolen device, and exactly why cross-PC restore of encrypted files does not work.
- **Redaction:** `redactUrls` (on by default) strips `?token=…` query strings and fragments before URLs are written.
- Auto-backup (`autoExportFolder`) copies each new snapshot to a folder you choose — point it at OneDrive or a network share for off-machine copies. Combine it with encryption when the folder is not fully trusted.
- Exclusions only affect new snapshots; delete old files if you need to remove existing data today.
- To back up a session, copy its file (or use **Export**). Restore it elsewhere with `-SnapshotPath`.

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

- Unsaved work is not recovered; only windows, folders and tabs are reopened. After a crash, the restore window points at Office AutoRecover files instead.
- Media playback positions are estimated between snapshots (VLC, MPC, PotPlayer); after a crash the video resumes up to one snapshot interval early. mpv reports exact positions only when started with `--input-ipc-server`.
- Virtual desktop restore uses the documented `IVirtualDesktopManager`: it can move windows back when the captured desktop still exists (desktop GUIDs survive reboots), but it cannot create missing desktops — that needs the undocumented `IVirtualDesktopManagerInternal`, which changes between Windows builds.
- Window position restore is best-effort: apps that hand off to an already-running instance, swap their main window while starting, or manage their own placement may not move. Windows from missing monitors are mapped proportionally onto the current layout.
- Explorer tab sets (Windows 11 23H2+) are not captured individually; the active tab's folder is captured per window.
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
- DPAPI-encrypted snapshots only restore for the same user on the same PC; export an unencrypted copy if you need a cross-PC backup.
- The tool is per-user.

## Uninstall

If you installed from the MSI, use **Settings → Apps → Installed apps → Session Recovery → Uninstall**, or **Start Menu → Session Recovery → Uninstall Session Recovery**. The MSI removes program files and shortcuts but keeps your snapshots and settings.

For the PowerShell installer, use **Start Menu → Session Recovery → Uninstall Session Recovery**, or:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\SessionRecovery\app\Uninstall-SessionRecovery.ps1"
```

Add `-RemoveData` to delete snapshots, logs and config as well. Removing scheduled tasks may require UAC.

## Building, testing and releasing

Prerequisites: .NET SDK 6 or newer and internet access for the WiX NuGet restore.

```powershell
# Run the Pester test suite (36 tests: strings, redaction, encryption
# round-trips, retention, compare, preview, plan shape, installer payload)
Import-Module Pester -MinimumVersion 5.5 -Force
Invoke-Pester -Path tests -Output Detailed

# Render every language and fail on clipped or overlapping controls
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-UiAudit.ps1

# Build the MSI (compiles the native host first)
powershell -NoProfile -ExecutionPolicy Bypass -File .\installer\Build-MSI.ps1

# Install, verify, render and uninstall the built MSI
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-InstallerSmoke.ps1 -MsiPath .\dist\SessionRecovery-2.6.0.msi
```

The build writes `dist\SessionRecovery-<version>.msi`, its `.sha256` file and a
short release README. `dist\` is intentionally ignored by Git; publish the MSI
as a GitHub Release asset rather than committing it.

**CI** (`.github/workflows/ci.yml`) runs on every push and pull request:

- **Pester tests** — parse checks every PowerShell source, then runs the suite.
- **UI layout audit** — renders all nine languages at the minimum window size,
  scrolled to the top and bottom, and fails on clipped or overlapping controls.
- **Build MSI** — compiles the native host and produces the installer artifact.
- **Installer smoke test** — installs the MSI, compares the installed payload
  with the checkout, renders the installed Studio, then uninstalls and verifies
  cleanup.

Enable *Settings → Branches → Require status checks* on all four jobs so no PR
merges without passing them — see `CONTRIBUTING.md`.

**Code signing**: `installer\Sign-Release.ps1` signs the MSI with Azure
Trusted Signing (`AZURE_TRUSTED_SIGNING_*` environment variables) or a PFX
(`SIGNING_PFX_PATH` / `SIGNING_PFX_PASSWORD`). CI signs automatically when the
secrets are present, which removes the SmartScreen warning.

**winget**: a ready-to-submit manifest lives in `packaging\winget\`. After a
release, run
`wingetcreate submit --urls <msi-url>,<sha256-url> --version <version>` (or
open a PR to `microsoft/winget-pkgs` with those files) to make the app
installable with `winget install Bilalmesk.SessionRecovery`.

The WiX package uses `Scope="perUser"` (no elevation and no explicit `ALLUSERS`/`MSIINSTALLPERUSER` properties), `WixUI_FeatureTree` for install-folder browsing and optional features, and a **Desktop shortcut** feature that is selected by default but can be cleared in Custom Setup. A registry search remembers a custom install folder so uninstall removes the same files. Every unversioned script payload has a `RemoveFile On="install"` entry so upgrades always replace old UI strings and engine files.

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
├── CONTRIBUTING.md                  PR and testing workflow
├── assets/                          Brand icon and installer artwork
├── .github/workflows/ci.yml         Tests + MSI build on every push/PR
├── installer/                       WiX MSI project, launcher, build and signing scripts
├── packaging/winget/                winget manifest for winget-pkgs submission
├── tests/                           Pester test suite
├── test-data/                       Isolated SESSIONRECOVERY_HOME for manual runs
└── src/
    ├── SessionRecoveryLauncher.cs   Native winexe host (no console windows)
    ├── Studio-SessionRecovery.ps1   Studio UI and off-screen render mode
    ├── StudioControls.cs            Custom WinForms controls for the Studio
    ├── SessionRecovery.psm1         Capture, exclusions, browsers, diagnostics, restore engine
    ├── Strings.ps1                  UI strings for the nine languages
    ├── Save-Session.ps1             One-shot snapshot
    ├── Restore-Session.ps1          Restore UI, selective CLI restore, snapshot listing
    ├── Tray-SessionRecovery.ps1     Notification-area app, snapshot timer, control pipe
    ├── Control-SessionRecovery.ps1  CLI control API (snapshot, status, workspaces)
    ├── Diagnostics.ps1              Health report
    ├── Watch-Session.ps1            Legacy hidden watcher (compatibility)
    └── RunHidden.vbs                Legacy hidden launcher (compatibility)
```
