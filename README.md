<div align="center">

# 🛟 Session Recovery

**Reopen the apps, Explorer folders and browser tabs that were open before a crash, power cut or unexpected restart.**

![Windows 10/11](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?logo=windows&logoColor=white)
![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell&logoColor=white)
![Version](https://img.shields.io/badge/version-3.0.8-8B5CF6)
![Local only](https://img.shields.io/badge/privacy-100%25%20local-22C55E)

[Install](#-install) · [Restore](#-restore) · [Configure](#%EF%B8%8F-configure) · [Troubleshoot](#-troubleshooting) · [Uninstall](#-uninstall)

</div>

---

Session Recovery snapshots your desktop every few minutes and offers to restore it after an unexpected shutdown. It ships with a native **Studio** app, needs no extra modules or browser extension, and sends no telemetry.

```powershell
winget install --id Bilalmesk.SessionRecovery
```

> [!IMPORTANT]
> It reopens apps and tabs. It **cannot** recover unsaved documents, editor buffers, passwords or form data. Its **unsaved-work radar** can flag unsaved-change markers in window titles at the last successful snapshot, prioritize those apps on restore, and point you at available Office AutoRecover drafts. These are hints, not a record of every unsaved change or a guarantee of recovery.

## ✨ Features

| | |
|---|---|
| 📸 **Auto snapshots** | Periodic snapshots (3-minute default), logon and best-effort workspace/system events, with a searchable timeline |
| 🪟 **Window-accurate restore** | Position, size and maximized state, clamped to your current monitors |
| 🌐 **Browser tabs** | Chrome, Edge, Brave, Vivaldi, Opera, Opera GX, Chromium, Firefox; window groups kept, duplicate URLs reopened once (`deduplicateTabs`) |
| 📁 **Explorer folders** | Reopened alongside your apps |
| 🎬 **VLC playback** | Resumes within one snapshot interval of where you left off; paused players hold their position instead of drifting |
| 🎯 **Selective restore** | Include/exclude by app, folder or browser with wildcards |
| 🔒 **Exclusions & pinning** | Keep apps, folders or URLs out of snapshots; pin snapshots forever |
| 📝 **Snapshot notes** | Searchable note on each snapshot; included in kits, removed with the snapshot |
| 🕵️ **Privacy scan** | Finds sensitive apps and sites from names and tab URLs, never page content |
| 📝 **Unsaved-work radar** | Detects apps whose windows carried unsaved-change markers, opens them first on restore, and flags them in the Studio |
| 🧳 **Recovery Kit** | Move snapshots, notes and exclusions between PCs in one `.srkit` file |
| 📊 **Recovery insights** | Local counts for snapshots, apps, sites, pins, notes and storage |
| 🩺 **Recovery timeline** | Restarts, power loss and blue screens from the last 30 days, read from the local event log |
| 🔍 **Compare snapshots** | Pick an older moment and see which apps, folders and tabs opened or closed since |
| ⚙️ **Cross-PC snapshots** | Every snapshot records machine, displays, scale and language; restore explains what changed |
| 💤 **Hibernate checkpoints** | Pins the last three snapshots taken just before sleep or hibernate, and offers **Hibernate with checkpoint** from the tray or `--hibernate` |
| ↩️ **Undo a restore** | Every restore first pins a safety snapshot of the current desktop, and **Undo last restore** brings it back in one click |
| 🕘 **Restore history** | The Diagnostics page lists recent restores, their source and outcome, with an Undo button for each |
| 🧹 **Storage health** | Finds unreadable snapshots, orphaned thumbnails and temp files, and cleans up while quarantining anything unreadable |
| 🗂️ **Workspaces** | Save the current desktop as a named workspace, then reopen or delete it from the Studio or the tray |
| 📦 **Export / import** | Back up snapshots as JSON or move them to another PC |
| 📦 **winget** | `winget install --id Bilalmesk.SessionRecovery` installs the latest release; `winget upgrade` keeps it current |
| 🖥️ **Native tray + Studio** | Dashboard, Snapshots, Workspaces, Exclusions, Recovery Kit, Settings, Diagnostics and About; 14 dark and light colour themes, no console windows |

## 📥 Install

### Option A: winget

```powershell
winget install --id Bilalmesk.SessionRecovery
```

This installs the latest release from the [winget community repository](https://github.com/microsoft/winget-pkgs/tree/master/manifests/b/Bilalmesk/SessionRecovery), per-user and without admin rights. To upgrade later:

```powershell
winget upgrade --id Bilalmesk.SessionRecovery
```

> [!TIP]
> If winget cannot find the package, the local index may be stale. Run `winget source update` and try again.

### Option B: MSI (recommended when winget is unavailable)

Download `SessionRecovery-<version>.msi` from **Releases** and run it. It installs per-user (no UAC), keeps your data on upgrade, and offers a Custom Setup page for the install folder and desktop shortcut.

> [!NOTE]
> The MSI is not code-signed. If SmartScreen appears, verify the published SHA256, then choose **More info → Run anyway**.

### Option C: PowerShell installer

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

Choose whichever method installed the app:

```powershell
# Installed with winget
winget upgrade --id Bilalmesk.SessionRecovery
```

**Studio → About → Application updates → Check for updates** downloads the MSI, verifies its SHA256 and installs it. Snapshots and settings are preserved. You can also download the MSI and its `.sha256` file from **Releases** and run it manually.

## 🔄 Restore

**Automatic:** after a crash, a restore window opens 20–30 seconds after sign-in using the newest pre-logon snapshot. Untick what you don't want, pick a tab mode, and click **Restore selected** (or **Skip**).

**Manual:** **Start Menu → Session Recovery → Restore Session**, or pick a snapshot in the Studio's **Snapshots** page. Manual restore works any time and shows live progress with per-item results.

The restore window uses the same layout, cards and colour theme as the Studio, and its labels are translated into all nine languages, including right-to-left Arabic.

### Unsaved-work radar

At capture time, each window title is checked for the dirty-document marker that editors put in the title: a leading `*`, `●` or `•` (VS Code `● main.ts`, Sublime `• main.py`, Notepad++ `*draft.txt`), a trailing `*` right after text, or a standalone `[+]` (vim, `main.c [+]`). Apps with such windows are recorded with a count, flagged in the Studio, and started first on restore (after anything listed in `launchOrder`).

This is a heuristic on the title only. It tells you which apps to check first; it cannot see what was unsaved and cannot recover it. Apps that show no marker in their title are not flagged.

### Browser tab modes

| Mode | Behavior |
|---|---|
| `Smart` | Captured tabs when available, otherwise the browser's own restore |
| `Captured` | Reopens the exact tabs from the snapshot |
| `Native` | Uses the browser's own session restore |
| `None` | Skips browsers |

Whatever the mode, a tab that is already open is never reopened. When the browser is still running, restore reads its live session, compares it with the snapshot and opens only the missing tabs. After a crash this is the difference between getting the desktop back and getting every page twice, because browsers often restore their own session on first launch. If the live session cannot be read, restore falls back to reopening every captured tab. Tab identity ignores query strings, host case and trailing slashes, so a redacted snapshot URL still matches the live tab.

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

The automation wrapper adds status, workspaces and storage commands:

```powershell
$ctl = "$app\Control-SessionRecovery.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File $ctl -Command status
powershell -NoProfile -ExecutionPolicy Bypass -File $ctl -Command undo-restore
powershell -NoProfile -ExecutionPolicy Bypass -File $ctl -Command workspaces
powershell -NoProfile -ExecutionPolicy Bypass -File $ctl -Command workspace-delete -Name Work
powershell -NoProfile -ExecutionPolicy Bypass -File $ctl -Command storage-health
powershell -NoProfile -ExecutionPolicy Bypass -File $ctl -Command storage-cleanup
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

Left-click opens the Studio. Right-click for restore, snapshot now, **undo last restore**, pause, **pause for 1 hour**, **Hibernate with checkpoint**, workspaces, folders, settings, diagnostics and exit. If Windows hides the icon, drag it out of the `^` overflow onto the taskbar.

**Pause applies to every automatic driver.** Pausing from the tray writes a small `paused.json` marker in the data folder, so the scheduled task and the legacy watcher stop taking periodic snapshots too, not only the tray's event capture. The pause survives tray restarts and stays in effect until you choose **Resume snapshots**; a timed pause expires on its own. An already-running snapshot may finish, and the best-effort shutdown checkpoint is skipped too. **Take snapshot now**, workspace saves and **Hibernate with checkpoint** are explicit actions and still run while paused. A forgotten pause is hard to miss: `paused.json` records `pausedAt`, and the pause is shown on the Studio dashboard (amber **PAUSED** badge with the start time and resume time), in Diagnostics (`Paused`, `PausedAt`, `ResumeAt`), as a tray notice when the tray starts while paused, and as a note in the restore window, since the newest snapshot may be older than the crash.

**Hibernate with checkpoint** saves a pinned recovery snapshot first and only then asks Windows to hibernate. The same thing happens automatically on suspend, display-off or lid-close while the guard is on. The latest three checkpoints stay pinned; older ones return to normal retention. This is a fast workspace checkpoint, not a memory image: apps still relaunch from disk and unsaved work is not recovered.

When scheduled tasks drive periodic snapshots, the tray runs in task-monitor mode: it does not run a second periodic snapshot loop, but its event-triggered capture and hibernate checkpoints remain available while the tray is resident. The legacy `Watch-Session.ps1` watcher is interval-only; it does not provide these event hooks.

**Workspace and system events** are enabled by `eventSnapshots` (default `true`), exposed as **Capture workspace and system events** in Studio Settings. The resident tray listens for native top-level window show, hide, destroy and title-change events, plus lock, sleep and low-battery transitions. Only visible, unowned, non-tool top-level windows with a title count; tooltips, menus, toasts and tool windows are ignored. Workspace changes are coalesced with a **2-second debounce**, a **10-second maximum burst delay**, and a **30-second automatic-attempt cooldown**. The first title a newly shown window receives counts as a structural change, because that is when the window becomes relevant. After that, a title change on its own is a weaker signal: it waits for **15 seconds of quiet** (or **60 seconds of continuous title changes**) and then observes a **2-minute automatic-attempt cooldown**, because browser pages and clocks change their titles frequently. These timings throttle attempts; they do not guarantee a saved snapshot within that time. Browser-internal changes, tabs that do not change a top-level window title, and other in-app state can go unnoticed, so **periodic capture remains necessary**. Disabling event capture does not disable the periodic fallback or the separate `hibernateGuard` setting.

**Shutdown and sign-out are best-effort only.** When Windows queries whether the session may end, the tray initiates a snapshot asynchronously, immediately permits the session to end, and never vetoes or waits for capture. That path has a **2-second cooperative stage budget**: it checks the remaining budget between stages, but cannot interrupt a blocked COM call, and Windows may terminate the process before saving finishes. It skips thumbnails, automatic exports and retention cleanup, while retaining exclusions, URL privacy rules and configured snapshot encryption. Each attempt writes a marker before capture and marks it complete only after the snapshot file is published; the next tray start logs whether the previous shutdown snapshot actually reached disk, so the success rate is visible in the log rather than assumed. It is not a shutdown blocker or a guarantee of a final snapshot, and it never recovers unsaved buffers. Hard power loss and crashes may give no notification at all.

## ⚙️ Configure

Use the Studio **Settings** page, or edit `%LOCALAPPDATA%\SessionRecovery\config.json`.

```json
{
  "snapshotIntervalMinutes": 3,
  "keepSnapshots": 48,
  "tieredRetention": true,
  "keepHourlyDays": 7,
  "keepDailyDays": 30,
  "keepSnapshotDays": 0,
  "promptOnLogon": "CrashOnly",
  "maxRestoreAgeHours": 72,
  "defaultTabMode": "Smart",
  "restoreWindowPositions": true,
  "theme": "Aurora",
  "encryptSnapshots": false,
  "compressSnapshots": false,
  "redactUrls": true,
  "redactUrlMode": "Full",
  "eventSnapshots": true,
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
| `snapshotIntervalMinutes` | `3` | Periodic fallback interval in minutes; still needed alongside event capture |
| `keepSnapshots` | `48` | Recent window: the newest files are always kept in full |
| `tieredRetention` | `true` | Beyond the recent window, thin history to hourly then daily representatives instead of deleting |
| `keepHourlyDays` | `7` | Days kept at one snapshot per clock hour |
| `keepDailyDays` | `30` | Days kept at one snapshot per calendar day |
| `keepSnapshotDays` | `0` | Age cleanup in days (`0` = off). Applied before the tiers, so nothing older than this survives |
| `launchOrder` | `[]` | App names or executable file names that start first on restore, in this order (for example a VPN or database other apps need) |
| `promptOnLogon` | `CrashOnly` | `CrashOnly`, `Always`, `Never` |
| `maxRestoreAgeHours` | `72` | Ignore older snapshots in the automatic prompt |
| `restoreBrowsers` | `true` | `false` removes browsers from restore |
| `restoreWindowPositions` | `true` | Restore position, size and maximized state |
| `defaultTabMode` | `Smart` | `Smart`, `Captured`, `Native`, `None` |
| `captureBrowserTabs` | `true` | Capture tabs in snapshots |
| `captureApproximateTabs` | `true` | UI Automation/history fallback (marked approximate) |
| `captureMediaPlayers` | `true` | Capture the VLC file and estimated position |
| `tabHistoryLookbackHours` | `24` | History fallback window |
| `pauseOnLowBattery` | `true` | Skip auto snapshots when on battery at or below `lowBatteryPercent` |
| `lowBatteryPercent` | `20` | Battery charge threshold for the low-battery pause (`0` disables it) |
| `minFreeDiskSpaceMB` | `200` | Skip auto snapshots when the snapshot drive has less free space (`0` disables it) |
| `showNotifications` | `true` | Tray balloons and toasts |
| `startWithWindows` | `true` | Create the Startup shortcut |
| `desktopShortcut` | `true` | Create the desktop shortcut |
| `theme` | `Aurora` | `Aurora`, `Daylight`, `Midnight`, `Forest`, `Ember`, `Neon`, `Sakura`, `Paper`, `Synthwave`, `Voltage`, `Frostbite`, `Magma`, `Aqua` or `Solar` |
| `encryptSnapshots` | `false` | Seal snapshots with DPAPI for this Windows user |
| `compressSnapshots` | `false` | Write gzip-compressed snapshots |
| `redactUrls` | `true` | Redact URL query strings and fragments before writing |
| `redactUrlMode` | `Full` | `Full` strips the whole query string; `Safe` keeps ordinary parameters and blanks credential-looking values |
| `eventSnapshots` | `true` | Resident tray: workspace/window changes, lock, sleep, low battery and best-effort shutdown/sign-out; also works in task-monitor mode, not the legacy watcher |
| `hibernateGuard` | `true` | Attempt to save and pin a checkpoint on suspend, display-off or lid-close; separate from `eventSnapshots` |
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
<summary><b>Tiered history and storage</b></summary>

- **Why:** a flat count of 48 snapshots at the default 3-minute interval covers about 2.4 hours. A crash the morning after a late night would find nothing to restore.
- **The policy** (`tieredRetention`, on by default): the newest `keepSnapshots` files are kept in full. Older ones are thinned instead of deleted: the newest snapshot of each clock hour for `keepHourlyDays` (7), then the newest of each calendar day for `keepDailyDays` (30). Anything older than every tier is removed.
- **Pinned snapshots** (including hibernate checkpoints) are never touched and do not count toward the budget.
- **One rule everywhere:** the sweep that runs after every snapshot and the storage cleanup (`Control-SessionRecovery.ps1 -Command storage-cleanup`) use the same policy.
- **`keepSnapshotDays`** runs first. With `keepSnapshotDays` set to 3, nothing older than 3 days survives, whatever the tiers say.
- **Upgrading:** a `config.json` without `tieredRetention` gets it switched on. History builds up from now; snapshots that earlier flat retention already deleted cannot come back.
- **Disk use:** with the defaults, up to about 246 snapshot files (48 + 168 hourly + 30 daily). `Diagnostics.ps1 -Json` reports this as `EstimatedStorage`, based on the average size of your current snapshots (8 KB each when there are none). The estimate counts snapshot files only, not thumbnails.
- **Turn it off** by setting `tieredRetention` to `false` to go back to count-only retention.

</details>

<details>
<summary><b>Developer workspaces and Windows Terminal</b></summary>

- **Captured from each tool's own state files**, without reading process memory: VS Code and Cursor (open folders and workspaces from `storage.json`), JetBrains IDEs (recent projects, up to 5 per product) and Windows Terminal (`state.json`).
- **Editors** reopen their folders through the editor's command-line launcher when it is found; otherwise the folder opens in Explorer so nothing is silently dropped.
- **Terminal tabs** reopen in a single Windows Terminal window with each tab's profile, directory and title, in the captured order. Terminal's default `windowingBehavior` is `useNew`, so one launch per tab would give one window per tab; instead the tabs go out as one `wt` command joined with `;`, 20 tabs per command. A very large session therefore continues in a second window. A `;` in a path or title is escaped, and a `"` inside one is dropped because `wt` has no quote escape.
- **Terminal capture depends on a Windows Terminal setting.** Terminal writes `persistedWindowLayouts` to `state.json` only when its `firstWindowPreference` is `persistedWindowLayout` (the default is `defaultProfile`), and it writes the layout when a window closes. By default no terminal tabs are captured, and even with the setting on, a crash leaves the layout from the last clean close. Editor folders are not affected.
- **Check why** with `Diagnostics.ps1 -Json`: the `TerminalCapture` entry says whether Terminal is installed, what `firstWindowPreference` is set to, how many tabs were found, and what to change.

</details>

<details>
<summary><b>Pin, export, import, search and VLC</b></summary>

- **Pin** keeps a snapshot forever and doesn't count toward `keepSnapshots`.
- **Export** saves a snapshot as plain JSON; **Import** validates and adds one back to the timeline.
- **Search** matches app names, folders, browsers, tab titles, URLs and dates.
- **Supported players:** VLC, mpv, MPC-HC, MPC-BE, PotPlayer and Windows Media Player. The playing file is always recorded; the position only when the player really stores one.
- **Where an exact position comes from**, verified by playing a real file in each player and inspecting what it wrote:
  - **mpv** — `watch_later/<MD5 of the file path>`, key `start=`. Exact. mpv writes it on a clean quit, which is the position playback resumed from.
  - **MPC-HC** — `HKCU\Software\MPC-HC\MPC-HC\MediaHistory`, `Filename` + `FilePosition` in milliseconds. Exact, but only when MPC-HC's own *Remember file position* option is on.
  - **VLC, MPC-BE, PotPlayer, Windows Media Player** — no usable stored position. VLC does not write one while playing (its resume file was unchanged across many minutes of playback, and `times` was `-1` for the file), MPC-BE's resume flag never produces position data, and PotPlayer's `Positions` key holds only window geometry.
- **When no position is known** the snapshot says *position not recorded* in the Studio and restore opens the file from the start. That is deliberate: an earlier version derived the position from how long the player had been running, and reported 4:51 for a file actually at 1:24:29. Opening near the start beats seeking to a confidently wrong time.
- **Known positions** advance by at most 30 minutes between snapshots, so idle time — or time the background app was not running — is never counted as watched. Only local files are seeked; discs, streams and playlists just open the player.
- **Recently closed tabs:** a tab closed in the last 30 minutes is added back to the capture, because Chromium records the close but not which URL it held. Each close record can claim only one URL, so closing three tabs adds three tabs back, never a day of browsing history. Turn off `captureApproximateTabs` to disable this entirely.

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
- **Crashes and power cuts cannot be predicted:** Windows sends no suspend notification before a blue screen or a hard power loss. Periodic capture (3-minute default), event attempts and crash detection remain the safety net, but recovery can only use the last successful snapshot. Pauses, capture failures or a stopped tray/task can leave older history; there is no guaranteed maximum data-loss window or exact pre-crash state.
- **Virtual desktops are best-effort:** restore uses the documented `IVirtualDesktopManager` interface and only moves windows owned by the restarted app. If a desktop no longer exists, the window stays on the current one. Moving arbitrary apps between desktops would need undocumented interfaces that change between Windows 11 builds, so it is out of scope.

</details>

## 🩺 Diagnostics

Open **Studio → Diagnostics** or **Start Menu → Run Diagnostics** for snapshot freshness, background mode, browsers, Windows Terminal capture status and recent errors. Studio also shows a rough snapshot-file storage estimate for the projected retention count, based on average snapshot size—not a full disk budget. Terminal capture uses the last saved layout, not live tabs; its status explains when the `firstWindowPreference` setting prevents layout capture. For a script-friendly report:

```powershell
$d = "$env:LOCALAPPDATA\SessionRecovery\app\Diagnostics.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File $d            # text
powershell -NoProfile -ExecutionPolicy Bypass -File $d -Json      # JSON
powershell -NoProfile -ExecutionPolicy Bypass -File $d -ReportPath "$env:TEMP\sr-report.txt"
```

Reports contain paths, URLs and log lines, so review them before sharing.

The JSON report also includes `TerminalCapture` (why Windows Terminal tabs are or are not being captured) and `EstimatedStorage` (how many snapshots tiered retention keeps and roughly how much disk they use). These two are in the report only; the Studio does not show them yet.

The **Recovery timeline** card lists restarts, power loss and blue screens from the Windows event log over the last 30 days. It is read locally and nothing is uploaded; only the event types and timestamps are shown, never message contents.

## 🔍 Compare snapshots

Select any snapshot in **Snapshots** and pick an older moment under **Compare with an earlier snapshot**. The details pane then shows which apps, folders, tabs and dev workspaces were opened or closed in between.

Each snapshot also records the PC facts that affect placement — machine name, display sizes, display scale and system language. When you restore a snapshot captured on another machine or with a different monitor layout, the details pane lists exactly what changed before you restore.

## 🔐 Privacy & data

- Everything stays on your PC: no extension, no debugging port and no telemetry. The app makes no network requests unless you check for or download an update.
- Snapshots hold executable paths, window titles, folder paths and URLs. They are plaintext by default; enable `encryptSnapshots` for DPAPI protection. Snapshot notes are always plaintext in `config.json`, and a Recovery Kit is a plain ZIP unless the snapshots inside are encrypted. Use BitLocker or account permissions on shared PCs.
- URLs are redacted before they are written, for browser tabs and for URL-shaped arguments in captured command lines. Two modes, set with `redactUrlMode`:
  - `Full` (default) drops the entire query string and fragment, so search terms, deep links and tokens never reach disk. The cost is that a restore reopens the site, not the exact page.
  - `Safe` keeps ordinary parameters so the exact page comes back, and blanks only values whose name looks like a credential (`token`, `secret`, `api_key`, `password`, `code`, `sid`, `signature` and similar). Fragments are always removed.
  - Both modes are bypassed when `redactUrls` is `false`. `excludeUrls` wildcards match the raw URL first, so an excluded domain is never captured at all.
  - Window titles and non-URL command-line arguments are still stored verbatim — a window title can contain a document name.
- To back up a session, copy its JSON and restore it elsewhere with `-SnapshotPath`.

| Path (under `%LOCALAPPDATA%\SessionRecovery`) | Contents |
|---|---|
| `snapshots\` | Snapshot JSON files |
| `logs\session-recovery.log` | Snapshot, restore and error messages |
| `config.json` | Settings and snapshot notes |
| `paused.json` | Shared pause marker, present only while snapshots are paused |
| `shutdown-attempt.json` | Last shutdown capture result, cleared at the next tray start |
| `shutdown-history.json` | Outcome of the last 20 shutdown captures (saved / not saved), shown in Diagnostics |
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
- Windows Terminal tabs are captured only when Terminal has saved a layout (`firstWindowPreference` set to `persistedWindowLayout`), and a crash leaves the layout from the last clean close.
- Unsaved-work detection relies on a marker in the window title; apps without one are not flagged.
- The tool is per-user.

</details>

## 🗑 Uninstall

- **MSI:** Settings → Apps → Session Recovery → Uninstall (snapshots and settings are kept).
- **PowerShell install:** Start Menu → *Uninstall Session Recovery*, or run `Uninstall-SessionRecovery.ps1` (add `-RemoveData` to delete snapshots, logs and config).

## 👩‍💻 Development

```powershell
# Build the MSI (needs .NET SDK 6+ and internet for WiX restore) → dist\SessionRecovery-<version>.msi
# (the default version is set in installer\Build-MSI.ps1)
powershell -NoProfile -ExecutionPolicy Bypass -File .\installer\Build-MSI.ps1

# Build the native host only
powershell -NoProfile -ExecutionPolicy Bypass -File .\installer\Build-Launcher.ps1 -Force

# Run from source with isolated test data
$env:SESSIONRECOVERY_HOME = Join-Path $PWD 'test-data'
.\dist\SessionRecovery.exe
```

`dist\` is git-ignored; publish the MSI as a GitHub Release asset.

Tests are Pester 5 and run in CI on every pull request: a parse check of every PowerShell source, the module tests, a UI layout audit in all nine languages, an MSI build and an installer smoke test. To run the module tests locally:

```powershell
Import-Module Pester -MinimumVersion 5.5 -Force
Invoke-Pester -Path tests -Output Detailed
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full checklist, including the rule that every UI string exists in all nine languages.

<details>
<summary><b>Project layout</b></summary>

```
session-recovery/
├── Install-SessionRecovery.ps1     Installer and shortcuts
├── Uninstall-SessionRecovery.ps1   Uninstaller
├── CONTRIBUTING.md                 Pull request checks and how to add a feature
├── assets/                         Brand icon and installer artwork
├── installer/                      WiX MSI project, launcher, build and signing scripts
├── packaging/winget/               winget manifests
├── tests/                          Pester suite, UI layout audit, installer smoke test
├── .github/workflows/ci.yml        CI: parse check, tests, UI audit, MSI build, smoke test
└── src/
    ├── SessionRecoveryLauncher.cs  Native host (no console windows)
    ├── Studio-SessionRecovery.ps1  Studio UI
    ├── StudioTheme.ps1             Shared theme catalog for Studio and restore
    ├── StudioControls.cs           Custom WinForms controls
    ├── Strings.ps1                 UI strings for all nine languages
    ├── SessionRecovery.psm1        Capture, exclusions, browsers, retention, diagnostics, restore engine
    ├── Save-Session.ps1            One-shot snapshot
    ├── Restore-Session.ps1         Restore UI and selective CLI restore
    ├── Tray-SessionRecovery.ps1    Tray app and snapshot timer
    ├── Control-SessionRecovery.ps1 Automation commands (status, workspaces, storage, undo)
    ├── InstallManifest.ps1         Install manifest helpers shared by the installer and uninstaller
    ├── Diagnostics.ps1             Health report
    ├── Watch-Session.ps1           Legacy watcher (compatibility)
    └── RunHidden.vbs               Legacy launcher (compatibility)
```

</details>
