#requires -Version 5.1
<#
    Tray-SessionRecovery.ps1
    Keeps Session Recovery running in the notification area.

    The tray app owns the snapshot timer when Windows Task Scheduler is not
    being used. If a scheduled snapshot task or another watcher is already
    running, it stays in monitor-only mode so snapshots are never duplicated.

    Usage:
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File Tray-SessionRecovery.ps1
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File Tray-SessionRecovery.ps1 -MonitorOnly
#>
[CmdletBinding()]
param(
    [switch]$MonitorOnly,
    [int]$FirstSnapshotDelaySeconds = 10
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'SessionRecovery.psm1'
Import-Module $modulePath -Force -ErrorAction Stop
. (Join-Path $PSScriptRoot 'Strings.ps1')
try {
    $trayLanguage = 'en'
    $trayConfig = Get-SRConfig
    $trayLanguageProperty = $trayConfig.PSObject.Properties['language']
    if ($null -ne $trayLanguageProperty -and -not [string]::IsNullOrWhiteSpace([string]$trayLanguageProperty.Value)) {
        $trayLanguage = [string]$trayLanguageProperty.Value
    }
} catch { $trayLanguage = 'en' }
$script:TrayLang = $trayLanguage
$script:TrayStrings = Get-SRStrings -Language $trayLanguage
function T {
    param([Parameter(Mandatory = $true)][string]$Key, [string]$Default = '')
    if ($script:TrayStrings -and $script:TrayStrings.ContainsKey($Key) -and -not [string]::IsNullOrWhiteSpace([string]$script:TrayStrings[$Key])) {
        return [string]$script:TrayStrings[$Key]
    }
    return $Default
}
try { Write-SRLog -Message 'Tray app booting.' } catch { }
try {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    if ($principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Repair-SRLegacyTasks | Out-Null
    }
} catch { }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Kept independently loadable for hermetic native-helper tests (no tray startup).
function Initialize-SRTrayNative {
if (-not ('SessionRecovery.TrayPowerMonitor' -as [type])) {
    Add-Type -ReferencedAssemblies 'System.Windows.Forms' -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text;
using Microsoft.Win32;
using System.Windows.Forms;

namespace SessionRecovery
{
    public sealed class TrayPowerMonitor : NativeWindow, IDisposable
    {
        private const int WM_POWERBROADCAST = 0x0218;
        private const int PBT_POWERSETTINGCHANGE = 0x8013;
        private const int DEVICE_NOTIFY_WINDOW_HANDLE = 0;
        private static readonly Guid DisplayGuid = new Guid("2B84C20E-AD23-4DDF-93DB-05FFBD7EFCA5");
        private static readonly Guid LidGuid = new Guid("BA3E0F4D-B817-4094-A2D1-D56379E6A0F3");
        private IntPtr displayNotification;
        private IntPtr lidNotification;
        private bool disposed;

        public event EventHandler DisplayOff;
        public event EventHandler LidClosed;
        public event EventHandler SuspendRequested;
        public event EventHandler ShutdownRequested;
        public event EventHandler ShutdownCancelled;
        private bool ending;
        private bool shutdownDispatched;
        private readonly object signalGate = new object();
        private bool resumeSignal, suspendSignal, lockSignal, suspendDispatched;
        private long suspendSignalAt;
        private static long ClockMilliseconds { get { return (long)(Stopwatch.GetTimestamp() * (1000.0 / Stopwatch.Frequency)); } }

        // Foreign-thread fallback is only fresh until resume, native dispatch,
        // or expiry. It must never turn into a stale pre-sleep save after wake.
        public void SignalPowerMode(PowerModes mode)
        {
            lock (signalGate) {
                if (mode == PowerModes.Resume) {
                    resumeSignal = true;
                    suspendSignal = suspendDispatched = false;
                } else if (mode == PowerModes.Suspend && !suspendDispatched) {
                    suspendSignal = true;
                    suspendSignalAt = ClockMilliseconds;
                }
            }
        }
        public void SignalNativeSuspend()
        {
            lock (signalGate) {
                suspendSignal = false;
                if (suspendDispatched) return;
                suspendDispatched = true;
            }
            Raise(SuspendRequested);
        }
        private readonly PowerModeChangedEventHandler powerHandler;
        private readonly SessionSwitchEventHandler sessionHandler;

        // SystemEvents may run on a foreign thread. Only C# state crosses it.
        public bool[] DrainSystemSignals()
        {
            lock (signalGate) {
                bool freshSuspend = suspendSignal && !suspendDispatched && !resumeSignal &&
                    ClockMilliseconds - suspendSignalAt < 2000;
                if (freshSuspend) suspendDispatched = true;
                bool[] result = new bool[] { resumeSignal, freshSuspend, lockSignal };
                resumeSignal = suspendSignal = lockSignal = false;
                return result;
            }
        }

        // Separate from WndProc so tests can exercise cancellation/dedup safely.
        public void SignalSessionEnd(bool query, bool committed)
        {
            if (!query && !committed) {
                ending = false;
                shutdownDispatched = false;
                Raise(ShutdownCancelled);
                return;
            }
            if (!ending) { ending = true; }
            if (!shutdownDispatched) {
                shutdownDispatched = true;
                Raise(ShutdownRequested);
            }
        }

        public bool DisplayRegistered { get { return displayNotification != IntPtr.Zero; } }
        public bool LidRegistered { get { return lidNotification != IntPtr.Zero; } }

        public TrayPowerMonitor()
        {
            CreateParams cp = new CreateParams();
            cp.Caption = "SessionRecoveryPowerMonitor";
            CreateHandle(cp);

            // The API requires a modifiable Guid, so copy the static values.
            Guid display = DisplayGuid;
            Guid lid = LidGuid;
            displayNotification = RegisterPowerSettingNotification(Handle, ref display, DEVICE_NOTIFY_WINDOW_HANDLE);
            lidNotification = RegisterPowerSettingNotification(Handle, ref lid, DEVICE_NOTIFY_WINDOW_HANDLE);
            powerHandler = delegate(object sender, PowerModeChangedEventArgs e) {
                SignalPowerMode(e.Mode);
            };
            sessionHandler = delegate(object sender, SessionSwitchEventArgs e) {
                if (e.Reason == SessionSwitchReason.SessionLock) {
                    lock (signalGate) { lockSignal = true; }
                }
            };
            SystemEvents.PowerModeChanged += powerHandler;
            SystemEvents.SessionSwitch += sessionHandler;
        }

        protected override void WndProc(ref Message m)
        {
            // This hidden window is top-level (not HWND_MESSAGE), so it receives
            // session broadcasts. Dispatch NOW; a timer may never tick again.
            if (m.Msg == 0x0011) {
                try { SignalSessionEnd(true, false); } catch { }
                m.Result = new IntPtr(1); // Always allow shutdown, even on error.
                return;
            }
            if (m.Msg == 0x0016) {
                try { SignalSessionEnd(false, m.WParam != IntPtr.Zero); } catch { }
                m.Result = IntPtr.Zero;
                return;
            }
            if (m.Msg == WM_POWERBROADCAST) {
                if (m.WParam.ToInt64() == 0x0004) { // PBT_APMSUSPEND
                    try { SignalNativeSuspend(); } catch { }
                    m.Result = new IntPtr(1);
                    return;
                }
                if (m.WParam.ToInt64() == 0x0007 || m.WParam.ToInt64() == 0x0012) {
                    SignalPowerMode(PowerModes.Resume); // resume suspend/automatic
                }
            }
            if (m.Msg == WM_POWERBROADCAST && m.WParam.ToInt64() == PBT_POWERSETTINGCHANGE && m.LParam != IntPtr.Zero)
            {
                Guid setting = (Guid)Marshal.PtrToStructure(m.LParam, typeof(Guid));
                int length = Marshal.ReadInt32(m.LParam, 16);
                if (length >= 4)
                {
                    int value = Marshal.ReadInt32(m.LParam, 20);
                    if (setting == DisplayGuid && value == 0) { Raise(DisplayOff); }
                    else if (setting == LidGuid && value == 0) { Raise(LidClosed); }
                }
            }
            base.WndProc(ref m);
        }

        private void Raise(EventHandler handler)
        {
            if (handler != null) { handler(this, EventArgs.Empty); }
        }

        public void Dispose()
        {
            if (disposed) { return; }
            disposed = true;
            SystemEvents.PowerModeChanged -= powerHandler;
            SystemEvents.SessionSwitch -= sessionHandler;
            DisplayOff = LidClosed = SuspendRequested = ShutdownRequested = ShutdownCancelled = null;
            if (displayNotification != IntPtr.Zero)
            {
                UnregisterPowerSettingNotification(displayNotification);
                displayNotification = IntPtr.Zero;
            }
            if (lidNotification != IntPtr.Zero)
            {
                UnregisterPowerSettingNotification(lidNotification);
                lidNotification = IntPtr.Zero;
            }
            DestroyHandle();
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr RegisterPowerSettingNotification(IntPtr hRecipient, ref Guid powerSettingGuid, int flags);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool UnregisterPowerSettingNotification(IntPtr handle);
    }

    // WinEventProc NEVER enters PowerShell. The rooted delegate only filters
    // native metadata and coalesces first/last timestamps under a lock.
    public sealed class TrayWindowEvents : IDisposable
    {
        private delegate void WinEventProc(IntPtr hook, uint eventType, IntPtr hwnd,
            int objectId, int childId, uint eventThread, uint eventTime);
        private readonly WinEventProc callback;
        private readonly List<IntPtr> hooks = new List<IntPtr>();
        private readonly HashSet<IntPtr> knownTopLevels = new HashSet<IntPtr>();
        private readonly object gate = new object();
        private readonly uint ownProcess = (uint)Process.GetCurrentProcess().Id;
        private long structuralFirst, structuralLast, nameFirst, nameLast;
        private bool disposed;
        private static readonly HashSet<string> IgnoredClasses = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "Progman", "WorkerW",
            "Windows.UI.Core.CoreWindow", "ApplicationFrameWindow",
            "TaskListThumbnailWnd", "DV2ControlHost", "MsgrIMEWindowClass",
            "SysShadow", "Button", "tooltips_class32", "#32768"
        };
        public TrayWindowEvents() { callback = OnEvent; }
        public bool Start()
        {
            // Seed handles so destroy callbacks can still identify windows after
            // Windows has invalidated the HWND and native metadata is gone.
            EnumWindows(delegate(IntPtr hwnd, IntPtr unused) {
                uint pid; GetWindowThreadProcessId(hwnd, out pid);
                if (pid != ownProcess && IsRelevantTopLevel(hwnd)) knownTopLevels.Add(hwnd);
                return true;
            }, IntPtr.Zero);
            foreach (uint kind in new uint[] { 0x8001, 0x8002, 0x8003, 0x800C }) {
                IntPtr hook = SetWinEventHook(kind, kind, IntPtr.Zero, callback, 0, 0, 2);
                if (hook == IntPtr.Zero) { Dispose(); return false; }
                hooks.Add(hook);
            }
            return true;
        }
        public static bool AcceptMetadata(uint kind, int objectId, int childId,
            uint pid, uint ownPid, bool topLevel, bool known)
        {
            // Show/hide/destroy may arrive after the window has lost its title
            // or visibility, so a previously relevant handle stays acceptable
            // until it is destroyed. A title change must pass the live filter.
            bool structural = (kind == 0x8001 || kind == 0x8002 || kind == 0x8003);
            return objectId == 0 && childId == 0 && pid != ownPid &&
                (structural || kind == 0x800C) &&
                (topLevel || (structural && known));
        }
        // Pure decision: takes the window facts, touches no native state, so the
        // rules can be tested without a desktop. Real app windows only:
        // tooltips, menus, toasts, tool windows and owned dialogs must not
        // start a full capture.
        public static bool IsRelevantWindow(int style, int exStyle, bool hasOwner,
            string title, string className)
        {
            if ((style & 0x10000000) == 0) return false;      // WS_VISIBLE
            if ((style & 0x40000000) != 0) return false;      // WS_CHILD
            if ((exStyle & 0x00000080) != 0) return false;    // WS_EX_TOOLWINDOW
            if (hasOwner) return false;                       // GW_OWNER
            if (title == null || title.Trim().Length == 0) return false;
            if (className != null && IgnoredClasses.Contains(className)) return false;
            return true;
        }

        // 0 = ignore, 1 = structural change (a window appeared, disappeared or
        // became relevant), 2 = title-only change on a window already known.
        // Apps usually show a window first and set its title afterwards. That
        // first title is the moment the window becomes relevant, so it counts
        // as structural; treating it as a title-only change would delay the
        // capture of a newly opened app behind the long title debounce.
        public static int ClassifyEvent(uint kind, bool topLevel, bool known)
        {
            bool structural = (kind == 0x8001 || kind == 0x8002 || kind == 0x8003);
            if (structural) return (topLevel || known) ? 1 : 0;
            if (kind == 0x800C) {
                if (!topLevel) return 0;
                return known ? 2 : 1;
            }
            return 0;
        }

        private static bool IsRelevantTopLevel(IntPtr hwnd)
        {
            if (GetAncestor(hwnd, 2) != hwnd) return false;
            int style = GetWindowLong(hwnd, -16);
            int exStyle = GetWindowLong(hwnd, -20);
            bool hasOwner = GetWindow(hwnd, 4) != IntPtr.Zero;
            string titleText = "";
            int titleLength = GetWindowTextLength(hwnd);
            if (titleLength > 0) {
                StringBuilder title = new StringBuilder(titleLength + 1);
                if (GetWindowText(hwnd, title, title.Capacity) > 0) titleText = title.ToString();
            }
            StringBuilder className = new StringBuilder(256);
            GetClassName(hwnd, className, className.Capacity);
            return IsRelevantWindow(style, exStyle, hasOwner, titleText, className.ToString());
        }
        private void OnEvent(IntPtr hook, uint kind, IntPtr hwnd, int objectId,
            int childId, uint eventThread, uint eventTime)
        {
            if (hwnd == IntPtr.Zero || objectId != 0 || childId != 0) return;
            uint pid; GetWindowThreadProcessId(hwnd, out pid);
            lock (gate) {
                if (disposed) return;
                bool known = knownTopLevels.Contains(hwnd);
                bool top = pid != 0 && IsRelevantTopLevel(hwnd);
                if (!AcceptMetadata(kind, objectId, childId, pid, ownProcess, top, known)) return;
                int category = ClassifyEvent(kind, top, known);
                if (category == 0) return;
                if (kind == 0x8001) knownTopLevels.Remove(hwnd);
                else if (top) knownTopLevels.Add(hwnd);
                long now = (long)(Stopwatch.GetTimestamp() * (1000.0 / Stopwatch.Frequency));
                // Rename-only traffic is mostly browser page titles and clocks.
                // Report it separately so the scheduler can wait longer before
                // spending a full capture on it. The first title of a window
                // that was not known yet is structural (see ClassifyEvent).
                if (category == 2) {
                    if (nameFirst == 0) nameFirst = now;
                    nameLast = now;
                } else {
                    if (structuralFirst == 0) structuralFirst = now;
                    structuralLast = now;
                }
            }
        }
        public long[] Drain()
        {
            lock (gate) {
                long[] result = new long[] { structuralFirst, structuralLast, nameFirst, nameLast };
                structuralFirst = structuralLast = nameFirst = nameLast = 0;
                return result;
            }
        }
        public void Dispose()
        {
            lock (gate) { disposed = true; structuralFirst = structuralLast = nameFirst = nameLast = 0; knownTopLevels.Clear(); }
            foreach (IntPtr hook in hooks) UnhookWinEvent(hook);
            hooks.Clear();
            GC.KeepAlive(callback);
        }
        private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr parameter);
        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
        [DllImport("user32.dll")] private static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr module, WinEventProc callback, uint pid, uint thread, uint flags);
        [DllImport("user32.dll")] private static extern bool UnhookWinEvent(IntPtr hook);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
        [DllImport("user32.dll")] private static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
        [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr hwnd, uint command);
        [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr hwnd, int index);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextLength(IntPtr hwnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int maxCount);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hwnd, StringBuilder text, int maxCount);
    }
}
'@
}
}
Initialize-SRTrayNative

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:ink = [System.Drawing.Color]::FromArgb(32, 37, 43)
$script:muted = [System.Drawing.Color]::FromArgb(91, 101, 112)
$script:line = [System.Drawing.Color]::FromArgb(224, 229, 233)
$script:soft = [System.Drawing.Color]::FromArgb(244, 246, 248)
$script:accent = [System.Drawing.Color]::FromArgb(41, 79, 130)
$script:white = [System.Drawing.Color]::White

