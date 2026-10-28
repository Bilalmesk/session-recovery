using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;
using WinFormsTimer = System.Windows.Forms.Timer;

[assembly: AssemblyTitle("Session Recovery")]
[assembly: AssemblyDescription("Session Recovery desktop host")]
[assembly: AssemblyProduct("Session Recovery")]
[assembly: AssemblyCompany("Bilalmesk")]
[assembly: AssemblyVersion("2.7.0.0")]
[assembly: AssemblyFileVersion("2.7.0.0")]

namespace SessionRecoveryLauncher
{
    internal static class Program
    {
        private const string AppName = "Session Recovery";

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
                    Icon appIcon = null;
                    try { appIcon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
                    icon.Icon = appIcon ?? SystemIcons.Application;
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
}
