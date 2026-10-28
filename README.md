# Session Recovery

**Reopen the apps, Explorer folders and browser tabs that were open before a crash, power cut or unexpected restart.**

Session Recovery is a local Windows utility with a native desktop Studio. It snapshots your desktop every few minutes and offers to restore it after an unexpected shutdown. No browser extension, no telemetry and no external modules.

> **Important:** It reopens applications and tabs. It cannot recover unsaved document contents, passwords or form data.

## Requirements

- Windows 10/11 with Windows PowerShell 5.1.
- Chrome, Edge, Brave, Vivaldi, Opera, Opera GX, Chromium or Firefox.
- Native `SessionRecovery.exe` host: no visible `cmd` or PowerShell windows.

## Install

### winget

```powershell
winget install Bilalmesk.SessionRecovery
```

The package installs per-user. Settings and snapshots live in `%LOCALAPPDATA%\SessionRecovery` and survive upgrades.

### MSI

Download `SessionRecovery-<version>.msi` and its `.sha256` file from the [GitHub Releases](https://github.com/Bilalmesk/session-recovery/releases) page, verify the hash, then run the MSI. The wizard can change the install folder and clear the optional desktop shortcut. No UAC prompt is needed.

```powershell
Get-FileHash .\SessionRecovery-2.7.0.msi -Algorithm SHA256
Get-Content .\SessionRecovery-2.7.0.msi.sha256
```

The MSI is **not code-signed** unless Trusted Signing or PFX secrets are configured in CI. The in-app updater now shows **UNSIGNED UPDATE** and defaults to **No** before it runs a build without a valid signature. If SmartScreen appears, verify the published SHA256 first, then choose **More info -> Run anyway**. A matching hash proves the file matches the release asset; only a signature proves who built it.

### PowerShell installer

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-SessionRecovery.ps1
```

It asks for UAC once, copies files to `%LOCALAPPDATA%\SessionRecovery\app`, creates shortcuts, registers two scheduled tasks and starts the tray. Use `-NoTasks` to skip administrator rights and run from the Startup folder instead:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-SessionRecovery.ps1 -NoTasks
```

Install options: `-IntervalMinutes`, `-KeepSnapshots`, `-KeepSnapshotDays`, `-PromptOnLogon`, `-DefaultTabMode`, `-NoDesktopShortcut`, `-NoInitialSnapshot` and `-InstallDirectory`.

### First run

Open **Session Recovery** from the desktop or Start Menu and click **Capture now**. The Snapshots page should show the new snapshot immediately. Check the log with:

```powershell
Get-Content "$env:LOCALAPPDATA\SessionRecovery\logs\session-recovery.log" -Tail 10
```

## What it does

- **Session Recovery Studio** with Dashboard, Snapshots, Exclusions, Recovery Kit, Settings, Diagnostics and About; 14 themes and 9 languages.
- Automatic snapshots every 3 minutes, plus lock, sleep/resume and low-battery events. Unchanged states are skipped.
- Restores apps to their captured position, size and maximized state. Windows from missing monitors are mapped onto the current layout.
- Restores Explorer folders and browser tabs: Chromium session files first, UI Automation/history fallback, Firefox `recovery.jsonlz4`.
- Restores dev workspaces (VS Code, Cursor, JetBrains, Windows Terminal), PuTTY sessions and RDP targets.
- Media playback restore for VLC, MPC-HC/BE, mpv and PotPlayer. Positions are exact for mpv IPC and estimated otherwise.
- Crash-aware prompt with a localized shutdown reason from Event IDs 41, 1001, 6008, 1074 and 6006, plus Office AutoRecover files.
- Timeline search, per-snapshot change diff, pin, export/import, named workspaces and a restore preview.
- Searchable snapshot notes, a local privacy scan for sensitive apps and sites, portable Recovery Kits and local recovery insights.
- Opt-in window thumbnails, DPAPI encryption, gzip compression and URL query redaction.
- Named-pipe/CLI control API for automation.

### Notes, privacy scan and Recovery Kits

- **Snapshot notes** hold up to 500 characters of searchable text per snapshot. They are stored in `config.json` keyed by snapshot file name, included in Recovery Kits, and removed when their snapshot is deleted. Notes are plain text even when snapshots are encrypted.
- **Privacy scan** on the Exclusions page inspects visible application/process names and browser tab URLs and titles for categories such as password managers, banking, messaging, email, health and social media. It proposes wildcard exclusions that you can add one at a time or all at once. It never reads screenshots, window pixels or page content.
- **Recovery Kit** on its own Studio page bundles every snapshot, snapshot note and exclusion rule into one portable `.srkit` file. Import merges notes and rules without overwriting existing settings, marks imported snapshots as untrusted, and skips DPAPI-encrypted snapshots because only the Windows account that created them can read them. A kit never contains settings, logs, screenshots or page content. The `.srkit` is a ZIP archive and is plaintext unless the snapshots inside are encrypted, so treat it like a private document.
- **Recovery insights** on Diagnostics summarize locally what the snapshot store contains: counts, time span, unique apps and sites, pins, notes, imports and storage use.

### Restoring

Use **Start Menu -> Session Recovery -> Restore Session**, or select a snapshot in the Studio and click **Restore selected**. After an unexpected shutdown the prompt appears automatically about 20-30 seconds after sign-in when `promptOnLogon` is `CrashOnly`. Uncheck what you do not want, choose a tab mode, then restore.

Snapshots carry a per-install provenance ID. Imported snapshots, hand-dropped files and snapshots created by another installation are treated as untrusted input. The app shows the exact program list, including each program's saved arguments, and launches only `.exe` programs on local fixed drives. Path arguments must also resolve to local fixed drives, so nothing is opened from a network share. Network shares, script hosts, interpreters, download tools and shell launchers such as `mshta`, `wscript`, `powershell`, `cmd`, `certutil`, `bitsadmin` and `explorer` are blocked as restore programs; folder restore opens folders directly and is unaffected. Upgrades adopt the snapshots already on disk, so your own snapshots keep restoring without the untrusted-snapshot prompt. Imported files also record the source file's SHA256. Headless restores of an untrusted snapshot require `-AllowImportedSnapshot`.

```powershell
$app = "$env:LOCALAPPDATA\SessionRecovery\app"

# List snapshots
powershell -NoProfile -ExecutionPolicy Bypass -File "$app\Restore-Session.ps1" -ListSnapshots

# Preview without launching anything
powershell -NoProfile -ExecutionPolicy Bypass -File "$app\Restore-Session.ps1" -Manual -DryRun

# Restore a filtered selection without a window
powershell -NoProfile -ExecutionPolicy Bypass -File "$app\Restore-Session.ps1" -NoUI -IncludeApps 'Code,Terminal' -IncludeBrowsers Brave
```

Useful flags: `-Manual`, `-NoUI`, `-DryRun`, `-Force`, `-SnapshotPath`, `-TabMode`, `-MaxAgeHours`, `-ListSnapshots`, `-Include*`, `-Exclude*` and `-AllowImportedSnapshot`. Filters apply to `-NoUI` and `-DryRun`; the interactive window uses checkboxes.

Tab modes: `Smart` (captured tabs when available, otherwise the browser's own session), `Captured` (exact tabs), `Native` (browser restore) and `None`.

### Updates

**Studio -> About -> Application updates -> Check for updates** uses the public GitHub Releases API, downloads the MSI and `.sha256`, verifies the hash, and asks before installing. No GitHub account or token is needed.

The updater checks the SHA256 published with the release. That detects a corrupted or swapped download, but it does not independently prove who built the MSI. With code signing enabled, Windows shows a verified publisher instead of an unknown one.

## Configuration

Settings are in `%LOCALAPPDATA%\SessionRecovery\config.json`. The Studio Settings page edits the common options; advanced users can edit the JSON. Key settings:

| Setting | Default | Meaning |
| --- | --- | --- |
| `snapshotIntervalMinutes` | `3` | Minutes between snapshots. |
| `keepSnapshots` | `48` | Maximum files; unchanged states are skipped. |
| `keepSnapshotDays` | `0` | Age limit; `0` disables it. |
| `promptOnLogon` | `CrashOnly` | `CrashOnly`, `Always` or `Never`. |
| `maxRestoreAgeHours` | `72` | Ignore older snapshots in the automatic prompt. |
| `defaultTabMode` | `Smart` | `Smart`, `Captured`, `Native` or `None`. |
| `captureBrowserTabs` | `true` | Capture browser tabs. |
| `captureThumbnails` | `false` | Store a small JPEG per window. |
| `compressSnapshots` | `false` | Write gzip snapshots. |
| `encryptSnapshots` | `false` | Seal snapshots with DPAPI. |
| `redactUrls` | `true` | Strip URL query strings and fragments. |
| `eventSnapshots` | `true` | Capture on lock, sleep/resume and low battery. |
| `excludeApps` / `excludeFolders` / `excludeUrls` | `[]` | Wildcard exclusions for new snapshots. |
| `pinnedSnapshots` | `[]` | Snapshot file names kept by retention. |
| `snapshotNotes` | `{}` | Searchable notes keyed by snapshot file name. |

Exclusions only affect new snapshots; existing files still contain what was captured before. Add patterns such as `KeePass*`, `D:\Private*` or `*bank*` on the Studio Exclusions page.

## Privacy and data

Everything stays on the PC. Snapshots, logs and settings live under `%LOCALAPPDATA%\SessionRecovery`:

| Path | Contents |
| --- | --- |
| `snapshots` | Snapshot JSON, gzip or DPAPI files. |
| `snapshots\thumbs` | Window thumbnails, only when enabled. |
| `workspaces` | Named workspaces. |
| `logs\session-recovery.log` | Snapshot, restore and error messages. |
| `config.json` | Settings and snapshot notes. |
| `app` | Program files. |

> **Plaintext warning:** snapshots are plain JSON by default. They contain executable paths, window titles, Explorer folder paths and browser URLs; media snapshots also contain the playing file and position; thumbnails contain a small image of each captured window. Snapshot notes are plain text in `config.json`, and a Recovery Kit bundles snapshots, notes and exclusions into a plain ZIP unless the snapshots inside are encrypted. Anyone who can read your profile, a kit or a backup/synced copy can read them. Turn on `encryptSnapshots` for DPAPI protection. Encrypted files restore only for the same Windows user on the same PC, so keep an unencrypted export only if you need cross-PC recovery and can protect it yourself.

- `redactUrls` removes query strings and fragments before URLs are written.
- Exclusions apply before a snapshot is written; they never rewrite old snapshots.
- The privacy scan reads only visible app/process names and browser tab URLs/titles. It never captures screenshots or page content, and it suggests exclusions without changing anything until you confirm.
- Recovery Kit import validates archive paths, caps entry sizes, skips DPAPI-encrypted snapshots and never overwrites existing settings or exclusion rules.
- The app makes no network requests unless you check for or download an update.
- Diagnostics are local. Reports contain paths, URLs and log lines, so review them before sharing.

## Troubleshooting

Start with **Studio -> Diagnostics** or **Start Menu -> Session Recovery -> Run Diagnostics**.

| Problem | What to check |
| --- | --- |
| Installer blocked | Run it with `powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-SessionRecovery.ps1`; use `Unblock-File` on downloaded files. |
| No UAC or tasks missing | Install with `-NoTasks`, or re-run and approve UAC. Check Task Scheduler and Task Manager -> Startup. |
| No snapshots | Click **Capture now**; check the log, folder permissions, free space and whether the tray or task is running. |
| No prompt after a crash | Check `promptOnLogon`, `maxRestoreAgeHours`, crash detection and whether it was already skipped. Use **Restore Session**. |
| Prompt after a normal restart | Crash detection is heuristic. Set `promptOnLogon` to `Never` or click **Skip**. |
| Apps missing | Only visible top-level windows are captured. UWP, elevated, tray-only and exited apps are skipped. |
| Tabs missing or wrong | Use **Captured tabs**. Chromium session files can lag; approximate tabs are marked. |
| Apps start twice | Leave **Force** off and uncheck apps Windows already starts at logon. |
| Uninstall leaves files | The script uninstaller removes only files listed in `install-manifest.json`. If the manifest is missing or a file is locked, close the app and remove `%LOCALAPPDATA%\SessionRecovery\app` manually. |

Crash detection reads Event IDs 41, 6008, 1001, 1074 and 6006. Inspect recent events with:

```powershell
Get-WinEvent -FilterHashtable @{
    LogName = 'System'; Id = 41, 6008, 1001, 1074, 6006
    StartTime = (Get-Date).AddDays(-7)
} -ErrorAction SilentlyContinue | Sort-Object TimeCreated -Descending |
    Select-Object -First 15 TimeCreated, Id, ProviderName
```

## Known limitations

- Unsaved work, passwords, cookies and form data are not recovered.
- Store/UWP, elevated, tray-only and hidden windows are skipped.
- Window placement and virtual desktops are best-effort; missing desktops cannot be recreated.
- Chromium session files can lag, and approximate tabs may miss or add a tab.
- Private/incognito windows are not guaranteed to be captured.
- One launch per executable/argument group; multiple document windows may not be recreated.
- Encrypted snapshots only restore for the same Windows user and PC.
- The app is per-user.

## Uninstall

MSI: **Settings -> Apps -> Installed apps -> Session Recovery -> Uninstall**, or **Start Menu -> Session Recovery -> Uninstall Session Recovery**.

PowerShell installer:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\SessionRecovery\app\Uninstall-SessionRecovery.ps1"
```

Add `-RemoveData` to delete snapshots, logs and config. The script deletes only files recorded by the installer manifest and never recursively removes an arbitrary `-InstallDirectory`. Removing scheduled tasks may require UAC.

## Build and test

Prerequisites: .NET SDK 6 or newer and internet access for the WiX NuGet restore.

```powershell
Import-Module Pester -MinimumVersion 5.5 -Force
Invoke-Pester -Path tests -Output Detailed

# Render all nine languages and fail on clipped or overlapping controls
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-UiAudit.ps1

# Build the native host and MSI
powershell -NoProfile -ExecutionPolicy Bypass -File .\installer\Build-MSI.ps1

# Install, verify, render and uninstall the built MSI
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-InstallerSmoke.ps1 -MsiPath .\dist\SessionRecovery-2.7.0.msi
```

The build writes `dist\SessionRecovery-<version>.msi`, its `.sha256` file and a short release README. `dist\` is ignored by Git; publish the MSI as a GitHub Release asset.

CI runs four jobs on every push and pull request: Pester tests, the nine-language layout audit, the MSI build and the installer smoke test. Branch protection requires all four.

**Code signing:** `installer\Sign-Release.ps1` signs with Azure Trusted Signing (`AZURE_TRUSTED_SIGNING_*`) or a PFX (`SIGNING_PFX_PATH`, `SIGNING_PFX_PASSWORD`). CI signs when the secrets exist; otherwise it skips signing.

**winget:** install with `winget install Bilalmesk.SessionRecovery`. The manifest is in `packaging\winget\`. Publish a release first, then run:

```powershell
wingetcreate submit --urls <msi-url>,<sha256-url> --version <version>
```

## Running from source

```powershell
.\dist\SessionRecovery.exe                # Studio
.\dist\SessionRecovery.exe --snapshot     # Snapshot through the native host
.\dist\SessionRecovery.exe --restore-manual
.\dist\SessionRecovery.exe --diagnostics

powershell -NoProfile -ExecutionPolicy Bypass -Command "Import-Module '.\src\SessionRecovery.psm1' -Force; Save-SRSnapshot"
powershell -NoProfile -ExecutionPolicy Bypass -File .\src\Restore-Session.ps1 -Manual
```

Build the native host with `.\installer\Build-Launcher.ps1 -Force`. Use `$env:SESSIONRECOVERY_HOME` to redirect snapshots, logs and config during manual testing.

## Project layout

```text
session-recovery/
├── Install-SessionRecovery.ps1      Script installer (writes install-manifest.json)
├── Uninstall-SessionRecovery.ps1    Safe uninstaller (requires install-manifest.json)
├── src/                             Module, Studio, restore, tray, strings and capture
├── installer/                       WiX MSI project, launcher, build and signing
├── packaging/winget/                winget manifest
├── tests/                           Pester, UI audit and installer smoke tests
└── assets/                          Brand icon and installer artwork
```

## License

MIT. See [LICENSE](LICENSE).