$script:trayMutex = $null
$script:snapshotMutex = $null
$script:notify = $null
$script:menu = $null
$script:snapshotTimer = $null
$script:firstTimer = $null
$script:healthTimer = $null
$script:resumeTimer = $null
$script:powerWindow = $null
$script:lastPowerCheckpointAt = [DateTime]::MinValue
$script:appContext = $null
$script:installRoot = $PSScriptRoot
$script:exiting = $false
$script:paused = $false
$script:resumeAt = $null
$script:updatingPauseMenu = $false
$script:pauseMarkerAt = [DateTime]::MinValue
$script:snapshotBusy = $false
$script:snapshotRunspace = $null
$script:snapshotJob = $null
$script:eventTimer = $null
$script:windowEvents = $null
$script:eventCaptureEnabled = $true
$script:sessionEnding = $false
$script:shutdownAttempted = $false
$script:ownsSnapshots = $false
$script:taskMode = $false
$script:watcherMode = $false
$script:snapshotFailures = 0
$script:intervalMinutes = 3
$script:hostExe = Join-Path $PSScriptRoot 'SessionRecovery.exe'
if (-not (Test-Path -LiteralPath $script:hostExe)) {
    $candidate = Join-Path (Split-Path $PSScriptRoot -Parent) 'dist\SessionRecovery.exe'
    if (Test-Path -LiteralPath $candidate) { $script:hostExe = $candidate }
}

