using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;
using WinFormsTimer = System.Windows.Forms.Timer;

[assembly: AssemblyTitle("Session Recovery")]
[assembly: AssemblyDescription("Session Recovery desktop host")]
[assembly: AssemblyProduct("Session Recovery")]
[assembly: AssemblyCompany("Bilalmesk")]
[assembly: AssemblyVersion("3.1.0.0")]
[assembly: AssemblyFileVersion("3.1.0.0")]

namespace SessionRecoveryLauncher
{
    internal static class Program
    {
        private const string AppName = "Session Recovery";
        private const string StudioWindowTitle = "Session Recovery";
        private const int SW_RESTORE = 9;
        private static FileStream windowLock;
        private static string windowPidPath;
        private static SplashForm splash;
        internal static EventWaitHandle splashEvent;
        private static readonly object splashSync = new object();

        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);
        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")]
        private static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int command);
        [DllImport("user32.dll")]
        private static extern bool SetForegroundWindow(IntPtr hWnd);

        [STAThread]
        private static int Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            string appDirectory = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            string mode = args.Length > 0 ? args[0].Trim().ToLowerInvariant() : "--studio";

            string scriptName;
            string scriptArguments = "";
            bool showErrors = true;
            bool notifySnapshot = false;

            switch (mode)
            {
                case "--tray":
                    scriptName = "Tray-SessionRecovery.ps1";
                    showErrors = false;
                    break;
                case "--tray-monitor":
                    scriptName = "Tray-SessionRecovery.ps1";
                    scriptArguments = "-MonitorOnly";
                    showErrors = false;
                    break;
                case "--snapshot":
                case "--save":
                    scriptName = "Save-Session.ps1";
                    // Manual capture: runs even during smart-capture pauses.
                    scriptArguments = "-Quiet -Force";
                    showErrors = false;
                    // Manual snapshot (Start Menu shortcut): confirm with a
                    // toast when desktop notifications are enabled.
                    notifySnapshot = true;
                    break;
                case "--snapshot-quiet":
                case "--save-quiet":
                    // Scheduled/automatic snapshots must stay completely
                    // silent, and respect idle/fullscreen smart-capture skips.
                    scriptName = "Save-Session.ps1";
                    scriptArguments = "-Quiet";
                    showErrors = false;
                    notifySnapshot = false;
                    break;
                case "--snapshot-studio":
                    // Manual capture from the Studio: forced, but the Studio
                    // shows its own progress and result toast.
                    scriptName = "Save-Session.ps1";
                    scriptArguments = "-Quiet -Force";
                    showErrors = false;
                    notifySnapshot = false;
                    break;
                case "--hibernate":
                    // Save a pinned checkpoint, then hibernate through
                    // shutdown.exe. The checkpoint is mandatory.
                    scriptName = "Save-Session.ps1";
                    scriptArguments = "-Hibernate";
                    showErrors = true;
                    notifySnapshot = false;
                    break;
                case "--restore":
                case "--restore-prompt":
                    scriptName = "Restore-Session.ps1";
                    showErrors = true;
                    break;
                case "--restore-manual":
                    scriptName = "Restore-Session.ps1";
                    scriptArguments = "-Manual";
                    showErrors = true;
                    break;
                case "--diagnostics":
                    scriptName = "Studio-SessionRecovery.ps1";
                    scriptArguments = "-Page Diagnostics";
                    showErrors = true;
                    break;
                case "--control":
                    // Local command-line API (snapshot, status, workspaces...).
                    scriptName = "Control-SessionRecovery.ps1";
                    showErrors = true;
                    break;
                case "--settings":
                    scriptName = "Studio-SessionRecovery.ps1";
                    scriptArguments = "-Page Settings";
                    showErrors = true;
                    break;
                case "--about":
                    scriptName = "Studio-SessionRecovery.ps1";
                    scriptArguments = "-Page About";
                    showErrors = true;
                    break;
                case "--studio":
                case "":
                    scriptName = "Studio-SessionRecovery.ps1";
                    showErrors = true;
                    break;
                default:
                    scriptName = "Studio-SessionRecovery.ps1";
                    showErrors = true;
                    break;
            }

            // Extra arguments let the Studio open a specific snapshot or pass
            // restore options without going through a PowerShell console.
            if (args.Length > 1)
            {
                List<string> extras = new List<string>();
                for (int i = 1; i < args.Length; i++) extras.Add(args[i]);
                foreach (string extra in extras)
                {
                    if (String.IsNullOrWhiteSpace(extra)) continue;
                    if (extra.StartsWith("-") || extra.StartsWith("/"))
                    {
                        scriptArguments += " " + extra;
                    }
                    else
                    {
                        scriptArguments += " '" + extra.Replace("'", "''") + "'";
                    }
                }
            }

            string scriptPath = ResolveScript(appDirectory, scriptName);
            if (scriptPath == null)
            {
                if (showErrors)
                {
                    MessageBox.Show(
                        "The Session Recovery program files are incomplete.\r\n\r\nMissing: " + scriptName +
                        "\r\n\r\nReinstall Session Recovery from the MSI and try again.",
                        AppName, MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
                Log("Missing script: " + scriptName + " in " + appDirectory);
                return 2;
            }

            bool studioMode = String.Equals(scriptName, "Studio-SessionRecovery.ps1", StringComparison.OrdinalIgnoreCase);
            bool restoreMode = String.Equals(mode, "--restore-manual", StringComparison.OrdinalIgnoreCase);
            string windowKind = studioMode ? "studio" : (restoreMode ? "restore" : "");
            if (!String.IsNullOrEmpty(windowKind) && TryActivateExistingWindow(windowKind, 0)) return 0;
            if (!String.IsNullOrEmpty(windowKind))
            {
                if (!TryAcquireWindowLock(windowKind))
                {
                    // Another launch is already loading or showing this window.
                    // Wait briefly for it instead of starting a second
                    // PowerShell process and doubling the delay.
                    if (TryActivateExistingWindow(windowKind, 12000)) return 0;
                    return 0;
                }
                WriteWindowPid();
                ShowSplash();
            }

            try
            {
                Environment.SetEnvironmentVariable("SESSIONRECOVERY_HOST", "1");
                Environment.SetEnvironmentVariable("SESSIONRECOVERY_HOST_EXE", Application.ExecutablePath);
                Directory.SetCurrentDirectory(appDirectory);

                DateTime started = DateTime.Now;
                string error;
                bool success = RunScript(scriptPath, scriptArguments, showErrors, out error);

                if (notifySnapshot && NotificationsEnabled())
                {
                    bool saved = success && SnapshotSavedSince(started);
                    ShowSnapshotToast(saved, saved ? "Snapshot saved" : "Snapshot could not be saved");
                }

                return success ? 0 : 1;
            }
            finally
            {
                CloseSplash();
                try
                {
                    if (splashEvent != null)
                    {
                        splashEvent.Set();
                        splashEvent.Dispose();
                        splashEvent = null;
                    }
                }
                catch { }
                ReleaseWindowLock();
            }
        }

        private static string GetStudioRoot()
        {
            string root = Environment.GetEnvironmentVariable("SESSIONRECOVERY_HOME");
            if (String.IsNullOrWhiteSpace(root))
            {
                root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SessionRecovery");
            }
            return root;
        }

        private static bool TryAcquireWindowLock(string kind)
        {
            try
            {
                string root = GetStudioRoot();
                Directory.CreateDirectory(root);
                windowPidPath = Path.Combine(root, kind + ".pid");
                windowLock = new FileStream(Path.Combine(root, kind + ".lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
                return true;
            }
            catch (IOException)
            {
                return false;
            }
            catch
            {
                // If the data folder cannot be locked, never block the app.
                return true;
            }
        }

        private static void WriteWindowPid()
        {
            try
            {
                if (String.IsNullOrWhiteSpace(windowPidPath)) return;
                File.WriteAllText(windowPidPath, Process.GetCurrentProcess().Id.ToString(System.Globalization.CultureInfo.InvariantCulture));
            }
            catch { }
        }

        private static void ReleaseWindowLock()
        {
            try
            {
                if (!String.IsNullOrWhiteSpace(windowPidPath) && File.Exists(windowPidPath))
                {
                    string text = File.ReadAllText(windowPidPath).Trim();
                    if (text == Process.GetCurrentProcess().Id.ToString(System.Globalization.CultureInfo.InvariantCulture))
                    {
                        File.Delete(windowPidPath);
                    }
                }
            }
            catch { }
            try
            {
                if (windowLock != null)
                {
                    windowLock.Dispose();
                    windowLock = null;
                }
            }
            catch { }
        }

        internal static IntPtr FindStudioWindow(int processId)
        {
            IntPtr found = IntPtr.Zero;
            try
            {
                EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
                {
                    if (!IsWindowVisible(hWnd)) return true;
                    uint owner;
                    GetWindowThreadProcessId(hWnd, out owner);
                    if (owner != (uint)processId) return true;
                    StringBuilder title = new StringBuilder(256);
                    GetWindowText(hWnd, title, title.Capacity);
                    if (String.Equals(title.ToString(), StudioWindowTitle, StringComparison.Ordinal))
                    {
                        found = hWnd;
                        return false;
                    }
                    return true;
                }, IntPtr.Zero);
            }
            catch { }
            return found;
        }

        private static bool TryActivateExistingWindow(string kind, int waitMilliseconds)
        {
            string root = GetStudioRoot();
            string pidPath = Path.Combine(root, kind + ".pid");
            DateTime deadline = DateTime.UtcNow.AddMilliseconds(Math.Max(0, waitMilliseconds));

            while (true)
            {
                int processId = 0;
                try
                {
                    if (File.Exists(pidPath))
                    {
                        Int32.TryParse(File.ReadAllText(pidPath).Trim(), out processId);
                    }
                }
                catch { }

                if (processId > 0 && processId != Process.GetCurrentProcess().Id)
                {
                    Process process = null;
                    try
                    {
                        process = Process.GetProcessById(processId);
                        if (process.HasExited || !String.Equals(process.ProcessName, "SessionRecovery", StringComparison.OrdinalIgnoreCase))
                        {
                            process = null;
                        }
                    }
                    catch { process = null; }

                    if (process != null)
                    {
                        IntPtr window = FindStudioWindow(processId);
                        if (window != IntPtr.Zero)
                        {
                            try
                            {
                                if (IsIconic(window)) ShowWindow(window, SW_RESTORE);
                                SetForegroundWindow(window);
                            }
                            catch { }
                            return true;
                        }
                    }
                    else
                    {
                        try { File.Delete(pidPath); } catch { }
                    }
                }

                if (waitMilliseconds <= 0 || DateTime.UtcNow >= deadline) return false;
                Thread.Sleep(75);
            }
        }

        private static void ShowSplash()
        {
            try
            {
                // The Studio sets this event from its first Shown handler. The
                // splash owns the wait check, so it cannot be left on screen by
                // a cross-thread close race or a window-title mismatch.
                string eventName = "Local\\SessionRecovery.Splash." + Guid.NewGuid().ToString("N");
                splashEvent = new EventWaitHandle(false, EventResetMode.ManualReset, eventName);
                Environment.SetEnvironmentVariable("SESSIONRECOVERY_SPLASH_EVENT", eventName);

                Thread thread = new Thread(delegate()
                {
                    try
                    {
                        SplashForm form = new SplashForm();
                        form.FormClosed += delegate
                        {
                            lock (splashSync)
                            {
                                if (Object.ReferenceEquals(splash, form)) splash = null;
                            }
                        };
                        lock (splashSync) { splash = form; }
                        Application.Run(form);
                    }
                    catch { }
                });
                thread.IsBackground = true;
                thread.SetApartmentState(ApartmentState.STA);
                thread.Start();

                Thread watcher = new Thread(delegate()
                {
                    DateTime deadline = DateTime.UtcNow.AddSeconds(30);
                    while (DateTime.UtcNow < deadline)
                    {
                        if (FindStudioWindow(Process.GetCurrentProcess().Id) != IntPtr.Zero)
                        {
                            CloseSplash();
                            return;
                        }
                        Thread.Sleep(50);
                    }
                    CloseSplash();
                });
                watcher.IsBackground = true;
                watcher.Start();
            }
            catch { }
        }

        private static void CloseSplash()
        {
            SplashForm form;
            lock (splashSync) { form = splash; }
            if (form == null) return;
            Action close = delegate()
            {
                try { form.Close(); } catch { }
            };
            try
            {
                if (form.IsDisposed) return;
                if (form.IsHandleCreated)
                {
                    form.BeginInvoke(close);
                }
                else
                {
                    // The worker thread may not have created the handle yet.
                    // Close on first shown instead of leaving the splash up.
                    form.Shown += delegate { close(); };
                }
            }
            catch { }
        }

        private static string ResolveScript(string appDirectory, string scriptName)
        {
            string[] candidates = new string[]
            {
                Path.Combine(appDirectory, scriptName),
                Path.Combine(appDirectory, "src", scriptName),
                Path.Combine(appDirectory, "..", "src", scriptName),
                Path.Combine(appDirectory, "..", "..", "src", scriptName)
            };

            foreach (string candidate in candidates)
            {
                try
                {
                    string full = Path.GetFullPath(candidate);
                    if (File.Exists(full)) return full;
                }
                catch { }
            }
            return null;
        }

        private static bool RunScript(string scriptPath, string scriptArguments, bool showErrors, out string error)
        {
            error = "";
            try
            {
                InitialSessionState session = InitialSessionState.CreateDefault();
                session.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;

                using (Runspace runspace = RunspaceFactory.CreateRunspace(session))
                {
                    runspace.ApartmentState = ApartmentState.STA;
                    runspace.ThreadOptions = PSThreadOptions.ReuseThread;
                    runspace.Open();

                    using (PowerShell powerShell = PowerShell.Create())
                    {
                        powerShell.Runspace = runspace;
                        string command = "& '" + scriptPath.Replace("'", "''") + "'";
                        if (!String.IsNullOrWhiteSpace(scriptArguments)) command += " " + scriptArguments;
                        powerShell.AddScript(command);

                        try
                        {
                            powerShell.Invoke();
                        }
                        catch (Exception invokeError)
                        {
                            // A script that calls exit can surface as a pipeline
                            // exception. Keep the useful message if there is one.
                            error = invokeError.Message;
                        }

                        if (powerShell.HadErrors)
                        {
                            List<string> messages = new List<string>();
                            foreach (ErrorRecord record in powerShell.Streams.Error)
                            {
                                if (record == null) continue;
                                messages.Add(record.ToString());
                            }
                            if (messages.Count == 0)
                            {
                                // A script that calls `exit 1` stops the pipeline
                                // without adding an error record. Surface the exit
                                // code so callers do not mistake a failure for a
                                // skipped capture (which exits 0).
                                object lastExitCode = null;
                                try { lastExitCode = runspace.SessionStateProxy.GetVariable("LASTEXITCODE"); } catch { }
                                int numericExitCode = 0;
                                if (lastExitCode != null && Int32.TryParse(lastExitCode.ToString(), out numericExitCode) && numericExitCode != 0)
                                {
                                    messages.Add("The script exited with code " + numericExitCode + ".");
                                }
                                else
                                {
                                    messages.Add("The script reported an error without details.");
                                }
                            }
                            error = String.Join("\r\n", messages.ToArray());
                            Log("PowerShell errors:\r\n" + error);
                        }
                    }
                }

                if (!String.IsNullOrWhiteSpace(error))
                {
                    if (showErrors)
                    {
                        CloseSplash();
                        MessageBox.Show(
                            "Session Recovery could not complete that action.\r\n\r\n" + error,
                            AppName, MessageBoxButtons.OK, MessageBoxIcon.Error);
                    }
                    return false;
                }
                return true;
            }
            catch (Exception ex)
            {
                error = ex.ToString();
                Log("Host error:\r\n" + error);
                if (showErrors)
                {
                    CloseSplash();
                    MessageBox.Show(
                        "Session Recovery could not start.\r\n\r\n" + ex.Message,
                        AppName, MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
                return false;
            }
        }

        private static bool NotificationsEnabled()
        {
            try
            {
                string root = Environment.GetEnvironmentVariable("SESSIONRECOVERY_HOME");
                if (String.IsNullOrWhiteSpace(root))
                {
                    root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SessionRecovery");
                }
                string configPath = Path.Combine(root, "config.json");
                if (!File.Exists(configPath)) return true;
                string json = File.ReadAllText(configPath);
                Match match = Regex.Match(json, "\"showNotifications\"\\s*:\\s*(true|false)", RegexOptions.IgnoreCase);
                if (match.Success) return match.Groups[1].Value.Equals("true", StringComparison.OrdinalIgnoreCase);
            }
            catch { }
            return true;
        }

        private static bool SnapshotSavedSince(DateTime started)
        {
            try
            {
                string root = Environment.GetEnvironmentVariable("SESSIONRECOVERY_HOME");
                if (String.IsNullOrWhiteSpace(root))
                {
                    root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SessionRecovery");
                }
                string snapshots = Path.Combine(root, "snapshots");
                if (!Directory.Exists(snapshots)) return false;

                foreach (string file in Directory.GetFiles(snapshots, "session-*.json*"))
                {
                    try
                    {
                        if (File.GetLastWriteTime(file) >= started.AddSeconds(-2)) return true;
                    }
                    catch { }
                }
            }
            catch { }
            return false;
        }

        private static void ShowSnapshotToast(bool success, string message)
        {
            try
            {
                using (NotifyIcon icon = new NotifyIcon())
                {
                    // ExtractAssociatedIcon returns an HICON that nothing else
                    // frees, and assigning it to the NotifyIcon does not
                    // transfer ownership - one handle leaked per toast. The
                    // icon owns its handle, so clone it for the NotifyIcon and
                    // dispose the original (its Dispose destroys the HICON).
                    Icon appIcon = null;
                    try { appIcon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
                    if (appIcon != null)
                    {
                        try { icon.Icon = (Icon)appIcon.Clone(); }
                        finally { appIcon.Dispose(); }
                    }
                    else
                    {
                        icon.Icon = SystemIcons.Application;
                    }
                    icon.Text = AppName;
                    icon.Visible = true;
                    icon.BalloonTipTitle = AppName;
                    icon.BalloonTipText = message;
                    icon.BalloonTipIcon = success ? ToolTipIcon.Info : ToolTipIcon.Warning;
                    icon.ShowBalloonTip(3200);

                    ApplicationContext context = new ApplicationContext();
                    WinFormsTimer timer = new WinFormsTimer();
                    timer.Interval = 3600;
                    timer.Tick += delegate
                    {
                        timer.Stop();
                        timer.Dispose();
                        context.ExitThread();
                    };
                    timer.Start();
                    Application.Run(context);
                    icon.Visible = false;
                }
            }
            catch { }
        }

        private static void Log(string message)
        {
            try
            {
                string root = Environment.GetEnvironmentVariable("SESSIONRECOVERY_HOME");
                if (String.IsNullOrWhiteSpace(root))
                {
                    root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SessionRecovery");
                }
                string logDirectory = Path.Combine(root, "logs");
                Directory.CreateDirectory(logDirectory);
                string line = String.Format("{0:yyyy-MM-dd HH:mm:ss.fff} [HOST] {1}{2}", DateTime.Now, message, Environment.NewLine);
                File.AppendAllText(Path.Combine(logDirectory, "host.log"), line);
            }
            catch { }
        }
    }

    internal sealed class SplashForm : Form
    {
        private readonly Font titleFont;
        private readonly Font bodyFont;
        private readonly Font hintFont;
        private readonly Icon appIcon;
        private readonly WinFormsTimer fadeTimer;
        private readonly WinFormsTimer closeTimer;
        private readonly DateTime closeDeadline;

        public SplashForm()
        {
            Text = "Session Recovery - Starting";
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(420, 190);
            BackColor = Color.FromArgb(24, 21, 36);
            DoubleBuffered = true;
            ShowInTaskbar = false;
            TopMost = true;
            Opacity = 0;

            titleFont = new Font("Segoe UI Semibold", 16f, FontStyle.Regular, GraphicsUnit.Point);
            bodyFont = new Font("Segoe UI", 9f, FontStyle.Regular, GraphicsUnit.Point);
            hintFont = new Font("Segoe UI", 8f, FontStyle.Regular, GraphicsUnit.Point);
            try { appIcon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

            Label title = new Label();
            title.Text = "Session Recovery";
            title.Font = titleFont;
            title.ForeColor = Color.White;
            title.BackColor = Color.Transparent;
            title.SetBounds(98, 42, 300, 30);
            Controls.Add(title);

            Label subtitle = new Label();
            subtitle.Text = "Opening your studio...";
            subtitle.Font = bodyFont;
            subtitle.ForeColor = Color.FromArgb(190, 186, 210);
            subtitle.BackColor = Color.Transparent;
            subtitle.SetBounds(98, 76, 300, 22);
            Controls.Add(subtitle);

            ProgressBar progress = new ProgressBar();
            progress.Style = ProgressBarStyle.Marquee;
            progress.MarqueeAnimationSpeed = 30;
            progress.SetBounds(28, 134, 364, 8);
            Controls.Add(progress);

            Label hint = new Label();
            hint.Text = "The first launch can take a few seconds.";
            hint.Font = hintFont;
            hint.ForeColor = Color.FromArgb(130, 126, 150);
            hint.BackColor = Color.Transparent;
            hint.SetBounds(28, 156, 364, 16);
            Controls.Add(hint);

            fadeTimer = new WinFormsTimer();
            fadeTimer.Interval = 20;
            fadeTimer.Tick += delegate
            {
                try
                {
                    if (Opacity >= 1)
                    {
                        fadeTimer.Stop();
                        return;
                    }
                    Opacity = Math.Min(1, Opacity + 0.16);
                }
                catch { fadeTimer.Stop(); }
            };

            // A Form timer runs on the splash's own thread, so closing it here
            // is reliable even while the PowerShell/Studio thread is busy
            // building its first page.
            closeDeadline = DateTime.UtcNow.AddSeconds(30);
            closeTimer = new WinFormsTimer();
            closeTimer.Interval = 100;
            closeTimer.Tick += delegate
            {
                try
                {
                    bool studioReady = false;
                    try
                    {
                        if (Program.splashEvent != null) studioReady = Program.splashEvent.WaitOne(0);
                    }
                    catch { }
                    if (studioReady ||
                        Program.FindStudioWindow(Process.GetCurrentProcess().Id) != IntPtr.Zero ||
                        DateTime.UtcNow >= closeDeadline)
                    {
                        closeTimer.Stop();
                        Close();
                    }
                }
                catch { closeTimer.Stop(); Close(); }
            };
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            fadeTimer.Start();
            closeTimer.Start();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            using (LinearGradientBrush accent = new LinearGradientBrush(
                new Rectangle(0, 0, Width, 3),
                Color.FromArgb(139, 92, 246),
                Color.FromArgb(45, 212, 191),
                0f))
            {
                e.Graphics.FillRectangle(accent, 0, 0, Width, 3);
            }
            if (appIcon != null)
            {
                e.Graphics.DrawIcon(appIcon, new Rectangle(28, 46, 52, 52));
            }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                try { fadeTimer.Stop(); fadeTimer.Dispose(); } catch { }
                try { closeTimer.Stop(); closeTimer.Dispose(); } catch { }
                try { titleFont.Dispose(); } catch { }
                try { bodyFont.Dispose(); } catch { }
                try { hintFont.Dispose(); } catch { }
                try { if (appIcon != null) appIcon.Dispose(); } catch { }
            }
            base.Dispose(disposing);
        }
    }
}
