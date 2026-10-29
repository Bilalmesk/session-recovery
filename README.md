<div align="center">

# 🛟 Session Recovery

**Reopen the apps, Explorer folders and browser tabs that were open before a crash, power cut or unexpected restart.**

![Windows 10/11](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?logo=windows&logoColor=white)
![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell&logoColor=white)
![Version](https://img.shields.io/badge/version-2.8.0-8B5CF6)
![Local only](https://img.shields.io/badge/privacy-100%25%20local-22C55E)

[Install](#-install) · [Restore](#-restore) · [Configure](#%EF%B8%8F-configure) · [Troubleshoot](#-troubleshooting) · [Uninstall](#-uninstall)

</div>

---

Session Recovery snapshots your desktop every few minutes and offers to restore it after an unexpected shutdown. It ships with a native **Studio** app, needs no extra modules or browser extension, and sends no telemetry.

> [!IMPORTANT]
> It reopens apps and tabs. It **cannot** recover unsaved documents, passwords or form data.

## ✨ Features

| | |
|---|---|
| 📸 **Auto snapshots** | Every 3 minutes and at logon, with a searchable timeline |
| 🪟 **Window-accurate restore** | Position, size and maximized state, clamped to your current monitors |
| 🌐 **Browser tabs** | Chrome, Edge, Brave, Vivaldi, Opera, Opera GX, Chromium, Firefox; duplicates and window groups kept |
| 📁 **Explorer folders** | Reopened alongside your apps |
| 🎬 **VLC playback** | Resumes within one snapshot interval of where you left off |
| 🎯 **Selective restore** | Include/exclude by app, folder or browser with wildcards |
| 🔒 **Exclusions & pinning** | Keep apps, folders or URLs out of snapshots; pin snapshots forever |
| 📝 **Snapshot notes** | Searchable note on each snapshot; included in kits, removed with the snapshot |
| 🕵️ **Privacy scan** | Finds sensitive apps and sites from names and tab URLs, never page content |
| 🧳 **Recovery Kit** | Move snapshots, notes and exclusions between PCs in one `.srkit` file |
| 📊 **Recovery insights** | Local counts for snapshots, apps, sites, pins, notes and storage |
| 💤 **Hibernate checkpoints** | Pins the last three snapshots taken just before sleep or hibernate, and offers **Hibernate with checkpoint** from the tray or `--hibernate` |
| 📦 **Export / import** | Back up snapshots as JSON or move them to another PC |
| 🖥️ **Native tray + Studio** | Dashboard, Snapshots, Exclusions, Recovery Kit, Settings, Diagnostics and About; dark **Aurora** and light **Daylight** themes, no console windows |

## 📥 Install

### Option A: MSI (recommended)

Download `SessionRecovery-<version>.msi` from **Releases** and run it. It installs per-user (no UAC), keeps your data on upgrade, and offers a Custom Setup page for the install folder and desktop shortcut.

> [!NOTE]
> The MSI is not code-signed. If SmartScreen appears, verify the published SHA256, then choose **More info → Run anyway**.

### Option B: PowerShell installer

```powershell
# With scheduled tasks (one UAC prompt)
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-SessionRecovery.ps1

# Without admin rights (tray app owns the snapshot timer)
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-SessionRecovery.ps1 -NoTasks
```

<details>
<summary><b>Installer options</b></summary>

| Option | Default | Meaning |
|---|---|---|
| `-NoTasks` | off | Use the tray app instead of scheduled tasks |
| `-IntervalMinutes <n>` | `3` | Minutes between snapshots |
| `-KeepSnapshots <n>` | `48` | Max snapshot files |
| `-KeepSnapshotDays <n>` | `0` | Delete snapshots older than *n* days (`0` = off) |
| `-PromptOnLogon <mode>` | `CrashOnly` | `CrashOnly`, `Always` or `Never` |
| `-DefaultTabMode <mode>` | `Smart` | `Smart`, `Captured`, `Native` or `None` |
| `-NoDesktopShortcut` | off | Skip the desktop shortcut |
| `-NoInitialSnapshot` | off | Skip the snapshot taken during install |
| `-InstallDirectory <path>` | `%LOCALAPPDATA%\SessionRecovery\app` | Custom program folder |

Re-running the installer replaces program files and preserves snapshots and most settings.

</details>

**Check it works:** open **Session Recovery**, click **Capture now** on the Dashboard, and confirm the snapshot appears. Data lives in `%LOCALAPPDATA%\SessionRecovery`.

### Updating

**Studio → About → Check for updates** downloads the MSI, verifies its SHA256 and installs it. Snapshots and settings are preserved. You can also download the MSI and its `.sha256` file from **Releases** and run it manually.

## 🔄 Restore

**Automatic:** after a crash, a restore window opens 20–30 seconds after sign-in using the newest pre-logon snapshot. Untick what you don't want, pick a tab mode, and click **Restore selected** (or **Skip**).

**Manual:** **Start Menu → Session Recovery → Restore Session**, or pick a snapshot in the Studio's **Snapshots** page. Manual restore works any time and shows live progress with per-item results.

### Browser tab modes

| Mode | Behavior |
|---|---|
| `Smart` | Captured tabs when available, otherwise the browser's own restore |
| `Captured` | Reopens the exact tabs from the snapshot |
| `Native` | Uses the browser's own session restore |
| `None` | Skips browsers |

<details>
<summary><b>Command line</b></summary>

```powershell
$app = "$env:LOCALAPPDATA\SessionRecovery\app"

& "$app\SessionRecovery.exe" --snapshot          # take a snapshot
& "$app\SessionRecovery.exe" --hibernate         # checkpoint, then hibernate
& "$app\SessionRecovery.exe" --restore-manual    # open restore window

$rs = "$app\Restore-Session.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File $rs -ListSnapshots
powershell -NoProfile -ExecutionPolicy Bypass -File $rs -Manual -DryRun
powershell -NoProfile -ExecutionPolicy Bypass -File $rs -NoUI -IncludeApps 'OpenCode,ZCode' -IncludeBrowsers Brave
powershell -NoProfile -ExecutionPolicy Bypass -File $rs -NoUI -ExcludeApps 'Game*' -ExcludeFolders 'D:\Private\*'
```

| Parameter | Meaning |
|---|---|
| `-Manual` | Show the restore window with all snapshots |
| `-NoUI` | Restore the newest eligible snapshot silently |
| `-DryRun` | Print what would be restored |
| `-Force` | Start apps even if already running (may duplicate) |
| `-SnapshotPath <path>` | Use a specific snapshot JSON |
| `-TabMode <mode>` | Override the tab mode |
| `-MaxAgeHours <n>` | Override `maxRestoreAgeHours` |
| `-ListSnapshots` | List snapshots and exit |
| `-Include/Exclude` `Apps` `Folders` `Browsers` | Wildcard filters (`*`, `?`, `[abc]`); includes run first |

Filters apply to `-NoUI` and `-DryRun` only. Pass multiple patterns as one comma-separated string.

</details>

## 🧭 Tray app

Left-click opens the Studio. Right-click for restore, snapshot now, pause, **pause for 1 hour**, **Hibernate with checkpoint**, folders, settings, diagnostics and exit. If Windows hides the icon, drag it out of the `^` overflow onto the taskbar.

**Hibernate with checkpoint** saves a pinned recovery snapshot first and only then asks Windows to hibernate. The same thing happens automatically on suspend, display-off or lid-close while the guard is on. The latest three checkpoints stay pinned; older ones return to normal retention. This is a fast workspace checkpoint, not a memory image: apps still relaunch from disk and unsaved work is not recovered.

When scheduled tasks drive snapshots, the tray runs in monitor-only mode so normal snapshots are never duplicated. The one-off hibernate checkpoint still runs at suspend.

## ⚙️ Configure

Use the Studio **Settings** page, or edit `%LOCALAPPDATA%\SessionRecovery\config.json`.

```json
{
  "snapshotIntervalMinutes": 3,
  "keepSnapshots": 48,
  "keepSnapshotDays": 0,
  "promptOnLogon": "CrashOnly",
  "maxRestoreAgeHours": 72,
  "defaultTabMode": "Smart",
  "restoreWindowPositions": true,
  "theme": "Aurora",
  "encryptSnapshots": false,
  "compressSnapshots": false,
  "redactUrls": true,
  "hibernateGuard": true,
  "keepHibernateCheckpoints": 3,
  "excludeApps": ["KeePass*"],
  "excludeFolders": ["D:\\Taxes"],
  "excludeUrls": ["*bank*", "*mail.google.com*"],
  "snapshotNotes": {}
}
```

<details>
<summary><b>All settings</b></summary>

| Setting | Default | Meaning |
|---|---|---|
| `snapshotIntervalMinutes` | `3` | Minutes between snapshots |
| `keepSnapshots` | `48` | Max files (~2.4 h at 3 min) |
| `keepSnapshotDays` | `0` | Age cleanup in days (`0` = off) |
| `promptOnLogon` | `CrashOnly` | `CrashOnly`, `Always`, `Never` |
| `maxRestoreAgeHours` | `72` | Ignore older snapshots in the automatic prompt |
| `restoreBrowsers` | `true` | `false` removes browsers from restore |
| `restoreWindowPositions` | `true` | Restore position, size and maximized state |
| `defaultTabMode` | `Smart` | `Smart`, `Captured`, `Native`, `None` |
| `captureBrowserTabs` | `true` | Capture tabs in snapshots |
| `captureApproximateTabs` | `true` | UI Automation/history fallback (marked approximate) |
| `captureMediaPlayers` | `true` | Capture the VLC file and estimated position |
| `tabHistoryLookbackHours` | `24` | History fallback window |
| `showNotifications` | `true` | Tray balloons and toasts |
| `startWithWindows` | `true` | Create the Startup shortcut |
| `desktopShortcut` | `true` | Create the desktop shortcut |
| `theme` | `Aurora` | `Aurora` (dark) or `Daylight` (light) |
| `encryptSnapshots` | `false` | Seal snapshots with DPAPI for this Windows user |
| `compressSnapshots` | `false` | Write gzip-compressed snapshots |
| `redactUrls` | `true` | Strip URL query strings and fragments before writing |
| `hibernateGuard` | `true` | Save and pin a checkpoint whenever Windows suspends |
| `keepHibernateCheckpoints` | `3` | Number of hibernate/suspend checkpoints kept pinned |
| `excludeApps` / `excludeFolders` / `excludeUrls` | `[]` | Case-insensitive wildcards |
| `pinnedSnapshots` | `[]` | Files retention never deletes (managed via **Pin**) |
| `snapshotNotes` | `{}` | Searchable notes keyed by snapshot file name |

**Notes**
- Exclusions affect **new snapshots only**; delete old files to remove earlier data.
- If every tab of a browser profile is excluded, that profile is omitted.
- Tray/MSI mode reads interval, retention and exclusions every cycle. In scheduled-task mode, re-run the installer to change the interval.

</details>

<details>
<summary><b>Pin, export, import, search and VLC</b></summary>

- **Pin** keeps a snapshot forever and doesn't count toward `keepSnapshots`.
- **Export** saves a snapshot as plain JSON; **Import** validates and adds one back to the timeline.
- **Search** matches app names, folders, browsers, tab titles, URLs and dates.
- **VLC:** the playing file and position are recorded. After a crash, playback resumes up to one snapshot interval *early* (never ahead). Estimated positions show a `~` in the Studio. Only local files are seeked; discs, streams and playlists just open the player.

</details>

<details>
<summary><b>Notes, privacy scan, Recovery Kit and insights</b></summary>

- **Snapshot notes** hold up to 500 characters of searchable text per snapshot. They live in `config.json` keyed by snapshot file name, are included in Recovery Kits, and are removed when their snapshot is deleted. Notes are plain text even when snapshots are encrypted.
- **Privacy scan** on the Exclusions page inspects visible app/process names and browser tab URLs and titles for categories such as password managers, banking, messaging, email, health and social media. It suggests wildcard exclusions you can add one at a time or all at once. It never reads screenshots, window pixels or page content.
- **Recovery Kit** bundles every snapshot, note and exclusion rule into one portable `.srkit` file. Import merges notes and rules without overwriting existing settings, marks imported snapshots as untrusted, and skips DPAPI-encrypted snapshots because only the Windows account that created them can read them. A kit never contains settings, logs, screenshots or page content. The `.srkit` is a ZIP archive and is plaintext unless the snapshots inside are encrypted, so treat it like a private document.
- **Recovery insights** on Diagnostics summarize locally what the snapshot store contains: counts, time span, unique apps and sites, pins, notes, imports and storage use.

</details>

<details>
<summary><b>Hibernate checkpoints and deep-state limits</b></summary>

- **What it does:** with `hibernateGuard` on, the tray saves a forced snapshot when Windows reports suspend (sleep or hibernate), marks it `reason: "hibernate"`, pins it, and keeps the newest `keepHibernateCheckpoints` (default 3). Older checkpoints are unpinned; normal retention decides when they go. Classic suspend arrives through `PowerModeChanged`. Modern Standby often skips that message, so the same checkpoint also runs on display-off and lid-close, with a 30-second debounce so one transition does not create duplicates. Use **Hibernate with checkpoint** in the tray or `SessionRecovery.exe --hibernate` to do it explicitly. If the checkpoint cannot be saved, the explicit action cancels instead of hibernating without one.
- **What it cannot do:** Windows offers no safe user-mode way to freeze and resume an arbitrary app's RAM. This is a workspace checkpoint, not a process clone or VM snapshot. Unsaved editor buffers, passwords and form data are still not captured. Hibernate itself is handled by Windows; if hibernation is disabled in Power Options, `shutdown.exe /h` fails and the app reports the error.
- **No memory dumps:** the app never reads another process's memory or writes a crash dump. The only data saved is the same app, folder, tab, window and workspace metadata as a normal snapshot.
- **Crashes and power cuts cannot be predicted:** Windows sends no suspend notification before a blue screen or a hard power loss. The normal 3-minute timer and crash detection remain the safety net, so the worst case is a layout from the last few minutes rather than the exact moment before the crash.
- **Virtual desktops are best-effort:** restore uses the documented `IVirtualDesktopManager` interface and only moves windows owned by the restarted app. If a desktop no longer exists, the window stays on the current one. Moving arbitrary apps between desktops would need undocumented interfaces that change between Windows 11 builds, so it is out of scope.

</details>

## 🩺 Diagnostics

Open **Studio → Diagnostics** or **Start Menu → Run Diagnostics** for snapshot freshness, background mode, browsers and recent errors. For a script-friendly report:

```powershell
$d = "$env:LOCALAPPDATA\SessionRecovery\app\Diagnostics.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File $d            # text
powershell -NoProfile -ExecutionPolicy Bypass -File $d -Json      # JSON
powershell -NoProfile -ExecutionPolicy Bypass -File $d -ReportPath "$env:TEMP\sr-report.txt"
```

Reports contain paths, URLs and log lines, so review them before sharing.

## 🔐 Privacy & data

- Everything stays on your PC: no extension, no debugging port and no telemetry. The app makes no network requests unless you check for or download an update.
- Snapshots hold executable paths, window titles, folder paths and URLs. They are plaintext by default; enable `encryptSnapshots` for DPAPI protection. Snapshot notes are always plaintext in `config.json`, and a Recovery Kit is a plain ZIP unless the snapshots inside are encrypted. Use BitLocker or account permissions on shared PCs.
- To back up a session, copy its JSON and restore it elsewhere with `-SnapshotPath`.

| Path (under `%LOCALAPPDATA%\SessionRecovery`) | Contents |
|---|---|
| `snapshots\` | Snapshot JSON files |
| `logs\session-recovery.log` | Snapshot, restore and error messages |
| `config.json` | Settings and snapshot notes |
| `media-state.json` | VLC tracking between snapshots |
| `app\` | Program files |

## 🛠 Troubleshooting

Start with **Run Diagnostics**. Quick manual check:

```powershell
$root = Join-Path $env:LOCALAPPDATA 'SessionRecovery'
Get-Content (Join-Path $root 'logs\session-recovery.log') -Tail 50
Get-ScheduledTask -TaskName 'SessionRecovery-*' -ErrorAction SilentlyContinue | Format-Table TaskName, State
```

| Problem | Fix |
|---|---|
| Installer blocked | Use the `-ExecutionPolicy Bypass` command above; run `Unblock-File` on downloaded files |
| No tasks / no UAC | Install with `-NoTasks`, or re-run and approve UAC |
| No snapshots | Click **Capture now**; check the log, folder permissions, free space and that the tray/task is running |
| No prompt after a crash | Check `promptOnLogon` and `maxRestoreAgeHours`, or use **Restore Session** |
| Prompt after a normal restart | Crash detection is heuristic: set `promptOnLogon` to `Never` or click **Skip** |
| Apps missing | Only visible, non-elevated desktop windows are captured (no UWP/Store, tray-only or exited apps) |
| Tabs missing or wrong | Use **Captured** mode; Chromium session files can lag, and fallback tabs are marked approximate |
| Extra blank browser window | A quirk of some Chromium builds: close it |
| Apps start twice | Leave **Force** off and untick apps Windows already starts at logon |
| Uninstall leaves files | Sign out and back in, delete `%LOCALAPPDATA%\SessionRecovery`, run the uninstaller elevated if tasks remain |

<details>
<summary><b>Known limitations</b></summary>

- Unsaved work is not recovered.
- Window placement is best-effort (apps that hand off to a running instance or manage their own placement may not move).
- One launch per executable/argument group; individual document windows may not be recreated.
- UWP/Store, elevated, tray-only and hidden windows are skipped; command-line switches are mostly dropped.
- Pinned browser tabs reopen as normal tabs; internal/extension URLs and private windows are not guaranteed.
- Age-based retention permanently deletes unpinned history.
- The tool is per-user.

</details>

## 🗑 Uninstall

- **MSI:** Settings → Apps → Session Recovery → Uninstall (snapshots and settings are kept).
- **PowerShell install:** Start Menu → *Uninstall Session Recovery*, or run `Uninstall-SessionRecovery.ps1` (add `-RemoveData` to delete snapshots, logs and config).

## 👩‍💻 Development

```powershell
# Build the MSI (needs .NET SDK 6+ and internet for WiX restore) → dist\SessionRecovery-2.8.0.msi
powershell -NoProfile -ExecutionPolicy Bypass -File .\installer\Build-MSI.ps1

# Build the native host only
powershell -NoProfile -ExecutionPolicy Bypass -File .\installer\Build-Launcher.ps1 -Force

# Run from source with isolated test data
$env:SESSIONRECOVERY_HOME = Join-Path $PWD 'test-data'
.\dist\SessionRecovery.exe
```

`dist\` is git-ignored; publish the MSI as a GitHub Release asset.

<details>
<summary><b>Project layout</b></summary>

```
session-recovery/
├── Install-SessionRecovery.ps1     Installer and shortcuts
├── Uninstall-SessionRecovery.ps1   Uninstaller
├── assets/                         Brand icon and installer artwork
├── installer/                      WiX MSI project, launcher and build scripts
└── src/
    ├── SessionRecoveryLauncher.cs  Native host (no console windows)
    ├── Studio-SessionRecovery.ps1  Studio UI
    ├── StudioTheme.ps1             Shared theme catalog for Studio and restore
    ├── StudioControls.cs           Custom WinForms controls
    ├── SessionRecovery.psm1        Capture, exclusions, browsers, diagnostics, restore engine
    ├── Save-Session.ps1            One-shot snapshot
    ├── Restore-Session.ps1         Restore UI and selective CLI restore
    ├── Tray-SessionRecovery.ps1    Tray app and snapshot timer
    ├── Diagnostics.ps1             Health report
    ├── Watch-Session.ps1           Legacy watcher (compatibility)
    └── RunHidden.vbs               Legacy launcher (compatibility)
```

</details>