function Test-SRTrayEventSnapshots {
    try {
        $config = Get-SRConfig
        $property = $config.PSObject.Properties['eventSnapshots']
        if ($null -ne $property) { return [bool]$property.Value }
    } catch { }
    return $true
}

function Test-SRTrayHibernateGuard {
    try { return (Test-SRHibernateGuardEnabled) } catch { }
    return $true
}

function Test-SRTrayRecentHibernateCheckpoint {
    param([int]$WithinSeconds = 30)

    # An explicit --hibernate or tray hibernate already saved a checkpoint.
    # The suspend event that follows must not create a duplicate.
    try {
        $newest = @(Get-SRSnapshotFiles) | Select-Object -First 1
        if ($null -eq $newest) { return $false }
        if ($newest.LastWriteTime -lt (Get-Date).AddSeconds(-$WithinSeconds)) { return $false }
        $snapshot = Read-SRSnapshotFile -Path $newest.FullName
        $reason = $snapshot.PSObject.Properties['reason']
        return ($null -ne $reason -and [string]$reason.Value -eq 'hibernate')
    } catch { return $false }
}

function Invoke-SRTrayPowerCheckpoint {
    param([string]$Source = 'suspend')

    # Display-off and lid-close are the practical Modern Standby signals.
    # They arrive a moment before the machine is throttled, so use the same
    # quick, pinned checkpoint as classic suspend and debounce the burst.
    if ($script:exiting -or $script:paused) { return }
    if (-not (Test-SRTrayEventSnapshots)) { return }
    if (-not (Test-SRTrayHibernateGuard)) { return }
    if ($script:lastPowerCheckpointAt -ne [DateTime]::MinValue -and
        ((Get-Date) - $script:lastPowerCheckpointAt).TotalSeconds -lt 30) { return }
    if (Test-SRTrayRecentHibernateCheckpoint -WithinSeconds 30) {
        $script:lastPowerCheckpointAt = Get-Date
        return
    }

    if ($script:sessionEnding -or $script:snapshotBusy) { return }
    if (Start-SRTrayCapture -Operation Power -Detail $Source) {
        $script:lastPowerCheckpointAt = Get-Date
    }
}

function Set-SRTrayPaused {
    # The tray process and the scheduled task are separate processes. Persist
    # pause so every automatic driver honors it, not only event captures.
    param([bool]$Paused, [Nullable[datetime]]$ResumeAt)
    $script:paused = $Paused
    $script:resumeAt = if ($Paused) { $ResumeAt } else { $null }
    try {
        Set-SRSnapshotPause -Paused:$Paused -ResumeAt $script:resumeAt
    } catch {
        try { Write-SRLog -Level WARN -Message ('Could not persist pause state: {0}' -f $_.Exception.Message) } catch { }
    }
    $script:pauseMarkerAt = [DateTime]::MinValue
    if ($Paused) {
        Stop-SRTrayTimers
        if ($script:resumeTimer) { $script:resumeTimer.Stop() }
    }
    Update-SRTrayStatus
}

function Sync-SRTrayPauseMarker {
    # Another tray/Studio process (or an expired timed pause) may have changed
    # the shared marker. Pick it up without touching an explicit local choice.
    if ($null -eq $script:notify) { return }
    if ($script:pauseMarkerAt -ne [DateTime]::MinValue -and ((Get-Date) - $script:pauseMarkerAt).TotalSeconds -lt 2) { return }
    $script:pauseMarkerAt = Get-Date
    try { $pause = Get-SRSnapshotPause } catch { return }
    if ($pause.Paused -eq $script:paused) { return }
    $script:paused = [bool]$pause.Paused
    $script:resumeAt = $pause.ResumeAt
    if ($script:paused) {
        Stop-SRTrayTimers
        if ($script:resumeTimer) { $script:resumeTimer.Stop() }
    } else {
        if ($script:resumeTimer) { $script:resumeTimer.Stop() }
        if ($script:ownsSnapshots -and -not $script:exiting) { Start-SRTrayFirstSnapshot }
    }
    Update-SRTrayStatus
}

function Get-SRTrayPausedNoticeText {
    # Text for the notice shown when the tray starts while snapshots are
    # paused. A pause now survives restarts and stops every automatic snapshot,
    # so starting silently in that state would hide the loss of protection.
    param([object]$Pause)
    if ($null -eq $Pause -or -not [bool]$Pause.Paused) { return '' }
    $since = if ($null -ne $Pause.PausedAt) {
        ([datetime]$Pause.PausedAt).ToString('g')
    } else {
        (T 'PausedSinceUnknown' 'an unknown time')
    }
    return ((T 'TrayPausedAtStart' 'Snapshots are paused (since {0}). Choose "Resume snapshots" to protect your session again.') -f $since)
}

function Get-SRTrayIntervalMinutes {
    try {
        $config = Get-SRConfig
        $configured = [int]$config.snapshotIntervalMinutes
        if ($configured -ge 1) { return $configured }
    } catch { }
    return 3
}

function Test-SRScheduledSnapshotTask {
    try {
        $task = Get-ScheduledTask -TaskName 'SessionRecovery-Snapshot' -ErrorAction SilentlyContinue
        if ($null -eq $task) { return $false }
        return ([string]$task.State -ne 'Disabled')
    } catch {
        return $false
    }
}

function Get-SRLastSnapshotInfo {
    try {
        $file = Get-ChildItem -LiteralPath (Get-SRSnapshotDirectory) -Filter 'session-*.json*' -File -ErrorAction SilentlyContinue |
            Sort-Object -Property LastWriteTime -Descending |
            Select-Object -First 1
        if ($null -eq $file) { return $null }
        return [pscustomobject]@{
            Path       = $file.FullName
            CapturedAt = $file.LastWriteTime
        }
    } catch {
        return $null
    }
}

function Format-SRTrayAge {
    param([datetime]$CapturedAt)
    $delta = (Get-Date) - $CapturedAt
    if ($delta.TotalMinutes -lt 1) { return 'just now' }
    if ($delta.TotalMinutes -lt 60) { return ('{0:N0} min ago' -f $delta.TotalMinutes) }
    if ($delta.TotalHours -lt 24) { return ('{0:N0} hr ago' -f $delta.TotalHours) }
    return ('{0:N0} day(s) ago' -f $delta.TotalDays)
}

function Get-SRTrayModeText {
    if ($script:paused) {
        if ($null -ne $script:resumeAt) { return ((T 'ModePausedUntil' 'paused until {0}') -f $script:resumeAt.ToString('HH:mm')) }
        return (T 'ModePaused' 'paused')
    }
    if ($script:ownsSnapshots) { return ((T 'ModeEveryMin' 'every {0} min') -f $script:intervalMinutes) }
    if ($script:taskMode) { return (T 'ModeTask' 'scheduled task') }
    if ($script:watcherMode) { return (T 'ModeWatcher' 'watcher active') }
    return (T 'ModeManual' 'manual')
}

function Update-SRTraySettings {
    $newInterval = Get-SRTrayIntervalMinutes
    if ($newInterval -ne $script:intervalMinutes) {
        $script:intervalMinutes = $newInterval
        if ($script:ownsSnapshots -and -not $script:paused) {
            Start-SRTraySnapshotTimer
        }
    }
}

function Update-SRTrayStatus {
    if ($null -eq $script:notify) { return }
    $modeText = Get-SRTrayModeText
    $tooltip = 'Session Recovery - ' + $modeText
    if ($tooltip.Length -gt 63) { $tooltip = $tooltip.Substring(0, 63) }
    $script:notify.Text = $tooltip

    if ($null -ne $script:statusLabel) {
        $script:statusLabel.Text = ((T 'BackgroundStatus' 'Background status: {0}') -f $modeText)
    }

    $last = Get-SRLastSnapshotInfo
    if ($null -ne $script:lastLabel) {
        if ($null -eq $last) {
            $script:lastLabel.Text = (T 'LastSnapshotNone' 'Last snapshot: none yet')
        } else {
            $script:lastLabel.Text = ((T 'LastSnapshotInfo' 'Last snapshot: {0} ({1})') -f $last.CapturedAt.ToString('MMM d, HH:mm'), (Format-SRTrayAge -CapturedAt $last.CapturedAt))
        }
    }

    if ($null -ne $script:pauseItem) {
        $script:pauseItem.Enabled = $true
        # Setting Checked programmatically raises CheckedChanged. Suppress the
        # handler so a timed pause is not cancelled by its own status update.
        $script:updatingPauseMenu = $true
        try {
            $script:pauseItem.Checked = [bool]$script:paused
        } finally {
            $script:updatingPauseMenu = $false
        }
        $script:pauseItem.Text = if ($script:paused) { (T 'TrayResume' 'Resume snapshots') } else { (T 'TrayPause' 'Pause snapshots') }
    }
    if ($null -ne $script:pauseHourItem) {
        $script:pauseHourItem.Enabled = (-not $script:paused)
    }
}

