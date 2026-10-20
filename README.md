# Session Recovery

**Reopen the apps, Explorer folders and browser tabs that were open before a crash, power cut or unexpected restart.**

Session Recovery is a small, local Windows utility. It runs quietly in the background, saves a snapshot of your desktop every few minutes, and offers to put everything back after an unexpected shutdown.

> **Important:** Session Recovery reopens applications and browser tabs. It cannot recover unsaved document contents, passwords, form data or anything else that was only in memory.

- Pure Windows PowerShell 5.1 and .NET. No external modules or installers to download.
- Keeps snapshots on your PC. Nothing is uploaded.
- Works with Chrome, Edge, Brave, Vivaldi, Opera and Firefox.
- Keeps browser windows together and preserves duplicate tabs.
- Uses either Windows Task Scheduler (one UAC prompt) or a Startup-folder watcher (no administrator rights).

## Contents

- [Features](#features)
- [Supported software](#supported-software)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Installation options](#installation-options)
- [How it works](#how-it-works)
- [Restoring a session](#restoring-a-session)
- [Browser tab modes](#browser-tab-modes)
- [Command-line reference](#command-line-reference)
- [Configuration](#configuration)
- [Crash detection](#crash-detection)
- [Data, logs and privacy](#data-logs-and-privacy)
- [Troubleshooting](#troubleshooting)
- [Known limitations](#known-limitations)
- [Uninstall](#uninstall)
- [Running from source](#running-from-source)
- [Project layout](#project-layout)

## Features

- **Automatic snapshots** every 3 minutes, plus one at logon and during installation.
- **Crash-aware restore prompt** after an unexpected shutdown, power loss or blue screen.
- **Manual restore** at any time, including after a normal shutdown.
- **Application windows** are grouped by executable and simple file arguments, then reopened without duplicates unless the force option is used.
- **File Explorer folders** are reopened at their captured paths.
- **Browser tabs** are read directly from the browser's own session files. No extension, remote debugging port or browser automation is used.
- **Window groups are preserved** for Chromium browsers, so tabs that belonged to the same browser window reopen together.
- **Duplicate tabs are preserved** instead of being collapsed into one.
- **Snapshot history** is rotated automatically so it cannot grow without limit.
- **Everything is local.** The tool makes no network requests and does not collect telemetry.

## Supported software

### Browsers

| Browser | Engine | How tabs are read |
| --- | --- | --- |
| Google Chrome | Chromium | `Session_*` files in the profile's `Sessions` folder |
| Microsoft Edge | Chromium | `Session_*` files in the profile's `Sessions` folder |
| Brave | Chromium | `Session_*` files in the profile's `Sessions` folder |
| Vivaldi | Chromium | `Session_*` files in the profile's `Sessions` folder |
| Opera | Chromium | `Session_*` files in the Opera profile folder |
| Mozilla Firefox | Gecko | `sessionstore-backups\recovery.jsonlz4`, then `sessionstore.jsonlz4` |

Multiple Chromium profiles are supported and restored profile by profile. Firefox captures its default profile(s), but the restore engine currently starts the first captured Firefox profile only. Each captured browser window is kept together.

### Applications

Any normal desktop application with a visible top-level window can be captured. Session Recovery records the executable path, simple file arguments, window titles and whether the main window was minimized. Applications are grouped by executable and arguments; without the force option, an executable that is already running is skipped, so it normally opens once.

File Explorer windows are captured as folder paths and reopened with `explorer.exe`.

## Requirements

- Windows 10 or Windows 11.
- Windows PowerShell 5.1 (included with Windows).
- No third-party software, PowerShell modules or internet connection.
- Administrator rights are **optional**. They are only needed for the scheduled-task installation mode.

## Quick start

### 1. Get the files

Clone the repository:

```powershell
git clone https://github.com/Bilalmesk/session-recovery.git
cd session-recovery
```

Or open the repository on GitHub, choose **Code > Download ZIP**, extract the ZIP, and open the extracted folder in PowerShell.

If the files came from the internet and Windows marks them as blocked, unblock them once:

```powershell
Get-ChildItem -Recurse | Unblock-File
```

### 2. Install

Open PowerShell in the folder that contains `Install-SessionRecovery.ps1` and run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-SessionRecovery.ps1
```

This is the recommended installation. Windows shows a UAC prompt once. The installer registers two scheduled tasks:

- `SessionRecovery-Snapshot` runs at logon and every 3 minutes.
- `SessionRecovery-RestorePrompt` runs at logon and checks whether the previous shutdown was clean.

If you do not want to use administrator rights, install with the Startup-folder watcher instead:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-SessionRecovery.ps1 -NoTasks
```

In this mode a hidden PowerShell watcher starts from the Startup folder at each logon and takes snapshots every 3 minutes. The restore prompt is also started from the Startup folder.

### 3. Check that it works

Open **Start Menu > Session Recovery > Take Snapshot Now**, then check the log:

```powershell
Get-Content "$env:LOCALAPPDATA\SessionRecovery\logs\session-recovery.log" -Tail 10
```

You should see a line ending in `Snapshot saved`. The snapshot files are in:

```text
%LOCALAPPDATA%\SessionRecovery\snapshots
```

You can also open **Start Menu > Session Recovery > Restore Session** (or the desktop shortcut) to confirm that the restore window lists your current applications and folders.

## Installation options

Pass these options to `Install-SessionRecovery.ps1`:

| Option | Default | Meaning |
| --- | --- | --- |
| `-NoTasks` | off | Use the Startup-folder watcher instead of scheduled tasks. No administrator rights required. |
| `-IntervalMinutes <n>` | `3` | Minutes between snapshots. Minimum 1. |
| `-KeepSnapshots <n>` | `48` | Number of snapshot files to keep. Older files are deleted automatically. |
| `-PromptOnLogon <mode>` | `CrashOnly` | `CrashOnly`, `Always` or `Never`. |
| `-DefaultTabMode <mode>` | `Smart` | `Smart`, `Captured`, `Native` or `None`. |
| `-NoDesktopShortcut` | off | Do not create the desktop shortcut. |
| `-NoInitialSnapshot` | off | Do not take a snapshot during installation. |
| `-InstallDirectory <path>` | `%LOCALAPPDATA%\SessionRecovery\app` | Advanced: install the program somewhere else. |

Examples:

```powershell
# Snapshot every 5 minutes and keep 96 files (about 8 hours of history)
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-SessionRecovery.ps1 -IntervalMinutes 5 -KeepSnapshots 96

# No UAC prompt, but keep a longer history
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-SessionRecovery.ps1 -NoTasks -IntervalMinutes 10 -KeepSnapshots 144

# Ask to restore after every logon, not only after a crash
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-SessionRecovery.ps1 -PromptOnLogon Always
```

### What the installer creates

| Location | Contents |
| --- | --- |
| `%LOCALAPPDATA%\SessionRecovery\app` | Program files and a copy of this README. |
| `%LOCALAPPDATA%\SessionRecovery\snapshots` | Snapshot JSON files. |
| `%LOCALAPPDATA%\SessionRecovery\logs` | `session-recovery.log` and its rotated backup. |
| `%LOCALAPPDATA%\SessionRecovery\config.json` | Settings. |
| Start Menu > Session Recovery | Restore Session, Take Snapshot Now, Uninstall Session Recovery. |
| Desktop | Restore Session shortcut (unless `-NoDesktopShortcut` is used). |
| Task Scheduler | `SessionRecovery-Snapshot` and `SessionRecovery-RestorePrompt` (default mode). |
| Startup folder | Watcher and restore-prompt shortcuts (`-NoTasks` mode). |

The installer stops an older watcher before copying new files, so upgrading does not leave two watchers running. Saved snapshots and most configuration values are preserved when you reinstall.

## How it works

1. **Capture.** A hidden PowerShell process reads the visible top-level windows, their owning process paths, File Explorer locations and browser session files. It writes a small JSON file under `%LOCALAPPDATA%\SessionRecovery\snapshots`.
2. **Rotate.** After each snapshot, the oldest files are removed so only `keepSnapshots` files remain.
3. **Detect.** At logon, the restore prompt reads the Windows System event log and compares the latest unexpected-shutdown event with the latest clean-shutdown event.
4. **Restore.** If the previous shutdown was unexpected (or `promptOnLogon` is `Always`), the tool shows the latest snapshot from before logon. You choose what to reopen, and the selected applications, folders and browser windows are started.

Snapshots are taken at logon and then on the configured interval. The watcher mode reads the interval from `config.json` on every cycle; the scheduled-task mode has the interval baked into the task trigger.

### What is captured

| Item | Captured | Restored |
| --- | --- | --- |
| Application executable, simple file arguments and window titles | Yes | One launch per executable/argument group; already-running executables are skipped unless forced |
| Whether an application was minimized | Yes | Started minimized |
| File Explorer folder paths | Yes | Folder reopened |
| Browser profiles and tabs | Yes | New windows/tabs, grouped by captured window |
| Minimized/maximized state and window position | Minimized state only | Minimized apps start minimized; maximized state and position are not restored |
| Unsaved document contents | No | No |
| Passwords, cookies or form data | No | No |

## Restoring a session

### The automatic prompt

After an unexpected shutdown, sign in normally. About 20–30 seconds later, a **Session Recovery** window appears with the newest snapshot taken before you signed in.

The default `CrashOnly` setting means the prompt appears only when Windows records a crash or unexpected shutdown. If the previous shutdown was clean, no prompt appears. You can change this with `promptOnLogon` or the `-PromptOnLogon` installer option.

The prompt lists:

- Applications, with their captured window titles.
- File Explorer folders.
- Browsers, with the number of captured tabs per profile.

Everything is checked by default. Clear the items you do not want, choose a browser tab mode, and click **Restore selected**. Click **Skip** to leave the snapshot untouched. Skipping does not delete anything, and the prompt will not ask again during the same logon session.

### The manual restore window

Use **Start Menu > Session Recovery > Restore Session** or the desktop shortcut. Manual restore:

- Always opens the window, even after a clean shutdown.
- Lets you choose any saved snapshot from the drop-down list, not only the latest one.
- Still respects your selected browser tab mode and force option.

### Steps in the restore window

1. Choose a snapshot. The automatic prompt uses the latest eligible snapshot; the manual window defaults to the newest one.
2. Review the list. Applications, folders and browsers are grouped and checked by default. Use **Select all** to toggle everything.
3. Pick a **Browser tabs** mode (see the table below).
4. Optionally tick **Start applications even when they are already running**. Leave it off to avoid duplicate windows.
5. Click **Restore selected**. A result window reports each item as `[OK]` or `[SKIP]`.

## Browser tab modes

The command-line values and the labels in the restore window are slightly different:

| CLI value | Restore window label | Behavior |
| --- | --- | --- |
| `Smart` | Smart - reopen captured tabs when available | Uses captured tabs when the snapshot has any; otherwise asks the browser to restore its own session. |
| `Captured` | Captured tabs - reopen the exact tabs | Opens the URLs from the snapshot or the browser's current session file. Falls back to the browser's own restore if no tabs were captured. |
| `Native` | Browser session - use the browser's own restore | Starts the browser with `--restore-last-session` (Chromium) or `-restore` (Firefox). |
| `None` | Do not reopen browsers or tabs | Skips browsers entirely. This mode does not start a blank browser window. |

Notes:

- **Captured tabs** preserves the captured window grouping and duplicate tabs. Very large windows are split into several launches so the Windows command line stays within its limit.
- **Native** is skipped when the browser is already running. Chromium may try anyway if the force option is enabled; Firefox still skips its native restore while it is running. Starting a second copy of a running Chromium browser normally opens a new window in the existing process rather than restoring the old session.
- **Smart** is the safest default after a crash because it uses the captured tab list whenever one is available.

## Command-line reference

All scripts are in the installed program folder:

```text
%LOCALAPPDATA%\SessionRecovery\app
```

The examples below use PowerShell. If you are running them from a normal PowerShell window, `-ExecutionPolicy Bypass` is included so unsigned local scripts are allowed.

### Take a snapshot now

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\SessionRecovery\app\Save-Session.ps1"
```

Add `-Quiet` to suppress console output. The Start Menu shortcut uses this switch and runs hidden.

### Run one watcher cycle

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\SessionRecovery\app\Watch-Session.ps1" -Once
```

Running `Watch-Session.ps1` without `-Once` starts a continuous watcher. Do not start a second watcher: a named mutex prevents duplicates, and the second process exits immediately.

### Restore a session

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\SessionRecovery\app\Restore-Session.ps1" -Manual
```

| Parameter | Meaning |
| --- | --- |
| `-Manual` | Show the restore window and list every saved snapshot, even after a clean shutdown. |
| `-NoUI` | Restore the newest eligible snapshot without showing a window. |
| `-DryRun` | Print what would be restored and exit without starting anything. |
| `-Force` | Start applications even when they are already running. May create duplicate windows; use deliberately. |
| `-SnapshotPath <path>` | Restore a specific JSON snapshot instead of selecting the newest one. |
| `-TabMode <mode>` | Override the configured tab mode for this run. |
| `-MaxAgeHours <n>` | Override `maxRestoreAgeHours` for automatic snapshot selection. |
| `-StartupDelaySeconds <n>` | Wait before showing the UI. Used internally by the Startup-folder restore shortcut. |

Examples:

```powershell
# Preview the latest snapshot without launching anything
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\SessionRecovery\app\Restore-Session.ps1" -Manual -DryRun

# Restore a specific snapshot without a window
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\SessionRecovery\app\Restore-Session.ps1" -NoUI -SnapshotPath "C:\Backups\session-20260101-120000-000.json" -TabMode Captured

# Restore the latest eligible snapshot after a clean shutdown, with the UI
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\SessionRecovery\app\Restore-Session.ps1" -Manual
```

`-NoUI` still applies the automatic age and pre-logon filters. It does not check whether the last shutdown was a crash, so it can be used after a normal restart. `-Manual` shows all saved snapshots regardless of age; use it to recover an older session.

## Configuration

Settings live in:

```text
%LOCALAPPDATA%\SessionRecovery\config.json
```

Default contents:

```json
{
  "snapshotIntervalMinutes": 3,
  "keepSnapshots": 48,
  "promptOnLogon": "CrashOnly",
  "maxRestoreAgeHours": 72,
  "restoreBrowsers": true,
  "defaultTabMode": "Smart"
}
```

| Setting | Default | Meaning |
| --- | --- | --- |
| `snapshotIntervalMinutes` | `3` | Minutes between snapshots. Minimum 1. |
| `keepSnapshots` | `48` | Maximum number of snapshot files. At the default interval this is about 2.4 hours of history. |
| `promptOnLogon` | `CrashOnly` | `CrashOnly` prompts only after an unexpected shutdown; `Always` prompts at every logon; `Never` disables the automatic prompt. Manual restore still works. |
| `maxRestoreAgeHours` | `72` | The automatic prompt ignores snapshots older than this. Manual restore lists all snapshots. |
| `restoreBrowsers` | `true` | Set to `false` to remove browsers from the restore plan and the restore window entirely. |
| `defaultTabMode` | `Smart` | Tab mode used when the restore window opens: `Smart`, `Captured`, `Native` or `None`. |

Edit the file with Notepad or another plain-text editor. Keep the JSON valid: quoted property names, commas between entries, no trailing comma. If the file cannot be parsed, the module logs a warning and falls back to the defaults.

### Applying changes

- **Watcher mode (`-NoTasks`):** `snapshotIntervalMinutes` and `keepSnapshots` are read on every cycle/save. The new interval applies after the current sleep ends; no restart is needed. Other settings are read when the restore prompt runs.
- **Scheduled-task mode:** `keepSnapshots` and the restore settings are read at runtime. To change the snapshot interval, re-run the installer with the new `-IntervalMinutes` value (or edit the task trigger in Task Scheduler).
- **Reinstalling:** the installer stops the old watcher, copies the program files and applies the install-time options (`-IntervalMinutes`, `-KeepSnapshots`, `-PromptOnLogon`, `-DefaultTabMode`). Snapshots and the other settings are preserved.

## Crash detection

The automatic prompt uses a deliberately simple heuristic:

- **Crash indicators:** System event 41 (`Microsoft-Windows-Kernel-Power`), event 6008 (unexpected shutdown), and event 1001 (`Microsoft-Windows-WER-SystemErrorReporting`).
- **Clean-shutdown indicators:** System events 1074 and 6006.
- The newest crash event is compared with the newest clean event over the last 7 days. If the crash is newer, or no clean event exists, the prompt is shown.
- If the event log cannot be read, the tool logs a warning and shows the prompt rather than silently skipping recovery.

This is not forensic software. Windows can record unusual shutdown sequences differently depending on Fast Startup, updates, power loss and the machine's firmware. If the prompt appears when you do not want it, set `promptOnLogon` to `Never` and use manual restore. If it does not appear after a real crash, run the manual restore shortcut; the snapshot is still there.

You can test the detector from PowerShell:

```powershell
Import-Module "$env:LOCALAPPDATA\SessionRecovery\app\SessionRecovery.psm1" -Force
Test-SRUnexpectedShutdown
```

`True` means the most recent shutdown signal looks like a crash, `False` means a clean shutdown is newer, and an empty result means the event log could not be read.

## Data, logs and privacy

| Path | Contents |
| --- | --- |
| `%LOCALAPPDATA%\SessionRecovery\snapshots` | One JSON file per snapshot. |
| `%LOCALAPPDATA%\SessionRecovery\logs\session-recovery.log` | Snapshot, restore and error messages. |
| `%LOCALAPPDATA%\SessionRecovery\logs\session-recovery.old.log` | Previous log after the current one exceeds 1 MB. |
| `%LOCALAPPDATA%\SessionRecovery\config.json` | Settings. |
| `%LOCALAPPDATA%\SessionRecovery\app` | Installed program files. |

- Snapshots contain executable paths, window titles, folder paths and browser URLs. Treat them as private data.
- The tool does not upload anything and does not contact a server. It does not use a browser extension or a debugging port.
- Browser session files are opened read-only.
- Snapshots and logs are not encrypted. If your device is shared, rely on Windows account permissions or BitLocker.
- To back up a session, copy the JSON file somewhere else. To restore it later, use `-SnapshotPath` with the manual or `-NoUI` restore command.

## Troubleshooting

### First checks

Run these in one PowerShell window so the variables stay available:

```powershell
$root = Join-Path $env:LOCALAPPDATA 'SessionRecovery'
$app  = Join-Path $root 'app'

Get-Content (Join-Path $root 'logs\session-recovery.log') -Tail 50
Get-ChildItem (Join-Path $root 'snapshots') -File |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 5 Name, Length, LastWriteTime

Get-ScheduledTask -TaskName 'SessionRecovery-*' -ErrorAction SilentlyContinue |
    Format-Table TaskName, State

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*Watch-Session.ps1*' } |
    Select-Object ProcessId, CommandLine
```

Run a snapshot immediately:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$app\Save-Session.ps1"
```

The log is the first place to look for `Snapshot saved`, `Snapshot failed`, `Missing executable`, `Restore prompt skipped` and similar messages.

### The installer is blocked or does nothing

Use the explicit PowerShell command instead of right-clicking the file:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-SessionRecovery.ps1
```

If the file was downloaded, unblock it first:

```powershell
Unblock-File .\Install-SessionRecovery.ps1
Get-ChildItem .\src | Unblock-File
```

If your organization enforces a restrictive execution policy, you may need to ask your administrator. Do not weaken the machine-wide policy just for this tool.

### The UAC prompt was cancelled, or scheduled tasks are missing

The default installation needs administrator rights for Task Scheduler. Either re-run the installer and choose **Yes** at the UAC prompt, or install without tasks:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-SessionRecovery.ps1 -NoTasks
```

To check the tasks:

```powershell
Get-ScheduledTask -TaskName 'SessionRecovery-*' | Format-Table TaskName, State
```

If a task exists but is disabled, enable and start it:

```powershell
Enable-ScheduledTask -TaskName 'SessionRecovery-Snapshot'
Start-ScheduledTask -TaskName 'SessionRecovery-Snapshot'
```

In `-NoTasks` mode, check that these Startup entries exist and are enabled in **Task Manager > Startup**:

```text
Session Recovery - Snapshot Watcher
Session Recovery - Restore Prompt
```

You can open the Startup folder with `shell:startup` in the Run dialog. If you deleted the shortcuts, re-run the installer.

### No snapshots are being created

1. Check the log for errors and confirm whether a snapshot has ever been written.
2. Run `Save-Session.ps1` manually (see [First checks](#first-checks)).
3. In task mode, confirm `SessionRecovery-Snapshot` exists and is `Ready`, then start it manually.
4. In watcher mode, confirm the `Watch-Session.ps1` process is running and the Startup shortcut is enabled.
5. Check that `%LOCALAPPDATA%\SessionRecovery\snapshots` is writable and the drive is not full.
6. If the machine crashed before the first snapshot at logon, there is nothing to restore. The installer normally creates an initial snapshot; `-NoInitialSnapshot` skips it.

### The restore prompt does not appear after a crash

Check, in order:

1. **Was there a snapshot before logon?** The prompt ignores snapshots taken after you signed in. Run `-Manual -DryRun` to see what is available.
2. **Is `promptOnLogon` set to `Never`?** Change it to `CrashOnly` or `Always`.
3. **Was the crash detected?** Run `Test-SRUnexpectedShutdown` and check the event log commands below.
4. **Is the snapshot too old?** The automatic prompt honors `maxRestoreAgeHours` (default 72). Use the manual shortcut for older snapshots.
5. **Was the prompt already shown and skipped?** It asks at most once per logon. Use **Restore Session** to open it again.
6. **Is the Startup entry or scheduled task disabled?** Check Task Manager > Startup or Task Scheduler.
7. **Is the log recording a skip?** Look for messages such as `Restore prompt skipped: the last shutdown was clean` or `No recent saved session was available to restore`.

Inspect recent shutdown events:

```powershell
Get-WinEvent -FilterHashtable @{
    LogName = 'System'
    Id = 41, 6008, 1001, 1074, 6006
    StartTime = (Get-Date).AddDays(-7)
} -ErrorAction SilentlyContinue |
    Sort-Object TimeCreated -Descending |
    Select-Object -First 15 TimeCreated, Id, ProviderName
```

The manual shortcut is always available, even when automatic detection is wrong.

### The restore prompt appears after a normal restart

Crash detection is a heuristic. Some shutdown paths do not write a clean-shutdown event, so the previous crash can still look newer. You can:

- Set `promptOnLogon` to `Never` and use the desktop shortcut when you want to restore.
- Leave it on `CrashOnly` and click **Skip**; this is harmless.
- Use `Always` only if you want a prompt at every logon.

### A snapshot is empty or misses applications

Session Recovery only captures visible, top-level desktop windows. Common reasons for missing items:

- The application was minimized to the notification area and had no visible window.
- The application is a Microsoft Store/UWP app. These are intentionally skipped because their host process cannot be relaunched reliably.
- The application is running elevated (as administrator) and its executable path is not readable by the non-elevated watcher.
- The application has no window of its own (a background service, helper or browser subprocess).
- The window was hidden, cloaked or a tool window.
- The application had already exited when the snapshot ran.

File Explorer is captured only when a folder window is open. Special shell locations and virtual folders may not have a normal file-system path and are skipped.

### A browser does not reopen its tabs

- For reliable capture, the browser should be running when the snapshot is taken, because tabs are read from its session files.
- Use **Captured tabs** mode to reopen the tab list collected by the tool instead of asking the browser to restore its own session. **Smart** falls back to the browser's own restore only when no tabs were captured.
- Chromium browsers keep the current `Session_*` file locked while running. Session Recovery reads the newest unlocked session file from the same profile, which may be a few minutes behind. Captured tabs can therefore miss tabs opened in the last minute or two.
- The tool prefers a readable current browser session file over the older snapshot. If the browser started at logon and has already written a new session, that newer session can win. If the restored tabs are wrong, select **Captured tabs** explicitly; the snapshot's tab list is used when the current session has no usable tabs.
- Firefox needs a readable `sessionstore-backups\recovery.jsonlz4` or `sessionstore.jsonlz4`. A profile that has never saved a session will have nothing to read.
- If the browser executable is installed in a non-standard location, the log reports `Browser executable not found` or `Missing executable`.
- Restoring a second profile may require closing the first browser instance. The tool passes `--profile-directory` for non-default profiles, but a running Chromium process can ignore profile switches.
- Opera's profile location varies between versions and installation methods. Check the log if Opera is not detected.

### Some tabs are missing or URLs are skipped

Only `http://`, `https://` and `file://` URLs are restored. The tool deliberately skips:

- `chrome://`, `edge://`, `brave://`, `vivaldi://`, `opera://` and `about:` pages.
- `chrome-extension://` and other extension pages, including OneTab-style extension URLs.
- DevTools and internal browser pages.
- Empty or malformed URLs.

Pinned tabs are reopened as normal tabs. Private/incognito windows are not guaranteed to be present in the browser's session files.

### The browser opens an extra blank window

Some Chromium builds show their startup page and then open the restored window separately. Close the blank window. If it happens often:

- Use **Browser session** mode instead of **Captured tabs**, or
- Start the browser before restoring, then use **Captured tabs** so the URLs open in the existing process.

### Applications do not start

Check the restore result window and the log for the exact message. Common causes:

- **Executable moved or uninstalled:** the captured path no longer exists.
- **Elevation required:** the restore process runs as your normal user. An app that needs administrator rights may show its own UAC prompt or fail to start. Start it manually if necessary.
- **Launcher or command-line arguments:** switches are intentionally dropped; only simple file paths and URLs are preserved. Apps that require a launcher or a specific command line may not restore correctly.
- **Working directory:** the tool starts the executable directly. An app that depends on being launched from a particular folder may behave differently.
- **Already running:** the app is skipped unless you enable the force option. This is intentional to avoid duplicate windows.
- **Microsoft Store app:** not supported; reopen it from the Start Menu.

### Applications start twice

The already-running check compares executable paths. It can miss an app that was started through a launcher, updater stub or a different copy of the executable. Leave the force option off, and uncheck apps that Windows already started automatically at logon.

### The restore window is clipped or hard to read

The window has a minimum size of 760×560 and is resizable. If Windows display scaling makes the text cramped, maximize the window or lower the display scaling. For unattended restores, use `-NoUI` instead of the window.

### The watcher uses too much CPU or disk

Snapshots are brief, but machines with hundreds of tabs or many windows take longer to inspect. You can:

- Increase `snapshotIntervalMinutes` to 5 or 10.
- Reduce `keepSnapshots`.
- Check for duplicate watcher processes; the mutex should prevent them, but a manually started copy can still appear briefly.
- Check the snapshot folder size:

```powershell
Get-ChildItem (Join-Path $root 'snapshots') -File | Measure-Object Length -Sum
```

Logs rotate automatically at 1 MB. Snapshot JSON files are normally small, but a browser with thousands of tabs can produce larger files.

### Antivirus or SmartScreen warns about the tool

The tool uses a `.vbs` launcher and hidden PowerShell, which some security products treat as suspicious. The scripts are plain text and can be reviewed before installation. If you trust the source, add an exclusion for `%LOCALAPPDATA%\SessionRecovery`. Do not disable real-time protection globally.

### I need an older snapshot, or I am restoring on another PC

Manual restore lists every snapshot regardless of `maxRestoreAgeHours`. Choose the older entry from the drop-down list, or use `-SnapshotPath`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\SessionRecovery\app\Restore-Session.ps1" -Manual -SnapshotPath "D:\Backup\session-20260101-120000-000.json"
```

On another PC, install Session Recovery first, copy the JSON file over, and use `-SnapshotPath`. The applications and browser profiles must exist on that PC for the restore to succeed; unavailable executables are reported as skipped.

### Uninstall leaves files behind

The uninstaller schedules deletion of files that are still in use and may need a few seconds. If the folder remains:

1. Sign out and back in, then delete `%LOCALAPPDATA%\SessionRecovery` manually.
2. If scheduled tasks remain, run the uninstaller from an elevated PowerShell window.
3. If you used a custom `SESSIONRECOVERY_HOME` for testing, remove that folder separately.

## Known limitations

- **Unsaved work is not recovered.** Only application windows, folders and browser tabs are reopened.
- **Exact window positions and monitor layout are not restored.**
- **One launch per executable/argument group.** Multiple document windows from the same executable are not recreated individually, and a program opened with different files may appear as separate entries. Without force, later entries are skipped once the executable is running.
- **Microsoft Store/UWP apps are skipped.**
- **Elevated applications may be skipped** because their executable path can be unreadable to the non-elevated watcher.
- **Command-line switches are generally dropped.** Simple file paths and URLs may be kept.
- **Pinned tabs reopen as normal tabs.**
- **Browser internal and extension URLs are skipped.**
- **Private/incognito windows are not guaranteed to be captured.**
- **Chromium session files can lag by a few minutes** when the live file is locked.
- **A readable current browser session wins over the snapshot.** If the browser has already written a new session, the tool may reopen those tabs instead of the older snapshot's tabs.
- **Crash detection is heuristic**, not a guarantee that every crash or clean shutdown is classified correctly.
- **Snapshots and logs are not encrypted.** They contain window titles and URLs.
- **The tool is per-user.** Each Windows user needs their own installation and data.

## Uninstall

Use **Start Menu > Session Recovery > Uninstall Session Recovery**, or run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\SessionRecovery\app\Uninstall-SessionRecovery.ps1"
```

By default, saved snapshots, logs and `config.json` are kept. Add `-RemoveData` to delete them as well:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\SessionRecovery\app\Uninstall-SessionRecovery.ps1" -RemoveData
```

Removing scheduled tasks requires administrator rights, so the uninstaller may show a UAC prompt once. If no scheduled tasks are present (for example, a clean `-NoTasks` installation), no elevation is needed. The uninstaller stops the hidden watcher, removes both startup entries, the Start Menu folder and the desktop shortcut, and then removes the program folder.

To repair an installation, simply run the installer again. It replaces the program files, stops an old watcher, and re-registers the tasks or Startup entries.

## Running from source

You can run the tool without installing it:

```powershell
cd session-recovery
powershell -NoProfile -ExecutionPolicy Bypass -Command "Import-Module '.\src\SessionRecovery.psm1' -Force; Save-SRSnapshot"
powershell -NoProfile -ExecutionPolicy Bypass -File .\src\Restore-Session.ps1 -Manual
```

To keep test data away from your real snapshots, point the module at a temporary data folder before importing it:

```powershell
$env:SESSIONRECOVERY_HOME = Join-Path $PWD 'test-data'
powershell -NoProfile -ExecutionPolicy Bypass -Command "Import-Module '.\src\SessionRecovery.psm1' -Force; Save-SRSnapshot"
```

`SESSIONRECOVERY_HOME` changes the root used for `snapshots`, `logs` and `config.json`. Remove the environment variable when you are done. The installed app does not need it.

## Project layout

```text
session-recovery/
├── Install-SessionRecovery.ps1      Installer, shortcuts, tasks or Startup entries
├── Uninstall-SessionRecovery.ps1    Removes the installation
├── README.md                        This guide
└── src/
    ├── SessionRecovery.psm1         Capture, browser parsing, crash detection, restore engine
    ├── Save-Session.ps1             One-shot snapshot entry point
    ├── Restore-Session.ps1          Restore UI and command-line restore
    ├── Watch-Session.ps1            Hidden periodic watcher
    └── RunHidden.vbs                Starts the scripts without a console window
```