function Show-SRTrayBalloon {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$Title = 'Session Recovery',
        [System.Windows.Forms.ToolTipIcon]$Icon = [System.Windows.Forms.ToolTipIcon]::Info,
        [int]$Timeout = 3000,
        [switch]$Force
    )
    if (-not $Force) {
        try {
            $config = Get-SRConfig
            if (-not [bool]$config.showNotifications) { return }
        } catch { }
    }
    if ($null -eq $script:notify -or -not $script:notify.Visible) { return }
    try {
        $script:notify.BalloonTipTitle = $Title
        $script:notify.BalloonTipText = $Text
        $script:notify.BalloonTipIcon = $Icon
        $script:notify.ShowBalloonTip($Timeout)
    } catch { }
}

function Start-SRTraySnapshotTimer {
    if (-not $script:ownsSnapshots -or $script:paused -or $script:exiting) { return }
    if ($null -eq $script:snapshotTimer) { return }
    $script:snapshotTimer.Stop()
    $script:snapshotTimer.Interval = [Math]::Max(60000, ($script:intervalMinutes * 60000))
    $script:snapshotTimer.Start()
}

function Stop-SRTrayTimers {
    if ($null -ne $script:snapshotTimer) {
        try { $script:snapshotTimer.Stop() } catch { }
    }
    if ($null -ne $script:firstTimer) {
        try { $script:firstTimer.Stop() } catch { }
    }
}

function Initialize-SRTrayWorker {
    param([string]$ModulePath)
    # Import before the message loop: shutdown must only enqueue work, never
    # synchronously open/import a module in its native message callback.
    $script:snapshotRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $script:snapshotRunspace.ApartmentState = [System.Threading.ApartmentState]::STA
    $script:snapshotRunspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $script:snapshotRunspace.Open()
    $setup = [powershell]::Create()
    try {
        $setup.Runspace = $script:snapshotRunspace
        [void]$setup.AddCommand('Import-Module').AddParameter('Name', $ModulePath).AddParameter('Force').AddParameter('ErrorAction', 'Stop')
        [void]$setup.Invoke()
        if ($setup.HadErrors) { throw $setup.Streams.Error[0] }
    } finally { $setup.Dispose() }
}

function Start-SRTrayCapture {
    param([ValidateSet('Automatic','Manual','Shutdown','Power','Workspace','Hibernate')][string]$Operation = 'Automatic', [string]$Detail = '')
    if ($script:exiting -or $script:snapshotBusy -or $null -eq $script:snapshotRunspace) { return $false }
    if ($script:sessionEnding -and $Operation -ne 'Shutdown') { return $false }
    $pipeline = [powershell]::Create()
    try {
        $pipeline.Runspace = $script:snapshotRunspace
        [void]$pipeline.AddScript({
            param($operation, $detail)
            $ErrorActionPreference = 'Stop'
            switch ($operation) {
                'Shutdown' { Save-SRSnapshot -Shutdown }
                'Manual' { Save-SRSnapshot -Force }
                'Power' { Save-SRHibernateSnapshot -Force }
                'Hibernate' { Invoke-SRHibernate }
                'Workspace' {
                    $path = Save-SRSnapshot -Force
                    if (-not $path) { throw 'Snapshot was skipped; workspace was not changed.' }
                    Save-SRWorkspace -Name $detail
                }
                default { Save-SRSnapshot }
            }
        }).AddArgument($Operation).AddArgument($Detail)
        $script:snapshotBusy = $true
        $handle = $pipeline.BeginInvoke()
        $script:snapshotJob = [pscustomobject]@{ Pipeline = $pipeline; Handle = $handle; Operation = $Operation; Detail = $Detail }
        if ($Operation -eq 'Automatic' -and $null -ne $script:eventState) {
            $script:eventState.LastAttempt = Get-SRTrayClock
        }
        return $true
    } catch {
        $script:snapshotBusy = $false
        $pipeline.Dispose()
        # The shutdown callback must remain nonblocking and silent.
        if ($Operation -ne 'Shutdown') { try { Write-SRLog -Level ERROR -Message "Tray worker dispatch failed: $($_.Exception.Message)" } catch { } }
        return $false
    }
}

function Complete-SRTrayCapture {
    $job = $script:snapshotJob
    if ($null -eq $job -or -not $job.Handle.IsCompleted) { return }
    try {
        $result = @($job.Pipeline.EndInvoke($job.Handle) | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($job.Pipeline.HadErrors) { throw $job.Pipeline.Streams.Error[0] }
        $script:snapshotFailures = 0
        if (-not $script:sessionEnding) {
            if ($job.Operation -eq 'Workspace') {
                Show-SRTrayBalloon -Text ((T 'TrayWorkspaceSaved' 'Workspace "{0}" saved.') -f $job.Detail) -Icon Information
            } elseif ($job.Operation -eq 'Manual') {
                if ($result.Count -gt 0) { Show-SRTrayBalloon -Text (T 'TrayBalloonSaved' 'Snapshot saved. Your current windows and tabs are protected.') -Icon Information }
                else { Show-SRTrayBalloon -Text (T 'TrayBalloonSkip' 'The snapshot was skipped because another snapshot is running.') -Icon Warning }
            }
        }
    } catch {
        $script:snapshotFailures++
        try { Write-SRLog -Level ERROR -Message "Tray snapshot failed: $($_.Exception.Message)" } catch { }
        if (-not $script:sessionEnding -and ($job.Operation -in @('Manual','Workspace','Hibernate') -or $script:snapshotFailures -eq 1)) {
            Show-SRTrayBalloon -Text ((T 'TrayBalloonFail' 'Snapshot failed: {0}') -f $_.Exception.Message) -Icon Error -Timeout 5000
        }
    } finally {
        $job.Pipeline.Dispose()
        $script:snapshotJob = $null
        $script:snapshotBusy = $false
        if ($null -ne $script:eventState) {
            Complete-SREventSnapshotRequest -State $script:eventState -NowMilliseconds (Get-SRTrayClock)
        }
        if (-not $script:sessionEnding) { Update-SRTrayStatus }
    }
}

function Invoke-SRTraySnapshot {
    param([switch]$Manual)
    if ($script:snapshotBusy) {
        if ($Manual) { Show-SRTrayBalloon -Text (T 'TrayBalloonBusy' 'A snapshot is already in progress.') -Icon Information }
        return
    }
    if (-not $Manual -and $null -ne $script:eventState -and $null -ne $script:eventState.LastAttempt -and
        ((Get-SRTrayClock) - $script:eventState.LastAttempt) -lt 30000) { return }
    $operation = if ($Manual) { 'Manual' } else { 'Automatic' }
    [void](Start-SRTrayCapture -Operation $operation)
}

function Request-SRTrayShutdown {
    # Called by the native window on its owning UI thread. No disk/config I/O,
    # timers, dialogs, waits, or synchronous save calls are allowed here.
    $script:sessionEnding = $true
    if ($script:shutdownAttempted) { return }
    $script:shutdownAttempted = $true
    Add-SREventSnapshotSignal -State $script:eventState -Signal 'session-ending' -NowMilliseconds (Get-SRTrayClock) -Enabled $script:eventCaptureEnabled -Paused $script:paused
    if ($script:paused -or -not $script:eventCaptureEnabled -or $script:snapshotBusy) {
        # This notification is consumed, not queued behind an in-flight save.
        $script:eventState.SessionEnding = $false
        $script:eventState.SessionEndingAttempted = $true
        return
    }
    $request = Get-SREventSnapshotRequest -State $script:eventState -NowMilliseconds (Get-SRTrayClock)
    if ($null -ne $request -and -not (Start-SRTrayCapture -Operation Shutdown)) {
        Complete-SREventSnapshotRequest -State $script:eventState -NowMilliseconds (Get-SRTrayClock)
    }
}

function Cancel-SRTrayShutdown {
    $script:sessionEnding = $false
    $script:shutdownAttempted = $false
    Reset-SREventSnapshotState -State $script:eventState -CancelSessionEnding
}

function Get-SRTrayClock {
    return [long]([System.Diagnostics.Stopwatch]::GetTimestamp() * (1000.0 / [System.Diagnostics.Stopwatch]::Frequency))
}

function Request-SRTraySuspend {
    if ($script:exiting -or $script:sessionEnding -or $script:paused -or -not $script:eventCaptureEnabled) { return }
    if (Test-SRTrayHibernateGuard) { Invoke-SRTrayPowerCheckpoint -Source 'suspend' }
    else { Invoke-SRTraySnapshot }
}

function Invoke-SRTrayEventPoll {
    Complete-SRTrayCapture
    if ($script:exiting -or $script:sessionEnding) { return }
    $script:eventCaptureEnabled = Test-SRTrayEventSnapshots
    $enabled = $script:eventCaptureEnabled -and -not $script:paused
    if (-not $enabled) { Reset-SREventSnapshotState -State $script:eventState }
    if ($null -ne $script:windowEvents) {
        $dirty = $script:windowEvents.Drain()
        if ($enabled -and $dirty.Count -ge 4 -and $dirty[2] -ne 0) {
            # Keep title-only traffic in the event state. It is a weaker signal
            # with its own longer debounce and cooldown.
            Add-SREventSnapshotSignal -State $script:eventState -Signal 'window-name' -NowMilliseconds $dirty[2]
            if ($dirty[3] -ne $dirty[2]) {
                Add-SREventSnapshotSignal -State $script:eventState -Signal 'window-name' -NowMilliseconds $dirty[3]
            }
        }
        if ($enabled -and $dirty[0] -ne 0) {
            Add-SREventSnapshotSignal -State $script:eventState -Signal 'window' -NowMilliseconds $dirty[0]
            Add-SREventSnapshotSignal -State $script:eventState -Signal 'window' -NowMilliseconds $dirty[1]
        }
    }
    if ($null -ne $script:powerWindow) {
        $signals = $script:powerWindow.DrainSystemSignals()
        if ($enabled) {
            if ($signals[0]) {
                Add-SREventSnapshotSignal -State $script:eventState -Signal 'resume' -NowMilliseconds (Get-SRTrayClock)
            }
            if ($signals[1]) { Request-SRTraySuspend }
            if ($signals[2]) {
                Add-SREventSnapshotSignal -State $script:eventState -Signal 'lock' -NowMilliseconds (Get-SRTrayClock)
            }
        }
    }
    $request = Get-SREventSnapshotRequest -State $script:eventState -NowMilliseconds (Get-SRTrayClock) -Busy $script:snapshotBusy -Enabled $script:eventCaptureEnabled -Paused $script:paused
    if ($null -ne $request -and -not (Start-SRTrayCapture -Operation Automatic)) {
        Complete-SREventSnapshotRequest -State $script:eventState -NowMilliseconds (Get-SRTrayClock)
    }
}

function Invoke-SRTrayHibernate {
    $answer = [System.Windows.Forms.MessageBox]::Show(
        (T 'HibernateConfirmText' 'Session Recovery will save and pin a recovery snapshot, then hibernate this PC. Unsaved work can still be lost if an app cannot reopen it. Continue?'),
        (T 'HibernateConfirmTitle' 'Hibernate with checkpoint'),
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    try {
        Show-SRTrayBalloon -Text (T 'TrayHibernateSaving' 'Saving a recovery checkpoint, then hibernating...') -Icon Information
        if (-not (Start-SRTrayCapture -Operation Hibernate)) {
            Show-SRTrayBalloon -Text (T 'TrayBalloonBusy' 'A snapshot is already in progress.') -Icon Information
        }
    } catch {
        try { Write-SRLog -Level ERROR -Message ("Hibernate from tray failed: {0}" -f $_.Exception.Message) } catch { }
        Show-SRTrayBalloon -Text ((T 'HibernateFailed' 'Could not hibernate: {0}') -f $_.Exception.Message) -Icon Error -Timeout 8000
    }
}

function Start-SRTrayFirstSnapshot {
    if (-not $script:ownsSnapshots -or $script:paused -or $script:exiting) { return }
    if ($null -eq $script:firstTimer) { return }
    $script:firstTimer.Stop()
    $script:firstTimer.Interval = [Math]::Max(1000, ($FirstSnapshotDelaySeconds * 1000))
    $script:firstTimer.Start()
}

function Resume-SRTraySnapshots {
    if ($script:resumeTimer) { $script:resumeTimer.Stop() }
    Set-SRTrayPaused -Paused $false
    if ($script:ownsSnapshots -and -not $script:exiting) {
        Start-SRTrayFirstSnapshot
        Show-SRTrayBalloon -Text (T 'TrayResumed' 'Snapshots resumed.')
    }
}

function Open-SRDataFolder {
    try {
        $root = Get-SRRoot
        if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $root) | Out-Null
    } catch {
        Show-SRTrayBalloon -Text ('Could not open the data folder: ' + $_.Exception.Message) -Icon Error
    }
}

function Open-SRSnapshotsFolder {
    try {
        $folder = Get-SRSnapshotDirectory
        if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $folder) | Out-Null
    } catch {
        Show-SRTrayBalloon -Text ('Could not open the snapshots folder: ' + $_.Exception.Message) -Icon Error
    }
}

function Start-SRStudio {
    param([string]$Mode = '--studio')
    try {
        if (-not (Test-Path -LiteralPath $script:hostExe)) { throw 'SessionRecovery.exe is missing.' }
        Start-Process -FilePath $script:hostExe -ArgumentList $Mode -WorkingDirectory $PSScriptRoot -WindowStyle Normal | Out-Null
    } catch {
        Show-SRTrayBalloon -Text ('Could not open Session Recovery: ' + $_.Exception.Message) -Icon Error
    }
}

function Open-SRSettingsFile {
    Start-SRStudio -Mode '--settings'
}

function Start-SRRestoreWindow {
    Start-SRStudio -Mode '--restore-manual'
}

function Start-SRDiagnosticsWindow {
    Start-SRStudio -Mode '--diagnostics'
}

function Stop-SRTrayWorker {
    if ($null -ne $script:snapshotJob) {
        if ($script:snapshotJob.Handle.IsCompleted) { Complete-SRTrayCapture }
        else {
            # Stop/Dispose can wait indefinitely on blocked native/COM calls.
            # Request cancellation and leave active objects rooted until process
            # exit; do not synchronously close their runspace on either exit path.
            try { [void]$script:snapshotJob.Pipeline.BeginStop($null, $null) } catch { }
            return
        }
    }
    if ($null -ne $script:snapshotRunspace -and -not $script:snapshotBusy) {
        try { $script:snapshotRunspace.Dispose() } catch { }
        $script:snapshotRunspace = $null
    }
}

function Exit-SRTray {
    if ($script:exiting) { return }
    $script:exiting = $true
    Stop-SRTrayTimers
    foreach ($timerName in @('snapshotTimer','firstTimer','eventTimer','batteryTimer')) {
        $timer = Get-Variable -Scope Script -Name $timerName -ValueOnly -ErrorAction SilentlyContinue
        if ($null -ne $timer) { try { $timer.Stop(); $timer.Dispose() } catch { } }
        Set-Variable -Scope Script -Name $timerName -Value $null
    }
    if ($null -ne $script:windowEvents) {
        try { $script:windowEvents.Dispose() } catch { }
        $script:windowEvents = $null
    }
    Stop-SRTrayWorker
    if ($null -ne $script:controlTimer) {
        try { $script:controlTimer.Stop(); $script:controlTimer.Dispose() } catch { }
        $script:controlTimer = $null
    }
    try {
        if ('SessionRecovery.Tray.ControlPipe' -as [type]) {
            [SessionRecovery.Tray.ControlPipe]::Stop((-not $script:sessionEnding))
        }
    } catch { }
    if ($null -ne $script:hotkeyTimer) {
        try { $script:hotkeyTimer.Stop(); $script:hotkeyTimer.Dispose() } catch { }
        $script:hotkeyTimer = $null
    }
    if ($null -ne $script:healthTimer) {
        try { $script:healthTimer.Stop(); $script:healthTimer.Dispose() } catch { }
        $script:healthTimer = $null
    }
    if ($null -ne $script:resumeTimer) {
        try { $script:resumeTimer.Stop(); $script:resumeTimer.Dispose() } catch { }
        $script:resumeTimer = $null
    }
    if ($null -ne $script:powerWindow) {
        try { $script:powerWindow.Dispose() } catch { }
        $script:powerWindow = $null
    }
    try {
        if ($null -ne $script:notify) {
            $script:notify.Visible = $false
            $script:notify.Dispose()
            $script:notify = $null
        }
    } catch { }
    try {
        if ($null -ne $script:menu) { $script:menu.Dispose(); $script:menu = $null }
    } catch { }
    try {
        if ($null -ne $script:appContext) { $script:appContext.ExitThread() }
        else { [System.Windows.Forms.Application]::Exit() }
    } catch { }
}

# ---------------------------------------------------------------------------
# Single-instance and snapshot ownership
# ---------------------------------------------------------------------------

try {
    $script:trayMutex = New-Object System.Threading.Mutex($false, 'Local\SessionRecoveryTray')
    $haveTrayMutex = $false
    try {
        $haveTrayMutex = $script:trayMutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        $haveTrayMutex = $true
    }
    if (-not $haveTrayMutex) { exit 0 }
} catch {
    $script:trayMutex = $null
}

$script:intervalMinutes = Get-SRTrayIntervalMinutes
$script:taskMode = Test-SRScheduledSnapshotTask
try { Write-SRLog -Message ('Tray mode check: interval {0}, task mode {1}, monitor-only {2}.' -f $script:intervalMinutes, $script:taskMode, $MonitorOnly) } catch { }

if (-not $MonitorOnly -and -not $script:taskMode) {
    try {
        $script:snapshotMutex = New-Object System.Threading.Mutex($false, 'Local\SessionRecoveryWatcher')
        $acquired = $false
        try {
            $acquired = $script:snapshotMutex.WaitOne(0)
        } catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if ($acquired) {
            $script:ownsSnapshots = $true
        } else {
            $script:watcherMode = $true
            try { $script:snapshotMutex.Dispose() } catch { }
            $script:snapshotMutex = $null
        }
    } catch {
        # If the mutex cannot be created, fall back to monitor-only rather
        # than risk two snapshot loops.
        $script:snapshotMutex = $null
        $script:watcherMode = $true
    }
}

# ---------------------------------------------------------------------------
# Tray icon and menu
# ---------------------------------------------------------------------------

$iconPath = Join-Path $PSScriptRoot 'SessionRecovery.ico'
if (-not (Test-Path -LiteralPath $iconPath)) {
    $fallback = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\SessionRecovery.ico'
    if (Test-Path -LiteralPath $fallback) { $iconPath = $fallback } else { $iconPath = $null }
}

$trayIcon = $null
if ($iconPath) {
    try { $trayIcon = New-Object System.Drawing.Icon($iconPath) } catch { $trayIcon = $null }
}

$script:notify = New-Object System.Windows.Forms.NotifyIcon
$script:notify.Text = 'Session Recovery'
$script:notify.Visible = $true
if ($null -ne $trayIcon) { $script:notify.Icon = $trayIcon }

$script:menu = New-Object System.Windows.Forms.ContextMenuStrip
$script:menu.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$script:menu.BackColor = $script:white
$script:menu.ForeColor = $script:ink
$script:menu.ShowImageMargin = $false
$script:menu.ShowCheckMargin = $true
$script:menu.Padding = New-Object System.Windows.Forms.Padding(4, 6, 4, 6)
$script:menu.RenderMode = [System.Windows.Forms.ToolStripRenderMode]::Professional
$script:notify.ContextMenuStrip = $script:menu

$headerLabel = New-Object System.Windows.Forms.ToolStripLabel('SESSION RECOVERY')
$headerLabel.AutoSize = $false
$headerLabel.Width = 268
$headerLabel.Height = 24
$headerLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$headerLabel.ForeColor = $script:accent
$headerLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$headerLabel.Padding = New-Object System.Windows.Forms.Padding(2, 2, 2, 0)
[void]$script:menu.Items.Add($headerLabel)

$script:statusLabel = New-Object System.Windows.Forms.ToolStripLabel
$script:statusLabel.AutoSize = $false
$script:statusLabel.Width = 268
$script:statusLabel.Height = 19
$script:statusLabel.Font = New-Object System.Drawing.Font('Segoe UI', 8.25)
$script:statusLabel.ForeColor = $script:muted
$script:statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$script:statusLabel.Padding = New-Object System.Windows.Forms.Padding(2, 0, 2, 0)
[void]$script:menu.Items.Add($script:statusLabel)

$script:lastLabel = New-Object System.Windows.Forms.ToolStripLabel
$script:lastLabel.AutoSize = $false
$script:lastLabel.Width = 268
$script:lastLabel.Height = 19
$script:lastLabel.Font = New-Object System.Drawing.Font('Consolas', 7.75)
$script:lastLabel.ForeColor = $script:muted
$script:lastLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$script:lastLabel.Padding = New-Object System.Windows.Forms.Padding(2, 0, 2, 2)
[void]$script:menu.Items.Add($script:lastLabel)

[void]$script:menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$studioItem = New-Object System.Windows.Forms.ToolStripMenuItem((T 'TrayOpen' 'Open Session Recovery'))
$studioItem.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
[void]$studioItem.Add_Click({ Start-SRStudio })
[void]$script:menu.Items.Add($studioItem)

$restoreItem = New-Object System.Windows.Forms.ToolStripMenuItem((T 'TrayRestore' 'Restore last session...'))
$restoreItem.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
[void]$restoreItem.Add_Click({ Start-SRRestoreWindow })
[void]$script:menu.Items.Add($restoreItem)

$snapshotItem = New-Object System.Windows.Forms.ToolStripMenuItem((T 'TraySnapshotNow' 'Take snapshot now'))
[void]$snapshotItem.Add_Click({ Invoke-SRTraySnapshot -Manual })
[void]$script:menu.Items.Add($snapshotItem)

# Undo the last restore: reopen the desktop captured right before it.
$undoItem = New-Object System.Windows.Forms.ToolStripMenuItem((T 'TrayUndoLastRestore' 'Undo last restore'))
$script:undoMenuItem = $undoItem
[void]$undoItem.Add_Click({
    $checkpoint = $null
    try { $checkpoint = Get-SRRestoreCheckpoint } catch { }
    if ($null -eq $checkpoint) {
        Show-SRTrayBalloon -Text (T 'UndoNoCheckpoint' 'No safety snapshot is available yet.') -Icon Warning
        return
    }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        (T 'UndoConfirmText' 'Reopen the desktop that was captured right before your last restore?'),
        (T 'UndoConfirmTitle' 'Undo last restore'), [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    try {
        [void](Start-SRUndoLastRestore)
        Show-SRTrayBalloon -Text (T 'UndoStarted' 'Restoring the desktop from before your last restore...') -Icon Information
    } catch {
        Show-SRTrayBalloon -Text ((T 'UndoFailed' 'Could not undo the last restore: {0}') -f $_.Exception.Message) -Icon Error
    }
})
[void]$script:menu.Items.Add($undoItem)

# Named workspaces: manually saved sessions that restore in one click.
$workspaceMenu = New-Object System.Windows.Forms.ToolStripMenuItem((T 'TrayWorkspaces' 'Workspaces'))
[void]$workspaceMenu.Add_DropDownOpening({
    $workspaceMenu.DropDownItems.Clear()
    $saveItem = New-Object System.Windows.Forms.ToolStripMenuItem((T 'TraySaveWorkspace' 'Save current session as...'))
    [void]$saveItem.Add_Click({
        $name = ''
        try {
            Add-Type -AssemblyName Microsoft.VisualBasic
            $name = [Microsoft.VisualBasic.Interaction]::InputBox((T 'TrayWorkspacePrompt' 'Name this workspace'), 'Session Recovery', '')
        } catch { return }
        if ([string]::IsNullOrWhiteSpace($name)) { return }
        try {
            if (-not (Start-SRTrayCapture -Operation Workspace -Detail $name)) {
                Show-SRTrayBalloon -Text (T 'TrayBalloonBusy' 'A snapshot is already in progress.') -Icon Information
            }
        } catch {
            Show-SRTrayBalloon -Text ((T 'TrayWorkspaceFail' 'Could not save the workspace: {0}') -f $_.Exception.Message) -Icon Error
        }
    })
    [void]$workspaceMenu.DropDownItems.Add($saveItem)
    $saved = @(Get-SRWorkspaces)
    if ($saved.Count -gt 0) {
        [void]$workspaceMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        foreach ($workspace in $saved) {
            $item = New-Object System.Windows.Forms.ToolStripMenuItem($workspace.Name)
            $item.Tag = $workspace.Path
            [void]$item.Add_Click({
                param($sender, $eventArgs)
                Start-SRStudio -Mode ('--restore-manual -SnapshotPath "' + ([string]$sender.Tag).Replace('"', '""') + '"')
            })
            [void]$workspaceMenu.DropDownItems.Add($item)
        }
    }
})
[void]$script:menu.Items.Add($workspaceMenu)

$script:pauseItem = New-Object System.Windows.Forms.ToolStripMenuItem((T 'TrayPause' 'Pause snapshots'))
$script:pauseItem.CheckOnClick = $true
[void]$script:pauseItem.Add_CheckedChanged({
    if ($script:updatingPauseMenu) { return }
    if ($script:pauseItem.Checked) {
        Set-SRTrayPaused -Paused $true
    } else {
        # Unchecking Pause also cancels a timed pause and its resume timer.
        Resume-SRTraySnapshots
    }
})
[void]$script:menu.Items.Add($script:pauseItem)

$script:pauseHourItem = New-Object System.Windows.Forms.ToolStripMenuItem((T 'TrayPauseHour' 'Pause for 1 hour'))
[void]$script:pauseHourItem.Add_Click({
    Set-SRTrayPaused -Paused $true -ResumeAt ((Get-Date).AddHours(1))
    if ($null -eq $script:resumeTimer) {
        $script:resumeTimer = New-Object System.Windows.Forms.Timer
        [void]$script:resumeTimer.Add_Tick({
            $script:resumeTimer.Stop()
            Resume-SRTraySnapshots
        })
    }
    $remaining = [int]($script:resumeAt - (Get-Date)).TotalMilliseconds
    $script:resumeTimer.Interval = [Math]::Max(1000, $remaining)
    $script:resumeTimer.Stop()
    $script:resumeTimer.Start()
    Show-SRTrayBalloon -Text ((T 'TrayPausedUntil' 'Snapshots paused until {0}. They resume automatically.') -f $script:resumeAt.ToString('HH:mm'))
})
[void]$script:menu.Items.Add($script:pauseHourItem)

$hibernateItem = New-Object System.Windows.Forms.ToolStripMenuItem((T 'TrayHibernate' 'Hibernate with checkpoint'))
[void]$hibernateItem.Add_Click({ Invoke-SRTrayHibernate })
[void]$script:menu.Items.Add($hibernateItem)

[void]$script:menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$folderItem = New-Object System.Windows.Forms.ToolStripMenuItem((T 'TrayOpenFolder' 'Open snapshots folder'))
[void]$folderItem.Add_Click({ Open-SRSnapshotsFolder })
[void]$script:menu.Items.Add($folderItem)

$settingsItem = New-Object System.Windows.Forms.ToolStripMenuItem((T 'TraySettings' 'Settings'))
[void]$settingsItem.Add_Click({ Open-SRSettingsFile })
[void]$script:menu.Items.Add($settingsItem)

$diagnosticsItem = New-Object System.Windows.Forms.ToolStripMenuItem((T 'TrayDiagnostics' 'Run diagnostics'))
[void]$diagnosticsItem.Add_Click({ Start-SRDiagnosticsWindow })
[void]$script:menu.Items.Add($diagnosticsItem)

[void]$script:menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem((T 'TrayExit' 'Exit Session Recovery'))
[void]$exitItem.Add_Click({ Exit-SRTray })
[void]$script:menu.Items.Add($exitItem)

[void]$script:menu.Add_Opening({
    Update-SRTraySettings
    Update-SRTrayStatus
    try {
        $checkpoint = Get-SRRestoreCheckpoint
        $script:undoMenuItem.Enabled = ($null -ne $checkpoint)
        if ($null -ne $checkpoint) {
            $when = ''
            try { $when = '  (' + ([datetime]::Parse([string]$checkpoint.At)).ToString('t') + ')' } catch { }
            $script:undoMenuItem.Text = (T 'TrayUndoLastRestore' 'Undo last restore') + $when
        } else {
            $script:undoMenuItem.Text = (T 'TrayUndoLastRestore' 'Undo last restore')
        }
    } catch { }
})
$script:notify.Add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Start-SRStudio }
})

# ---------------------------------------------------------------------------
# Timers and power events
# ---------------------------------------------------------------------------

$script:snapshotTimer = New-Object System.Windows.Forms.Timer
$script:snapshotTimer.Interval = [Math]::Max(60000, ($script:intervalMinutes * 60000))
[void]$script:snapshotTimer.Add_Tick({
    Update-SRTraySettings
    if ($script:paused -or -not $script:ownsSnapshots) { return }
    Invoke-SRTraySnapshot
    Start-SRTraySnapshotTimer
})

$script:firstTimer = New-Object System.Windows.Forms.Timer
$script:firstTimer.Interval = [Math]::Max(1000, ($FirstSnapshotDelaySeconds * 1000))
[void]$script:firstTimer.Add_Tick({
    $script:firstTimer.Stop()
    if ($script:paused -or -not $script:ownsSnapshots) { return }
    Invoke-SRTraySnapshot
    Start-SRTraySnapshotTimer
})

# Exit quietly if the installed files disappear (for example, the MSI was
# uninstalled while the tray app was still running).
$script:healthTimer = New-Object System.Windows.Forms.Timer
$script:healthTimer.Interval = 10000
[void]$script:healthTimer.Add_Tick({
    if ($script:exiting) { return }
    $trayScript = Join-Path $script:installRoot 'Tray-SessionRecovery.ps1'
    $module = Join-Path $script:installRoot 'SessionRecovery.psm1'
    if (-not (Test-Path -LiteralPath $trayScript) -or -not (Test-Path -LiteralPath $module) -or -not (Test-Path -LiteralPath $script:hostExe)) {
        Exit-SRTray
    }
})
$script:healthTimer.Start()

# Global capture hotkey Ctrl+Alt+S. RegisterHotKey needs its own message
# window, so this polls the async key state instead: simple and reliable in
# a PowerShell host. The latch makes the combination fire once per press.
try {
    if (-not ('SessionRecovery.Tray.HotkeyPoll' -as [type])) {
        Add-Type -Namespace SessionRecovery.Tray -Name HotkeyPoll -MemberDefinition '[DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);'
    }
    $script:hotkeyAvailable = $true
} catch { $script:hotkeyAvailable = $false }
$script:hotkeyLatch = $false
$script:hotkeyTimer = New-Object System.Windows.Forms.Timer
$script:hotkeyTimer.Interval = 250
[void]$script:hotkeyTimer.Add_Tick({
    if (-not $script:hotkeyAvailable -or $script:exiting) { return }
    $pressed = $false
    try {
        $ctrl = ([SessionRecovery.Tray.HotkeyPoll]::GetAsyncKeyState(0x11) -band 0x8000) -ne 0
        $alt = ([SessionRecovery.Tray.HotkeyPoll]::GetAsyncKeyState(0x12) -band 0x8000) -ne 0
        $s = ([SessionRecovery.Tray.HotkeyPoll]::GetAsyncKeyState(0x53) -band 0x8000) -ne 0
        $pressed = ($ctrl -and $alt -and $s)
    } catch { }
    if ($pressed -and -not $script:hotkeyLatch) {
        $script:hotkeyLatch = $true
        $enabled = $true
        try {
            $hotkeyConfig = Get-SRConfig
            $hotkeyProperty = $hotkeyConfig.PSObject.Properties['captureHotkey']
            if ($null -ne $hotkeyProperty) { $enabled = [bool]$hotkeyProperty.Value }
        } catch { }
        if ($enabled -and -not $script:paused) {
            Invoke-SRTraySnapshot -Manual
        }
    } elseif (-not $pressed) {
        $script:hotkeyLatch = $false
    }
})
$script:hotkeyTimer.Start()

# ---------------------------------------------------------------------------
# Local control API: a named pipe other tools can talk to
# ---------------------------------------------------------------------------

try {
    if (-not ('SessionRecovery.Tray.ControlPipe' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Threading;

namespace SessionRecovery.Tray
{
    public static class ControlPipe
    {
        // Raw .NET threads cannot run PowerShell, so the pipe thread only
        // queues command lines; the UI timer picks them up on the STA thread.
        private static readonly ConcurrentQueue<string> Queue = new ConcurrentQueue<string>();
        private static Thread worker;
        private static volatile bool stopping;
        private static readonly object PipeGate = new object();
        private static NamedPipeServerStream activePipe;

        public static bool TryDequeue(out string command)
        {
            return Queue.TryDequeue(out command);
        }

        public static void Start()
        {
            if (worker != null) return;
            stopping = false;
            worker = new Thread(new ThreadStart(Run));
            worker.IsBackground = true;
            worker.Start();
        }

        public static void Stop(bool wait)
        {
            stopping = true;
            lock (PipeGate) {
                try { if (activePipe != null) activePipe.Dispose(); } catch { }
                activePipe = null;
            }
            Thread local = worker;
            worker = null;
            try { if (wait && local != null) local.Join(700); } catch { }
        }

        private static void Run()
        {
            while (!stopping)
            {
                NamedPipeServerStream pipe = null;
                try
                {
                    pipe = new NamedPipeServerStream(
                        "SessionRecoveryControl", PipeDirection.InOut, 1,
                        PipeTransmissionMode.Byte, PipeOptions.None);
                    lock (PipeGate) {
                        if (stopping) return;
                        activePipe = pipe;
                    }
                    pipe.WaitForConnection();
                    if (stopping) return;
                    string line = null;
                    try
                    {
                        using (StreamReader reader = new StreamReader(pipe, Encoding.UTF8, false, 4096, true))
                        {
                            line = reader.ReadLine();
                        }
                        if (!string.IsNullOrWhiteSpace(line))
                        {
                            Queue.Enqueue(line);
                            byte[] ack = Encoding.UTF8.GetBytes("{\"accepted\":true}\n");
                            pipe.Write(ack, 0, ack.Length);
                            pipe.Flush();
                        }
                    }
                    catch { }
                }
                catch
                {
                    // A failed connection must not kill the server thread.
                }
                finally
                {
                    lock (PipeGate) { if (activePipe == pipe) activePipe = null; }
                    try { if (pipe != null) pipe.Dispose(); } catch { }
                }
            }
        }
    }
}
'@ -ErrorAction Stop
    }
    [SessionRecovery.Tray.ControlPipe]::Start()
    $script:controlPipeRunning = $true
} catch {
    $script:controlPipeRunning = $false
    try { Write-SRLog -Level WARN -Message ('Control pipe could not start: {0}' -f $_.Exception.Message) } catch { }
}

function Invoke-SRTrayControl {
    # Handles one JSON command line from the control pipe on the UI thread.
    param([string]$JsonLine)
    try {
        $request = ([string]$JsonLine).Trim() | ConvertFrom-Json
        $command = [string]$request.command
        $name = [string]$request.name
        switch ($command) {
            'snapshot' { Invoke-SRTraySnapshot -Manual }
            'pause' {
                if (-not $script:paused) {
                    Set-SRTrayPaused -Paused $true
                }
            }
            'resume' { Resume-SRTraySnapshots }
            'restore-latest' { Start-SRStudio -Mode '--restore-prompt' }
            'workspace-save' {
                if ([string]::IsNullOrWhiteSpace($name)) { break }
                try {
                    if (-not (Start-SRTrayCapture -Operation Workspace -Detail $name)) {
                        Show-SRTrayBalloon -Text (T 'TrayBalloonBusy' 'A snapshot is already in progress.') -Icon Information
                    }
                } catch {
                    Show-SRTrayBalloon -Text ((T 'TrayWorkspaceFail' 'Could not save the workspace: {0}') -f $_.Exception.Message) -Icon Error
                }
            }
            'workspace-restore' {
                if ([string]::IsNullOrWhiteSpace($name)) { break }
                $workspace = @(Get-SRWorkspaces) | Where-Object { $_.Name -eq $name } | Select-Object -First 1
                if ($workspace) {
                    Start-SRStudio -Mode ('--restore-manual -SnapshotPath "' + ([string]$workspace.Path).Replace('"', '""') + '"')
                }
            }
            'workspace-delete' {
                if ([string]::IsNullOrWhiteSpace($name)) { break }
                try {
                    [void](Remove-SRWorkspace -Name $name)
                    Show-SRTrayBalloon -Text ((T 'WsDeletedToast' 'Workspace "{0}" deleted.') -f $name) -Icon Information
                } catch {
                    Show-SRTrayBalloon -Text ((T 'WsDeleteFailed' 'Could not delete workspace: {0}') -f $_.Exception.Message) -Icon Error
                }
            }
            'undo-restore' {
                try {
                    [void](Start-SRUndoLastRestore)
                    Show-SRTrayBalloon -Text (T 'UndoStarted' 'Restoring the desktop from before your last restore...') -Icon Information
                } catch {
                    Show-SRTrayBalloon -Text ((T 'UndoFailed' 'Could not undo the last restore: {0}') -f $_.Exception.Message) -Icon Error
                }
            }
        }
        try { Write-SRLog -Message ('Control command handled: {0}' -f $command) } catch { }
    } catch {
        try { Write-SRLog -Level WARN -Message ('Control command failed: {0}' -f $_.Exception.Message) } catch { }
    }
}

$script:controlTimer = New-Object System.Windows.Forms.Timer
$script:controlTimer.Interval = 500
[void]$script:controlTimer.Add_Tick({
    if (-not $script:controlPipeRunning) { return }
    for ($drained = 0; $drained -lt 5; $drained++) {
        $line = $null
        $has = $false
        try { $has = [SessionRecovery.Tray.ControlPipe]::TryDequeue([ref]$line) } catch { $has = $false }
        if (-not $has) { break }
        Invoke-SRTrayControl -JsonLine ([string]$line)
    }
})
$script:controlTimer.Start()

# Low battery: capture once when the charge first drops to the low band.
$script:batteryTimer = New-Object System.Windows.Forms.Timer
$script:batteryTimer.Interval = 60000
$script:batteryLowSeen = $false
[void]$script:batteryTimer.Add_Tick({
    if ($script:exiting) { return }
    try {
        $power = [System.Windows.Forms.SystemInformation]::PowerStatus
        if ($power.PowerLineStatus -eq [System.Windows.Forms.PowerLineStatus]::Online) {
            $script:batteryLowSeen = $false
            return
        }
        $low = ($power.BatteryChargeStatus -band [System.Windows.Forms.BatteryChargeStatus]::Low) -ne 0
        $critical = ($power.BatteryChargeStatus -band [System.Windows.Forms.BatteryChargeStatus]::Critical) -ne 0
        if (($low -or $critical) -and -not $script:batteryLowSeen) {
            $script:batteryLowSeen = $true
            if ((Test-SRTrayEventSnapshots) -and -not $script:paused) {
                Invoke-SRTraySnapshot
            }
        }
        if (-not $low -and -not $critical -and [double]$power.BatteryLifePercent -gt 0.35) {
            $script:batteryLowSeen = $false
        }
    } catch { }
})
$script:batteryTimer.Start()

# Classic SystemEvents are marshalled as C# flags by TrayPowerMonitor;
# the event timer drains them on this STA, never on a foreign .NET thread.
Initialize-SRTrayWorker -ModulePath $modulePath
$script:eventState = New-SREventSnapshotState
$script:eventCaptureEnabled = Test-SRTrayEventSnapshots
try {
    $previousShutdown = Get-SRLastShutdownCapture
    if ($null -ne $previousShutdown) { Clear-SRShutdownAttempt }
} catch { }

# Modern Standby (and some lid-close paths) does not reliably send the
# classic suspend message. Display-off and lid-close arrive early enough to
# save the same checkpoint, and the 30 second debounce prevents duplicates
# when both fire for one transition.
try {
    $script:powerWindow = New-Object SessionRecovery.TrayPowerMonitor
    $script:powerWindow.add_DisplayOff({ Invoke-SRTrayPowerCheckpoint -Source 'display-off' })
    $script:powerWindow.add_LidClosed({ Invoke-SRTrayPowerCheckpoint -Source 'lid-closed' })
    $script:powerWindow.add_SuspendRequested({ Request-SRTraySuspend })
    $script:powerWindow.add_ShutdownRequested({ Request-SRTrayShutdown })
    $script:powerWindow.add_ShutdownCancelled({ Cancel-SRTrayShutdown })
    try {
        Write-SRLog -Message ('Power monitor registered (display: {0}, lid: {1}).' -f $script:powerWindow.DisplayRegistered, $script:powerWindow.LidRegistered)
    } catch { }
} catch {
    $script:powerWindow = $null
    try { Write-SRLog -Level WARN -Message ("Power monitor unavailable; classic suspend only: {0}" -f $_.Exception.Message) } catch { }
}

try {
    $script:windowEvents = New-Object SessionRecovery.TrayWindowEvents
    if (-not $script:windowEvents.Start()) { throw 'SetWinEventHook registration failed.' }
} catch {
    if ($null -ne $script:windowEvents) { $script:windowEvents.Dispose() }
    $script:windowEvents = $null
    try { Write-SRLog -Level WARN -Message ("Window notifications unavailable; periodic capture remains active: {0}" -f $_.Exception.Message) } catch { }
}

$script:eventTimer = New-Object System.Windows.Forms.Timer
$script:eventTimer.Interval = 250
[void]$script:eventTimer.Add_Tick({ Sync-SRTrayPauseMarker; Invoke-SRTrayEventPoll })
$script:eventTimer.Start()

# A timed pause persisted by another process expires on its own; the marker
# check above promotes that back to a normal running state.
try { Sync-SRTrayPauseMarker } catch { }
try {
    $noticeText = Get-SRTrayPausedNoticeText -Pause (Get-SRSnapshotPause)
    if (-not [string]::IsNullOrWhiteSpace($noticeText)) {
        Show-SRTrayBalloon -Text $noticeText -Icon Warning -Timeout 8000
    }
} catch { }

try {
    Write-SRLog -Message ('Tray app started (owns snapshots: {0}, scheduled task: {1}, monitor-only: {2}).' -f $script:ownsSnapshots, $script:taskMode, $MonitorOnly)
} catch { }

Update-SRTrayStatus
if ($script:ownsSnapshots) {
    Start-SRTrayFirstSnapshot
    Show-SRTrayBalloon -Text (T 'TrayStarted' 'Session Recovery is running in the background. Double-click the tray icon to restore a session.')
} else {
    Show-SRTrayBalloon -Text ((T 'TrayStarted' 'Session Recovery is running in the background. Double-click the tray icon to restore a session.') + ' [' + (Get-SRTrayModeText) + ']')
}

$script:appContext = New-Object System.Windows.Forms.ApplicationContext
try {
    [System.Windows.Forms.Application]::Run($script:appContext)
} finally {
    Exit-SRTray
    try {
        if ($null -ne $script:snapshotMutex) {
            try { [void]$script:snapshotMutex.ReleaseMutex() } catch { }
            $script:snapshotMutex.Dispose()
        }
    } catch { }
    try {
        if ($null -ne $script:trayMutex) {
            try { [void]$script:trayMutex.ReleaseMutex() } catch { }
            $script:trayMutex.Dispose()
        }
    } catch { }
    try {
        if ($null -ne $script:notify) { $script:notify.Dispose() }
    } catch { }
    try { if ($null -ne $trayIcon) { $trayIcon.Dispose() } } catch { }
    try { Write-SRLog -Message 'Tray app stopped.' } catch { }
}
