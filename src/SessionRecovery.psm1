Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Native helpers
# ---------------------------------------------------------------------------

if (-not ('SessionRecovery.WindowEnumerator' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace SessionRecovery
{
    public sealed class WindowInfo
    {
        public IntPtr Handle;
        public uint ProcessId;
        public string ProcessName;
        public string Title;
        public string ClassName;
        public bool Visible;
        public bool Minimized;
        public bool Maximized;
        public int X;
        public int Y;
        public int Width;
        public int Height;
    }

    public static class WindowEnumerator
    {
        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowTextLength(IntPtr hWnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")]
        private static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")]
        private static extern bool IsZoomed(IntPtr hWnd);
        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
        [DllImport("user32.dll")]
        private static extern int GetWindowLong(IntPtr hWnd, int nIndex);
        [DllImport("user32.dll")]
        private static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
        [DllImport("dwmapi.dll")]
        private static extern int DwmGetWindowAttribute(IntPtr hwnd, int dwAttribute, out int pvAttribute, int cbAttribute);

        [StructLayout(LayoutKind.Sequential)]
        private struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

        private const int GWL_EXSTYLE = -20;
        private const int WS_EX_TOOLWINDOW = 0x00000080;
        private const int DWMWA_CLOAKED = 14;

        private static readonly HashSet<string> IgnoredClasses = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "Progman", "WorkerW",
            "Windows.UI.Core.CoreWindow", "ApplicationFrameWindow",
            "TaskListThumbnailWnd", "DV2ControlHost", "MsgrIMEWindowClass",
            "SysShadow", "Button", "tooltips_class32", "#32768"
        };

        public static WindowInfo[] GetVisibleWindows()
        {
            List<WindowInfo> result = new List<WindowInfo>();
            uint ownPid = (uint)Process.GetCurrentProcess().Id;

            EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
            {
                try
                {
                    if (!IsWindowVisible(hWnd)) return true;

                    int titleLength = GetWindowTextLength(hWnd);
                    if (titleLength <= 0) return true;

                    int exStyle = GetWindowLong(hWnd, GWL_EXSTYLE);
                    if ((exStyle & WS_EX_TOOLWINDOW) != 0) return true;

                    int cloaked = 0;
                    if (DwmGetWindowAttribute(hWnd, DWMWA_CLOAKED, out cloaked, sizeof(int)) == 0 && cloaked != 0)
                        return true;

                    StringBuilder titleBuilder = new StringBuilder(titleLength + 1);
                    GetWindowText(hWnd, titleBuilder, titleBuilder.Capacity);
                    string title = titleBuilder.ToString().Trim();
                    if (title.Length == 0) return true;

                    StringBuilder classBuilder = new StringBuilder(256);
                    GetClassName(hWnd, classBuilder, classBuilder.Capacity);
                    string className = classBuilder.ToString();
                    if (IgnoredClasses.Contains(className)) return true;

                    uint pid;
                    GetWindowThreadProcessId(hWnd, out pid);
                    if (pid == 0 || pid == ownPid) return true;

                    string processName = "";
                    try { processName = Process.GetProcessById((int)pid).ProcessName; }
                    catch { }

                    WindowInfo info = new WindowInfo();
                    info.Handle = hWnd;
                    info.ProcessId = pid;
                    info.ProcessName = processName;
                    info.Title = title;
                    info.ClassName = className;
                    info.Visible = true;
                    info.Minimized = IsIconic(hWnd);
                    info.Maximized = IsZoomed(hWnd);

                    RECT rect;
                    if (GetWindowRect(hWnd, out rect))
                    {
                        info.X = rect.Left;
                        info.Y = rect.Top;
                        info.Width = rect.Right - rect.Left;
                        info.Height = rect.Bottom - rect.Top;
                    }

                    result.Add(info);
                }
                catch
                {
                    // A window disappearing mid-enumeration must not abort the scan.
                }
                return true;
            }, IntPtr.Zero);

            return result.ToArray();
        }
    }

    // Restores captured window bounds. Placement happens on one background
    // thread so a slow-starting application never blocks the restore loop.
    public static class WindowPlacer
    {
        private sealed class Placement
        {
            public int ProcessId;
            public int X;
            public int Y;
            public int Width;
            public int Height;
            public bool Maximized;
            public DateTime Deadline;
        }

        private static readonly Queue<Placement> Queue = new Queue<Placement>();
        private static readonly object Lock = new object();
        private static Thread worker;

        [DllImport("user32.dll")]
        private static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int x, int y, int cx, int cy, uint uFlags);
        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")]
        private static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")]
        private static extern int GetSystemMetrics(int nIndex);

        private const uint SWP_NOZORDER = 0x0004;
        private const uint SWP_NOACTIVATE = 0x0010;
        private const int SW_MAXIMIZE = 3;
        private const int SW_RESTORE = 9;
        private const int SM_XVIRTUALSCREEN = 76;
        private const int SM_YVIRTUALSCREEN = 77;
        private const int SM_CXVIRTUALSCREEN = 78;
        private const int SM_CYVIRTUALSCREEN = 79;

        public static void QueueProcessWindow(int processId, int timeoutMs, int x, int y, int width, int height, bool maximized)
        {
            if (width <= 0 || height <= 0) return;
            Placement placement = new Placement();
            placement.ProcessId = processId;
            placement.X = x;
            placement.Y = y;
            placement.Width = width;
            placement.Height = height;
            placement.Maximized = maximized;
            placement.Deadline = DateTime.UtcNow.AddMilliseconds(Math.Max(500, timeoutMs));
            lock (Lock)
            {
                Queue.Enqueue(placement);
                if (worker == null)
                {
                    worker = new Thread(new ThreadStart(ProcessQueue));
                    worker.IsBackground = true;
                    worker.Start();
                }
            }
        }

        private static void ProcessQueue()
        {
            while (true)
            {
                Placement placement;
                lock (Lock)
                {
                    if (Queue.Count == 0)
                    {
                        // Clear the worker while still holding the lock so an
                        // enqueue cannot slip in between the empty check and
                        // the thread exiting, leaving an item stranded.
                        worker = null;
                        return;
                    }
                    placement = Queue.Dequeue();
                }

                IntPtr handle = IntPtr.Zero;
                while (DateTime.UtcNow < placement.Deadline)
                {
                    try
                    {
                        System.Diagnostics.Process process = System.Diagnostics.Process.GetProcessById(placement.ProcessId);
                        process.Refresh();
                        if (process.MainWindowHandle != IntPtr.Zero)
                        {
                            handle = process.MainWindowHandle;
                            break;
                        }
                    }
                    catch
                    {
                        // The launcher process exited (for example a stub that
                        // hands off to an already-running instance).
                        break;
                    }
                    System.Threading.Thread.Sleep(150);
                }

                if (handle != IntPtr.Zero)
                {
                    // Give the window a moment to finish its own initial
                    // layout before moving it, and re-read the handle because
                    // some apps swap main windows while starting.
                    System.Threading.Thread.Sleep(250);
                    try
                    {
                        System.Diagnostics.Process process = System.Diagnostics.Process.GetProcessById(placement.ProcessId);
                        process.Refresh();
                        if (process.MainWindowHandle != IntPtr.Zero) handle = process.MainWindowHandle;
                    }
                    catch { }
                    Apply(handle, placement.X, placement.Y, placement.Width, placement.Height, placement.Maximized);
                }
            }
        }

        private static void Apply(IntPtr hWnd, int x, int y, int width, int height, bool maximized)
        {
            if (hWnd == IntPtr.Zero) return;
            try
            {
                // Clamp into the current virtual screen so a window captured
                // on a monitor that no longer exists stays reachable.
                int screenLeft = GetSystemMetrics(SM_XVIRTUALSCREEN);
                int screenTop = GetSystemMetrics(SM_YVIRTUALSCREEN);
                int screenWidth = GetSystemMetrics(SM_CXVIRTUALSCREEN);
                int screenHeight = GetSystemMetrics(SM_CYVIRTUALSCREEN);
                if (screenWidth > 0 && screenHeight > 0)
                {
                    // Keep the whole window on the virtual desktop. If the
                    // capture came from a larger monitor layout, shrink it
                    // before clamping its origin.
                    int maxWidth = screenWidth;
                    int maxHeight = screenHeight;
                    if (width > maxWidth) width = maxWidth;
                    if (height > maxHeight) height = maxHeight;
                    if (x < screenLeft) x = screenLeft;
                    if (y < screenTop) y = screenTop;
                    if (x > screenLeft + screenWidth - width) x = screenLeft + screenWidth - width;
                    if (y > screenTop + screenHeight - height) y = screenTop + screenHeight - height;
                }
                if (IsIconic(hWnd)) ShowWindow(hWnd, SW_RESTORE);
                SetWindowPos(hWnd, IntPtr.Zero, x, y, width, height, SWP_NOZORDER | SWP_NOACTIVATE);
                if (maximized) ShowWindow(hWnd, SW_MAXIMIZE);
            }
            catch
            {
                // Positioning is best-effort; the app still opened.
            }
        }
    }

    public static class CommandLineSplitter
    {
        [DllImport("shell32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr CommandLineToArgvW(string lpCmdLine, out int pNumArgs);
        [DllImport("kernel32.dll")]
        private static extern IntPtr LocalFree(IntPtr hMem);

        public static string[] Split(string commandLine)
        {
            if (String.IsNullOrWhiteSpace(commandLine)) return new string[0];
            int argc;
            IntPtr argv = CommandLineToArgvW(commandLine, out argc);
            if (argv == IntPtr.Zero) return new string[0];
            try
            {
                string[] result = new string[argc];
                for (int i = 0; i < argc; i++)
                {
                    IntPtr ptr = Marshal.ReadIntPtr(argv, i * IntPtr.Size);
                    result[i] = Marshal.PtrToStringUni(ptr);
                }
                return result;
            }
            finally
            {
                LocalFree(argv);
            }
        }
    }

    public sealed class SessionTab
    {
        public int WindowId;
        public int TabId;
        public int TabOrder;
        public int VisualIndex;
        public bool Pinned;
        public string Url;
        public string Title;
    }

    public static class SessionFileReader
    {
        private sealed class Navigation
        {
            public int Index;
            public string Url;
            public string Title;
        }

        private sealed class TabState
        {
            public int TabId;
            public int WindowId;
            public int VisualIndex;
            public int SelectedIndex;
            public int Order;
            public bool Pinned;
            public bool Closed;
            public SortedDictionary<int, Navigation> Navigations = new SortedDictionary<int, Navigation>();
        }

        private sealed class WindowState
        {
            public int WindowId;
            public int Type;
            public int Order;
            public bool Closed;
        }

        public static SessionTab[] ReadFile(string path)
        {
            using (System.IO.FileStream fs = new System.IO.FileStream(
                path, System.IO.FileMode.Open, System.IO.FileAccess.Read,
                System.IO.FileShare.ReadWrite | System.IO.FileShare.Delete))
            {
                using (System.IO.MemoryStream ms = new System.IO.MemoryStream())
                {
                    fs.CopyTo(ms);
                    return Parse(ms.ToArray());
                }
            }
        }

        public static SessionTab[] Parse(byte[] data)
        {
            List<SessionTab> result = new List<SessionTab>();
            if (data == null || data.Length < 8) return result.ToArray();
            if (data[0] != (byte)'S' || data[1] != (byte)'N' || data[2] != (byte)'S' || data[3] != (byte)'S')
                return result.ToArray();

            Dictionary<int, TabState> tabs = new Dictionary<int, TabState>();
            Dictionary<int, WindowState> windows = new Dictionary<int, WindowState>();
            int order = 0;
            int pos = 8;

            while (pos + 2 <= data.Length)
            {
                int size = data[pos] | (data[pos + 1] << 8);
                pos += 2;
                if (size < 1 || pos + size > data.Length) break;
                int contentStart = pos;
                int contentLength = size - 1;
                byte command = data[pos];
                int content = pos + 1;
                pos += size;

                try
                {
                    switch (command)
                    {
                        case 0: // SetTabWindow: window_id, tab_id
                        {
                            if (contentLength < 8) break;
                            int windowId = BitConverter.ToInt32(data, content);
                            int tabId = BitConverter.ToInt32(data, content + 4);
                            TabState tab = GetTab(tabs, tabId, ref order);
                            tab.WindowId = windowId;
                            if (!windows.ContainsKey(windowId))
                                windows[windowId] = new WindowState { WindowId = windowId, Order = order++ };
                            break;
                        }
                        case 2: // SetTabIndexInWindow: tab_id, visual index
                        {
                            if (contentLength < 8) break;
                            int tabId = BitConverter.ToInt32(data, content);
                            TabState tab = GetTab(tabs, tabId, ref order);
                            tab.VisualIndex = BitConverter.ToInt32(data, content + 4);
                            break;
                        }
                        case 5: // legacy prune from back: tab_id, index
                        {
                            if (contentLength < 8) break;
                            int tabId = BitConverter.ToInt32(data, content);
                            int index = BitConverter.ToInt32(data, content + 4);
                            TabState tab = GetTab(tabs, tabId, ref order);
                            List<int> remove = new List<int>();
                            foreach (int key in tab.Navigations.Keys)
                                if (key >= index) remove.Add(key);
                            foreach (int key in remove) tab.Navigations.Remove(key);
                            break;
                        }
                        case 6: // UpdateTabNavigation: pickle size, tab_id, index, url, title16
                        {
                            if (contentLength < 16) break;
                            // This command's content is a serialized base::Pickle,
                            // including its leading 4-byte payload size. All
                            // alignment inside a Pickle is relative to the start
                            // of its payload, not to the file offset.
                            int payload = content + 4;
                            int commandEnd = contentStart + size;
                            int offset = payload;
                            int tabId = BitConverter.ToInt32(data, offset); offset += 4;
                            int navIndex = BitConverter.ToInt32(data, offset); offset += 4;
                            string url = ReadString(data, ref offset, payload, commandEnd);
                            string title = ReadString16(data, ref offset, payload, commandEnd);
                            TabState tab = GetTab(tabs, tabId, ref order);
                            Navigation nav = new Navigation();
                            nav.Index = navIndex;
                            nav.Url = url;
                            nav.Title = title;
                            tab.Navigations[navIndex] = nav;
                            break;
                        }
                        case 7: // SetSelectedNavigationIndex: tab_id, index
                        {
                            if (contentLength < 8) break;
                            int tabId = BitConverter.ToInt32(data, content);
                            int index = BitConverter.ToInt32(data, content + 4);
                            GetTab(tabs, tabId, ref order).SelectedIndex = index;
                            break;
                        }
                        case 9: // SetWindowType: window_id, type
                        {
                            if (contentLength < 8) break;
                            int windowId = BitConverter.ToInt32(data, content);
                            WindowState window = GetWindow(windows, windowId, ref order);
                            window.Type = BitConverter.ToInt32(data, content + 4);
                            break;
                        }
                        case 11: // legacy prune from front: tab_id, count
                        {
                            if (contentLength < 8) break;
                            int tabId = BitConverter.ToInt32(data, content);
                            int count = BitConverter.ToInt32(data, content + 4);
                            PruneRange(GetTab(tabs, tabId, ref order), 0, count);
                            break;
                        }
                        case 12: // SetPinnedState: tab_id, bool
                        {
                            if (contentLength < 5) break;
                            int tabId = BitConverter.ToInt32(data, content);
                            GetTab(tabs, tabId, ref order).Pinned = data[content + 4] != 0;
                            break;
                        }
                        case 16: // TabClosed: tab_id, close time
                        {
                            if (contentLength < 4) break;
                            int tabId = BitConverter.ToInt32(data, content);
                            TabState tab;
                            if (tabs.TryGetValue(tabId, out tab)) tab.Closed = true;
                            break;
                        }
                        case 17: // WindowClosed: window_id, close time
                        {
                            if (contentLength < 4) break;
                            int windowId = BitConverter.ToInt32(data, content);
                            WindowState window;
                            if (windows.TryGetValue(windowId, out window)) window.Closed = true;
                            break;
                        }
                        case 24: // TabNavigationPathPruned: tab_id, index, count
                        {
                            if (contentLength < 12) break;
                            int tabId = BitConverter.ToInt32(data, content);
                            int index = BitConverter.ToInt32(data, content + 4);
                            int count = BitConverter.ToInt32(data, content + 8);
                            PruneRange(GetTab(tabs, tabId, ref order), index, count);
                            break;
                        }
                        default:
                            break;
                    }
                }
                catch
                {
                    // A malformed command should not discard commands that were
                    // parsed successfully before it. Keep going.
                }

                // Keep the next iteration aligned even if we jumped past the
                // content due to an exception.
                pos = contentStart + size;
            }

            List<TabState> orderedTabs = new List<TabState>();
            foreach (TabState tab in tabs.Values)
            {
                if (tab.Closed || tab.WindowId == 0 || tab.Navigations.Count == 0) continue;
                WindowState window;
                if (!windows.TryGetValue(tab.WindowId, out window)) continue;
                if (window.Closed || window.Type == 4) continue;
                orderedTabs.Add(tab);
            }

            orderedTabs.Sort(delegate(TabState a, TabState b)
            {
                int cmp = a.WindowId.CompareTo(b.WindowId);
                if (cmp != 0) return cmp;
                cmp = a.VisualIndex.CompareTo(b.VisualIndex);
                if (cmp != 0) return cmp;
                return a.Order.CompareTo(b.Order);
            });

            foreach (TabState tab in orderedTabs)
            {
                Navigation selected = FindNavigation(tab);
                if (selected == null || String.IsNullOrWhiteSpace(selected.Url)) continue;

                SessionTab output = new SessionTab();
                output.WindowId = tab.WindowId;
                output.TabId = tab.TabId;
                output.TabOrder = tab.Order;
                output.VisualIndex = tab.VisualIndex;
                output.Pinned = tab.Pinned;
                output.Url = selected.Url;
                output.Title = selected.Title;
                result.Add(output);
            }

            return result.ToArray();
        }

        private static TabState GetTab(Dictionary<int, TabState> tabs, int id, ref int order)
        {
            TabState tab;
            if (!tabs.TryGetValue(id, out tab))
            {
                tab = new TabState();
                tab.TabId = id;
                tab.Order = order++;
                tabs[id] = tab;
            }
            return tab;
        }

        private static WindowState GetWindow(Dictionary<int, WindowState> windows, int id, ref int order)
        {
            WindowState window;
            if (!windows.TryGetValue(id, out window))
            {
                window = new WindowState();
                window.WindowId = id;
                window.Order = order++;
                windows[id] = window;
            }
            return window;
        }

        private static Navigation FindNavigation(TabState tab)
        {
            Navigation nav;
            if (tab.Navigations.TryGetValue(tab.SelectedIndex, out nav)) return nav;
            foreach (Navigation candidate in tab.Navigations.Values)
            {
                if (candidate.Index >= tab.SelectedIndex) return candidate;
            }
            if (tab.Navigations.Count == 0) return null;
            Navigation last = null;
            foreach (Navigation candidate in tab.Navigations.Values) last = candidate;
            return last;
        }

        private static void PruneRange(TabState tab, int index, int count)
        {
            if (count <= 0) return;
            List<int> remove = new List<int>();
            foreach (int key in tab.Navigations.Keys)
                if (key >= index && key < index + count) remove.Add(key);
            foreach (int key in remove) tab.Navigations.Remove(key);

            SortedDictionary<int, Navigation> shifted = new SortedDictionary<int, Navigation>();
            foreach (Navigation nav in tab.Navigations.Values)
            {
                int newIndex = nav.Index;
                if (newIndex >= index + count) newIndex -= count;
                nav.Index = newIndex;
                shifted[newIndex] = nav;
            }
            tab.Navigations = shifted;
        }

        private static int Align4(int value)
        {
            return (value + 3) & ~3;
        }

        private static string ReadString(byte[] data, ref int offset, int baseOffset, int endOffset)
        {
            if (offset + 4 > endOffset) throw new InvalidOperationException();
            int length = BitConverter.ToInt32(data, offset);
            offset += 4;
            if (length < 0 || offset + length > endOffset) throw new InvalidOperationException();
            string value = Encoding.UTF8.GetString(data, offset, length);
            offset = baseOffset + Align4(offset - baseOffset + length);
            if (offset > endOffset) throw new InvalidOperationException();
            return value;
        }

        private static string ReadString16(byte[] data, ref int offset, int baseOffset, int endOffset)
        {
            if (offset + 4 > endOffset) throw new InvalidOperationException();
            int chars = BitConverter.ToInt32(data, offset);
            offset += 4;
            if (chars < 0 || offset + chars * 2 > endOffset) throw new InvalidOperationException();
            string value = Encoding.Unicode.GetString(data, offset, chars * 2);
            offset = baseOffset + Align4(offset - baseOffset + chars * 2);
            if (offset > endOffset) throw new InvalidOperationException();
            return value;
        }
    }

    public static class MozLz4
    {
        public static byte[] Decompress(byte[] source)
        {
            if (source == null || source.Length < 12)
                throw new InvalidOperationException("Not a mozLz4 file.");
            if (!(source[0] == (byte)'m' && source[1] == (byte)'o' && source[2] == (byte)'z' &&
                  source[3] == (byte)'L' && source[4] == (byte)'z' && source[5] == (byte)'4' &&
                  source[6] == (byte)'0' && source[7] == 0))
                throw new InvalidOperationException("Not a mozLz4 file.");

            int expected = BitConverter.ToInt32(source, 8);
            if (expected <= 0 || expected > 256 * 1024 * 1024)
                throw new InvalidOperationException("Invalid mozLz4 output size.");

            byte[] output = new byte[expected];
            int ip = 12;
            int op = 0;

            while (ip < source.Length)
            {
                int token = source[ip++];
                int literals = token >> 4;
                if (literals == 15)
                {
                    int b;
                    do { b = source[ip++]; literals += b; } while (b == 255 && ip < source.Length);
                }
                if (op + literals > output.Length || ip + literals > source.Length)
                    throw new InvalidOperationException("Corrupt mozLz4 data.");
                Array.Copy(source, ip, output, op, literals);
                ip += literals;
                op += literals;

                if (ip >= source.Length) break;
                if (ip + 2 > source.Length) throw new InvalidOperationException("Corrupt mozLz4 data.");

                int distance = source[ip] | (source[ip + 1] << 8);
                ip += 2;
                if (distance <= 0 || distance > op) throw new InvalidOperationException("Corrupt mozLz4 data.");

                int match = token & 15;
                if (match == 15)
                {
                    int b;
                    do { b = source[ip++]; match += b; } while (b == 255 && ip < source.Length);
                }
                match += 4;
                if (op + match > output.Length) throw new InvalidOperationException("Corrupt mozLz4 data.");

                int matchPos = op - distance;
                for (int i = 0; i < match; i++) output[op++] = output[matchPos++];
            }

            if (op != expected) Array.Resize(ref output, op);
            return output;
        }
    }
}
'@ -ErrorAction Stop
}

# Modern Chromium browsers keep their session files locked, lazily flushed,
# or completely empty while the browser is running. Read the live tab strip
# through UI Automation and combine it with the local History database when
# the structured session file has nothing useful. This is deliberately a
# fallback: session files remain the exact source whenever they are available.
if (-not ('SessionRecovery.BrowserUiAutomation' -as [type])) {
    try {
        Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
        Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
        $uiaReferences = @(
            [System.Windows.Automation.AutomationElement].Assembly.Location,
            [System.Windows.Automation.ControlType].Assembly.Location,
            'System.Core'
        )
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows.Automation;

namespace SessionRecovery
{
    public sealed class BrowserUiTab
    {
        public string Title;
        public bool Selected;
    }

    public sealed class BrowserUiInfo
    {
        public BrowserUiTab[] Tabs = new BrowserUiTab[0];
        public string CurrentUrl = "";
        public bool HasTabStrip;
        public string Error = "";
    }

    public static class BrowserUiAutomation
    {
        public static BrowserUiInfo Read(IntPtr hwnd, int timeoutMs)
        {
            if (hwnd == IntPtr.Zero) return new BrowserUiInfo();
            try
            {
                Task<BrowserUiInfo> task = Task.Factory.StartNew<BrowserUiInfo>(delegate { return ReadCore(hwnd); });
                if (!task.Wait(timeoutMs))
                {
                    BrowserUiInfo timedOut = new BrowserUiInfo();
                    timedOut.Error = "timeout";
                    return timedOut;
                }
                return task.Result;
            }
            catch (Exception ex)
            {
                BrowserUiInfo failed = new BrowserUiInfo();
                failed.Error = ex.Message;
                return failed;
            }
        }

        private static BrowserUiInfo ReadCore(IntPtr hwnd)
        {
            BrowserUiInfo info = new BrowserUiInfo();
            AutomationElement root = AutomationElement.FromHandle(hwnd);
            if (root == null) return info;

            List<BrowserUiTab> tabs = new List<BrowserUiTab>();
            Condition tabCondition = new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.TabItem);
            AutomationElementCollection foundTabs = root.FindAll(TreeScope.Descendants, tabCondition);
            foreach (AutomationElement tab in foundTabs)
            {
                try
                {
                    string name = tab.Current.Name ?? "";
                    if (name.Length == 0) continue;

                    // Chrome appends live memory/audio status to the accessible
                    // tab name. It is not part of the page title.
                    int suffix = name.IndexOf(" - Memory usage", StringComparison.OrdinalIgnoreCase);
                    if (suffix > 0) name = name.Substring(0, suffix).Trim();
                    suffix = name.IndexOf(" - Audio playing", StringComparison.OrdinalIgnoreCase);
                    if (suffix > 0) name = name.Substring(0, suffix).Trim();
                    suffix = name.IndexOf(" - Muted", StringComparison.OrdinalIgnoreCase);
                    if (suffix > 0) name = name.Substring(0, suffix).Trim();

                    bool selected = false;
                    try
                    {
                        SelectionItemPattern selection = (SelectionItemPattern)tab.GetCurrentPattern(SelectionItemPattern.Pattern);
                        if (selection != null) selected = selection.Current.IsSelected;
                    }
                    catch { }

                    BrowserUiTab item = new BrowserUiTab();
                    item.Title = name;
                    item.Selected = selected;
                    tabs.Add(item);
                }
                catch { }
            }

            info.Tabs = tabs.ToArray();
            info.HasTabStrip = tabs.Count > 0;

            try
            {
                Condition editCondition = new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Edit);
                AutomationElementCollection edits = root.FindAll(TreeScope.Descendants, editCondition);
                foreach (AutomationElement edit in edits)
                {
                    try
                    {
                        string name = edit.Current.Name ?? "";
                        if (name.IndexOf("address", StringComparison.OrdinalIgnoreCase) < 0 &&
                            name.IndexOf("search", StringComparison.OrdinalIgnoreCase) < 0) continue;
                        ValuePattern value = (ValuePattern)edit.GetCurrentPattern(ValuePattern.Pattern);
                        if (value == null) continue;
                        string current = value.Current.Value ?? "";
                        if (!String.IsNullOrWhiteSpace(current))
                        {
                            info.CurrentUrl = current.Trim();
                            break;
                        }
                    }
                    catch { }
                }
            }
            catch { }

            return info;
        }
    }

    public sealed class ChromiumHistoryEntry
    {
        public string Url;
        public string Title;
        public DateTime LastVisit;
    }

    public static class ChromiumHistory
    {
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_open_v2(byte[] filename, out IntPtr db, int flags, IntPtr vfs);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int nByte, out IntPtr stmt, IntPtr tail);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_step(IntPtr stmt);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr sqlite3_column_text(IntPtr stmt, int col);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_column_bytes(IntPtr stmt, int col);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern long sqlite3_column_int64(IntPtr stmt, int col);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_finalize(IntPtr stmt);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_close(IntPtr db);

        public static ChromiumHistoryEntry[] ReadRecent(string profileDirectory, DateTime notBefore, int max)
        {
            if (max < 1) max = 40;
            if (notBefore == DateTime.MinValue) notBefore = DateTime.UtcNow.AddHours(-24);

            string historyPath = System.IO.Path.Combine(profileDirectory, "History");
            if (!System.IO.File.Exists(historyPath)) return new ChromiumHistoryEntry[0];

            List<ChromiumHistoryEntry> entries = new List<ChromiumHistoryEntry>();
            string tempDir = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "SessionRecovery", "history-" + Guid.NewGuid().ToString("N"));
            try
            {
                System.IO.Directory.CreateDirectory(tempDir);
                string copyPath = System.IO.Path.Combine(tempDir, "History");
                CopyShared(historyPath, copyPath);
                foreach (string suffix in new string[] { "-wal", "-shm" })
                {
                    string sidecar = historyPath + suffix;
                    if (System.IO.File.Exists(sidecar)) CopyShared(sidecar, copyPath + suffix);
                }
                entries = Query(copyPath, notBefore, max);
            }
            catch { }
            finally
            {
                try { System.IO.Directory.Delete(tempDir, true); } catch { }
            }

            if (entries.Count == 0)
            {
                try { entries = RawScan(historyPath, max); } catch { }
            }
            return entries.ToArray();
        }

        private static void CopyShared(string source, string destination)
        {
            using (System.IO.FileStream input = new System.IO.FileStream(source, System.IO.FileMode.Open, System.IO.FileAccess.Read, System.IO.FileShare.ReadWrite | System.IO.FileShare.Delete))
            using (System.IO.FileStream output = new System.IO.FileStream(destination, System.IO.FileMode.Create, System.IO.FileAccess.Write, System.IO.FileShare.None))
            {
                input.CopyTo(output);
            }
        }

        private static List<ChromiumHistoryEntry> Query(string path, DateTime notBefore, int max)
        {
            List<ChromiumHistoryEntry> result = new List<ChromiumHistoryEntry>();
            IntPtr db;
            IntPtr stmt;
            int rc = sqlite3_open_v2(Encoding.UTF8.GetBytes(path + "\0"), out db, 1, IntPtr.Zero);
            if (rc != 0) return result;
            try
            {
                string sql = "SELECT url, title, last_visit_time FROM urls ORDER BY last_visit_time DESC LIMIT 1200";
                rc = sqlite3_prepare_v2(db, Encoding.UTF8.GetBytes(sql + "\0"), -1, out stmt, IntPtr.Zero);
                if (rc != 0) return result;
                try
                {
                    HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                    while (sqlite3_step(stmt) == 100 && result.Count < max)
                    {
                        string url = ColumnText(stmt, 0).Trim();
                        string title = ColumnText(stmt, 1).Trim();
                        long raw = sqlite3_column_int64(stmt, 2);
                        if (raw <= 0) continue;

                        DateTime visited;
                        try { visited = DateTime.FromFileTimeUtc(raw * 10); }
                        catch { continue; }
                        if (visited < notBefore) continue;
                        if (!IsRestorableUrl(url)) continue;
                        if (!seen.Add(url)) continue;

                        ChromiumHistoryEntry entry = new ChromiumHistoryEntry();
                        entry.Url = url;
                        entry.Title = title;
                        entry.LastVisit = visited;
                        result.Add(entry);
                    }
                }
                finally { sqlite3_finalize(stmt); }
            }
            finally { sqlite3_close(db); }
            return result;
        }

        private static List<ChromiumHistoryEntry> RawScan(string path, int max)
        {
            List<ChromiumHistoryEntry> result = new List<ChromiumHistoryEntry>();
            byte[] bytes;
            using (System.IO.FileStream input = new System.IO.FileStream(path, System.IO.FileMode.Open, System.IO.FileAccess.Read, System.IO.FileShare.ReadWrite | System.IO.FileShare.Delete))
            using (System.IO.MemoryStream memory = new System.IO.MemoryStream())
            {
                input.CopyTo(memory);
                bytes = memory.ToArray();
            }

            string text = Encoding.UTF8.GetString(bytes);
            MatchCollection matches = Regex.Matches(text, @"(?i)(?:https?|file)://[^\x00-\x20\x7f""'<>]+");
            HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (Match match in matches)
            {
                string url = match.Value.TrimEnd(')', ']', '}', '.', ',', ';');
                if (!IsRestorableUrl(url)) continue;
                if (url.Length > 2048) continue;
                if (!seen.Add(url)) continue;
                ChromiumHistoryEntry entry = new ChromiumHistoryEntry();
                entry.Url = url;
                entry.Title = "";
                entry.LastVisit = DateTime.UtcNow;
                result.Add(entry);
                if (result.Count >= max) break;
            }
            return result;
        }

        private static string ColumnText(IntPtr stmt, int column)
        {
            IntPtr pointer = sqlite3_column_text(stmt, column);
            if (pointer == IntPtr.Zero) return "";
            int length = sqlite3_column_bytes(stmt, column);
            if (length <= 0) return "";
            byte[] bytes = new byte[length];
            Marshal.Copy(pointer, bytes, 0, length);
            return Encoding.UTF8.GetString(bytes);
        }

        private static bool IsRestorableUrl(string url)
        {
            if (String.IsNullOrWhiteSpace(url)) return false;
            if (!(url.StartsWith("http://", StringComparison.OrdinalIgnoreCase) ||
                  url.StartsWith("https://", StringComparison.OrdinalIgnoreCase) ||
                  url.StartsWith("file://", StringComparison.OrdinalIgnoreCase))) return false;
            if (url.StartsWith("http://localhost", StringComparison.OrdinalIgnoreCase) && url.Length < 24) return false;
            return true;
        }
    }
}
'@ -ReferencedAssemblies $uiaReferences -ErrorAction Stop
    } catch {
        # UI Automation or winsqlite3 is unavailable. Session files remain the
        # primary source and the rest of Session Recovery keeps working.
    }
}

# ---------------------------------------------------------------------------
# Paths, configuration and logging
# ---------------------------------------------------------------------------

$script:SRRoot = if ($env:SESSIONRECOVERY_HOME) {
    $env:SESSIONRECOVERY_HOME
} else {
    Join-Path $env:LOCALAPPDATA 'SessionRecovery'
}

$script:SRSnapshotDir = Join-Path $script:SRRoot 'snapshots'
$script:SRLogDir = Join-Path $script:SRRoot 'logs'
$script:SRConfigPath = Join-Path $script:SRRoot 'config.json'
$script:SRInstallIdPath = Join-Path $script:SRRoot 'installation.id'
$script:SRInstallationId = $null

function Get-SRRoot { $script:SRRoot }
function Get-SRSnapshotDirectory { $script:SRSnapshotDir }
function Get-SRLogDirectory { $script:SRLogDir }
function Get-SRConfigPath { $script:SRConfigPath }

function Get-SRInstallationId {
    # Snapshots carry this per-install ID as provenance. A file that was
    # copied into the snapshot folder by hand, imported from another PC or
    # created by a previous install has no matching ID and is treated as
    # untrusted at restore time. The ID is not a secret; it only separates
    # snapshots this installation created from everything else.
    if (-not [string]::IsNullOrWhiteSpace($script:SRInstallationId)) {
        return [string]$script:SRInstallationId
    }
    $candidate = ''
    try {
        if (Test-Path -LiteralPath $script:SRInstallIdPath -PathType Leaf) {
            $candidate = ([string](Get-Content -LiteralPath $script:SRInstallIdPath -Raw -ErrorAction Stop)).Trim()
        }
    } catch {
        Write-SRLog -Level WARN -Message ("Could not read the installation ID: {0}" -f $_.Exception.Message)
    }
    if ($candidate -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        $script:SRInstallationId = $candidate.ToLowerInvariant()
        return [string]$script:SRInstallationId
    }
    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
        Write-SRLog -Level WARN -Message 'The installation ID file was invalid; a new ID will be created.'
    }
    $created = [guid]::NewGuid().ToString('D')
    $persisted = $false
    try {
        $parent = Split-Path -Parent $script:SRInstallIdPath
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($script:SRInstallIdPath, $created, (New-Object System.Text.UTF8Encoding($false)))
        $persisted = $true
    } catch {
        Write-SRLog -Level WARN -Message ("Could not persist the installation ID: {0}" -f $_.Exception.Message)
    }
    $script:SRInstallationId = $created
    if ($persisted) {
        # First run after upgrading from a version that did not track
        # provenance: adopt the snapshots already on disk so a crash restore
        # right after the update is not greeted by the untrusted-snapshot
        # prompt for the user's own files. Anything dropped into the folder
        # later still has no provenance and stays untrusted.
        try { Update-SRLegacySnapshotProvenance -InstallationId $created } catch {
            Write-SRLog -Level WARN -Message ("Could not adopt existing snapshots: {0}" -f $_.Exception.Message)
        }
    }
    return $created
}

function Update-SRLegacySnapshotProvenance {
    # One-time adoption of snapshots written before provenance was tracked
    # (2.6.1 and earlier): they receive the freshly created installation ID
    # so an upgrade does not prompt on the user's own snapshots. Deliberately
    # imported files keep their untrusted marker, and each file is rewritten
    # in its original plain / gzip / DPAPI format.
    param([Parameter(Mandatory = $true)][string]$InstallationId)
    if (-not (Test-Path -LiteralPath $script:SRSnapshotDir -PathType Container)) { return }
    $adopted = 0
    foreach ($file in @(Get-SRSnapshotFiles)) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
            $encrypted = ($bytes.Length -ge 5 -and $bytes[0] -eq 0x53 -and $bytes[1] -eq 0x52 -and $bytes[2] -eq 0x44 -and $bytes[3] -eq 0x50 -and $bytes[4] -eq 0x31)
            $inner = if ($encrypted) { Unprotect-SRSnapshotBytes -Bytes $bytes } else { $bytes }
            $gzipped = ($inner.Length -ge 2 -and $inner[0] -eq 0x1F -and $inner[1] -eq 0x8B)
            $snapshot = Read-SRSnapshotFile -Path $file.FullName
            $importedProperty = $snapshot.PSObject.Properties['imported']
            if ($null -ne $importedProperty -and $null -ne $importedProperty.Value) {
                try { if ([bool]$importedProperty.Value) { continue } } catch { continue }
            }
            $provenanceProperty = $snapshot.PSObject.Properties['provenance']
            if ($null -ne $provenanceProperty -and $null -ne $provenanceProperty.Value) {
                $existingId = $provenanceProperty.Value.PSObject.Properties['installationId']
                if ($null -ne $existingId -and -not [string]::IsNullOrWhiteSpace([string]$existingId.Value)) { continue }
            }
            $snapshot | Add-Member -NotePropertyName provenance -NotePropertyValue ([pscustomobject]@{ format = 1; installationId = $InstallationId }) -Force
            # Same payload pipeline as Save-SRSnapshot: JSON -> gzip -> DPAPI.
            $json = $snapshot | ConvertTo-Json -Depth 12
            $payload = [System.Text.Encoding]::UTF8.GetBytes($json)
            if ($gzipped) {
                $plainStream = New-Object System.IO.MemoryStream (,$payload)
                $packed = New-Object System.IO.MemoryStream
                $gzipWriter = $null
                try {
                    $gzipWriter = New-Object System.IO.Compression.GZipStream($packed, [System.IO.Compression.CompressionLevel]::Optimal, $true)
                    $plainStream.CopyTo($gzipWriter)
                } finally {
                    if ($null -ne $gzipWriter) { $gzipWriter.Dispose() }
                    $plainStream.Dispose()
                }
                $payload = $packed.ToArray()
                $packed.Dispose()
            }
            if ($encrypted) { $payload = Protect-SRSnapshotBytes -Bytes $payload }
            [System.IO.File]::WriteAllBytes($file.FullName, $payload)
            $adopted++
        } catch {
            Write-SRLog -Level DEBUG -Message ("Could not adopt snapshot {0}: {1}" -f $file.Name, $_.Exception.Message)
        }
    }
    if ($adopted -gt 0) {
        Write-SRLog -Message ("Adopted {0} existing snapshot(s) written before provenance was tracked." -f $adopted)
    }
}

function Get-SRDefaultConfig {
    [pscustomobject][ordered]@{
        snapshotIntervalMinutes = 3
        keepSnapshots           = 48
        keepSnapshotDays        = 0
        promptOnLogon           = 'CrashOnly'
        maxRestoreAgeHours      = 72
        restoreBrowsers         = $true
        restoreWindowPositions  = $true
        defaultTabMode          = 'Smart'
        captureBrowserTabs      = $true
        captureApproximateTabs  = $true
        captureMediaPlayers     = $true
        tabHistoryLookbackHours = 24
        showNotifications       = $true
        startWithWindows        = $true
        desktopShortcut         = $true
        theme                   = 'Aurora'
        language                = 'en'
        pauseWhenIdleMinutes    = 15
        pauseOnFullscreen       = $true
        captureHotkey           = $true
        autoExportFolder        = ''
        captureThumbnails       = $false
        redactUrls              = $true
        compressSnapshots       = $false
        encryptSnapshots        = $false
        eventSnapshots          = $true
        captureDevWorkspaces    = $true
        restoreVirtualDesktops  = $true
        launchOrder             = @()
        appLaunchDelays         = @{}
        launchWaits             = @{}
        workspaces              = @()
        excludeApps             = @()
        excludeFolders          = @()
        excludeUrls             = @()
        pinnedSnapshots         = @()
        snapshotNotes           = @{}
    }
}

function ConvertTo-SRNoteTable {
    # Notes live in config.json keyed by snapshot file name. JSON turns the
    # hashtable into an object, so normalize both shapes before callers use it.
    param($Value)
    $table = @{}
    if ($null -eq $Value) { return $table }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            $name = [string]$key
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($name.Length -gt 260 -or $name -ne [System.IO.Path]::GetFileName($name)) { continue }
            $text = [string]$Value[$key]
            if ($null -eq $text) { $text = '' }
            $text = [regex]::Replace($text, '[\x00-\x08\x0B\x0C\x0E-\x1F]', '').Trim()
            if ($text.Length -gt 500) { $text = $text.Substring(0, 500) }
            if (-not [string]::IsNullOrWhiteSpace($text)) { $table[$name] = $text }
        }
        return $table
    }
    try {
        foreach ($property in @($Value.PSObject.Properties)) {
            $name = [string]$property.Name
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($name.Length -gt 260 -or $name -ne [System.IO.Path]::GetFileName($name)) { continue }
            $text = [string]$property.Value
            $text = [regex]::Replace($text, '[\x00-\x08\x0B\x0C\x0E-\x1F]', '').Trim()
            if ($text.Length -gt 500) { $text = $text.Substring(0, 500) }
            if (-not [string]::IsNullOrWhiteSpace($text)) { $table[$name] = $text }
        }
    } catch { }
    return $table
}

function Get-SRConfig {
    $defaults = Get-SRDefaultConfig
    if (-not (Test-Path -LiteralPath $script:SRConfigPath)) { return $defaults }
    try {
        $saved = Get-Content -LiteralPath $script:SRConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($property in $defaults.PSObject.Properties) {
            $value = $null
            $savedProperty = $saved.PSObject.Properties[$property.Name]
            if ($null -ne $savedProperty) { $value = $savedProperty.Value }
            if ($null -eq $value) { $value = $property.Value }
            $defaults.($property.Name) = $value
        }
        $savedNotes = $saved.PSObject.Properties['snapshotNotes']
        if ($null -ne $savedNotes) {
            $defaults.snapshotNotes = ConvertTo-SRNoteTable -Value $savedNotes.Value
        } else {
            $defaults.snapshotNotes = @{}
        }
    } catch {
        Write-SRLog -Level WARN -Message "Could not read config: $($_.Exception.Message)"
    }
    return $defaults
}

function Save-SRConfig {
    param([Parameter(Mandatory = $true)]$Config)
    $parent = Split-Path -Parent $script:SRConfigPath
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $json = $Config | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($script:SRConfigPath, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-SRLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO'
    )
    try {
        if (-not (Test-Path -LiteralPath $script:SRLogDir)) {
            New-Item -ItemType Directory -Path $script:SRLogDir -Force | Out-Null
        }
        $logPath = Join-Path $script:SRLogDir 'session-recovery.log'
        if ((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -gt 1MB) {
            $oldPath = Join-Path $script:SRLogDir 'session-recovery.old.log'
            Remove-Item -LiteralPath $oldPath -Force -ErrorAction SilentlyContinue
            Move-Item -LiteralPath $logPath -Destination $oldPath -Force -ErrorAction SilentlyContinue
        }
        $line = '{0:yyyy-MM-dd HH:mm:ss.fff} [{1}] {2}' -f (Get-Date), $Level, $Message
        [System.IO.File]::AppendAllText($logPath, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        # Logging must never take down the snapshot or restore path.
    }
}

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------

function Get-SRProcessMap {
    $map = @{}
    try {
        foreach ($process in Get-CimInstance Win32_Process -ErrorAction Stop) {
            $map[[int]$process.ProcessId] = $process
        }
    } catch {
        Write-SRLog -Level WARN -Message "Could not enumerate processes: $($_.Exception.Message)"
    }
    return $map
}

function Get-SRAppPath {
    # Reading App Paths through the registry provider is slow because it loads
    # the provider for every lookup. Direct registry access keeps diagnostics
    # and browser capture quick even when several browsers are installed.
    param([Parameter(Mandatory = $true)][string]$ExeName)
    if ([string]::IsNullOrWhiteSpace($ExeName)) { return $null }
    $subKey = 'SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\' + $ExeName
    $locations = @(
        @{ Hive = [Microsoft.Win32.RegistryHive]::CurrentUser; View = [Microsoft.Win32.RegistryView]::Default },
        @{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; View = [Microsoft.Win32.RegistryView]::Default },
        @{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; View = [Microsoft.Win32.RegistryView]::Registry32 }
    )
    foreach ($location in $locations) {
        $base = $null
        $key = $null
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($location.Hive, $location.View)
            $key = $base.OpenSubKey($subKey)
            if ($null -eq $key) { continue }
            $value = [string]$key.GetValue('')
            if (-not [string]::IsNullOrWhiteSpace($value) -and (Test-Path -LiteralPath $value)) {
                return $value
            }
        } catch {
        } finally {
            if ($null -ne $key) { try { $key.Dispose() } catch { } }
            if ($null -ne $base) { try { $base.Dispose() } catch { } }
        }
    }
    return $null
}

function Get-SRLogonTime {
    try {
        $sessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
        $explorers = @(Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessionId })
        if ($explorers.Count -gt 0) {
            $earliest = $explorers | Sort-Object -Property StartTime | Select-Object -First 1
            return $earliest.StartTime
        }
    } catch { }
    try {
        return (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    } catch { }
    return (Get-Date).AddHours(-1)
}

function Get-SRFileBytes {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
    try {
        $memory = New-Object System.IO.MemoryStream
        $stream.CopyTo($memory)
        return $memory.ToArray()
    } finally {
        $stream.Dispose()
    }
}

function Test-SRRestorableUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    return ($Url -match '^(?i)(https?|file)://')
}

function Test-SRPatternMatch {
    param(
        [string[]]$Patterns,
        [string[]]$Values
    )
    foreach ($pattern in @($Patterns)) {
        if ([string]::IsNullOrWhiteSpace([string]$pattern)) { continue }
        foreach ($value in @($Values)) {
            if ([string]::IsNullOrWhiteSpace([string]$value)) { continue }
            if ([string]$value -like [string]$pattern) { return $true }
        }
    }
    return $false
}

function Test-SRLocalFixedPath {
    # Restore must never launch an executable from a network share or a
    # removable/remote device. Parse the path before touching the file system
    # so a UNC path cannot trigger a network connection during validation.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'The program path is empty.' }
    }
    $value = $Path.Trim()
    if ($value -match '^[\\/]{2}') {
        return [pscustomobject]@{ Ok = $false; Reason = 'Network and device paths cannot be restored.' }
    }
    try {
        $full = [System.IO.Path]::GetFullPath($value)
        $root = [System.IO.Path]::GetPathRoot($full)
    } catch {
        return [pscustomobject]@{ Ok = $false; Reason = 'The program path is not valid.' }
    }
    if ([string]::IsNullOrWhiteSpace($root) -or $root -notmatch '^[A-Za-z]:\\$') {
        return [pscustomobject]@{ Ok = $false; Reason = 'Only local fixed drives can be restored.' }
    }
    try {
        $drive = New-Object System.IO.DriveInfo($root)
        if ($drive.DriveType -ne [System.IO.DriveType]::Fixed) {
            return [pscustomobject]@{ Ok = $false; Reason = ('Only local fixed drives can be restored; {0} is {1}.' -f $root, $drive.DriveType) }
        }
    } catch {
        return [pscustomobject]@{ Ok = $false; Reason = 'The drive could not be verified as a local fixed drive.' }
    }
    return [pscustomobject]@{ Ok = $true; Reason = '' }
}

function Test-SRRestoreExecutable {
    param([string]$Path)
    # Snapshots are user data and imported snapshots can come from another PC,
    # so restore must not trust the saved executable or its arguments. Only
    # ordinary .exe programs on local fixed drives are launched, and script
    # hosts / interpreters / living-off-the-land binaries that turn a path or
    # URL argument into code or a download are rejected.
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'The program path is empty.' }
    }
    try {
        $extension = [System.IO.Path]::GetExtension($Path)
        $leaf = [System.IO.Path]::GetFileNameWithoutExtension($Path).ToLowerInvariant()
    } catch {
        return [pscustomobject]@{ Ok = $false; Reason = 'The program path is not valid.' }
    }
    if ($extension -ne '.exe') {
        return [pscustomobject]@{ Ok = $false; Reason = 'Only .exe programs can be restored.' }
    }
    $localPath = Test-SRLocalFixedPath -Path $Path
    if (-not $localPath.Ok) {
        return [pscustomobject]@{ Ok = $false; Reason = $localPath.Reason }
    }
    # Explorer is on the list as well: it opens any path argument with the
    # registered default handler, which turns one argument into arbitrary
    # execution. Folder restore does not go through this filter; it opens
    # folders with Explorer directly from its own checked folder list.
    $blocked = @(
        'mshta', 'wscript', 'cscript', 'powershell', 'powershell_ise', 'pwsh', 'cmd',
        'conhost', 'explorer', 'rundll32', 'regsvr32', 'msiexec', 'wmic', 'forfiles',
        'installutil', 'regasm', 'regsvcs', 'csc', 'msbuild', 'hh',
        'pcalua', 'msdt', 'wsl', 'bash', 'mintty', 'wt', 'windowsterminal',
        'openconsole', 'scriptrunner', 'python', 'pythonw', 'node', 'java', 'javaw',
        'certutil', 'certreq', 'bitsadmin', 'makecab', 'expand', 'extrac32',
        'curl', 'wget', 'ftp', 'tftp', 'telnet', 'ssh', 'scp', 'sftp', 'nc', 'ncat', 'netcat',
        'reg', 'regedit', 'sc', 'schtasks', 'taskkill', 'tasklist', 'net', 'net1', 'netsh',
        'attrib', 'icacls', 'takeown', 'cacls', 'bcdedit', 'diskpart', 'format',
        'mountvol', 'vssadmin', 'wbadmin', 'wevtutil', 'wusa', 'dism', 'psexec', 'procdump'
    )
    if ($blocked -contains $leaf) {
        return [pscustomobject]@{ Ok = $false; Reason = ("Script host, interpreter or system tool blocked: {0}.exe" -f $leaf) }
    }
    return [pscustomobject]@{ Ok = $true; Reason = '' }
}

function Test-SRRestoreArgumentList {
    param([string[]]$Arguments)
    # Applies the same rules as capture-time Get-SRSafeArguments, but to the
    # argument array stored in a snapshot. It runs on every restore, so a
    # tampered or imported file cannot smuggle command-line switches through.
    $safe = New-Object System.Collections.Generic.List[string]
    foreach ($argument in @($Arguments)) {
        if ($null -eq $argument) { return [pscustomobject]@{ Ok = $false; Reason = 'The program has an empty argument.'; Arguments = @() } }
        $value = [string]$argument
        if ([string]::IsNullOrWhiteSpace($value)) {
            return [pscustomobject]@{ Ok = $false; Reason = 'The program has an empty argument.'; Arguments = @() }
        }
        if ($value.Length -gt 2048) {
            return [pscustomobject]@{ Ok = $false; Reason = 'The program has an argument that is too long.'; Arguments = @() }
        }
        if ($value -match '[\x00-\x1F\x7F]') {
            return [pscustomobject]@{ Ok = $false; Reason = 'The program has an argument with control characters.'; Arguments = @() }
        }
        if ($value -match '^-' -or $value -match '^/') {
            return [pscustomobject]@{ Ok = $false; Reason = ('Unsafe command-line switch: {0}' -f $value); Arguments = @() }
        }
        if ($value -match '^(?i)https?://') {
            $safe.Add($value)
            continue
        }
        # Path arguments must stay on local fixed drives, and the drive check
        # runs before Test-Path so a network path never triggers a connection
        # just to be rejected.
        $argumentDrive = Test-SRLocalFixedPath -Path $value
        if (-not $argumentDrive.Ok) {
            return [pscustomobject]@{ Ok = $false; Reason = ('Unsafe argument: {0} ({1})' -f $value, $argumentDrive.Reason); Arguments = @() }
        }
        if (Test-Path -LiteralPath $value) {
            $safe.Add($value)
            continue
        }
        return [pscustomobject]@{ Ok = $false; Reason = ('Unsafe argument: {0}' -f $value); Arguments = @() }
    }
    if ($safe.Count -gt 8) {
        return [pscustomobject]@{ Ok = $false; Reason = 'The program has too many arguments.'; Arguments = @() }
    }
    return [pscustomobject]@{ Ok = $true; Reason = ''; Arguments = $safe.ToArray() }
}

function Get-SRSafeArguments {
    param(
        [string]$CommandLine,
        [string]$ExePath
    )
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return @() }
    try {
        $parts = @([SessionRecovery.CommandLineSplitter]::Split($CommandLine))
    } catch {
        return @()
    }
    if ($parts.Count -le 1) { return @() }

    $result = Test-SRRestoreArgumentList -Arguments @($parts[1..($parts.Count - 1)])
    if (-not $result.Ok) { return @() }
    return $result.Arguments
}

function Start-SRDetached {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [ValidateSet('Normal', 'Minimized', 'Maximized')][string]$WindowStyle = 'Normal'
    )
    if (-not (Test-Path -LiteralPath $FilePath)) {
        throw "Executable not found: $FilePath"
    }

    $quoted = foreach ($argument in $Arguments) {
        if ($null -eq $argument) { continue }
        $clean = [string]$argument
        $clean = $clean.Replace('"', '\"')
        '"' + $clean + '"'
    }

    $styleValue = [System.Diagnostics.ProcessWindowStyle]::Normal
    switch ($WindowStyle) {
        'Minimized' { $styleValue = [System.Diagnostics.ProcessWindowStyle]::Minimized }
        'Maximized' { $styleValue = [System.Diagnostics.ProcessWindowStyle]::Maximized }
    }

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $FilePath
    $info.Arguments = ($quoted -join ' ')
    $info.UseShellExecute = $true
    $info.WindowStyle = $styleValue
    return [System.Diagnostics.Process]::Start($info)
}

function Get-SRWindowPlacement {
    param([Parameter(Mandatory = $true)]$App)
    # Snapshots from releases before 2.2 have no restore block; treat those
    # as "no known position" rather than failing under StrictMode.
    $property = $App.PSObject.Properties['restore']
    if ($null -eq $property -or $null -eq $property.Value) { return $null }
    $value = $property.Value
    $x = 0; $y = 0; $width = 0; $height = 0
    try { $x = [int]$value.x } catch { return $null }
    try { $y = [int]$value.y } catch { return $null }
    try { $width = [int]$value.width } catch { return $null }
    try { $height = [int]$value.height } catch { return $null }
    $maximized = $false
    try { $maximized = [bool]$value.maximized } catch { }
    if ($width -lt 80 -or $height -lt 40) { return $null }
    return [pscustomobject]@{ X = $x; Y = $y; Width = $width; Height = $height; Maximized = $maximized }
}

function Start-SRApplication {
    param(
        [Parameter(Mandatory = $true)]$App,
        [switch]$Force,
        $SnapshotMonitors = $null
    )
    $exePath = [string]$App.exe
    $appName = [string]$App.name
    if ([string]::IsNullOrWhiteSpace($appName)) { $appName = [System.IO.Path]::GetFileName($exePath) }

    # Validate the path before Test-Path: a UNC program path must never reach
    # the network just to discover that it is blocked.
    $executableCheck = Test-SRRestoreExecutable -Path $exePath
    if (-not $executableCheck.Ok) {
        return [pscustomobject]@{ Started = $false; Message = ("Blocked unsafe program {0}: {1}" -f $appName, $executableCheck.Reason); App = $App }
    }
    if (-not $exePath -or -not (Test-Path -LiteralPath $exePath)) {
        return [pscustomobject]@{ Started = $false; Message = "Missing executable: $exePath"; App = $App }
    }

    # Never replay terminal/shell windows. A saved cmd.exe or PowerShell
    # window can flash a console during a restore and looks suspicious.
    $consoleHosts = @('cmd', 'powershell', 'pwsh', 'conhost', 'wsl', 'wt', 'windowsterminal', 'openconsole', 'bash', 'mintty')
    $leaf = [System.IO.Path]::GetFileNameWithoutExtension($exePath).ToLowerInvariant()
    $appNameLower = $appName.ToLowerInvariant()
    if ($consoleHosts -contains $leaf -or $consoleHosts -contains $appNameLower) {
        return [pscustomobject]@{ Started = $false; Message = "Skipped console window: $appName"; App = $App }
    }

    $argumentsProperty = $App.PSObject.Properties['args']
    $savedArguments = if ($null -ne $argumentsProperty -and $null -ne $argumentsProperty.Value) { @($argumentsProperty.Value) } else { @() }
    $argumentCheck = Test-SRRestoreArgumentList -Arguments $savedArguments
    if (-not $argumentCheck.Ok) {
        return [pscustomobject]@{ Started = $false; Message = ("Skipped unsafe arguments for {0}: {1}" -f $appName, $argumentCheck.Reason); App = $App }
    }

    if (-not $Force) {
        $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            try { $_.Path -and ($_.Path -ieq $exePath) } catch { $false }
        })
        if ($running.Count -gt 0) {
            return [pscustomobject]@{ Started = $false; Message = "Already running: $appName"; App = $App }
        }
    }

    $windowStyle = if ($App.startMinimized) { 'Minimized' } else { 'Normal' }
    try {
        # A captured media entry (playing video) replaces the plain command
        # line so the player reopens the same file at the saved position.
        $launchArguments = @($argumentCheck.Arguments)
        $mediaProperty = $App.PSObject.Properties['media']
        if ($null -ne $mediaProperty -and $null -ne $mediaProperty.Value) {
            $mediaArguments = Get-SRMediaLaunchArguments -ExePath $exePath -Media $mediaProperty.Value
            if ($null -ne $mediaArguments) { $launchArguments = $mediaArguments }
        }
        $process = Start-SRDetached -FilePath $exePath -Arguments $launchArguments -WindowStyle $windowStyle
        $placeWindows = $true
        try {
            $config = Get-SRConfig
            $placeProperty = $config.PSObject.Properties['restoreWindowPositions']
            if ($null -ne $placeProperty) { $placeWindows = [bool]$placeProperty.Value }
        } catch { }
        if ($placeWindows -and -not $App.startMinimized -and $null -ne $process -and ('SessionRecovery.WindowPlacer' -as [type])) {
            $placement = Get-SRWindowPlacement -App $App
            if ($null -ne $placement) {
                # Translate the captured position into the current monitor
                # layout (an undocked laptop keeps its windows proportionally).
                $placement = ConvertTo-SRScreenPlacement -Placement $placement -SnapshotMonitors $SnapshotMonitors
                [void][SessionRecovery.WindowPlacer]::QueueProcessWindow(
                    $process.Id, 6000, $placement.X, $placement.Y, $placement.Width, $placement.Height, $placement.Maximized)
            }
        }
        # Virtual desktop: put the window back on the desktop it was captured
        # on, when that desktop still exists. Best-effort and quiet on failure.
        if ($null -ne $process) {
            $desktopProperty = $App.PSObject.Properties['desktopId']
            if ($null -ne $desktopProperty -and -not [string]::IsNullOrWhiteSpace([string]$desktopProperty.Value)) {
                $restoreDesktops = $true
                try {
                    $configDesktops = Get-SRConfig
                    $restoreDesktopsProperty = $configDesktops.PSObject.Properties['restoreVirtualDesktops']
                    if ($null -ne $restoreDesktopsProperty) { $restoreDesktops = [bool]$restoreDesktopsProperty.Value }
                } catch { }
                if ($restoreDesktops -and (Get-SRVirtualDesktopHelper)) {
                    try {
                        [SessionRecovery.VirtualDesktop]::QueueMove([int]$process.Id, [string]$desktopProperty.Value, 8000)
                    } catch { }
                }
            }
        }
        return [pscustomobject]@{ Started = $true; Message = "Started: $appName"; App = $App }
    } catch {
        return [pscustomobject]@{ Started = $false; Message = "Failed to start ${appName}: $($_.Exception.Message)"; App = $App }
    }
}

function Open-SRFolder {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return [pscustomobject]@{ Started = $false; Message = "Missing folder: $Path" }
    }
    try {
        # The returned Process is only needed by Start-SRApplication; every
        # other caller must discard it or it leaks into the pipeline output.
        [void](Start-SRDetached -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -Arguments @($Path))
        return [pscustomobject]@{ Started = $true; Message = "Opened: $Path" }
    } catch {
        return [pscustomobject]@{ Started = $false; Message = "Failed to open ${Path}: $($_.Exception.Message)" }
    }
}

# ---------------------------------------------------------------------------
# Application and Explorer capture
# ---------------------------------------------------------------------------

function Get-SRApplications {
    param(
        [Parameter(Mandatory = $true)]$Windows,
        [Parameter(Mandatory = $true)]$ProcessMap
    )

    $blockedNames = @(
        'ApplicationFrameHost', 'RuntimeBroker', 'ShellExperienceHost',
        'StartMenuExperienceHost', 'SearchHost', 'SearchApp', 'TextInputHost',
        'LockApp', 'SecurityHealthSystray', 'SystemSettings', 'WidgetService',
        'Widgets', 'msedgewebview2', 'WebViewHost', 'MoUsoCoreWorker',
        'backgroundTaskHost', 'dwm', 'Explorer', 'cmd', 'powershell', 'pwsh',
        'conhost', 'WindowsTerminal', 'wt', 'OpenConsole', 'wsl', 'bash', 'mintty'
    )
    $blockedExeParts = @(
        '\Windows\System32\ApplicationFrameHost.exe',
        '\Windows\System32\RuntimeBroker.exe',
        '\Windows\System32\ShellExperienceHost.exe',
        '\Windows\System32\StartMenuExperienceHost.exe',
        '\Windows\System32\SearchHost.exe',
        '\Windows\System32\TextInputHost.exe',
        '\Windows\System32\LockApp.exe'
    )
    $browserNames = @('chrome', 'msedge', 'brave', 'vivaldi', 'opera', 'chromium', 'firefox', 'waterfox', 'librewolf')

    $groups = @{}

    foreach ($window in $Windows) {
        $processId = [int]$window.ProcessId
        $process = $ProcessMap[$processId]
        if ($null -eq $process) { continue }

        $processName = ([string]$process.Name) -replace '\.exe$', ''
        $exe = [string]$process.ExecutablePath
        if ([string]::IsNullOrWhiteSpace($exe)) { continue }
        if ($blockedNames -contains $processName) { continue }
        if ($browserNames -contains $processName.ToLowerInvariant()) { continue }

        $skip = $false
        foreach ($part in $blockedExeParts) {
            if ($exe -like ('*' + $part)) { $skip = $true; break }
        }
        if ($skip) { continue }

        $commandLine = [string]$process.CommandLine
        if ($commandLine -match '(?i)SessionRecovery|Save-Session\.ps1|Restore-Session\.ps1|Watch-Session\.ps1|Tray-SessionRecovery\.ps1|Install-SessionRecovery\.ps1|Uninstall-SessionRecovery\.ps1') { continue }

        # Our own hidden helper and shell host never need to be restored.
        if ($processName -in @('wscript', 'conhost')) { continue }

        $arguments = @(Get-SRSafeArguments -CommandLine $commandLine -ExePath $exe)
        $argumentKey = ($arguments -join [char]31)
        $key = ($exe.ToLowerInvariant() + [char]30 + $argumentKey)

        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = [pscustomobject]@{
                exe            = $exe
                name           = $processName
                args           = $arguments
                windows        = New-Object System.Collections.Generic.List[object]
                startMinimized = $true
            }
        }

        $entry = $groups[$key]
        $entry.windows.Add([pscustomobject]@{
            title     = [string]$window.Title
            minimized = [bool]$window.Minimized
            maximized = [bool]$window.Maximized
            x         = [int]$window.X
            y         = [int]$window.Y
            width     = [int]$window.Width
            height    = [int]$window.Height
        })
        if (-not $window.Minimized) { $entry.startMinimized = $false }
    }

    foreach ($entry in $groups.Values) {
        if ($entry.windows.Count -gt 0) { $entry.startMinimized = [bool]$entry.startMinimized }
        # Store a plain array. PowerShell 5.1's @() can throw an
        # "Argument types do not match" error for generic List<object> values.
        $entry.windows = $entry.windows.ToArray()

        # Remember where this application's main window lived. Prefer a
        # restored (non-minimized) window: minimized windows report the
        # -32000 placeholder position.
        $restoreSource = @($entry.windows | Where-Object {
            -not $_.minimized -and $_.width -gt 0 -and $_.height -gt 0
        } | Select-Object -First 1)
        if ($restoreSource.Count -eq 0) {
            $restoreSource = @($entry.windows | Where-Object { $_.width -gt 0 -and $_.height -gt 0 } | Select-Object -First 1)
        }
        if ($restoreSource.Count -gt 0) {
            $source = $restoreSource[0]
            $entry | Add-Member -NotePropertyName restore -NotePropertyValue ([pscustomobject]@{
                x         = [int]$source.x
                y         = [int]$source.y
                width     = [int]$source.width
                height    = [int]$source.height
                maximized = [bool]$source.maximized
            })
        }
    }

    return @($groups.Values | Sort-Object -Property name, exe)
}

function Get-SRExplorerFolders {
    param([Parameter(Mandatory = $true)]$Windows)

    $handles = @()
    foreach ($window in $Windows) {
        if (([string]$window.ProcessName).ToLowerInvariant() -eq 'explorer') {
            $handles += [int64]$window.Handle
        }
    }
    if ($handles.Count -eq 0) { return @() }

    $folders = New-Object System.Collections.Generic.List[string]
    $shell = $null
    try {
        $shell = New-Object -ComObject Shell.Application
        foreach ($explorerWindow in @($shell.Windows())) {
            try {
                $hwnd = [int64]$explorerWindow.HWND
                if ($handles -notcontains $hwnd) { continue }

                $path = $null
                try {
                    $path = [string]$explorerWindow.Document.Folder.Self.Path
                } catch { }

                if ([string]::IsNullOrWhiteSpace($path)) {
                    try {
                        $location = [string]$explorerWindow.LocationURL
                        if ($location -like 'file:///*') {
                            $path = ([System.Uri]$location).LocalPath
                        }
                    } catch { }
                }

                if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path -PathType Container)) {
                    if (-not $folders.Contains($path)) { $folders.Add($path) }
                }
            } catch { }
        }
    } catch {
        Write-SRLog -Level WARN -Message "Could not read Explorer windows: $($_.Exception.Message)"
    } finally {
        if ($null -ne $shell) {
            try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } catch { }
        }
    }
    return $folders.ToArray()
}

# ---------------------------------------------------------------------------
# Browser discovery and tab capture
# ---------------------------------------------------------------------------

function Get-SRBrowserDefinitions {
    $programFiles = $env:ProgramFiles
    $programFilesX86 = ${env:ProgramFiles(x86)}
    $localAppData = $env:LOCALAPPDATA
    $roaming = $env:APPDATA

    return @(
        [pscustomobject]@{
            key          = 'chrome'
            name         = 'Google Chrome'
            processNames = @('chrome')
            kind         = 'chromium'
            userDataDir  = (Join-Path $localAppData 'Google\Chrome\User Data')
            candidates   = @(
                (Join-Path $programFiles 'Google\Chrome\Application\chrome.exe'),
                (Join-Path $programFilesX86 'Google\Chrome\Application\chrome.exe'),
                (Join-Path $localAppData 'Google\Chrome\Application\chrome.exe')
            )
        },
        [pscustomobject]@{
            key          = 'edge'
            name         = 'Microsoft Edge'
            processNames = @('msedge')
            kind         = 'chromium'
            userDataDir  = (Join-Path $localAppData 'Microsoft\Edge\User Data')
            candidates   = @(
                (Join-Path $programFilesX86 'Microsoft\Edge\Application\msedge.exe'),
                (Join-Path $programFiles 'Microsoft\Edge\Application\msedge.exe'),
                (Join-Path $localAppData 'Microsoft\Edge\Application\msedge.exe')
            )
        },
        [pscustomobject]@{
            key          = 'brave'
            name         = 'Brave'
            processNames = @('brave')
            kind         = 'chromium'
            userDataDir  = (Join-Path $localAppData 'BraveSoftware\Brave-Browser\User Data')
            candidates   = @(
                (Join-Path $programFiles 'BraveSoftware\Brave-Browser\Application\brave.exe'),
                (Join-Path $programFilesX86 'BraveSoftware\Brave-Browser\Application\brave.exe'),
                (Join-Path $localAppData 'BraveSoftware\Brave-Browser\Application\brave.exe')
            )
        },
        [pscustomobject]@{
            key          = 'vivaldi'
            name         = 'Vivaldi'
            processNames = @('vivaldi')
            kind         = 'chromium'
            userDataDir  = (Join-Path $localAppData 'Vivaldi\User Data')
            candidates   = @(
                (Join-Path $localAppData 'Vivaldi\Application\vivaldi.exe'),
                (Join-Path $programFiles 'Vivaldi\Application\vivaldi.exe'),
                (Join-Path $programFilesX86 'Vivaldi\Application\vivaldi.exe')
            )
        },
        [pscustomobject]@{
            key                 = 'opera'
            name                = 'Opera'
            processNames        = @('opera')
            processPathPatterns = @('*\Opera\opera.exe')
            kind                = 'chromium'
            userDataDir         = (Join-Path $roaming 'Opera Software\Opera Stable')
            candidates   = @(
                (Join-Path $localAppData 'Programs\Opera\opera.exe'),
                (Join-Path $programFiles 'Opera\opera.exe'),
                (Join-Path $programFilesX86 'Opera\opera.exe')
            )
        },
        [pscustomobject]@{
            key                 = 'opera-gx'
            name                = 'Opera GX'
            processNames        = @('opera')
            processPathPatterns = @('*\Opera GX\opera.exe')
            kind                = 'chromium'
            userDataDir         = (Join-Path $roaming 'Opera Software\Opera GX Stable')
            candidates   = @(
                (Join-Path $localAppData 'Programs\Opera GX\opera.exe'),
                (Join-Path $programFiles 'Opera GX\opera.exe'),
                (Join-Path $programFilesX86 'Opera GX\opera.exe')
            )
        },
        [pscustomobject]@{
            key          = 'chromium'
            name         = 'Chromium'
            processNames = @('chromium')
            kind         = 'chromium'
            userDataDir  = (Join-Path $localAppData 'Chromium\User Data')
            candidates   = @(
                (Join-Path $localAppData 'Chromium\Application\chromium.exe'),
                (Join-Path $programFiles 'Chromium\Application\chromium.exe'),
                (Join-Path $programFilesX86 'Chromium\Application\chromium.exe')
            )
        },
        [pscustomobject]@{
            key          = 'firefox'
            name         = 'Mozilla Firefox'
            processNames = @('firefox')
            kind         = 'firefox'
            userDataDir  = (Join-Path $roaming 'Mozilla\Firefox')
            candidates   = @(
                (Join-Path $programFiles 'Mozilla Firefox\firefox.exe'),
                (Join-Path $programFilesX86 'Mozilla Firefox\firefox.exe'),
                (Join-Path $localAppData 'Mozilla Firefox\firefox.exe')
            )
        },
        [pscustomobject]@{
            key          = 'waterfox'
            name         = 'Waterfox'
            processNames = @('waterfox')
            kind         = 'firefox'
            userDataDir  = (Join-Path $roaming 'Waterfox')
            candidates   = @(
                (Join-Path $programFiles 'Waterfox\waterfox.exe'),
                (Join-Path $programFilesX86 'Waterfox\waterfox.exe'),
                (Join-Path $localAppData 'Waterfox\waterfox.exe')
            )
        },
        [pscustomobject]@{
            key          = 'librewolf'
            name         = 'LibreWolf'
            processNames = @('librewolf')
            kind         = 'firefox'
            userDataDir  = (Join-Path $roaming 'LibreWolf')
            candidates   = @(
                (Join-Path $programFiles 'LibreWolf\librewolf.exe'),
                (Join-Path $programFilesX86 'LibreWolf\librewolf.exe'),
                (Join-Path $localAppData 'LibreWolf\librewolf.exe')
            )
        }
    )
}

function Test-SRBrowserProcess {
    param(
        [Parameter(Mandatory = $true)]$Definition,
        $Process
    )
    if ($null -eq $Process) { return $false }

    $processName = (([string]$Process.Name) -replace '\.exe$', '').ToLowerInvariant()
    if (@($Definition.processNames) -notcontains $processName) { return $false }

    # Opera and Opera GX both run as opera.exe. Their installation paths are
    # the only reliable way to tell two simultaneously running browsers apart.
    $patterns = @()
    $patternProperty = $Definition.PSObject.Properties['processPathPatterns']
    if ($null -ne $patternProperty) { $patterns = @($patternProperty.Value) }
    if ($patterns.Count -eq 0) { return $true }

    $path = [string]$Process.ExecutablePath
    if ([string]::IsNullOrWhiteSpace($path)) { return $true }
    foreach ($pattern in $patterns) {
        if ($path -like [string]$pattern) { return $true }
    }
    return $false
}

function Get-SRShortcutTarget {
    param([Parameter(Mandatory = $true)][string]$ShortcutPath)
    $shell = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($ShortcutPath)
        $target = [string]$shortcut.TargetPath
        if (-not [string]::IsNullOrWhiteSpace($target) -and (Test-Path -LiteralPath $target)) { return $target }
    } catch {
    } finally {
        if ($null -ne $shell) { try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } catch { } }
    }
    return $null
}

function Resolve-SRBrowserFromShortcuts {
    # Some browsers install to unusual folders with no registry entry. Their
    # Start Menu shortcut is then the only reliable pointer to the exe.
    param([Parameter(Mandatory = $true)]$Definition)

    $nameHints = @()
    foreach ($processName in @($Definition.processNames)) {
        $hint = [System.IO.Path]::GetFileNameWithoutExtension($processName)
        if ($nameHints -notcontains $hint) { $nameHints += $hint }
    }
    $patterns = @()
    $patternProperty = $Definition.PSObject.Properties['processPathPatterns']
    if ($null -ne $patternProperty) { $patterns = @($patternProperty.Value) }

    $menuRoots = @(
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs')
    )
    foreach ($root in $menuRoots) {
        if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root)) { continue }
        $links = @()
        try {
            $links = @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.lnk' -File -ErrorAction SilentlyContinue)
        } catch { continue }
        foreach ($link in $links) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($link.Name)
            $nameMatch = $false
            foreach ($hint in $nameHints) {
                if ($base -like ('*' + $hint + '*')) { $nameMatch = $true; break }
            }
            if (-not $nameMatch) { continue }
            $target = Get-SRShortcutTarget -ShortcutPath $link.FullName
            if ([string]::IsNullOrWhiteSpace($target)) { continue }
            # Opera and Opera GX both run opera.exe; keep the shortcut that
            # matches this definition's install folder.
            if ($patterns.Count -gt 0) {
                $pathMatch = $false
                foreach ($pattern in $patterns) {
                    if ($target -like [string]$pattern) { $pathMatch = $true; break }
                }
                if (-not $pathMatch) { continue }
            }
            return $target
        }
    }
    return $null
}

function Resolve-SRBrowserExe {
    param(
        [Parameter(Mandatory = $true)]$Definition,
        $ProcessMap
    )

    if ($null -ne $ProcessMap) {
        foreach ($process in $ProcessMap.Values) {
            if (Test-SRBrowserProcess -Definition $Definition -Process $process) {
                $path = [string]$process.ExecutablePath
                if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path)) {
                    return $path
                }
            }
        }
    }

    foreach ($candidate in $Definition.candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }

    $exeName = $Definition.processNames[0] + '.exe'
    $value = Get-SRAppPath -ExeName $exeName
    if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }

    $fromShortcut = Resolve-SRBrowserFromShortcuts -Definition $Definition
    if (-not [string]::IsNullOrWhiteSpace($fromShortcut)) { return $fromShortcut }
    return $null
}

function Get-SRChromiumProfileNamesInUse {
    param(
        [Parameter(Mandatory = $true)]$Definition,
        [Parameter(Mandatory = $true)]$ProcessMap
    )

    $names = New-Object System.Collections.Generic.List[string]
    foreach ($process in $ProcessMap.Values) {
        if (-not (Test-SRBrowserProcess -Definition $Definition -Process $process)) { continue }
        $commandLine = [string]$process.CommandLine
        if ($commandLine -match '--profile-directory=(?:"([^"]+)"|([^\s]+))') {
            $value = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
            if (-not [string]::IsNullOrWhiteSpace($value) -and -not $names.Contains($value)) { $names.Add($value) }
        }
    }
    return $names.ToArray()
}

function Get-SRChromiumUserDataDir {
    param(
        [Parameter(Mandatory = $true)]$Definition,
        [Parameter(Mandatory = $true)]$ProcessMap
    )

    foreach ($process in $ProcessMap.Values) {
        if (-not (Test-SRBrowserProcess -Definition $Definition -Process $process)) { continue }
        $commandLine = [string]$process.CommandLine
        if ($commandLine -match '--user-data-dir=(?:"([^"]+)"|([^\s]+))') {
            $value = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
            if (-not [string]::IsNullOrWhiteSpace($value) -and (Test-Path -LiteralPath $value)) { return $value }
        }
    }
    return $Definition.userDataDir
}

function Get-SRChromiumRestoreOnStartup {
    param([Parameter(Mandatory = $true)][string]$ProfileDirectory)
    $paths = @(
        (Join-Path $ProfileDirectory 'Preferences'),
        (Join-Path $ProfileDirectory 'Secure Preferences')
    )
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try {
            $json = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($null -ne $json.session -and $null -ne $json.session.restore_on_startup) {
                return [int]$json.session.restore_on_startup
            }
        } catch { }
    }
    return $null
}

function Get-SRTitleKey {
    param([string]$Title)
    if ([string]::IsNullOrWhiteSpace($Title)) { return '' }
    $value = $Title.Trim()
    $value = $value -replace '\s+-\s+(Google Chrome|Microsoft Edge|Brave|Opera GX|Opera|Vivaldi|Mozilla Firefox|Chromium)$', ''
    $value = $value -replace '\s+-\s+(Memory usage|Audio playing|Muted).*$', ''
    return $value.Trim().ToLowerInvariant()
}

function Get-SRChromiumHistoryTabs {
    param(
        [Parameter(Mandatory = $true)][string]$ProfileDirectory,
        [IntPtr]$WindowHandle = [IntPtr]::Zero,
        [datetime]$BrowserStartTime = [datetime]::MinValue,
        [int]$LookbackHours = 24,
        [bool]$AllowApproximate = $true
    )

    if (-not $AllowApproximate) {
        return [pscustomobject]@{ tabs = @(); source = 'none'; file = $null; fileAt = $null; approximate = $false }
    }
    if (-not ('SessionRecovery.ChromiumHistory' -as [type])) {
        return [pscustomobject]@{ tabs = @(); source = 'none'; file = $null; fileAt = $null; approximate = $false }
    }

    $lookback = [Math]::Max(1, $LookbackHours)
    $since = (Get-Date).AddHours(-$lookback)
    if ($BrowserStartTime -and $BrowserStartTime -ne [datetime]::MinValue) {
        $started = $BrowserStartTime.AddMinutes(-10)
        if ($started -gt $since) { $since = $started }
    }

    $history = @([SessionRecovery.ChromiumHistory]::ReadRecent($ProfileDirectory, $since, 100))
    if ($history.Count -eq 0) {
        return [pscustomobject]@{ tabs = @(); source = 'none'; file = $null; fileAt = $null; approximate = $false }
    }

    $ui = $null
    if ($WindowHandle -ne [IntPtr]::Zero -and ('SessionRecovery.BrowserUiAutomation' -as [type])) {
        try {
            $ui = [SessionRecovery.BrowserUiAutomation]::Read($WindowHandle, 1500)
        } catch {
            Write-SRLog -Level DEBUG -Message "UI Automation tab read failed: $($_.Exception.Message)"
        }
    }

    $uiTabs = @()
    if ($null -ne $ui) { $uiTabs = @($ui.Tabs) }
    $result = New-Object System.Collections.Generic.List[object]
    $used = New-Object 'System.Collections.Generic.HashSet[int]'
    $seenUrls = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    function Add-SRHistoryTab {
        param($HistoryEntry, [string]$FallbackTitle)
        if ($null -eq $HistoryEntry) { return $false }
        $url = [string]$HistoryEntry.Url
        if (-not (Test-SRRestorableUrl -Url $url)) { return $false }
        if (-not $seenUrls.Add($url)) { return $false }
        $title = [string]$HistoryEntry.Title
        if ([string]::IsNullOrWhiteSpace($title)) { $title = $FallbackTitle }
        $result.Add([pscustomobject]@{
            url      = $url
            title    = $title
            pinned   = $false
            windowId = 0
        })
        return $true
    }

    for ($i = 0; $i -lt $uiTabs.Count; $i++) {
        $uiTab = $uiTabs[$i]
        $key = Get-SRTitleKey -Title ([string]$uiTab.Title)
        $matchIndex = -1
        if (-not [string]::IsNullOrWhiteSpace($key)) {
            for ($j = 0; $j -lt $history.Count; $j++) {
                if ($used.Contains($j)) { continue }
                $historyKey = Get-SRTitleKey -Title ([string]$history[$j].Title)
                if ([string]::IsNullOrWhiteSpace($historyKey)) { continue }
                if ($historyKey -eq $key -or $historyKey.Contains($key) -or $key.Contains($historyKey)) {
                    $matchIndex = $j
                    break
                }
            }
        }
        if ($matchIndex -ge 0) {
            [void]$used.Add($matchIndex)
            [void](Add-SRHistoryTab -HistoryEntry $history[$matchIndex] -FallbackTitle ([string]$uiTab.Title))
            continue
        }

        if ($uiTab.Selected -and $null -ne $ui -and (Test-SRRestorableUrl -Url ([string]$ui.CurrentUrl))) {
            $current = [string]$ui.CurrentUrl
            for ($j = 0; $j -lt $history.Count; $j++) {
                if ($used.Contains($j)) { continue }
                if ([string]::Equals([string]$history[$j].Url, $current, [StringComparison]::OrdinalIgnoreCase)) {
                    [void]$used.Add($j)
                    [void](Add-SRHistoryTab -HistoryEntry $history[$j] -FallbackTitle ([string]$uiTab.Title))
                    break
                }
            }
        }
    }

    $target = if ($uiTabs.Count -gt 0) { $uiTabs.Count } else { [Math]::Min(12, $history.Count) }
    if ($target -lt 1) { $target = [Math]::Min(12, $history.Count) }
    if ($target -gt 40) { $target = 40 }
    for ($j = 0; $j -lt $history.Count -and $result.Count -lt $target; $j++) {
        if ($used.Contains($j)) { continue }
        [void]$used.Add($j)
        [void](Add-SRHistoryTab -HistoryEntry $history[$j] -FallbackTitle '')
    }

    if ($result.Count -eq 0) {
        for ($j = 0; $j -lt $history.Count -and $result.Count -lt 20; $j++) {
            [void](Add-SRHistoryTab -HistoryEntry $history[$j] -FallbackTitle '')
        }
    }

    if ($result.Count -eq 0) {
        return [pscustomobject]@{ tabs = @(); source = 'none'; file = $null; fileAt = $null; approximate = $false }
    }

    $historyPath = Join-Path $ProfileDirectory 'History'
    $historyAt = $null
    if (Test-Path -LiteralPath $historyPath) {
        $historyAt = (Get-Item -LiteralPath $historyPath).LastWriteTime
    }
    $source = if ($uiTabs.Count -gt 0) { 'uia-history' } else { 'history-fallback' }
    Write-SRLog -Level DEBUG -Message ("Chromium tab fallback for {0}: {1} tab(s) from {2}" -f $ProfileDirectory, $result.Count, $source)
    return [pscustomobject]@{
        tabs        = $result.ToArray()
        source      = $source
        file        = $historyPath
        fileAt      = $historyAt
        approximate = $true
    }
}

function Get-SRChromiumTabs {
    param(
        [Parameter(Mandatory = $true)][string]$ProfileDirectory,
        [IntPtr]$WindowHandle = [IntPtr]::Zero,
        [datetime]$BrowserStartTime = [datetime]::MinValue,
        [int]$HistoryLookbackHours = 24,
        [bool]$AllowApproximate = $true
    )

    $candidates = New-Object System.Collections.Generic.List[object]

    $sessionsDir = Join-Path $ProfileDirectory 'Sessions'
    if (Test-Path -LiteralPath $sessionsDir) {
        foreach ($file in @(Get-ChildItem -LiteralPath $sessionsDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'Session_*' -or $_.Name -like 'Tabs_*' })) {
            if ($file.Length -gt 0) { $candidates.Add($file) }
        }
    }

    foreach ($legacyName in @('Current Session', 'Last Session', 'Current Tabs', 'Last Tabs')) {
        $legacy = Join-Path $ProfileDirectory $legacyName
        if (Test-Path -LiteralPath $legacy) {
            $item = Get-Item -LiteralPath $legacy -ErrorAction SilentlyContinue
            if ($item -and $item.Length -gt 0) { $candidates.Add($item) }
        }
    }

    $ordered = @($candidates | Sort-Object -Property LastWriteTime -Descending)
    $fallback = $null

    foreach ($file in $ordered) {
        try {
            $bytes = Get-SRFileBytes -Path $file.FullName
            if ($null -eq $fallback) { $fallback = [pscustomobject]@{ File = $file; Bytes = $bytes } }

            $tabs = @([SessionRecovery.SessionFileReader]::Parse($bytes))
            $clean = New-Object System.Collections.Generic.List[object]
            foreach ($tab in $tabs) {
                if (-not (Test-SRRestorableUrl -Url $tab.Url)) { continue }
                $clean.Add([pscustomobject]@{
                    url      = [string]$tab.Url
                    title    = [string]$tab.Title
                    pinned   = [bool]$tab.Pinned
                    windowId = [int]$tab.WindowId
                })
            }
            if ($clean.Count -gt 0) {
                return [pscustomobject]@{
                    tabs        = $clean.ToArray()
                    source      = 'session-file'
                    file        = $file.FullName
                    fileAt      = $file.LastWriteTime
                    approximate = $false
                }
            }
        } catch {
            Write-SRLog -Level DEBUG -Message "Could not parse session file $($file.FullName): $($_.Exception.Message)"
        }
    }

    # Fallback for browser versions with a different session format. This is
    # intentionally limited: session files contain navigation history, so a
    # regex scan can include back/forward entries. It is only used when the
    # structured parser found no current tabs at all.
    if ($null -ne $fallback) {
        try {
            # Only trust the raw scan when the browser touched the file
            # recently. An old file can contain URLs from tabs that were
            # closed long ago.
            if ($fallback.File.LastWriteTime -lt (Get-Date).AddMinutes(-30)) { throw 'Session file is stale.' }
            $text = [System.Text.Encoding]::UTF8.GetString($fallback.Bytes)
            $matches = [regex]::Matches($text, '(?i)(?:https?|file)://[^\x00-\x20\x7f"''<>]+')
            $clean = New-Object System.Collections.Generic.List[object]
            $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($match in $matches) {
                $url = $match.Value.TrimEnd(')', ']', '}', '.', ',', ';')
                if (-not (Test-SRRestorableUrl -Url $url)) { continue }
                if ($seen.Add($url)) {
                    $clean.Add([pscustomobject]@{ url = $url; title = ''; pinned = $false; windowId = 0 })
                }
                if ($clean.Count -ge 80) { break }
            }
            if ($clean.Count -gt 0) {
                return [pscustomobject]@{
                    tabs        = $clean.ToArray()
                    source      = 'regex-fallback'
                    file        = $fallback.File.FullName
                    fileAt      = $fallback.File.LastWriteTime
                    approximate = $false
                }
            }
        } catch {
            Write-SRLog -Level DEBUG -Message "Regex tab fallback failed: $($_.Exception.Message)"
        }
    }

    # New Chromium session files can be zero bytes while the browser is
    # running. Keep the exact-session-file path above as the primary source;
    # only use live UI Automation + local History when that produced nothing.
    return Get-SRChromiumHistoryTabs -ProfileDirectory $ProfileDirectory `
        -WindowHandle $WindowHandle -BrowserStartTime $BrowserStartTime `
        -LookbackHours $HistoryLookbackHours -AllowApproximate $AllowApproximate
}

function Get-SRFirefoxDefaultProfiles {
    param([Parameter(Mandatory = $true)]$Definition)

    $profileRoot = Join-Path $Definition.userDataDir 'Profiles'
    $iniPath = Join-Path $Definition.userDataDir 'profiles.ini'
    $defaults = New-Object System.Collections.Generic.List[string]
    $all = New-Object System.Collections.Generic.List[string]

    if (Test-Path -LiteralPath $iniPath) {
        try {
            $section = ''
            $current = @{}
            $sections = @()
            foreach ($line in Get-Content -LiteralPath $iniPath) {
                if ($line -match '^\s*\[(.+)\]\s*$') {
                    if ($current.Count -gt 0) { $sections += [pscustomobject]$current }
                    $current = @{ Section = $Matches[1] }
                } elseif ($line -match '^\s*([^=]+)=(.*)$' -and $current.Count -gt 0) {
                    $current[$Matches[1].Trim()] = $Matches[2].Trim()
                }
            }
            if ($current.Count -gt 0) { $sections += [pscustomobject]$current }

            foreach ($entry in $sections) {
                if ($entry.Section -notmatch '^Profile\d+$') { continue }
                if (-not $entry.Path) { continue }
                $relative = if ($entry.IsRelative -eq '0') { $false } else { $true }
                $path = if ($relative) { Join-Path $profileRoot $entry.Path } else { $entry.Path }
                if (Test-Path -LiteralPath $path) {
                    $all.Add($path)
                    if ($entry.Default -eq '1') { $defaults.Add($path) }
                }
            }
        } catch { }
    }

    if ($all.Count -eq 0 -and (Test-Path -LiteralPath $profileRoot)) {
        foreach ($dir in @(Get-ChildItem -LiteralPath $profileRoot -Directory -ErrorAction SilentlyContinue)) {
            $all.Add($dir.FullName)
        }
    }

    if ($defaults.Count -eq 0) {
        foreach ($path in $all) {
            $recovery = Join-Path $path 'sessionstore-backups\recovery.jsonlz4'
            $session = Join-Path $path 'sessionstore.jsonlz4'
            if ((Test-Path -LiteralPath $recovery) -or (Test-Path -LiteralPath $session)) {
                $defaults.Add($path)
                break
            }
        }
    }

    if ($defaults.Count -eq 0) { return @() }
    return $defaults.ToArray()
}

function Get-SRFirefoxTabs {
    param([Parameter(Mandatory = $true)][string]$ProfileDirectory)

    $backups = Join-Path $ProfileDirectory 'sessionstore-backups'
    $candidates = @(
        (Join-Path $backups 'recovery.jsonlz4'),
        (Join-Path $backups 'recovery.baklz4'),
        (Join-Path $backups 'previous.jsonlz4'),
        (Join-Path $ProfileDirectory 'sessionstore.jsonlz4')
    )

    foreach ($path in $candidates) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try {
            $item = Get-Item -LiteralPath $path
            if ($item.Length -lt 12) { continue }
            $bytes = Get-SRFileBytes -Path $path
            $jsonBytes = [SessionRecovery.MozLz4]::Decompress($bytes)
            $jsonText = [System.Text.Encoding]::UTF8.GetString($jsonBytes)
            $data = $jsonText | ConvertFrom-Json
            if ($null -eq $data.windows) { continue }

            $tabs = New-Object System.Collections.Generic.List[object]
            $windowIndex = 0
            foreach ($window in @($data.windows)) {
                $windowIndex++
                foreach ($tab in @($window.tabs)) {
                    $entries = @($tab.entries)
                    if ($entries.Count -eq 0) { continue }
                    $index = [int]$tab.index
                    if ($index -lt 1 -or $index -gt $entries.Count) { $index = $entries.Count }
                    $entry = $entries[$index - 1]
                    $url = [string]$entry.url
                    if (-not (Test-SRRestorableUrl -Url $url)) { continue }
                    $tabs.Add([pscustomobject]@{
                        url      = $url
                        title    = [string]$entry.title
                        pinned   = [bool]$tab.pinned
                        windowId = $windowIndex
                    })
                }
            }
            if ($tabs.Count -gt 0) {
                return [pscustomobject]@{
                    tabs   = $tabs.ToArray()
                    source = 'firefox-sessionstore'
                    file   = $path
                    fileAt = $item.LastWriteTime
                }
            }
        } catch {
            Write-SRLog -Level DEBUG -Message "Could not parse Firefox sessionstore ${path}: $($_.Exception.Message)"
        }
    }
    return [pscustomobject]@{ tabs = @(); source = 'none'; file = $null; fileAt = $null }
}

function Get-SRFirefoxRestoreOnStartup {
    param([Parameter(Mandatory = $true)][string]$ProfileDirectory)
    $prefsPath = Join-Path $ProfileDirectory 'prefs.js'
    if (-not (Test-Path -LiteralPath $prefsPath)) { return $null }
    try {
        $text = Get-Content -LiteralPath $prefsPath -Raw -ErrorAction Stop
        $match = [regex]::Match($text, 'user_pref\("browser\.startup\.page",\s*(\d+)\)')
        if ($match.Success) { return [int]$match.Groups[1].Value }
    } catch { }
    return $null
}

function Get-SRBrowsers {
    param(
        [Parameter(Mandatory = $true)]$Windows,
        [Parameter(Mandatory = $true)]$ProcessMap,
        $Config = $null
    )

    if ($null -eq $Config) { $Config = Get-SRConfig }
    $lookbackHours = 24
    $allowApproximate = $true
    if ($null -ne $Config.PSObject.Properties['tabHistoryLookbackHours']) {
        $lookbackHours = [Math]::Max(1, [int]$Config.tabHistoryLookbackHours)
    }
    if ($null -ne $Config.PSObject.Properties['captureApproximateTabs']) {
        $allowApproximate = [bool]$Config.captureApproximateTabs
    }

    $definitions = Get-SRBrowserDefinitions
    $browsers = New-Object System.Collections.Generic.List[object]

    foreach ($definition in $definitions) {
        $matchingWindows = @($Windows | Where-Object {
            $process = $ProcessMap[[int]$_.ProcessId]
            if ($null -eq $process) { return $false }
            Test-SRBrowserProcess -Definition $definition -Process $process
        })
        if ($matchingWindows.Count -eq 0) { continue }

        $exe = Resolve-SRBrowserExe -Definition $definition -ProcessMap $ProcessMap
        if ([string]::IsNullOrWhiteSpace($exe)) { continue }

        $primaryWindow = $matchingWindows | Where-Object { -not $_.Minimized } | Select-Object -First 1
        if ($null -eq $primaryWindow) { $primaryWindow = $matchingWindows[0] }
        $browserStarted = [datetime]::MinValue
        try {
            $browserStarted = (Get-Process -Id ([int]$primaryWindow.ProcessId) -ErrorAction Stop).StartTime
        } catch { }

        $profiles = New-Object System.Collections.Generic.List[object]
        if ($definition.kind -eq 'chromium') {
            $userDataDir = Get-SRChromiumUserDataDir -Definition $definition -ProcessMap $ProcessMap
            if (-not (Test-Path -LiteralPath $userDataDir)) { continue }

            $inUse = @(Get-SRChromiumProfileNamesInUse -Definition $definition -ProcessMap $ProcessMap)
            $lastUsed = $null
            $displayNames = @{}
            $localStatePath = Join-Path $userDataDir 'Local State'
            if (Test-Path -LiteralPath $localStatePath) {
                try {
                    $localState = Get-Content -LiteralPath $localStatePath -Raw -ErrorAction Stop | ConvertFrom-Json
                    if ($null -ne $localState.profile) {
                        if ($localState.profile.last_used) { $lastUsed = [string]$localState.profile.last_used }
                        if ($null -ne $localState.profile.info_cache) {
                            foreach ($property in $localState.profile.info_cache.PSObject.Properties) {
                                $displayNames[$property.Name] = [string]$property.Value.name
                            }
                        }
                    }
                } catch { }
            }

            $profileDirs = @(Get-ChildItem -LiteralPath $userDataDir -Directory -ErrorAction SilentlyContinue | Where-Object {
                $_.Name -eq 'Default' -or $_.Name -like 'Profile *'
            })

            foreach ($directory in $profileDirs) {
                $isInUse = ($inUse.Count -eq 0) -or ($inUse -contains $directory.Name)
                $isLastUsed = ($lastUsed -eq $directory.Name)
                $sessionFileTimes = @()
                $sessionsDir = Join-Path $directory.FullName 'Sessions'
                if (Test-Path -LiteralPath $sessionsDir) {
                    $sessionFileTimes += @(Get-ChildItem -LiteralPath $sessionsDir -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty LastWriteTime)
                }
                foreach ($legacyName in @('Current Session', 'Current Tabs', 'Last Session', 'Last Tabs')) {
                    $legacy = Join-Path $directory.FullName $legacyName
                    if (Test-Path -LiteralPath $legacy) { $sessionFileTimes += (Get-Item -LiteralPath $legacy).LastWriteTime }
                }
                $recent = $false
                if ($sessionFileTimes.Count -gt 0) {
                    $latest = $sessionFileTimes | Sort-Object -Descending | Select-Object -First 1
                    $recent = ($latest -gt (Get-Date).AddHours(-3))
                }

                # Include the profile that is actually in use. If command lines
                # do not identify one, include the last-used profile and any
                # profile whose files were touched recently.
                if ($inUse.Count -gt 0) {
                    if (-not $isInUse) { continue }
                } elseif (-not ($isLastUsed -or $recent -or ($lastUsed -eq $null -and $directory.Name -eq 'Default'))) {
                    continue
                }

                $tabData = Get-SRChromiumTabs -ProfileDirectory $directory.FullName `
                    -WindowHandle $primaryWindow.Handle -BrowserStartTime $browserStarted `
                    -HistoryLookbackHours $lookbackHours -AllowApproximate $allowApproximate
                $restoreOnStartup = Get-SRChromiumRestoreOnStartup -ProfileDirectory $directory.FullName
                $displayName = $displayNames[$directory.Name]
                if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $directory.Name }

                $profiles.Add([pscustomobject]@{
                    directory        = $directory.Name
                    displayName      = $displayName
                    path             = $directory.FullName
                    restoreOnStartup = $restoreOnStartup
                    tabs             = @($tabData.tabs)
                    tabsSource       = $tabData.source
                    tabsApproximate  = [bool]$tabData.approximate
                    tabsFile         = $tabData.file
                    tabsFileAt       = $tabData.fileAt
                })
            }
        } else {
            $profilePaths = @(Get-SRFirefoxDefaultProfiles -Definition $definition)
            foreach ($profilePath in $profilePaths) {
                $tabData = Get-SRFirefoxTabs -ProfileDirectory $profilePath
                $restoreOnStartup = Get-SRFirefoxRestoreOnStartup -ProfileDirectory $profilePath
                $profiles.Add([pscustomobject]@{
                    directory        = Split-Path -Leaf $profilePath
                    displayName      = Split-Path -Leaf $profilePath
                    path             = $profilePath
                    restoreOnStartup = $restoreOnStartup
                    tabs             = @($tabData.tabs)
                    tabsSource       = $tabData.source
                    tabsApproximate  = $false
                    tabsFile         = $tabData.file
                    tabsFileAt       = $tabData.fileAt
                })
            }
        }

        if ($profiles.Count -eq 0) { continue }

        $browsers.Add([pscustomobject]@{
            key      = $definition.key
            name     = $definition.name
            exe      = $exe
            kind     = $definition.kind
            profiles = $profiles.ToArray()
            windows  = @($matchingWindows | ForEach-Object { [pscustomobject]@{ title = [string]$_.Title } })
        })
    }

    return $browsers.ToArray()
}

# ---------------------------------------------------------------------------
# Media players (VLC first: file resolution + playback position tracking)
# ---------------------------------------------------------------------------

# Players beyond VLC. Their window title names the file being played; the
# position is dead-reckoned from the first sighting (same idea as the VLC
# fallback) and players that accept a start-position argument resume there.
function Get-SRMediaPlayerDefinitions {
    return @(
        [pscustomobject]@{
            key         = 'mpc-hc'
            processes   = @('mpc-hc64', 'mpc-hc')
            # Window title when nothing is open.
            idleTitle   = '(?i)^(media player classic|mpc-hc|mpc-be)\b.*'
            titleTokens = 'MPC-HC|MPC-BE|Media Player Classic'
            seekKind    = 'none'
        },
        [pscustomobject]@{
            key         = 'mpc-be'
            processes   = @('mpc-be64', 'mpc-be')
            idleTitle   = '(?i)^(media player classic|mpc-be)\b.*'
            titleTokens = 'MPC-BE|Media Player Classic'
            seekKind    = 'startpos'
        },
        [pscustomobject]@{
            key         = 'mpv'
            processes   = @('mpv')
            idleTitle   = '(?i)^mpv$'
            titleTokens = 'mpv'
            seekKind    = 'start'
        },
        [pscustomobject]@{
            key         = 'potplayer'
            processes   = @('potplayermini64', 'potplayermini', 'potplayer')
            idleTitle   = '(?i)^potplayer$'
            titleTokens = 'PotPlayer|Daum PotPlayer'
            seekKind    = 'seek'
        },
        [pscustomobject]@{
            key         = 'wmplayer'
            processes   = @('wmplayer')
            idleTitle   = '(?i)^(windows media player|media player)$'
            titleTokens = 'Windows Media Player'
            seekKind    = 'none'
        }
    )
}

function ConvertTo-SRPlayerMediaTitle {
    # "song.mp3 - MPC-HC", "movie.mkv — mpv" and "PotPlayer - clip.mp4" all
    # reduce to the file name once the player token is stripped.
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$TitleTokens
    )
    if ([string]::IsNullOrWhiteSpace($Title)) { return $null }
    $t = $Title.Trim()
    $t = [regex]::Replace($t, ('\s*[-–—]\s*(?:' + $TitleTokens + ')\s*$'), '', 'IgnoreCase')
    $t = [regex]::Replace($t, ('^(?:' + $TitleTokens + ')\s*[-–—]\s*'), '', 'IgnoreCase')
    if ([string]::IsNullOrWhiteSpace($t)) { return $null }
    return $t
}

function Resolve-SRMediaFileFromTitle {
    # Resolve a bare file name from a player title to a full path: first the
    # Windows Recent items (they point at the actual opened files), then a
    # shallow search of the usual media libraries.
    param([string]$Title)
    if ([string]::IsNullOrWhiteSpace($Title)) { return $null }
    if ($Title -match '^[A-Za-z]:\\' -and (Test-Path -LiteralPath $Title)) { return $Title }

    $leaf = Split-Path -Leaf $Title
    $recentDir = Join-Path $env:APPDATA 'Microsoft\Windows\Recent'
    try {
        $links = @(Get-ChildItem -LiteralPath $recentDir -Filter '*.lnk' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ieq ($leaf + '.lnk') } |
            Sort-Object -Property LastWriteTime -Descending)
        foreach ($link in $links) {
            $target = Get-SRShortcutTarget -ShortcutPath $link.FullName
            if (-not [string]::IsNullOrWhiteSpace($target)) { return $target }
        }
    } catch { }

    $roots = @(
        [Environment]::GetFolderPath('MyVideos'),
        [Environment]::GetFolderPath('MyMusic'),
        [Environment]::GetFolderPath('MyDocuments'),
        (Join-Path $env:USERPROFILE 'Downloads'),
        [Environment]::GetFolderPath('Desktop')
    )
    foreach ($root in $roots) {
        if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root)) { continue }
        try {
            $hit = Get-ChildItem -LiteralPath $root -Recurse -Depth 2 -File -Filter $leaf -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($null -ne $hit) { return $hit.FullName }
        } catch { }
    }
    return $null
}

# VLC keeps its recent files and resume positions in vlc-qt-interface.ini.
# The flat format is:  list=<uri>, <uri>, ...   times=<ms>, <ms>, ...
# (parallel arrays; index 0 is the most recent). Older builds used numbered
# groups (1\size=n, 1\1=uri). VLC writes a resume time only when an input is
# stopped or the player closes cleanly, so a crash loses the current
# position. The estimator below reconstructs it between snapshots.
$script:SRVlcConfigPath = Join-Path $env:APPDATA 'vlc\vlc-qt-interface.ini'

function Get-SRVlcRecentMedia {
    $result = [pscustomobject]@{
        Paths   = New-Object System.Collections.Generic.List[string]
        TimesMs = @{}
    }
    if (-not (Test-Path -LiteralPath $script:SRVlcConfigPath)) { return $result }

    $lines = @()
    try {
        $lines = @(Get-Content -LiteralPath $script:SRVlcConfigPath -ErrorAction Stop)
    } catch {
        return $result
    }

    $inRecents = $false
    $flatUris = @()
    $flatTimes = @()
    $numbered = @{}
    foreach ($line in $lines) {
        if ($line -match '^\[(.+)\]\s*$') {
            $inRecents = ($Matches[1] -eq 'RecentsMRL')
            continue
        }
        if (-not $inRecents) { continue }
        if ($line -match '^list=(.*)$') {
            $flatUris = @($Matches[1] -split ', ')
        } elseif ($line -match '^times=(.*)$') {
            $flatTimes = @(($Matches[1] -split ',') | ForEach-Object { $_.Trim() })
        } elseif ($line -match '^(\d+)\\(\d+)=(.*)$') {
            $numbered[('{0}\{1}' -f $Matches[1], $Matches[2])] = $Matches[3]
        }
    }

    $uris = @()
    if ($flatUris.Count -gt 0) {
        $uris = $flatUris
    } else {
        for ($group = 1; $group -le 20; $group++) {
            $groupUris = @()
            for ($item = 1; $item -le 50; $item++) {
                $key = '{0}\{1}' -f $group, $item
                if (-not $numbered.ContainsKey($key)) { break }
                $groupUris += $numbered[$key]
            }
            if ($groupUris.Count -eq 0) { break }
            $uris += $groupUris
        }
    }

    # Heal URIs that contain a literal comma (the list separator).
    $healed = New-Object System.Collections.Generic.List[string]
    foreach ($part in $uris) {
        $trimmed = ([string]$part).Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        if ($healed.Count -gt 0 -and $trimmed -notmatch '^[a-z][a-z0-9+.\-]*:') {
            $healed[$healed.Count - 1] = $healed[$healed.Count - 1] + ', ' + $trimmed
        } else {
            $healed.Add($trimmed)
        }
    }

    for ($i = 0; $i -lt $healed.Count; $i++) {
        $uri = $healed[$i]
        if ($uri -notlike 'file:///*') { continue }
        $path = $null
        try { $path = ([uri]$uri).LocalPath } catch { continue }
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $result.Paths.Add($path)
        if ($i -lt $flatTimes.Count) {
            $ms = [long]0
            try { $ms = [long][double]::Parse($flatTimes[$i], [System.Globalization.CultureInfo]::InvariantCulture) } catch { $ms = 0 }
            if ($ms -gt 0 -and -not $result.TimesMs.ContainsKey($path)) { $result.TimesMs[$path] = $ms }
        }
    }
    return $result
}

function Get-SRMediaDurationSeconds {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $null }
    $shell = $null
    try {
        $shell = New-Object -ComObject Shell.Application
        $folder = $shell.Namespace((Split-Path -Parent $Path))
        if ($null -eq $folder) { return $null }
        $item = $folder.ParseName((Split-Path -Leaf $Path))
        if ($null -eq $item) { return $null }
        # "Length" is detail index 27 on Windows 10/11.
        $text = [string]$folder.GetDetailsOf($item, 27)
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        $parts = @($text -split ':')
        if ($parts.Count -lt 2) { return $null }
        $seconds = [double]0
        for ($i = 0; $i -lt $parts.Count; $i++) {
            $value = 0.0
            if (-not [double]::TryParse($parts[$i], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)) { return $null }
            $seconds = $seconds * 60 + $value
        }
        if ($seconds -le 0) { return $null }
        return [Math]::Round($seconds, 1)
    } catch {
        return $null
    } finally {
        if ($null -ne $shell) {
            try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } catch { }
        }
    }
}

$script:SRMediaStatePath = Join-Path $script:SRRoot 'media-state.json'

function Get-SRMediaState {
    $empty = [pscustomobject]@{ players = @{} }
    if (-not (Test-Path -LiteralPath $script:SRMediaStatePath)) { return $empty }
    try {
        $saved = Get-Content -LiteralPath $script:SRMediaStatePath -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($null -eq $saved -or $null -eq $saved.PSObject.Properties['players']) { return $empty }
        $map = @{}
        foreach ($property in $saved.players.PSObject.Properties) { $map[$property.Name] = $property.Value }
        return [pscustomobject]@{ players = $map }
    } catch {
        return $empty
    }
}

function Save-SRMediaState {
    param([Parameter(Mandatory = $true)]$State)
    try {
        $parent = Split-Path -Parent $script:SRMediaStatePath
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $json = $State | ConvertTo-Json -Depth 6
        [System.IO.File]::WriteAllText($script:SRMediaStatePath, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        Write-SRLog -Level DEBUG -Message "Could not save media state: $($_.Exception.Message)"
    }
}

function ConvertTo-SRMediaTitle {
    param([string]$Title)
    # "<filename> - VLC media player" (also used while fullscreen).
    $name = [string]$Title
    $name = $name -replace '(?i)\s*-\s*VLC media player\s*$', ''
    return $name.Trim()
}

function Get-SRVlcResumeMode {
    # qt-continue in vlcrc: 0 = ask, 1 = always resume, 2 = never.
    # Only mode 1 guarantees VLC itself restarts from the saved position;
    # otherwise a reopened file starts at 0 and the saved time is stale.
    $vlcrc = Join-Path $env:APPDATA 'vlc\vlcrc'
    if (-not (Test-Path -LiteralPath $vlcrc)) { return 2 }
    try {
        foreach ($line in @(Get-Content -LiteralPath $vlcrc -ErrorAction Stop)) {
            if ($line -match '^qt-continue(?:-playback)?=(\d+)') { return [int]$Matches[1] }
        }
    } catch { }
    return 0
}

function Get-SRMediaPlayerMedia {
    param(
        [Parameter(Mandatory = $true)]$Apps,
        [Parameter(Mandatory = $true)]$Config
    )

    $state = Get-SRMediaState
    $stateDirty = $false
    $now = Get-Date
    $seenPlayer = $false

    # Earliest start time among running VLC processes. A newly started VLC
    # usually begins playing its file immediately, so this anchors the very
    # first snapshot after the player launches.
    $vlcStart = [datetime]::MinValue
    try {
        foreach ($process in @(Get-Process -Name vlc -ErrorAction SilentlyContinue)) {
            try {
                if ($process.StartTime -gt [datetime]::MinValue -and ($vlcStart -eq [datetime]::MinValue -or $process.StartTime -lt $vlcStart)) {
                    $vlcStart = $process.StartTime
                }
            } catch { }
        }
    } catch { }

    $recents = Get-SRVlcRecentMedia

    foreach ($app in @($Apps)) {
        if ($null -eq $app) { continue }
        $leaf = ([string]$app.name).ToLowerInvariant()
        if ($leaf -ne 'vlc') { continue }
        $seenPlayer = $true

        # Find the window actually playing something. Some files leave the
        # VLC title empty ("VLC media player"); those resolve through the
        # recents list below.
        $title = $null
        foreach ($window in @($app.windows)) {
            $candidate = ConvertTo-SRMediaTitle -Title ([string]$window.title)
            if (-not [string]::IsNullOrWhiteSpace($candidate) -and $candidate -notmatch '(?i)^vlc( media player)?$') {
                $title = $candidate
                break
            }
        }
        if ($null -eq $title -and $recents.Paths.Count -eq 0) { continue }

        $file = $null
        if ($null -ne $title) {
            foreach ($path in $recents.Paths) {
                if ((Split-Path -Leaf $path) -ieq $title) { $file = $path; break }
            }
        }
        if ($null -eq $file -or -not (Test-Path -LiteralPath $file)) {
            # VLC moves the opened file to the front of its recents while the
            # session runs, so the newest on-disk entry is the playing file
            # when the title is empty or shows metadata.
            foreach ($path in $recents.Paths) {
                if (Test-Path -LiteralPath $path) { $file = $path; break }
            }
        }
        if ($null -eq $file -or -not (Test-Path -LiteralPath $file)) { continue }
        if ($null -eq $title) { $title = Split-Path -Leaf $file }

        $savedMs = [long]0
        if ($recents.TimesMs.ContainsKey($file)) { $savedMs = [long]$recents.TimesMs[$file] }

        # Dead reckoning: advance the last known position by the time the same
        # file has stayed open between snapshots. VLC never writes the current
        # position during playback, so this is what survives a crash.
        $resumeMode = Get-SRVlcResumeMode
        $entry = $null
        if ($state.players.ContainsKey('vlc')) { $entry = $state.players['vlc'] }
        $anchoredFromVlc = $false
        $anchorMs = [long]0
        $anchorAt = $now
        $durationSeconds = $null

        $lastSeen = [datetime]::MinValue
        if ($null -ne $entry) {
            try { $lastSeen = [datetime]::Parse([string]$entry.lastSeenAt, [System.Globalization.CultureInfo]::InvariantCulture) } catch { }
            try { $durationSeconds = [double]$entry.durationSeconds } catch { $durationSeconds = $null }
        }

        $sameSession = ($null -ne $entry -and
            [string]$entry.file -eq $file -and
            $lastSeen -gt [datetime]::MinValue -and $lastSeen -lt $now -and
            ($vlcStart -eq [datetime]::MinValue -or $vlcStart -le $lastSeen))

        if ($sameSession) {
            # Continue from the previous snapshot's estimate.
            try {
                $anchorMs = [long][double]$entry.anchorPositionMs
                $anchorAt = [datetime]::Parse([string]$entry.anchorAt, [System.Globalization.CultureInfo]::InvariantCulture)
            } catch {
                $anchorMs = [long]0
                $anchorAt = $lastSeen
            }
            if ($resumeMode -eq 1 -and $savedMs -gt $anchorMs) {
                # VLC auto-resumes and knows a newer exact position.
                $anchorMs = $savedMs
                $anchorAt = $lastSeen
            }
            if ($resumeMode -eq 1 -and $savedMs -gt 0) { $anchoredFromVlc = $true }
        } else {
            # First sighting, or VLC restarted since the last snapshot: anchor
            # to the player's own start time. With VLC auto-resume enabled the
            # saved position is where playback actually continued from.
            if ($vlcStart -gt [datetime]::MinValue -and $vlcStart -lt $now) { $anchorAt = $vlcStart }
            if ($resumeMode -eq 1 -and $savedMs -gt 0) {
                $anchorMs = $savedMs
                $anchoredFromVlc = $true
            }
        }

        if ($null -eq $durationSeconds) { $durationSeconds = Get-SRMediaDurationSeconds -Path $file }

        $positionMs = $anchorMs + [int64](($now - $anchorAt).TotalMilliseconds)
        if ($positionMs -lt 0) { $positionMs = 0 }
        if ($null -ne $durationSeconds -and $durationSeconds -gt 0) {
            $capMs = [int64]($durationSeconds * 1000) - 5000
            if ($capMs -lt 0) { $capMs = 0 }
            if ($positionMs -gt $capMs) { $positionMs = $capMs }
        }

        $media = [pscustomobject]@{
            file            = $file
            title           = $title
            positionSeconds = [Math]::Round($positionMs / 1000.0, 1)
            durationSeconds = $durationSeconds
            estimated       = (-not $anchoredFromVlc)
        }
        $app | Add-Member -NotePropertyName media -NotePropertyValue $media -Force

        $state.players['vlc'] = [pscustomobject]@{
            file             = $file
            savedPositionMs  = $savedMs
            anchorPositionMs = $positionMs
            anchorAt         = $now.ToString('o')
            lastSeenAt       = $now.ToString('o')
            durationSeconds  = $durationSeconds
        }
        $stateDirty = $true
        Write-SRLog -Level DEBUG -Message ("VLC media captured: {0} at {1}s" -f $file, $media.positionSeconds)
    }

    # A player that is not running (or has nothing open) ends its session;
    # VLC will have written the exact position if it closed cleanly.
    if (-not $seenPlayer -and $state.players.ContainsKey('vlc')) {
        $state.players.Remove('vlc')
        $stateDirty = $true
    }

    # Other players: the window title names the file, and the position is
    # dead-reckoned from the first sighting of that file.
    $knownPlayerKeys = @{}
    foreach ($player in Get-SRMediaPlayerDefinitions) {
        foreach ($processName in @($player.processes)) { $knownPlayerKeys[$processName] = $player }
    }
    $seenKeys = @{}
    foreach ($app in @($Apps)) {
        if ($null -eq $app -or $null -ne $app.PSObject.Properties['media']) { continue }
        $player = $knownPlayerKeys[([string]$app.name).ToLowerInvariant()]
        if ($null -eq $player) { continue }

        $rawTitle = $null
        foreach ($window in @($app.windows)) {
            $candidate = ([string]$window.title).Trim()
            if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
            if ($candidate -match [string]$player.idleTitle) { continue }
            $rawTitle = $candidate
            break
        }
        if ($null -eq $rawTitle) { continue }

        $title = ConvertTo-SRPlayerMediaTitle -Title $rawTitle -TitleTokens ([string]$player.titleTokens)
        if ([string]::IsNullOrWhiteSpace($title)) { continue }
        $file = Resolve-SRMediaFileFromTitle -Title $title
        if ([string]::IsNullOrWhiteSpace($file)) { continue }
        $seenKeys[[string]$player.key] = $true

        # mpv only: ask its JSON IPC pipe for the exact position first.
        $mpvExact = $null
        if ([string]$player.key -eq 'mpv') { $mpvExact = Get-SRMpvPlayback }

        $entry = $null
        if ($state.players.ContainsKey([string]$player.key)) { $entry = $state.players[[string]$player.key] }
        $anchorMs = [long]0
        $anchorAt = $now
        if ($null -ne $entry -and [string]$entry.file -eq $file) {
            try {
                $anchorMs = [long][double]$entry.anchorPositionMs
                $anchorAt = [datetime]::Parse([string]$entry.anchorAt, [System.Globalization.CultureInfo]::InvariantCulture)
                if ($anchorAt -ge $now -or $anchorAt -eq [datetime]::MinValue) { $anchorAt = $now; $anchorMs = 0 }
            } catch {
                $anchorMs = [long]0
                $anchorAt = $now
            }
        }

        $durationSeconds = Get-SRMediaDurationSeconds -Path $file
        $positionMs = $anchorMs + [int64](($now - $anchorAt).TotalMilliseconds)
        if ($positionMs -lt 0) { $positionMs = 0 }
        $estimated = $true
        if ($null -ne $mpvExact -and $null -ne $mpvExact.Position -and [double]$mpvExact.Position -ge 0) {
            # Exact state straight from the player.
            $positionMs = [int64]([double]$mpvExact.Position * 1000)
            $anchorMs = $positionMs
            $anchorAt = $now
            $estimated = $false
            if ($null -ne $mpvExact.Duration -and [double]$mpvExact.Duration -gt 0) { $durationSeconds = [double]$mpvExact.Duration }
            if (-not [string]::IsNullOrWhiteSpace([string]$mpvExact.File) -and (Test-Path -LiteralPath ([string]$mpvExact.File))) {
                $file = [string]$mpvExact.File
            }
        }
        if ($null -ne $durationSeconds -and $durationSeconds -gt 0) {
            $capMs = [int64]($durationSeconds * 1000) - 5000
            if ($capMs -lt 0) { $capMs = 0 }
            if ($positionMs -gt $capMs) { $positionMs = $capMs }
        }

        $media = [pscustomobject]@{
            file            = $file
            title           = Split-Path -Leaf $file
            positionSeconds = [Math]::Round($positionMs / 1000.0, 1)
            durationSeconds = $durationSeconds
            estimated       = $estimated
        }
        $app | Add-Member -NotePropertyName media -NotePropertyValue $media -Force
        $state.players[[string]$player.key] = [pscustomobject]@{
            file             = $file
            savedPositionMs  = [long]0
            anchorPositionMs = $positionMs
            anchorAt         = $now.ToString('o')
            lastSeenAt       = $now.ToString('o')
            durationSeconds  = $durationSeconds
        }
        $stateDirty = $true
        Write-SRLog -Level DEBUG -Message ("{0} media captured: {1} at {2}s" -f $player.key, $file, $media.positionSeconds)
    }
    foreach ($player in Get-SRMediaPlayerDefinitions) {
        if (-not $seenKeys.ContainsKey([string]$player.key) -and $state.players.ContainsKey([string]$player.key)) {
            $state.players.Remove([string]$player.key)
            $stateDirty = $true
        }
    }

    if ($stateDirty) { Save-SRMediaState -State $state }
}

function Get-SRMediaLaunchArguments {
    param(
        [Parameter(Mandatory = $true)][string]$ExePath,
        $Media
    )
    if ($null -eq $Media) { return $null }
    $file = [string]$Media.file
    if ([string]::IsNullOrWhiteSpace($file) -or -not (Test-Path -LiteralPath $file)) { return $null }

    $leaf = [System.IO.Path]::GetFileNameWithoutExtension($ExePath).ToLowerInvariant()
    $position = 0.0
    try { $position = [double]$Media.positionSeconds } catch { $position = 0.0 }

    if ($leaf -eq 'vlc') {
        $arguments = New-Object System.Collections.Generic.List[string]
        if ($position -ge 10) {
            # Suppress VLC's own (stale) resume prompt so our position wins.
            $arguments.Add('--qt-continue=2')
            $arguments.Add(('--start-time={0}' -f [int][Math]::Floor($position)))
        }
        $arguments.Add($file)
        return $arguments.ToArray()
    }
    if ($leaf -eq 'mpv') {
        $arguments = New-Object System.Collections.Generic.List[string]
        if ($position -ge 10) { $arguments.Add(('--start={0}' -f [int][Math]::Floor($position))) }
        $arguments.Add($file)
        return $arguments.ToArray()
    }
    if ($leaf -like 'potplayer*') {
        $arguments = New-Object System.Collections.Generic.List[string]
        if ($position -ge 10) {
            $span = [timespan]::FromSeconds([int][Math]::Floor($position))
            $arguments.Add(('/seek={0:00}:{1:00}:{2:00}' -f [int]$span.TotalHours, $span.Minutes, $span.Seconds))
        }
        $arguments.Add($file)
        return $arguments.ToArray()
    }
    if ($leaf -eq 'mpc-be' -or $leaf -eq 'mpc-be64') {
        $arguments = New-Object System.Collections.Generic.List[string]
        if ($position -ge 10) { $arguments.Add(('/startpos {0}' -f [int][Math]::Floor($position))) }
        $arguments.Add($file)
        return $arguments.ToArray()
    }
    return @($file)
}

function Get-SRMpvPlayback {
    # Exact playback state from mpv's JSON IPC pipe. Only available when mpv
    # was started with --input-ipc-server; everything else keeps the
    # title-based estimate.
    param([string[]]$PipeNames = @('mpvsocket', 'mpvpipe', 'mpv-socket'))
    foreach ($name in @($PipeNames)) {
        $pipe = $null
        try {
            $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', $name, [System.IO.Pipes.PipeDirection]::InOut)
            $pipe.Connect(400)
            $writer = New-Object System.IO.StreamWriter($pipe)
            $writer.AutoFlush = $true
            $writer.NewLine = "`n"
            $reader = New-Object System.IO.StreamReader($pipe)
            [void]$reader.ReadLine() # greeting line

            $answers = @{}
            $requests = @(
                @{ Id = 101; Command = 'path' },
                @{ Id = 102; Command = 'time-pos' },
                @{ Id = 103; Command = 'duration' },
                @{ Id = 104; Command = 'pause' }
            )
            foreach ($request in $requests) {
                $writer.WriteLine(('{{"command":["get_property","{0}"],"request_id":{1}}}' -f $request.Command, $request.Id))
            }
            $deadline = [DateTime]::UtcNow.AddMilliseconds(1200)
            while ([DateTime]::UtcNow -lt $deadline -and $answers.Count -lt $requests.Count) {
                $task = $reader.ReadLineAsync()
                if (-not $task.Wait(250)) { continue }
                $line = $task.Result
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try {
                    $reply = $line | ConvertFrom-Json
                    if ($null -ne $reply -and $null -ne $reply.PSObject.Properties['request_id']) {
                        $answers[[int]$reply.request_id] = $reply
                    }
                } catch { }
            }
            $path = $null
            $timePos = $null
            $duration = $null
            $paused = $false
            try { if ($answers.ContainsKey(101) -and $answers[101].data) { $path = [string]$answers[101].data } } catch { }
            try { if ($answers.ContainsKey(102) -and $null -ne $answers[102].data) { $timePos = [double]$answers[102].data } } catch { }
            try { if ($answers.ContainsKey(103) -and $null -ne $answers[103].data) { $duration = [double]$answers[103].data } } catch { }
            try { if ($answers.ContainsKey(104)) { $paused = [bool]$answers[104].data } } catch { }
            if ([string]::IsNullOrWhiteSpace($path) -and $null -eq $timePos) { continue }
            return [pscustomobject]@{
                File        = $path
                Position    = $timePos
                Duration    = $duration
                Paused      = $paused
                PipeName    = $name
            }
        } catch {
            if ($null -ne $pipe) { try { $pipe.Dispose() } catch { } }
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Virtual desktops, monitor layout, remote sessions
# ---------------------------------------------------------------------------

$script:SRVirtualDesktopType = $null
function Get-SRVirtualDesktopHelper {
    # Documented IVirtualDesktopManager: it can read which desktop a window is
    # on and move windows. Best-effort only; every failure is non-fatal.
    if ($null -ne $script:SRVirtualDesktopType) { return $script:SRVirtualDesktopType }
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace SessionRecovery
{
    [ComImport]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [Guid("a5cd92ff-29be-454c-8d04-d82879fb3f1b")]
    public interface IVirtualDesktopManager
    {
        [PreserveSig] int IsWindowOnCurrentVirtualDesktop(IntPtr topLevelWindow, out bool onCurrentDesktop);
        [PreserveSig] int GetWindowDesktopId(IntPtr topLevelWindow, out Guid desktopId);
        [PreserveSig] int MoveWindowToDesktop(IntPtr topLevelWindow, ref Guid desktopId);
    }

    [ComImport]
    [Guid("aa509086-5ca9-4c25-b814-4ce35a3a0e10")]
    public class VirtualDesktopManagerComObject { }

    public static class VirtualDesktop
    {
        public static string GetDesktopId(IntPtr window)
        {
            try
            {
                IVirtualDesktopManager manager = (IVirtualDesktopManager)new VirtualDesktopManagerComObject();
                Guid id;
                int hr = manager.GetWindowDesktopId(window, out id);
                if (hr != 0 || id == Guid.Empty) return null;
                return id.ToString("D");
            }
            catch { return null; }
        }

        public static bool MoveToDesktop(IntPtr window, string desktopIdText)
        {
            try
            {
                Guid id = new Guid(desktopIdText);
                IVirtualDesktopManager manager = (IVirtualDesktopManager)new VirtualDesktopManagerComObject();
                int hr = manager.MoveWindowToDesktop(window, ref id);
                return hr == 0;
            }
            catch { return false; }
        }

        public static void QueueMove(int processId, string desktopIdText, int timeoutMs)
        {
            // Own background thread: wait for the process to show its main
            // window, then move it to the desktop it was captured on. If the
            // desktop no longer exists (rebuilt profile, different machine)
            // the call simply fails and the window stays where Windows put it.
            System.Threading.Thread thread = new System.Threading.Thread(delegate()
            {
                try { MoveProcessWhenReady(processId, desktopIdText, timeoutMs); }
                catch { }
            });
            thread.IsBackground = true;
            thread.Start();
        }

        private static void MoveProcessWhenReady(int processId, string desktopIdText, int timeoutMs)
        {
            try
            {
                IntPtr handle = IntPtr.Zero;
                DateTime deadline = DateTime.UtcNow.AddMilliseconds(Math.Max(500, timeoutMs));
                while (DateTime.UtcNow < deadline)
                {
                    try
                    {
                        System.Diagnostics.Process process = System.Diagnostics.Process.GetProcessById(processId);
                        process.Refresh();
                        if (process.MainWindowHandle != IntPtr.Zero) { handle = process.MainWindowHandle; break; }
                    }
                    catch { break; }
                    System.Threading.Thread.Sleep(250);
                }
                if (handle == IntPtr.Zero) return;
                System.Threading.Thread.Sleep(400);
                try
                {
                    System.Diagnostics.Process process = System.Diagnostics.Process.GetProcessById(processId);
                    process.Refresh();
                    if (process.MainWindowHandle != IntPtr.Zero) handle = process.MainWindowHandle;
                }
                catch { }
                MoveToDesktop(handle, desktopIdText);
            }
            catch { }
        }
    }
}
'@ -ErrorAction Stop
        $script:SRVirtualDesktopType = $true
    } catch {
        $script:SRVirtualDesktopType = $false
    }
    return $script:SRVirtualDesktopType
}

function Get-SRWindowDesktopId {
    param([Parameter(Mandatory = $true)][IntPtr]$WindowHandle)
    if (-not (Get-SRVirtualDesktopHelper)) { return $null }
    try {
        return [SessionRecovery.VirtualDesktop]::GetDesktopId($WindowHandle)
    } catch { return $null }
}

function Move-SRWindowToDesktop {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$WindowHandle,
        [Parameter(Mandatory = $true)][string]$DesktopId
    )
    if (-not (Get-SRVirtualDesktopHelper)) { return $false }
    try {
        return [bool][SessionRecovery.VirtualDesktop]::MoveToDesktop($WindowHandle, $DesktopId)
    } catch { return $false }
}

function Get-SRMonitors {
    # Current monitor layout, remembered in each snapshot so restore can map
    # windows from missing monitors instead of only clamping them.
    $result = New-Object System.Collections.Generic.List[object]
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        foreach ($screen in @([System.Windows.Forms.Screen]::AllScreens)) {
            $bounds = $screen.Bounds
            $result.Add([pscustomobject]@{
                device  = [string]$screen.DeviceName
                x       = [int]$bounds.X
                y       = [int]$bounds.Y
                width   = [int]$bounds.Width
                height  = [int]$bounds.Height
                primary = [bool]$screen.Primary
            })
        }
    } catch { }
    return $result.ToArray()
}

function ConvertTo-SRScreenPlacement {
    # Translates a captured window position into the current monitor layout.
    # Same device present: keep coordinates. Monitor missing (undocked laptop):
    # keep the window's relative position on the best-matching current monitor
    # instead of dumping it at a clamped screen edge.
    param(
        [Parameter(Mandatory = $true)]$Placement,
        $SnapshotMonitors
    )
    if ($null -eq $Placement) { return $Placement }
    $current = @(Get-SRMonitors)
    if ($current.Count -eq 0) { return $Placement }

    if (@($SnapshotMonitors).Count -eq 0) {
        # Old snapshot without monitor info: keep as-is, the placer clamps.
        return $Placement
    }

    $centerX = $Placement.X + [int]($Placement.Width / 2)
    $centerY = $Placement.Y + [int]($Placement.Height / 2)

    $source = $null
    foreach ($monitor in @($SnapshotMonitors)) {
        if ($centerX -ge [int]$monitor.x -and $centerX -lt ([int]$monitor.x + [int]$monitor.width) -and
            $centerY -ge [int]$monitor.y -and $centerY -lt ([int]$monitor.y + [int]$monitor.height)) {
            $source = $monitor
            break
        }
    }
    if ($null -eq $source) { return $Placement }

    foreach ($monitor in $current) {
        if ([string]::Equals([string]$monitor.device, [string]$source.device, [System.StringComparison]::OrdinalIgnoreCase)) {
            # The captured monitor still exists: coordinates stay valid.
            return $Placement
        }
    }

    # Monitor is gone. Prefer the primary, else the largest remaining screen.
    $target = @($current | Where-Object { $_.primary } | Select-Object -First 1)
    if ($target.Count -eq 0) {
        $target = @($current | Sort-Object -Property @{ Expression = { $_.width * $_.height } } -Descending | Select-Object -First 1)
    }
    if ($target.Count -eq 0) { return $Placement }
    $target = $target[0]

    $sourceWidth = [Math]::Max(1, [int]$source.width)
    $sourceHeight = [Math]::Max(1, [int]$source.height)
    $fractionX = ([double]($centerX - [int]$source.x)) / $sourceWidth
    $fractionY = ([double]($centerY - [int]$source.y)) / $sourceHeight

    $width = [Math]::Min([int]$Placement.Width, [int]$target.width)
    $height = [Math]::Min([int]$Placement.Height, [int]$target.height)
    $x = [int]$target.x + [int][Math]::Round($fractionX * ([int]$target.width - $width))
    $y = [int]$target.y + [int][Math]::Round($fractionY * ([int]$target.height - $height))
    $x = [Math]::Max([int]$target.x, [Math]::Min($x, [int]$target.x + [int]$target.width - $width))
    $y = [Math]::Max([int]$target.y, [Math]::Min($y, [int]$target.y + [int]$target.height - $height))

    return [pscustomobject]@{
        X        = $x
        Y        = $y
        Width    = $width
        Height   = $height
        Maximized = [bool]$Placement.Maximized
    }
}

function Get-SRRemoteSessions {
    # PuTTY session names and Remote Desktop targets that were actually open,
    # so restore can reconnect to them instead of opening a blank client.
    param([Parameter(Mandatory = $true)]$Windows)

    $result = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    $puttySessions = @()
    try {
        $sessionsKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\SimonTatham\PuTTY\Sessions')
        if ($null -ne $sessionsKey) {
            try {
                foreach ($name in $sessionsKey.GetSubKeyNames()) {
                    $decoded = [Uri]::UnescapeDataString($name.Replace('%20', ' '))
                    $puttySessions += $decoded
                }
            } finally { $sessionsKey.Dispose() }
        }
    } catch { }

    foreach ($window in @($Windows)) {
        $processName = ([string]$window.ProcessName).ToLowerInvariant()
        $title = ([string]$window.Title).Trim()
        if ([string]::IsNullOrWhiteSpace($title)) { continue }
        if ($processName -eq 'putty') {
            $session = $title -replace '(?i)\s*-\s*PuTTY\s*$', ''
            if ($session -and ($puttySessions -contains $session)) {
                $key = 'putty:' + $session
                if ($seen.Add($key)) {
                    $result.Add([pscustomobject]@{ kind = 'putty'; session = $session; title = $title })
                }
            }
        } elseif ($processName -eq 'mstsc') {
            $target = $title -replace '(?i)\s*-\s*(Remote Desktop Connection|Connexion Bureau à distance|Editor de conexão de área de trabalho remota)\s*$', ''
            if ($target) {
                $key = 'rdp:' + $target
                if ($seen.Add($key)) {
                    $result.Add([pscustomobject]@{ kind = 'rdp'; target = $target; title = $title })
                }
            }
        }
    }
    return $result.ToArray()
}

function Resolve-SRRdpFile {
    # Finds the .rdp file for a captured Remote Desktop window title, if any.
    param([Parameter(Mandatory = $true)][string]$Target)
    $candidates = @()
    try { $candidates += (Join-Path [Environment]::GetFolderPath('MyDocuments') ($Target + '.rdp')) } catch { }
    try { $candidates += (Join-Path [Environment]::GetFolderPath('MyDocuments') $Target) } catch { }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Snapshot comparison and restore preview
# ---------------------------------------------------------------------------

function Compare-SRSnapshot {
    # Side-by-side diff of two snapshots: which apps, folders and tabs were
    # added or removed between two moments.
    param(
        [Parameter(Mandatory = $true)]$Reference,
        [Parameter(Mandatory = $true)]$Difference
    )
    $appNameOf = {
        param($App)
        $n = [string]$App.displayName
        if ([string]::IsNullOrWhiteSpace($n)) { $n = [string]$App.name }
        if ([string]::IsNullOrWhiteSpace($n)) { $n = [string]$App.exe }
        return $n
    }
    $refApps = @(@($Reference.apps) | ForEach-Object { & $appNameOf $_ } | Where-Object { $_ })
    $diffApps = @(@($Difference.apps) | ForEach-Object { & $appNameOf $_ } | Where-Object { $_ })
    $refFolders = @(@($Reference.explorer) | ForEach-Object { [string]$_ } | Where-Object { $_ })
    $diffFolders = @(@($Difference.explorer) | ForEach-Object { [string]$_ } | Where-Object { $_ })
    $refUrls = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $diffUrls = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($browser in @($Reference.browsers)) {
        foreach ($profile in @($browser.profiles)) {
            foreach ($tab in @($profile.tabs)) { if ($tab.url) { [void]$refUrls.Add([string]$tab.url) } }
        }
    }
    foreach ($browser in @($Difference.browsers)) {
        foreach ($profile in @($browser.profiles)) {
            foreach ($tab in @($profile.tabs)) { if ($tab.url) { [void]$diffUrls.Add([string]$tab.url) } }
        }
    }
    $refDev = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $diffDev = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($workspace in @($Reference.devWorkspaces)) { foreach ($folder in @($workspace.folders)) { [void]$refDev.Add([string]$folder) } }
    foreach ($workspace in @($Difference.devWorkspaces)) { foreach ($folder in @($workspace.folders)) { [void]$diffDev.Add([string]$folder) } }

    return [pscustomobject]@{
        AppsAdded        = @($diffApps | Where-Object { $refApps -notcontains $_ })
        AppsRemoved      = @($refApps | Where-Object { $diffApps -notcontains $_ })
        FoldersAdded     = @($diffFolders | Where-Object { $refFolders -notcontains $_ })
        FoldersRemoved   = @($refFolders | Where-Object { $diffFolders -notcontains $_ })
        TabsAdded        = @($diffUrls | Where-Object { -not $refUrls.Contains($_) })
        TabsRemoved      = @($refUrls | Where-Object { -not $diffUrls.Contains($_) })
        DevFoldersAdded  = @($diffDev | Where-Object { -not $refDev.Contains($_) })
        DevFoldersRemoved = @($refDev | Where-Object { -not $diffDev.Contains($_) })
    }
}

function Get-SRRestorePreview {
    # What a restore would do right now: which apps are already running, which
    # will start, and which are missing from this machine.
    param([Parameter(Mandatory = $true)]$Plan)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($app in @($Plan.apps)) {
        if ($null -eq $app) { continue }
        $exe = [string]$app.exe
        $state = 'will-start'
        if ([string]::IsNullOrWhiteSpace($exe) -or -not (Test-Path -LiteralPath $exe)) { $state = 'missing' }
        elseif (Test-SRExeRunning -ExePath $exe) { $state = 'running' }
        $rows.Add([pscustomobject]@{
            Kind  = 'app'
            Name  = if ($app.name) { [string]$app.name } else { $exe }
            State = $state
        })
    }
    foreach ($folder in @($Plan.explorer)) {
        if ([string]::IsNullOrWhiteSpace([string]$folder)) { continue }
        $rows.Add([pscustomobject]@{
            Kind  = 'folder'
            Name  = [string]$folder
            State = if (Test-Path -LiteralPath ([string]$folder)) { 'will-open' } else { 'missing' }
        })
    }
    foreach ($browser in @($Plan.browsers)) {
        if ($null -eq $browser) { continue }
        $exe = [string]$browser.exe
        $state = 'will-start'
        if ([string]::IsNullOrWhiteSpace($exe) -or -not (Test-Path -LiteralPath $exe)) { $state = 'missing' }
        elseif (Test-SRExeRunning -ExePath $exe) { $state = 'running' }
        $rows.Add([pscustomobject]@{
            Kind  = 'browser'
            Name  = [string]$browser.name
            State = $state
        })
    }
    return [pscustomobject]@{
        Rows       = $rows.ToArray()
        Running    = @($rows | Where-Object { $_.State -eq 'running' }).Count
        WillStart  = @($rows | Where-Object { $_.State -in 'will-start', 'will-open' }).Count
        Missing    = @($rows | Where-Object { $_.State -eq 'missing' }).Count
    }
}

# ---------------------------------------------------------------------------
# Local control API (named pipe, used by the tray and Control-SessionRecovery)
# ---------------------------------------------------------------------------

function Send-SRControl {
    # Sends one command to the running tray app over the SessionRecoveryControl
    # named pipe. Commands: snapshot, pause, resume, status, restore-latest,
    # workspace-save <name>, workspace-restore <name>.
    param(
        [Parameter(Mandatory = $true)][ValidateSet('snapshot', 'pause', 'resume', 'status', 'restore-latest', 'workspace-save', 'workspace-restore')][string]$Command,
        [string]$Name = '',
        [int]$TimeoutMilliseconds = 4000
    )
    $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', 'SessionRecoveryControl', [System.IO.Pipes.PipeDirection]::InOut)
    try {
        $pipe.Connect($TimeoutMilliseconds)
        $payload = @{ command = $Command; name = $Name } | ConvertTo-Json -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
        $pipe.Write($bytes, 0, $bytes.Length)
        $pipe.WriteByte(10)
        $pipe.Flush()
        $pipe.ReadMode = [System.IO.Pipes.PipeTransmissionMode]::Byte
        $reader = New-Object System.IO.StreamReader($pipe)
        $task = $reader.ReadLineAsync()
        if (-not $task.Wait($TimeoutMilliseconds)) { throw 'The control pipe did not answer in time.' }
        return ($task.Result | ConvertFrom-Json)
    } finally {
        try { $pipe.Dispose() } catch { }
    }
}

# ---------------------------------------------------------------------------
# Snapshot creation
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Window thumbnails (opt-in), URL redaction, gzip and encrypted storage
# ---------------------------------------------------------------------------

$script:SRThumbHelper = $null
function Get-SRThumbHelper {
    if ($null -ne $script:SRThumbHelper) { return $script:SRThumbHelper }
    $source = @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;

namespace SessionRecovery {
    public static class WindowThumb {
        [StructLayout(LayoutKind.Sequential)]
        struct RECT { public int Left, Top, Right, Bottom; }
        [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hWnd);

        public static bool Capture(IntPtr hWnd, string path, int targetWidth) {
            if (hWnd == IntPtr.Zero || IsIconic(hWnd)) { return false; }
            RECT rect;
            if (!GetWindowRect(hWnd, out rect)) { return false; }
            int width = rect.Right - rect.Left;
            int height = rect.Bottom - rect.Top;
            if (width < 120 || height < 80) { return false; }
            if (width > 2000) { width = 2000; }
            if (height > 1200) { height = 1200; }
            try {
                using (Bitmap window = new Bitmap(width, height, PixelFormat.Format32bppRgb)) {
                    using (Graphics g = Graphics.FromImage(window)) {
                        IntPtr hdc = g.GetHdc();
                        try { PrintWindow(hWnd, hdc, 2); } finally { g.ReleaseHdc(hdc); }
                    }
                    int thumbWidth = targetWidth;
                    int thumbHeight = Math.Max(1, (int)Math.Round(height * (targetWidth / (double)width)));
                    using (Bitmap thumb = new Bitmap(thumbWidth, thumbHeight, PixelFormat.Format32bppRgb)) {
                        using (Graphics tg = Graphics.FromImage(thumb)) {
                            tg.InterpolationMode = InterpolationMode.HighQualityBilinear;
                            tg.DrawImage(window, 0, 0, thumbWidth, thumbHeight);
                        }
                        ImageCodecInfo jpeg = null;
                        foreach (ImageCodecInfo codec in ImageCodecInfo.GetImageEncoders()) {
                            if (codec.MimeType == "image/jpeg") { jpeg = codec; }
                        }
                        EncoderParameters quality = new EncoderParameters(1);
                        quality.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, 70L);
                        string parent = Path.GetDirectoryName(path);
                        if (!string.IsNullOrEmpty(parent) && !Directory.Exists(parent)) { Directory.CreateDirectory(parent); }
                        thumb.Save(path, jpeg, quality);
                        quality.Dispose();
                    }
                }
                return true;
            } catch {
                return false;
            }
        }
    }
}
'@
    Add-Type -TypeDefinition $source -ReferencedAssemblies System.Drawing -ErrorAction Stop
    $script:SRThumbHelper = $true
    return $script:SRThumbHelper
}

function New-SRThumbnailSet {
    # Saves one downscaled JPEG per captured application and browser window.
    # Only entries that survived the exclusion rules are asked for a picture,
    # so excluded apps are never rendered to disk.
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)][object[]]$Windows,
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$MaxThumbnails = 24
    )
    $result = @()
    try { Get-SRThumbHelper | Out-Null } catch { return $result }
    $thumbsRoot = Join-Path $script:SRSnapshotDir 'thumbs'
    $targetDir = Join-Path $thumbsRoot $Name
    $captured = 0
    $index = 0

    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($app in @($Snapshot.apps)) {
        $candidates.Add([pscustomobject]@{ Entry = $app; ProcessName = ([string]$app.name).ToLowerInvariant(); Owner = 'apps' })
    }
    foreach ($browser in @($Snapshot.browsers)) {
        $processNames = @('chrome', 'msedge', 'brave', 'vivaldi', 'opera', 'chromium', 'firefox', 'waterfox', 'librewolf')
        $matchName = ([string]$browser.exe)
        if (-not [string]::IsNullOrWhiteSpace($matchName)) {
            $matchName = [System.IO.Path]::GetFileNameWithoutExtension($matchName).ToLowerInvariant()
        }
        if ([string]::IsNullOrWhiteSpace($matchName)) { $matchName = 'chrome' }
        $candidates.Add([pscustomobject]@{ Entry = $browser; ProcessName = $matchName; Owner = 'browsers' })
    }

    foreach ($candidate in $candidates) {
        if ($captured -ge $MaxThumbnails) { break }
        $best = $null
        $bestArea = 0
        foreach ($window in $Windows) {
            if (([string]$window.ProcessName).ToLowerInvariant() -ne $candidate.ProcessName) { continue }
            if ([bool]$window.Minimized) { continue }
            $area = ([int]$window.Width) * ([int]$window.Height)
            if ($area -gt $bestArea) { $bestArea = $area; $best = $window }
        }
        if ($null -eq $best) { continue }
        $index++
        $fileName = '{0:d2}-{1}.jpg' -f $index, ($candidate.ProcessName -replace '[^a-z0-9_.-]', '_')
        $filePath = Join-Path $targetDir $fileName
        try {
            $ok = [SessionRecovery.WindowThumb]::Capture([IntPtr][int64]$best.Handle, $filePath, 240)
            if ($ok) {
                $relative = 'thumbs/' + $Name + '/' + $fileName
                if ($candidate.Owner -eq 'apps') {
                    $candidate.Entry | Add-Member -NotePropertyName thumb -NotePropertyValue $relative -Force
                } else {
                    $candidate.Entry | Add-Member -NotePropertyName thumb -NotePropertyValue $relative -Force
                }
                $result += $relative
                $captured++
            }
        } catch { }
    }
    return $result
}

function Remove-SRThumbnails {
    param([Parameter(Mandatory = $true)][string]$SnapshotName)
    try {
        $dir = Join-Path (Join-Path $script:SRSnapshotDir 'thumbs') $SnapshotName
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    } catch { }
}

function Redact-SRUrl {
    # Strips query strings and fragments so tokens never reach disk.
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $Url }
    $value = [string]$Url
    $hashIndex = $value.IndexOf('#')
    if ($hashIndex -ge 0) { $value = $value.Substring(0, $hashIndex) }
    $queryIndex = $value.IndexOf('?')
    if ($queryIndex -ge 0) { $value = $value.Substring(0, $queryIndex) }
    return $value
}

function Invoke-SRUrlRedaction {
    param([Parameter(Mandatory = $true)]$Snapshot)
    foreach ($browser in @($Snapshot.browsers)) {
        foreach ($profile in @($browser.profiles)) {
            foreach ($tab in @($profile.tabs)) {
                $urlProperty = $tab.PSObject.Properties['url']
                if ($null -ne $urlProperty) {
                    $tab.url = Redact-SRUrl ([string]$urlProperty.Value)
                }
            }
        }
    }
}

function Get-SRSnapshotStateHash {
    # A stable fingerprint of everything that matters in a snapshot, used to
    # skip writing files when nothing on screen changed.
    param([Parameter(Mandatory = $true)]$Snapshot)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($app in @($Snapshot.apps)) {
        $parts.Add('a:' + [string]$app.exe + ':' + @($app.windows).Count)
    }
    foreach ($folder in @($Snapshot.explorer)) { $parts.Add('f:' + [string]$folder) }
    foreach ($browser in @($Snapshot.browsers)) {
        foreach ($profile in @($browser.profiles)) {
            foreach ($tab in @($profile.tabs)) { $parts.Add('t:' + [string]$tab.url + ':' + [string]$tab.title) }
        }
    }
    foreach ($workspace in @($Snapshot.devWorkspaces)) {
        foreach ($folder in @($workspace.folders)) { $parts.Add('d:' + [string]$folder) }
    }
    $text = ($parts -join "`n")
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try { return ([System.BitConverter]::ToString($md5.ComputeHash($bytes)) -replace '-', '') } finally { $md5.Dispose() }
}

function Get-SRSnapshotEncryptionEntropy {
    # Fixed secondary entropy so every Session Recovery install on the machine
    # agrees with itself. The real protection is the DPAPI user key.
    return [System.Text.Encoding]::ASCII.GetBytes('SessionRecovery.Snapshot.v1')
}

function Protect-SRSnapshotBytes {
    # DPAPI (per-user) encryption for snapshot payloads. Returns a "SRDP1"
    # header followed by the protected blob so readers can detect it.
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    Add-Type -AssemblyName System.Security -ErrorAction Stop
    $entropy = Get-SRSnapshotEncryptionEntropy
    $protected = [System.Security.Cryptography.ProtectedData]::Protect($Bytes, $entropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    $stream = New-Object System.IO.MemoryStream
    $stream.Write([System.Text.Encoding]::ASCII.GetBytes('SRDP1'), 0, 5)
    $stream.Write($protected, 0, $protected.Length)
    return $stream.ToArray()
}

function Unprotect-SRSnapshotBytes {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    if ($Bytes.Length -le 5) { throw 'Encrypted snapshot payload is empty.' }
    Add-Type -AssemblyName System.Security -ErrorAction Stop
    $entropy = Get-SRSnapshotEncryptionEntropy
    $protected = New-Object byte[] ($Bytes.Length - 5)
    [Array]::Copy($Bytes, 5, $protected, 0, $protected.Length)
    return [System.Security.Cryptography.ProtectedData]::Unprotect($protected, $entropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
}

function Read-SRSnapshotFile {
    # Reads a snapshot as parsed JSON, transparently handling DPAPI-encrypted
    # ("SRDP1" header) and gzip (session-*.json.gz) files.
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 5 -and $bytes[0] -eq 0x53 -and $bytes[1] -eq 0x52 -and $bytes[2] -eq 0x44 -and $bytes[3] -eq 0x50 -and $bytes[4] -eq 0x31) {
        $bytes = Unprotect-SRSnapshotBytes -Bytes $bytes
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0x1F -and $bytes[1] -eq 0x8B) {
        $inputStream = $null; $gzip = $null
        try {
            $inputStream = New-Object System.IO.MemoryStream(,$bytes)
            $gzip = New-Object System.IO.Compression.GZipStream($inputStream, [System.IO.Compression.CompressionMode]::Decompress)
            $output = New-Object System.IO.MemoryStream
            $gzip.CopyTo($output)
            $text = [System.Text.Encoding]::UTF8.GetString($output.ToArray())
        } finally {
            if ($null -ne $gzip) { $gzip.Dispose() }
            if ($null -ne $inputStream) { $inputStream.Dispose() }
        }
    } else {
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    }
    # Hand-edited or externally restored snapshots may carry a UTF-8 BOM.
    # ConvertFrom-Json rejects it, so drop a single leading BOM.
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    return ($text | ConvertFrom-Json)
}

function Get-SRSnapshotFiles {
    # Both plain and gzip snapshots, newest first.
    return @(Get-ChildItem -LiteralPath $script:SRSnapshotDir -Filter 'session-*.json*' -File -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTime -Descending)
}

function ConvertFrom-SRFileUri {
    # 'file:///c%3A/Users/x' -> 'C:\Users\x' without relying on Uri parsing.
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    if (-not $Value.StartsWith('file://')) { return $Value }
    try {
        $rest = $Value.Substring('file://'.Length)
        $rest = [Uri]::UnescapeDataString($rest)
        if (-not $rest.StartsWith('/')) {
            # file://server/share is the UNC host form.
            return '\\' + $rest.Replace('/', '\')
        }
        if ($rest.StartsWith('/')) {
            # file:/<host>/share for UNC paths, file:///c:/ for local drives.
            $trimmed = $rest.TrimStart('/')
            $slash = $trimmed.IndexOf('/')
            if ($slash -gt 0 -and $trimmed.Substring(0, $slash) -notmatch '^[a-zA-Z]:$') {
                return '\\' + $trimmed.Replace('/', '\')
            }
            $rest = $trimmed
        }
        $path = $rest.Replace('/', '\')
        if ($path -match '^([a-zA-Z]):\\') {
            $path = $path.Substring(0, 1).ToUpperInvariant() + $path.Substring(1)
        }
        return $path
    } catch {
        return $Value
    }
}

function Get-SRDevWorkspaces {
    # Reads the editors' own state files (no processes needed) so a restore
    # can reopen the exact folders and projects that were open.
    $result = New-Object System.Collections.Generic.List[object]

    foreach ($pair in @(@('VS Code', (Join-Path $env:APPDATA 'Code')), @('Cursor', (Join-Path $env:APPDATA 'Cursor')))) {
        $tool = [string]$pair[0]
        $root = [string]$pair[1]
        try {
            $storagePath = Join-Path $root 'User\globalStorage\storage.json'
            if (-not (Test-Path -LiteralPath $storagePath)) { $storagePath = Join-Path $root 'storage.json' }
            if (-not (Test-Path -LiteralPath $storagePath)) { $storagePath = Join-Path $root 'backup\storage.json' }
            if (-not (Test-Path -LiteralPath $storagePath)) { continue }
            $storage = Get-Content -LiteralPath $storagePath -Raw -ErrorAction Stop | ConvertFrom-Json
            $folders = New-Object System.Collections.Generic.List[string]
            $state = $storage.windowsState
            if ($null -ne $state) {
                # Property-bag access keeps this working regardless of which
                # windowsState fields a given editor build persists.
                $candidates = @()
                $lastWindowProperty = $state.PSObject.Properties['lastActiveWindow']
                if ($null -ne $lastWindowProperty) { $candidates += @($lastWindowProperty.Value) }
                $openedProperty = $state.PSObject.Properties['openedWindows']
                if ($null -ne $openedProperty) { $candidates += @($openedProperty.Value) }
                $workspaceProperty = $state.PSObject.Properties['workspaceFolders']
                if ($null -ne $workspaceProperty) { $candidates += @($workspaceProperty.Value) }
                foreach ($entry in $candidates) {
                    if ($null -eq $entry) { continue }
                    foreach ($propertyName in @('folder', 'workspace')) {
                        $property = $entry.PSObject.Properties[$propertyName]
                        if ($null -eq $property) { continue }
                        $value = ConvertFrom-SRFileUri ([string]$property.Value)
                        if (-not [string]::IsNullOrWhiteSpace($value) -and -not $folders.Contains($value)) {
                            $folders.Add($value)
                        }
                    }
                }
            }
            if ($folders.Count -gt 0) {
                $result.Add([pscustomobject]@{
                    kind    = 'vscode'
                    tool    = $tool
                    folders = $folders.ToArray()
                })
            }
        } catch {
            try { Write-SRLog -Level DEBUG -Message ("DevWorkspace {0} failed: {1}" -f $tool, $_.Exception.Message) } catch { }
        }
    }

    # JetBrains IDEs keep recent projects in recentProjects.xml.
    try {
        $jetbrainsRoot = Join-Path $env:APPDATA 'JetBrains'
        if (Test-Path -LiteralPath $jetbrainsRoot) {
            foreach ($product in @(Get-ChildItem -LiteralPath $jetbrainsRoot -Directory -ErrorAction SilentlyContinue)) {
                $recentPath = Join-Path $product.FullName 'options\recentProjects.xml'
                if (-not (Test-Path -LiteralPath $recentPath)) { continue }
                try {
                    [xml]$xml = Get-Content -LiteralPath $recentPath -Raw -ErrorAction Stop
                    $folders = New-Object System.Collections.Generic.List[string]
                    foreach ($component in @($xml.component)) {
                        if ([string]$component.name -ne 'RecentProjectsManager') { continue }
                        foreach ($project in @($component.option | Where-Object { $_.name -eq 'recentPaths' } | ForEach-Object { $_.list.path })) {
                            $value = ([string]$project).Replace('$USER_HOME$', $env:USERPROFILE)
                            if (-not [string]::IsNullOrWhiteSpace($value) -and (Test-Path -LiteralPath $value) -and -not $folders.Contains($value)) {
                                $folders.Add($value)
                                if ($folders.Count -ge 5) { break }
                            }
                        }
                    }
                    if ($folders.Count -gt 0) {
                        $result.Add([pscustomobject]@{
                            kind    = 'jetbrains'
                            tool    = $product.Name
                            folders = $folders.ToArray()
                        })
                    }
                } catch { }
            }
        }
    } catch { }

    # Windows Terminal tabs live in state.json inside the store package.
    try {
        $wtState = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\state.json'
        if (Test-Path -LiteralPath $wtState) {
            $state = Get-Content -LiteralPath $wtState -Raw -ErrorAction Stop | ConvertFrom-Json
            $dirs = New-Object System.Collections.Generic.List[string]
            $tabRows = New-Object System.Collections.Generic.List[object]
            $walkTabs = $null
            $walkTabs = {
                param($Tabs)
                foreach ($tab in @($Tabs)) {
                    $title = [string]$tab.title
                    $cwd = [string]$tab.cwd
                    $profile = [string]$tab.profile
                    if ([string]::IsNullOrWhiteSpace($cwd)) { $cwd = '' }
                    if ($cwd.StartsWith('file://')) { $cwd = $cwd.Substring(7) -replace '/', '\' }
                    $tabRows.Add([pscustomobject]@{ title = $title; profile = $profile; cwd = $cwd })
                    if (-not [string]::IsNullOrWhiteSpace($cwd) -and (Test-Path -LiteralPath $cwd) -and -not $dirs.Contains($cwd)) { $dirs.Add($cwd) }
                    if ($null -ne $tab.panes) { & $walkTabs @($tab.panes) }
                    if ($null -ne $tab.tab.panes) { & $walkTabs @($tab.tab.panes) }
                    if ($null -ne $tab.tabs) { & $walkTabs @($tab.tabs) }
                }
            }
            if ($null -ne $state.windows) {
                foreach ($window in @($state.windows)) { & $walkTabs @($window.tabs) }
            } elseif ($null -ne $state.tabs) {
                & $walkTabs @($state.tabs)
            }
            if ($tabRows.Count -gt 0) {
                $result.Add([pscustomobject]@{
                    kind    = 'terminal'
                    tool    = 'Windows Terminal'
                    folders = $dirs.ToArray()
                    tabs    = $tabRows.ToArray()
                })
            }
        }
    } catch { }

    return $result.ToArray()
}

function Get-SRJetBrainsLauncher {
    # Maps a JetBrains config folder (for example IntelliJIdea2024.1) to the
    # installed IDE launcher so restore can open the project directly instead
    # of falling back to an Explorer window.
    param([string]$Product)
    if ([string]::IsNullOrWhiteSpace($Product)) { return $null }

    $executables = @{
        'IntelliJIdea' = 'idea64.exe'
        'IdeaIC'       = 'idea64.exe'
        'PyCharm'      = 'pycharm64.exe'
        'WebStorm'     = 'webstorm64.exe'
        'PhpStorm'     = 'phpstorm64.exe'
        'RubyMine'     = 'rubymine64.exe'
        'CLion'        = 'clion64.exe'
        'GoLand'       = 'goland64.exe'
        'Rider'        = 'rider64.exe'
        'DataGrip'     = 'datagrip64.exe'
        'DataSpell'    = 'dataspell64.exe'
        'AppCode'      = 'appcode64.exe'
        'Aqua'         = 'aqua64.exe'
        'RustRover'    = 'rustrover64.exe'
        'Writerside'   = 'writerside64.exe'
    }
    $exeName = $null
    foreach ($prefix in @($executables.Keys | Sort-Object -Property Length -Descending)) {
        if ($Product -like ($prefix + '*')) {
            $exeName = [string]$executables[$prefix]
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($exeName)) { return $null }

    $roots = @(
        (Join-Path $env:LOCALAPPDATA 'Programs'),
        (Join-Path $env:LOCALAPPDATA 'JetBrains\Toolbox\apps'),
        (Join-Path $env:ProgramFiles 'JetBrains'),
        (Join-Path ${env:ProgramFiles(x86)} 'JetBrains')
    )
    foreach ($root in $roots) {
        if ([string]::IsNullOrWhiteSpace([string]$root) -or -not (Test-Path -LiteralPath $root)) { continue }
        try {
            $found = Get-ChildItem -LiteralPath $root -Filter $exeName -File -Recurse -Depth 4 -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($null -ne $found) { return $found.FullName }
        } catch { }
    }
    return $null
}

function Get-SRLastShutdownReason {
    # Plain-language reason for the most recent shutdown, and whether it was
    # a crash. Replaces guesswork in the restore prompt with facts. ReasonKey
    # and ReasonArg let the UI translate the reason; Reason stays in English
    # for diagnostics/CLI output.
    $result = [pscustomobject]@{ Kind = 'unknown'; Reason = ''; ReasonKey = ''; ReasonArg = ''; At = $null }
    try {
        $since = (Get-Date).AddDays(-7)
        $events = @()
        foreach ($filter in @(
            @{ LogName = 'System'; Id = 41; ProviderName = 'Microsoft-Windows-Kernel-Power' },
            @{ LogName = 'System'; Id = 1001; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting' },
            @{ LogName = 'System'; Id = 6008 },
            @{ LogName = 'System'; Id = 1074 },
            @{ LogName = 'System'; Id = 6006 }
        )) {
            $query = @{ LogName = 'System'; Id = $filter['Id']; StartTime = $since }
            if ($filter['ProviderName']) { $query['ProviderName'] = $filter['ProviderName'] }
            foreach ($event in @(Get-WinEvent -FilterHashtable $query -ErrorAction SilentlyContinue)) {
                $properties = @()
                try { $properties = @($event.Properties | ForEach-Object { [string]$_.Value }) } catch { }
                $events += [pscustomobject]@{ Id = $filter['Id']; At = $event.TimeCreated; Message = [string]$event.Message; Properties = $properties }
            }
        }
        $events = @($events | Sort-Object -Property At -Descending)
        if ($events.Count -eq 0) { return $result }

        $bugcheck = @($events | Where-Object { $_.Id -eq 1001 } | Select-Object -First 1)
        $kernelPower = @($events | Where-Object { $_.Id -eq 41 } | Select-Object -First 1)
        $unexpected = @($events | Where-Object { $_.Id -eq 6008 } | Select-Object -First 1)
        $initiated = @($events | Where-Object { $_.Id -eq 1074 } | Select-Object -First 1)
        $clean = @($events | Where-Object { $_.Id -eq 6006 } | Select-Object -First 1)

        $cleanAt = [datetime]::MinValue
        if ($clean.Count -gt 0) { $cleanAt = $clean[0].At }
        if ($bugcheck.Count -gt 0 -and $cleanAt -lt $bugcheck[0].At) {
            $stop = ''
            if ($bugcheck[0].Message -match '0x[0-9a-fA-F]{8}') { $stop = $Matches[0] }
            $result.Kind = 'crash'
            $result.ReasonKey = 'ShutdownBlueScreen'
            $result.ReasonArg = $stop
            $result.Reason = 'Blue screen (stop code ' + $stop + ')'
            $result.At = $bugcheck[0].At
            return $result
        }
        if ($kernelPower.Count -gt 0 -and $cleanAt -lt $kernelPower[0].At) {
            $result.Kind = 'crash'
            $result.ReasonKey = 'ShutdownPowerLoss'
            $result.Reason = 'Power loss or forced restart (the system did not shut down cleanly)'
            $result.At = $kernelPower[0].At
            return $result
        }
        if ($unexpected.Count -gt 0 -and $cleanAt -lt $unexpected[0].At) {
            $result.Kind = 'crash'
            $result.ReasonKey = 'ShutdownUnexpected'
            $result.Reason = 'Unexpected shutdown'
            $result.At = $unexpected[0].At
            return $result
        }
        if ($initiated.Count -gt 0) {
            # Event 1074 messages are localized, so parse the structured
            # properties: the first is the process path, the last is the user.
            # Never return an empty "initiated by" name.
            $by = ''
            $properties = @($initiated[0].Properties)
            if ($properties.Count -gt 0) {
                $processValue = [string]$properties[0]
                if ($processValue -match '([^\\/]+\.exe)') { $by = $Matches[1] }
                elseif ($properties.Count -gt 6 -and -not [string]::IsNullOrWhiteSpace([string]$properties[6])) {
                    $by = [string]$properties[6]
                }
            }
            if ([string]::IsNullOrWhiteSpace($by)) { $by = 'Windows' }
            $result.Kind = 'clean'
            $result.ReasonKey = 'ShutdownInitiated'
            $result.ReasonArg = $by
            $result.Reason = 'Shutdown initiated by ' + $by
            $result.At = $initiated[0].At
            return $result
        }
        if ($clean.Count -gt 0) {
            $result.Kind = 'clean'
            $result.ReasonKey = 'ShutdownNormal'
            $result.Reason = 'Normal shutdown'
            $result.At = $clean[0].At
        }
    } catch { }
    return $result
}

function Get-SROfficeRecoveryFiles {
    # Lists the AutoRecover files Office keeps after a crash, so the user can
    # be pointed straight at them from the restore window.
    $result = New-Object System.Collections.Generic.List[object]
    $roots = @(
        @{ App = 'Word';  Path = Join-Path $env:APPDATA 'Microsoft\Word' },
        @{ App = 'Excel'; Path = Join-Path $env:APPDATA 'Microsoft\Excel' },
        @{ App = 'PowerPoint'; Path = Join-Path $env:APPDATA 'Microsoft\PowerPoint' },
        @{ App = 'Office'; Path = Join-Path $env:LOCALAPPDATA 'Microsoft\Office\UnsavedFiles' }
    )
    foreach ($root in $roots) {
        try {
            if (-not (Test-Path -LiteralPath $root.Path)) { continue }
            $files = @(Get-ChildItem -LiteralPath $root.Path -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in '.asd', '.wbk', '.xar', '.xlsb' -and $_.LastWriteTime -gt (Get-Date).AddDays(-3) })
            foreach ($file in $files) {
                $result.Add([pscustomobject]@{
                    app  = $root.App
                    file = $file.FullName
                    at   = $file.LastWriteTime.ToString('o')
                    size = $file.Length
                })
            }
        } catch { }
    }
    return $result.ToArray()
}

function Get-SRWorkspaces {
    # Named, manually saved sessions. Each is a full snapshot copy under
    # <data>\workspaces\<name>.json that the tray can restore directly.
    $result = New-Object System.Collections.Generic.List[object]
    try {
        $dir = Join-Path $script:SRRoot 'workspaces'
        if (-not (Test-Path -LiteralPath $dir)) { return $result.ToArray() }
        foreach ($file in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object -Property Name)) {
            $result.Add([pscustomobject]@{
                Name = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
                Path = $file.FullName
                At   = $file.LastWriteTime
            })
        }
    } catch { }
    return $result.ToArray()
}

function Save-SRWorkspace {
    param([Parameter(Mandatory = $true)][string]$Name)
    $safe = ($Name -replace '[^\w\-. ]', '_').Trim()
    if ([string]::IsNullOrWhiteSpace($safe)) { throw 'Workspace name is empty.' }
    $files = @(Get-SRSnapshotFiles)
    if ($files.Count -eq 0) { throw 'No snapshot exists yet.' }
    $source = $files[0].FullName
    $snapshot = Read-SRSnapshotFile -Path $source
    $dir = Join-Path $script:SRRoot 'workspaces'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $target = Join-Path $dir ($safe + '.json')
    $json = $snapshot | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($target, $json, (New-Object System.Text.UTF8Encoding($false)))
    try {
        $sourceThumbs = Join-Path $script:SRSnapshotDir ('thumbs\' + [System.IO.Path]::GetFileNameWithoutExtension($source))
        if (Test-Path -LiteralPath $sourceThumbs) {
            Copy-Item -LiteralPath $sourceThumbs -Destination (Join-Path $dir ($safe + '-thumbs')) -Recurse -Force
        }
    } catch { }
    return $target
}

function New-SRSnapshot {
    $windows = @([SessionRecovery.WindowEnumerator]::GetVisibleWindows())
    $processMap = Get-SRProcessMap
    $config = Get-SRConfig
    $apps = @(Get-SRApplications -Windows $windows -ProcessMap $processMap)
    $folders = @(Get-SRExplorerFolders -Windows $windows)
    $browsers = @()
    if ($null -eq $config.PSObject.Properties['captureBrowserTabs'] -or [bool]$config.captureBrowserTabs) {
        $browsers = @(Get-SRBrowsers -Windows $windows -ProcessMap $processMap -Config $config)
    }
    if ($null -eq $config.PSObject.Properties['captureMediaPlayers'] -or [bool]$config.captureMediaPlayers) {
        # Attaches the playing media file and an estimated position to media
        # player entries (currently VLC).
        Get-SRMediaPlayerMedia -Apps $apps -Config $config
    }

    # Apply the user's capture exclusions before the snapshot is written, so
    # excluded names, folders and URLs never reach the JSON files on disk.

    $excludeApps = @($config.excludeApps)
    if ($excludeApps.Count -gt 0) {
        $apps = @($apps | Where-Object {
            -not (Test-SRPatternMatch -Patterns $excludeApps -Values @([string]$_.name, [string]$_.exe))
        })
        # A browser the user excluded must not keep capturing tabs or window
        # thumbnails through the browser path.
        $browsers = @($browsers | Where-Object {
            -not (Test-SRPatternMatch -Patterns $excludeApps -Values @([string]$_.key, [string]$_.name, [string]$_.exe))
        })
    }

    $excludeFolders = @($config.excludeFolders)
    if ($excludeFolders.Count -gt 0) {
        # Media files inside excluded folders must not reach the snapshot.
        foreach ($app in $apps) {
            $mediaProperty = $app.PSObject.Properties['media']
            if ($null -eq $mediaProperty -or $null -eq $mediaProperty.Value) { continue }
            $mediaFile = [string]$mediaProperty.Value.file
            if (Test-SRPatternMatch -Patterns $excludeFolders -Values @($mediaFile)) {
                $app.PSObject.Properties.Remove('media')
            }
        }
    }

    $excludeFolders = @($config.excludeFolders)
    if ($excludeFolders.Count -gt 0) {
        $folders = @($folders | Where-Object {
            -not (Test-SRPatternMatch -Patterns $excludeFolders -Values @([string]$_))
        })
    }

    $excludeUrls = @($config.excludeUrls)
    if ($excludeUrls.Count -gt 0) {
        foreach ($browser in $browsers) {
            $keptProfiles = New-Object System.Collections.Generic.List[object]
            foreach ($profile in @($browser.profiles)) {
                $before = @($profile.tabs).Count
                $profile.tabs = @($profile.tabs | Where-Object {
                    -not (Test-SRPatternMatch -Patterns $excludeUrls -Values @([string]$_.url))
                })
                # If every tab in a profile was excluded, drop the profile so
                # Smart/native restore cannot silently reopen excluded pages.
                if ($before -gt 0 -and @($profile.tabs).Count -eq 0) { continue }
                $keptProfiles.Add($profile)
            }
            $browser.profiles = $keptProfiles.ToArray()
        }
        $browsers = @($browsers | Where-Object { @($_.profiles).Count -gt 0 })
    }

    $now = Get-Date
    $logonTime = Get-SRLogonTime
    $tabCount = 0
    foreach ($browser in $browsers) {
        foreach ($profile in $browser.profiles) {
            $tabCount += @($profile.tabs).Count
        }
    }

    # Privacy: strip query strings and fragments from captured URLs unless
    # the user turned redaction off.
    $redactUrls = $true
    try {
        $redactProperty = $config.PSObject.Properties['redactUrls']
        if ($null -ne $redactProperty) { $redactUrls = [bool]$redactProperty.Value }
    } catch { }
    if ($redactUrls) {
        foreach ($browser in $browsers) {
            foreach ($profile in @($browser.profiles)) {
                foreach ($tab in @($profile.tabs)) {
                    $urlProperty = $tab.PSObject.Properties['url']
                    if ($null -ne $urlProperty) { $tab.url = Redact-SRUrl ([string]$urlProperty.Value) }
                }
            }
        }
    }

    $devWorkspaces = @()
    $devCapture = $true
    try {
        $devProperty = $config.PSObject.Properties['captureDevWorkspaces']
        if ($null -ne $devProperty) { $devCapture = [bool]$devProperty.Value }
    } catch { }
    if ($devCapture) { $devWorkspaces = @(Get-SRDevWorkspaces) }

    # Virtual desktops (best-effort, documented IVirtualDesktopManager): each
    # captured app remembers the desktop its window lived on.
    $restoreDesktops = $true
    try {
        $desktopsProperty = $config.PSObject.Properties['restoreVirtualDesktops']
        if ($null -ne $desktopsProperty) { $restoreDesktops = [bool]$desktopsProperty.Value }
    } catch { }
    if ($restoreDesktops -and (Get-SRVirtualDesktopHelper)) {
        foreach ($app in $apps) {
            $matchName = ([string]$app.name).ToLowerInvariant()
            $best = $null
            foreach ($window in $windows) {
                if (([string]$window.ProcessName).ToLowerInvariant() -ne $matchName) { continue }
                if ([bool]$window.Minimized) { continue }
                $best = $window
                break
            }
            if ($null -eq $best) {
                foreach ($window in $windows) {
                    if (([string]$window.ProcessName).ToLowerInvariant() -eq $matchName) { $best = $window; break }
                }
            }
            if ($null -ne $best) {
                $desktopId = Get-SRWindowDesktopId -WindowHandle ([IntPtr][int64]$best.Handle)
                if (-not [string]::IsNullOrWhiteSpace($desktopId)) {
                    $app | Add-Member -NotePropertyName desktopId -NotePropertyValue $desktopId -Force
                }
            }
        }
    }

    # Remote sessions: open PuTTY sessions and Remote Desktop targets.
    $remote = @(Get-SRRemoteSessions -Windows $windows)

    # Monitor layout at capture time, so restore can map windows from
    # monitors that no longer exist instead of only clamping them.
    $monitors = @(Get-SRMonitors)

    # Kept for the thumbnail pass in Save-SRSnapshot; never serialized.
    $script:SRLastWindows = $windows

    $snapshot = [pscustomobject]@{
        schemaVersion = 1
        provenance    = [pscustomobject]@{
            format         = 1
            installationId = (Get-SRInstallationId)
        }
        capturedAt    = $now.ToString('o')
        capturedAtUtc = $now.ToUniversalTime().ToString('o')
        logonTime     = $logonTime.ToString('o')
        user          = [string]$env:USERNAME
        domain        = [string]$env:USERDOMAIN
        machine       = [string]$env:COMPUTERNAME
        sessionId     = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
        apps          = $apps
        explorer      = $folders
        browsers      = $browsers
        devWorkspaces = $devWorkspaces
        remote        = $remote
        monitors      = $monitors
        stats         = [pscustomobject]@{
            windows  = $windows.Count
            apps     = $apps.Count
            folders  = $folders.Count
            browsers = $browsers.Count
            tabs     = $tabCount
        }
    }
    $snapshot | Add-Member -NotePropertyName stateHash -NotePropertyValue (Get-SRSnapshotStateHash -Snapshot $snapshot) -Force
    return $snapshot
}

function Remove-OldSRSnapshots {
    param(
        [int]$Keep = 48,
        [int]$MaxAgeDays = 0,
        [string[]]$Pinned = @()
    )
    if ($Keep -lt 1) { $Keep = 1 }

    # Pinned snapshots are never deleted by retention, and they do not
    # consume the keep-count budget.
    $pinnedNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @($Pinned)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$name)) { [void]$pinnedNames.Add([string]$name) }
    }

    $files = @(Get-ChildItem -LiteralPath $script:SRSnapshotDir -Filter 'session-*.json*' -File -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTime -Descending)

    if ($MaxAgeDays -gt 0) {
        $cutoff = (Get-Date).AddDays(-1 * [Math]::Abs($MaxAgeDays))
        foreach ($file in $files) {
            if ($pinnedNames.Contains($file.Name)) { continue }
            if ($file.LastWriteTime -lt $cutoff) {
                Remove-SRSnapshotAndThumbnails -File $file
            }
        }
        $files = @(Get-ChildItem -LiteralPath $script:SRSnapshotDir -Filter 'session-*.json*' -File -ErrorAction SilentlyContinue |
            Sort-Object -Property LastWriteTime -Descending)
    }

    $removable = @($files | Where-Object { -not $pinnedNames.Contains($_.Name) })
    if ($removable.Count -le $Keep) { return }
    foreach ($file in $removable[$Keep..($removable.Count - 1)]) {
        Remove-SRSnapshotAndThumbnails -File $file
    }
}

function Remove-SRSnapshotAndThumbnails {
    # Deletes a snapshot file and its thumbnail folder together. Without this,
    # retention emptied the JSON directory while the thumbs tree kept growing.
    param([Parameter(Mandatory = $true)]$File)
    try {
        Remove-Item -LiteralPath $File.FullName -Force -ErrorAction Stop
    } catch { }
    try {
        $thumbName = [System.IO.Path]::GetFileName($File.Name) -replace '^session-', ''
        $thumbName = $thumbName -replace '\.json(\.gz)?$', ''
        if (-not [string]::IsNullOrWhiteSpace($thumbName)) {
            Remove-SRThumbnails -SnapshotName $thumbName
        }
    } catch { }
}

function Get-SRIdleSeconds {
    # Minutes since the last keyboard/mouse input, via GetLastInputInfo.
    try {
        if ($null -eq $script:SRGetIdleSeconds) {
            $source = @'
using System;
using System.Runtime.InteropServices;
public static class SRIdleInput {
    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    public static double GetIdleSeconds() {
        LASTINPUTINFO info = new LASTINPUTINFO();
        info.cbSize = (uint)Marshal.SizeOf(info);
        if (!GetLastInputInfo(ref info)) { return -1; }
        uint tick = (uint)Environment.TickCount;
        uint elapsed = tick - info.dwTime;
        return elapsed / 1000.0;
    }
}
'@
            Add-Type -TypeDefinition $source -ErrorAction Stop
        }
        return [SRIdleInput]::GetIdleSeconds()
    } catch { return -1 }
}
$script:SRGetIdleSeconds = $null

function Test-SRFullscreenActive {
    # True when the foreground window covers a full screen (games, video).
    try {
        if ($null -eq $script:SRScreens) {
            Add-Type -AssemblyName System.Windows.Forms
            $script:SRScreens = @([System.Windows.Forms.Screen]::AllScreens)
        }
        $source = @'
using System;
using System.Runtime.InteropServices;
public static class SRForeground {
    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    public static bool IsFullscreen(int screenWidth, int screenHeight) {
        IntPtr handle = GetForegroundWindow();
        if (handle == IntPtr.Zero) { return false; }
        // Skip maximized desktop windows: they are common and harmless.
        const int GWL_STYLE = -16;
        const int WS_CAPTION = 0x00C00000;
        int style = GetWindowLong(handle, GWL_STYLE);
        if ((style & WS_CAPTION) != 0) { return false; }
        RECT rect;
        if (!GetWindowRect(handle, out rect)) { return false; }
        return (rect.Right - rect.Left) >= screenWidth && (rect.Bottom - rect.Top) >= screenHeight;
    }
}
'@
        if ($null -eq $script:SRForegroundChecked) {
            Add-Type -TypeDefinition $source -ErrorAction Stop
            $script:SRForegroundChecked = $true
        }
        foreach ($screen in $script:SRScreens) {
            $bounds = $screen.Bounds
            if ([SRForeground]::IsFullscreen($bounds.Width, $bounds.Height)) { return $true }
        }
        return $false
    } catch { return $false }
}
$script:SRScreens = $null
$script:SRForegroundChecked = $null

function Save-SRSnapshot {
    param([switch]$Force)
    $config = Get-SRConfig
    if (-not (Test-Path -LiteralPath $script:SRSnapshotDir)) {
        New-Item -ItemType Directory -Path $script:SRSnapshotDir -Force | Out-Null
    }

    # Smart capture: skip pointless or intrusive snapshots. Manual captures
    # (from the tray or the hotkey) always run.
    if (-not $Force) {
        $idleMinutes = 0
        try { $idleMinutes = [int]$config.pauseWhenIdleMinutes } catch { $idleMinutes = 0 }
        if ($idleMinutes -gt 0) {
            $idle = Get-SRIdleSeconds
            if ($idle -ge 0 -and $idle -ge ($idleMinutes * 60)) {
                Write-SRLog -Level DEBUG -Message ("Skipped snapshot: idle for {0:N0} minutes." -f ($idle / 60))
                return $null
            }
        }
        $pauseFullscreen = $true
        try { $pauseFullscreen = [bool]$config.pauseOnFullscreen } catch { }
        if ($pauseFullscreen -and (Test-SRFullscreenActive)) {
            Write-SRLog -Level DEBUG -Message 'Skipped snapshot: a fullscreen app is in front.'
            return $null
        }
    }

    $lockPath = Join-Path $script:SRSnapshotDir '.save.lock'
    $lock = $null
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        try {
            $lock = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            break
        } catch {
            Start-Sleep -Milliseconds 150
        }
    }
    if ($null -eq $lock) {
        Write-SRLog -Level WARN -Message 'Skipped snapshot because another snapshot is still running.'
        return $null
    }

    try {
        $snapshot = New-SRSnapshot
        $captured = [DateTimeOffset]::Parse([string]$snapshot.capturedAt, [System.Globalization.CultureInfo]::InvariantCulture)

        # Change detection: when nothing relevant changed since the newest
        # snapshot, skip writing a new file. Manual captures always write.
        if (-not $Force) {
            try {
                $newest = @(Get-SRSnapshotFiles)
                if ($newest.Count -gt 0) {
                    $previous = Read-SRSnapshotFile -Path $newest[0].FullName
                    $previousHash = [string]$previous.stateHash
                    if (-not [string]::IsNullOrWhiteSpace($previousHash) -and $previousHash -eq [string]$snapshot.stateHash) {
                        Write-SRLog -Level DEBUG -Message 'Skipped snapshot: nothing changed since the last one.'
                        return $null
                    }
                }
            } catch { }
        }

        $compress = $false
        try {
            $compressProperty = $config.PSObject.Properties['compressSnapshots']
            if ($null -ne $compressProperty) { $compress = [bool]$compressProperty.Value }
        } catch { }

        # Thumbnails are opt-in: nothing is rendered unless the user asked,
        # and only entries that survived the exclusion rules get a picture.
        $captureThumbs = $false
        try {
            $thumbsProperty = $config.PSObject.Properties['captureThumbnails']
            if ($null -ne $thumbsProperty) { $captureThumbs = [bool]$thumbsProperty.Value }
        } catch { }
        if ($captureThumbs) {
            try {
                $thumbName = $captured.ToString('yyyyMMdd-HHmmss-fff')
                [void](New-SRThumbnailSet -Snapshot $snapshot -Windows @($script:SRLastWindows) -Name $thumbName)
            } catch { Write-SRLog -Level DEBUG -Message ("Thumbnails failed: {0}" -f $_.Exception.Message) }
        }

        $encrypt = $false
        try {
            $encryptProperty = $config.PSObject.Properties['encryptSnapshots']
            if ($null -ne $encryptProperty) { $encrypt = [bool]$encryptProperty.Value }
        } catch { }

        $fileName = 'session-{0}.json{1}' -f $captured.ToString('yyyyMMdd-HHmmss-fff'), $(if ($compress -and -not $encrypt) { '.gz' } else { '' })
        $path = Join-Path $script:SRSnapshotDir $fileName
        $json = $snapshot | ConvertTo-Json -Depth 12
        # Payload pipeline: JSON text -> (optional gzip) -> (optional DPAPI).
        # Encryption wraps compression because encrypted bytes do not compress.
        $payload = [System.Text.Encoding]::UTF8.GetBytes($json)
        if ($compress) {
            $plainStream = New-Object System.IO.MemoryStream (,$payload)
            $packed = New-Object System.IO.MemoryStream
            $gzipPlain = $null
            try {
                $gzipPlain = New-Object System.IO.Compression.GZipStream($packed, [System.IO.Compression.CompressionLevel]::Optimal, $true)
                $plainStream.CopyTo($gzipPlain)
            } finally {
                if ($null -ne $gzipPlain) { $gzipPlain.Dispose() }
                $plainStream.Dispose()
            }
            $payload = $packed.ToArray()
            $packed.Dispose()
        }
        if ($encrypt) {
            $payload = Protect-SRSnapshotBytes -Bytes $payload
        }
        [System.IO.File]::WriteAllBytes($path, $payload)
        Remove-OldSRSnapshots -Keep ([int]$config.keepSnapshots) -MaxAgeDays ([int]$config.keepSnapshotDays) -Pinned @($config.pinnedSnapshots)
        Write-SRLog -Message ("Snapshot saved: {0} ({1} apps, {2} folders, {3} browsers, {4} tabs)" -f $path, $snapshot.stats.apps, $snapshot.stats.folders, $snapshot.stats.browsers, $snapshot.stats.tabs)
        try {
            $exportFolder = [string]$config.autoExportFolder
            if (-not [string]::IsNullOrWhiteSpace($exportFolder)) {
                # Auto-backup: keep the newest snapshots as plain JSON copies
                # so OneDrive/Dropbox-style folders can carry them elsewhere.
                if (-not (Test-Path -LiteralPath $exportFolder)) {
                    New-Item -ItemType Directory -Path $exportFolder -Force | Out-Null
                }
                Copy-Item -LiteralPath $path -Destination (Join-Path $exportFolder (Split-Path -Leaf $path)) -Force
                $exports = @(Get-ChildItem -LiteralPath $exportFolder -Filter 'session-*.json*' -File -ErrorAction SilentlyContinue |
                    Sort-Object -Property LastWriteTime -Descending)
                if ($exports.Count -gt 10) {
                    foreach ($old in ($exports | Select-Object -Skip 10)) {
                        try { Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue } catch { }
                    }
                }
            }
        } catch {
            Write-SRLog -Level WARN -Message ("Auto-backup export failed: {0}" -f $_.Exception.Message)
        }
        return $path
    } catch {
        Write-SRLog -Level ERROR -Message "Snapshot failed: $($_.Exception.Message)"
        throw
    } finally {
        $lock.Dispose()
        try { Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Get-SRSnapshots {
    if (-not (Test-Path -LiteralPath $script:SRSnapshotDir)) { return @() }
    $snapshots = New-Object System.Collections.Generic.List[object]
    $files = @(Get-SRSnapshotFiles)
    foreach ($file in $files) {
        try {
            $snapshot = Read-SRSnapshotFile -Path $file.FullName
            $captured = [DateTimeOffset]::Parse([string]$snapshot.capturedAt, [System.Globalization.CultureInfo]::InvariantCulture)
            $snapshots.Add([pscustomobject]@{
                Path       = $file.FullName
                CapturedAt = $captured.LocalDateTime
                Snapshot   = $snapshot
            })
        } catch {
            Write-SRLog -Level WARN -Message "Ignoring unreadable snapshot $($file.FullName): $($_.Exception.Message)"
        }
    }
    return $snapshots.ToArray()
}

function Get-SRLatestSnapshotBeforeLogon {
    param(
        [DateTime]$LogonTime = (Get-SRLogonTime),
        [int]$MaxAgeHours = 72
    )
    $cutoff = (Get-Date).AddHours(-1 * [Math]::Abs($MaxAgeHours))
    foreach ($entry in @(Get-SRSnapshots)) {
        if ($entry.CapturedAt -ge $LogonTime.AddSeconds(-2)) { continue }
        if ($entry.CapturedAt -lt $cutoff) { continue }
        return $entry
    }
    return $null
}

function Test-SRSnapshotHasContent {
    param([Parameter(Mandatory = $true)]$Snapshot)
    if ($null -eq $Snapshot) { return $false }
    if (@($Snapshot.apps).Count -gt 0) { return $true }
    if (@($Snapshot.explorer).Count -gt 0) { return $true }
    foreach ($browser in @($Snapshot.browsers)) {
        if (@($browser.windows).Count -gt 0) { return $true }
        foreach ($profile in @($browser.profiles)) {
            if (@($profile.tabs).Count -gt 0) { return $true }
        }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Crash detection
# ---------------------------------------------------------------------------

function Test-SRUnexpectedShutdown {
    try {
        $since = (Get-Date).AddDays(-7)
        $crashEvents = New-Object System.Collections.Generic.List[object]
        $crashFilters = @(
            @{ LogName = 'System'; Id = 41; StartTime = $since; ProviderName = 'Microsoft-Windows-Kernel-Power' },
            @{ LogName = 'System'; Id = 6008; StartTime = $since },
            @{ LogName = 'System'; Id = 1001; StartTime = $since; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting' }
        )
        foreach ($filter in $crashFilters) {
            foreach ($event in @(Get-WinEvent -FilterHashtable $filter -ErrorAction SilentlyContinue)) {
                $crashEvents.Add($event)
            }
        }
        $cleanEvents = @(Get-WinEvent -FilterHashtable @{
            LogName = 'System'
            Id = 1074, 6006
            StartTime = $since
        } -ErrorAction SilentlyContinue)

        $lastCrash = $crashEvents | Sort-Object -Property TimeCreated -Descending | Select-Object -First 1
        $lastClean = $cleanEvents | Sort-Object -Property TimeCreated -Descending | Select-Object -First 1

        if ($null -eq $lastCrash) { return $false }
        if ($null -eq $lastClean) { return $true }
        return ($lastCrash.TimeCreated -gt $lastClean.TimeCreated)
    } catch {
        Write-SRLog -Level WARN -Message "Could not read shutdown events: $($_.Exception.Message)"
        return $null
    }
}

# ---------------------------------------------------------------------------
# Restore
# ---------------------------------------------------------------------------

function Test-SRExeRunning {
    param([Parameter(Mandatory = $true)][string]$ExePath)
    try {
        $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            try { $_.Path -and ($_.Path -ieq $ExePath) } catch { $false }
        })
        return ($running.Count -gt 0)
    } catch {
        return $false
    }
}

function Merge-SRTabLists {
    param(
        [object[]]$Preferred = @(),
        [object[]]$Fallback = @()
    )
    $result = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($tab in @($Preferred) + @($Fallback)) {
        if ($null -eq $tab) { continue }
        $url = [string]$tab.url
        if (-not (Test-SRRestorableUrl -Url $url)) { continue }
        if ($seen.Add($url)) {
            $result.Add([pscustomobject]@{
                url    = $url
                title  = [string]$tab.title
                pinned = [bool]$tab.pinned
            })
        }
    }
    return $result.ToArray()
}

function Group-SRTabsByWindow {
    param([object[]]$Tabs = @())
    $groups = New-Object System.Collections.Generic.List[object]
    $byWindow = @{}
    foreach ($tab in @($Tabs)) {
        if ($null -eq $tab) { continue }
        $windowId = 0
        try { $windowId = [int]$tab.windowId } catch { $windowId = 0 }
        if (-not $byWindow.ContainsKey($windowId)) {
            $list = New-Object System.Collections.Generic.List[object]
            $byWindow[$windowId] = $list
            $groups.Add($list)
        }
        $byWindow[$windowId].Add($tab)
    }
    return $groups.ToArray()
}

function Get-SRBrowserProfileState {
    param([Parameter(Mandatory = $true)]$Browser)

    $profiles = New-Object System.Collections.Generic.List[object]
    foreach ($profile in @($Browser.profiles)) {
        $current = $null
        $restoreOnStartup = $profile.restoreOnStartup
        if ($Browser.kind -eq 'chromium' -and $profile.path -and (Test-Path -LiteralPath $profile.path)) {
            $current = Get-SRChromiumTabs -ProfileDirectory $profile.path
            $preference = Get-SRChromiumRestoreOnStartup -ProfileDirectory $profile.path
            if ($null -ne $preference) { $restoreOnStartup = $preference }
        } elseif ($Browser.kind -eq 'firefox' -and $profile.path -and (Test-Path -LiteralPath $profile.path)) {
            $current = Get-SRFirefoxTabs -ProfileDirectory $profile.path
            $preference = Get-SRFirefoxRestoreOnStartup -ProfileDirectory $profile.path
            if ($null -ne $preference) { $restoreOnStartup = $preference }
        }

        $currentTabs = @()
        if ($null -ne $current) { $currentTabs = @($current.tabs) }

        # Prefer the browser's own current session file: it is newer than the
        # snapshot and preserves duplicate tabs/window grouping. The snapshot
        # is the fallback when the session file is missing or unreadable.
        if ($currentTabs.Count -gt 0) {
            $tabs = $currentTabs
            $tabsSource = $current.source
        } else {
            $tabs = @($profile.tabs)
            $tabsSource = $profile.tabsSource
        }

        $profiles.Add([pscustomobject]@{
            directory        = [string]$profile.directory
            displayName      = [string]$profile.displayName
            path             = [string]$profile.path
            restoreOnStartup = $restoreOnStartup
            tabs             = $tabs
            tabsSource       = $tabsSource
        })
    }
    return $profiles.ToArray()
}

function Restore-SRBrowser {
    param(
        [Parameter(Mandatory = $true)]$Browser,
        [ValidateSet('Smart', 'Captured', 'Native', 'None')][string]$TabMode = 'Smart',
        [switch]$Force
    )

    $results = New-Object System.Collections.Generic.List[object]
    if ($TabMode -eq 'None') { return $results.ToArray() }

    $exe = [string]$Browser.exe
    if ([string]::IsNullOrWhiteSpace($exe) -or -not (Test-Path -LiteralPath $exe)) {
        $results.Add([pscustomobject]@{ Started = $false; Message = "Browser executable not found: $($Browser.name)" })
        return $results.ToArray()
    }

    $isRunning = Test-SRExeRunning -ExePath $exe
    $profiles = @(Get-SRBrowserProfileState -Browser $Browser)

    if ($Browser.kind -eq 'firefox') {
        $profile = $profiles | Select-Object -First 1
        $tabs = @()
        if ($null -ne $profile) { $tabs = @($profile.tabs) }

        $preference = $null
        if ($null -ne $profile) { $preference = $profile.restoreOnStartup }
        $nativePreferred = ($preference -eq 3)

        $action = $TabMode
        if ($action -eq 'Smart') {
            if ($tabs.Count -gt 0) { $action = 'Captured' }
            else { $action = 'Native' }
        } elseif ($action -eq 'Captured' -and $tabs.Count -eq 0) {
            $action = 'Native'
        }

        if ($action -eq 'Native') {
            if ($isRunning) {
                $results.Add([pscustomobject]@{ Started = $false; Message = "Firefox is already running; skipped native session restore." })
                return $results.ToArray()
            }
            try {
                $args = if ($nativePreferred) { @() } else { @('-restore') }
                [void](Start-SRDetached -FilePath $exe -Arguments $args)
                $results.Add([pscustomobject]@{ Started = $true; Message = 'Firefox: asked to restore the previous session.' })
            } catch {
                $results.Add([pscustomobject]@{ Started = $false; Message = "Firefox restore failed: $($_.Exception.Message)" })
            }
            return $results.ToArray()
        }

        # Captured tabs: keep each captured browser window together.
        $opened = 0
        $windowCount = 0
        foreach ($group in @(Group-SRTabsByWindow -Tabs $tabs)) {
            $first = $true
            $windowCount++
            foreach ($tab in $group) {
                if (-not (Test-SRRestorableUrl -Url $tab.url)) { continue }
                try {
                    if ($first) {
                        [void](Start-SRDetached -FilePath $exe -Arguments @('-new-window', $tab.url))
                        $first = $false
                        Start-Sleep -Milliseconds 600
                    } else {
                        [void](Start-SRDetached -FilePath $exe -Arguments @('-new-tab', $tab.url))
                        Start-Sleep -Milliseconds 120
                    }
                    $opened++
                } catch {
                    Write-SRLog -Level WARN -Message "Could not reopen Firefox tab $($tab.url): $($_.Exception.Message)"
                }
            }
        }
        if ($opened -eq 0) {
            try {
                [void](Start-SRDetached -FilePath $exe)
                $results.Add([pscustomobject]@{ Started = $true; Message = 'Firefox: started with no recoverable URLs.' })
            } catch {
                $results.Add([pscustomobject]@{ Started = $false; Message = "Firefox start failed: $($_.Exception.Message)" })
            }
        } else {
            $results.Add([pscustomobject]@{ Started = $true; Message = "Firefox: reopened $opened captured tab(s) in $windowCount window(s)." })
        }
        return $results.ToArray()
    }

    # Chromium-family browsers. Restore each profile separately so multiple
    # profiles and their tab lists stay together.
    $multipleProfiles = ($profiles.Count -gt 1)
    foreach ($profile in $profiles) {
        $tabs = @($profile.tabs | Where-Object { Test-SRRestorableUrl -Url $_.url })
        $nativePreferred = ($profile.restoreOnStartup -eq 1)

        $action = $TabMode
        if ($action -eq 'Smart') {
            if ($tabs.Count -gt 0) { $action = 'Captured' }
            else { $action = 'Native' }
        } elseif ($action -eq 'Captured' -and $tabs.Count -eq 0) {
            $action = 'Native'
        }

        if ($action -eq 'Native') {
            if ($isRunning -and -not $Force) {
                $results.Add([pscustomobject]@{ Started = $false; Message = "$($Browser.name) is already running; skipped native restore for profile '$($profile.displayName)'." })
                continue
            }
            $args = New-Object System.Collections.Generic.List[string]
            if ($multipleProfiles -or $profile.directory -ne 'Default') {
                $args.Add(('--profile-directory={0}' -f $profile.directory))
            }
            if (-not $nativePreferred) { $args.Add('--restore-last-session') }
            try {
                [void](Start-SRDetached -FilePath $exe -Arguments $args.ToArray())
                $results.Add([pscustomobject]@{ Started = $true; Message = "$($Browser.name): asked to restore profile '$($profile.displayName)'." })
            } catch {
                $results.Add([pscustomobject]@{ Started = $false; Message = "$($Browser.name) restore failed: $($_.Exception.Message)" })
            }
            continue
        }

        # Captured tabs. Keep each captured browser window together, then
        # chunk long windows so the command line stays below the Windows limit.
        $profileArgs = @()
        if ($multipleProfiles -or $profile.directory -ne 'Default') {
            $profileArgs = @(('--profile-directory={0}' -f $profile.directory))
        }

        $opened = 0
        $windowCount = 0
        foreach ($group in @(Group-SRTabsByWindow -Tabs $tabs)) {
            $chunk = New-Object System.Collections.Generic.List[string]
            $chunkLength = 0
            $chunks = New-Object System.Collections.Generic.List[object]
            foreach ($tab in $group) {
                $url = [string]$tab.url
                if ([string]::IsNullOrWhiteSpace($url)) { continue }
                if ($url.Length -gt 8000) { continue }
                if ($chunk.Count -ge 40 -or ($chunkLength + $url.Length + 4) -gt 12000) {
                    $chunks.Add($chunk.ToArray())
                    $chunk.Clear()
                    $chunkLength = 0
                }
                $chunk.Add($url)
                $chunkLength += $url.Length + 4
            }
            if ($chunk.Count -gt 0) { $chunks.Add($chunk.ToArray()) }

            foreach ($urls in $chunks) {
                $args = New-Object System.Collections.Generic.List[string]
                foreach ($argument in $profileArgs) { $args.Add($argument) }
                $args.Add('--new-window')
                foreach ($url in $urls) { $args.Add($url) }
                try {
                    [void](Start-SRDetached -FilePath $exe -Arguments $args.ToArray())
                    $opened += $urls.Count
                    $windowCount++
                    Start-Sleep -Milliseconds 250
                } catch {
                    Write-SRLog -Level WARN -Message "Could not reopen tabs in $($Browser.name): $($_.Exception.Message)"
                }
            }
        }
        if ($opened -gt 0) {
            $results.Add([pscustomobject]@{ Started = $true; Message = "$($Browser.name): reopened $opened captured tab(s) in $windowCount window(s) for profile '$($profile.displayName)'." })
        } else {
            $results.Add([pscustomobject]@{ Started = $false; Message = "$($Browser.name): could not reopen captured tabs." })
        }
    }

    return $results.ToArray()
}

function Invoke-SRRestore {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [switch]$Force,
        [scriptblock]$Progress
    )

    $results = New-Object System.Collections.Generic.List[object]

    $config = Get-SRConfig

    # Launch ordering: apps listed in launchOrder start first, in that order,
    # so a VPN or database is up before the apps that need it. Per-app waits
    # (launchWaits: app -> process name) block until that process appears.
    $launchOrder = @()
    try { $launchOrder = @($config.launchOrder) } catch { }
    $appDelays = @{}
    try {
        $delaysProperty = $config.PSObject.Properties['appLaunchDelays']
        if ($null -ne $delaysProperty) {
            foreach ($property in $delaysProperty.Value.PSObject.Properties) { $appDelays[$property.Name] = $property.Value }
        }
    } catch { }
    $appWaits = @{}
    try {
        $waitsProperty = $config.PSObject.Properties['launchWaits']
        if ($null -ne $waitsProperty) {
            foreach ($property in $waitsProperty.Value.PSObject.Properties) { $appWaits[$property.Name] = $property.Value }
        }
    } catch { }

    $orderedApps = @($Plan.apps | Where-Object { $null -ne $_ })
    if (@($launchOrder).Count -gt 0) {
        $orderedApps = @(
            # Listed apps in launchOrder sequence, then everything else.
            foreach ($name in @($launchOrder)) {
                $leaf = ([string]$name).ToLowerInvariant()
                $orderedApps | Where-Object { (([string]$_.name).ToLowerInvariant() -eq $leaf) -or ([string]$_.exe -like ('*\' + $name)) }
            }
            $orderedApps | Where-Object {
                $app = $_
                $leaf = ([string]$app.name).ToLowerInvariant()
                $listed = $false
                foreach ($name in @($launchOrder)) {
                    if (([string]$name).ToLowerInvariant() -eq $leaf) { $listed = $true }
                }
                -not $listed
            }
        )
    }

    $total = 0
    foreach ($app in @($orderedApps)) { $total++ }
    foreach ($folder in @($Plan.explorer)) { if (-not [string]::IsNullOrWhiteSpace([string]$folder)) { $total++ } }
    foreach ($browser in @($Plan.browsers)) { if ($null -ne $browser) { $total++ } }
    $index = 0

    foreach ($app in @($orderedApps)) {
        if ($null -eq $app) { continue }
        $index++
        if ($null -ne $Progress) {
            try { & $Progress $index $total ([string]$app.name) } catch { }
        }
        $appKey = ([string]$app.name).ToLowerInvariant()
        if ($appWaits.ContainsKey($appKey)) {
            $waitMinutes = 0
            $rawWait = [string]$appWaits[$appKey]
            if ($rawWait -match '^(.+?)\s+after\s+(.+)$') { $rawWait = $Matches[1]; $waitMinutes = [int]$Matches[2] }
            $waitFor = ([string]$rawWait).Trim()
            if (-not [string]::IsNullOrWhiteSpace($waitFor) -and -not (Get-Process -Name $waitFor -ErrorAction SilentlyContinue)) {
                $deadline = (Get-Date).AddMinutes([Math]::Max(1, $waitMinutes))
                while ((Get-Date) -lt $deadline -and -not (Get-Process -Name $waitFor -ErrorAction SilentlyContinue)) {
                    Start-Sleep -Milliseconds 1500
                }
            }
        }
        if ($appDelays.ContainsKey($appKey)) {
            $delaySeconds = 0
            try { $delaySeconds = [int]$appDelays[$appKey] } catch { }
            if ($delaySeconds -gt 0) { Start-Sleep -Seconds ([Math]::Min(120, $delaySeconds)) }
        }
        $appResult = Start-SRApplication -App $app -Force:$Force -SnapshotMonitors $Plan.monitors
        $appResult | Add-Member -NotePropertyName Target -NotePropertyValue ([string]$app.name) -Force
        $results.Add($appResult)
    }

    foreach ($folder in @($Plan.explorer)) {
        if ([string]::IsNullOrWhiteSpace([string]$folder)) { continue }
        $index++
        if ($null -ne $Progress) {
            try { & $Progress $index $total ([string]$folder) } catch { }
        }
        $folderResult = Open-SRFolder -Path ([string]$folder)
        $folderResult | Add-Member -NotePropertyName Target -NotePropertyValue ([string]$folder) -Force
        $results.Add($folderResult)
    }

    $tabMode = 'Smart'
    if ($Plan.tabMode) { $tabMode = [string]$Plan.tabMode }
    foreach ($browser in @($Plan.browsers)) {
        if ($null -eq $browser) { continue }
        $index++
        if ($null -ne $Progress) {
            try { & $Progress $index $total ([string]$browser.name) } catch { }
        }
        foreach ($result in @(Restore-SRBrowser -Browser $browser -TabMode $tabMode -Force:$Force)) {
            $result | Add-Member -NotePropertyName Target -NotePropertyValue ([string]$browser.name) -Force
            $results.Add($result)
        }
    }

    # Dev workspaces: reopen the folders the editors had open. Editors are
    # launched through their CLI launcher when it exists; otherwise the
    # folder opens in Explorer so nothing is silently dropped.
    foreach ($workspace in @($Plan.dev)) {
        if ($null -eq $workspace) { continue }
        $tool = [string]$workspace.tool
        $kind = [string]$workspace.kind
        $launcher = $null
        if ($kind -eq 'vscode') {
            $launcherCandidates = @()
            if ($tool -eq 'Cursor') {
                $launcherCandidates = @(
                    (Join-Path $env:LOCALAPPDATA 'Programs\cursor\resources\app\bin\cursor.cmd'),
                    (Join-Path $env:LOCALAPPDATA 'Programs\Cursor\Cursor.exe')
                )
            } else {
                $launcherCandidates = @(
                    (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'),
                    (Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd'),
                    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft VS Code\bin\code.cmd')
                )
            }
            foreach ($candidate in $launcherCandidates) {
                if (Test-Path -LiteralPath $candidate) { $launcher = $candidate; break }
            }
        } elseif ($kind -eq 'terminal') {
            $wtExe = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'
            if (Test-Path -LiteralPath $wtExe) { $launcher = $wtExe }
        } elseif ($kind -eq 'jetbrains') {
            $launcher = Get-SRJetBrainsLauncher -Product $tool
        }
        foreach ($folder in @($workspace.folders)) {
            if ([string]::IsNullOrWhiteSpace([string]$folder) -or -not (Test-Path -LiteralPath $folder)) { continue }
            $index++
            if ($null -ne $Progress) {
                try { & $Progress $index $total ($tool + ': ' + $folder) } catch { }
            }
            $started = $false
            $message = ''
            try {
                if ($null -ne $launcher -and $kind -eq 'vscode') {
                    Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c ""{0}" "{1}""' -f $launcher, ([string]$folder)) -WindowStyle Hidden
                    $started = $true
                    $message = 'Reopened in ' + $tool
                } elseif ($null -ne $launcher -and $kind -eq 'terminal') {
                    Start-Process -FilePath $launcher -ArgumentList ('-d "{0}"' -f [string]$folder)
                    $started = $true
                    $message = 'Windows Terminal opened here'
                } elseif ($null -ne $launcher -and $kind -eq 'jetbrains') {
                    Start-Process -FilePath $launcher -ArgumentList ('"{0}"' -f [string]$folder)
                    $started = $true
                    $message = 'Reopened in ' + $tool
                } else {
                    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f [string]$folder)
                    $started = $true
                    $message = 'Folder opened in Explorer'
                }
            } catch {
                $message = 'Could not reopen: ' + $_.Exception.Message
            }
            $results.Add([pscustomobject]@{
                Target  = ($folder)
                Started = $started
                Message = $message
            })
        }
    }

    # Remote sessions: reopen the PuTTY sessions and Remote Desktop windows
    # that were captured, reconnecting straight to the same targets.
    foreach ($session in @($Plan.remote)) {
        if ($null -eq $session) { continue }
        $index++
        $target = ''
        $started = $false
        $message = ''
        try {
            if ([string]$session.kind -eq 'putty') {
                $target = 'PuTTY: ' + [string]$session.session
                $puttyExe = Get-SRAppPath -ExeName 'putty.exe'
                if ([string]::IsNullOrWhiteSpace([string]$puttyExe)) {
                    foreach ($candidate in @(
                        (Join-Path $env:ProgramFiles 'PuTTY\putty.exe'),
                        (Join-Path ${env:ProgramFiles(x86)} 'PuTTY\putty.exe')
                    )) {
                        if (Test-Path -LiteralPath $candidate) { $puttyExe = $candidate; break }
                    }
                }
                if (-not [string]::IsNullOrWhiteSpace([string]$puttyExe)) {
                    [void](Start-SRDetached -FilePath ([string]$puttyExe) -Arguments @('-load', [string]$session.session))
                    $started = $true
                    $message = 'PuTTY session reopened'
                } else {
                    $message = 'PuTTY was not found on this PC'
                }
            } elseif ([string]$session.kind -eq 'rdp') {
                $rdpTarget = [string]$session.target
                $target = 'Remote Desktop: ' + $rdpTarget
                $rdpFile = Resolve-SRRdpFile -Target $rdpTarget
                $mstsc = Join-Path $env:SystemRoot 'System32\mstsc.exe'
                if (-not (Test-Path -LiteralPath $mstsc)) {
                    $message = 'Remote Desktop client was not found'
                } elseif ($rdpFile) {
                    [void](Start-SRDetached -FilePath $mstsc -Arguments @($rdpFile))
                    $started = $true
                    $message = 'Reconnected with ' + (Split-Path -Leaf $rdpFile)
                } else {
                    [void](Start-SRDetached -FilePath $mstsc -Arguments @(('/v:{0}' -f $rdpTarget)))
                    $started = $true
                    $message = 'Reconnected to ' + $rdpTarget
                }
            }
        } catch {
            $message = 'Could not reopen: ' + $_.Exception.Message
        }
        $results.Add([pscustomobject]@{
            Target  = $target
            Started = $started
            Message = $message
        })
    }

    return $results.ToArray()
}

function New-SRRestorePlan {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [string[]]$AppKeys,
        [string[]]$Folders,
        [string[]]$BrowserKeys,
        [ValidateSet('Smart', 'Captured', 'Native', 'None')][string]$TabMode = 'Smart',
        [switch]$All
    )

    $apps = New-Object System.Collections.Generic.List[object]
    foreach ($app in @($Snapshot.apps)) {
        if ($null -eq $app) { continue }
        if ($All -or $null -eq $AppKeys -or ($AppKeys -contains ([string]$app.exe))) {
            $apps.Add($app)
        }
    }

    $explorer = New-Object System.Collections.Generic.List[string]
    foreach ($folder in @($Snapshot.explorer)) {
        if ($null -eq $folder) { continue }
        if ($All -or $null -eq $Folders -or ($Folders -contains [string]$folder)) {
            $explorer.Add([string]$folder)
        }
    }

    $browsers = New-Object System.Collections.Generic.List[object]
    foreach ($browser in @($Snapshot.browsers)) {
        if ($null -eq $browser) { continue }
        if ($All -or $null -eq $BrowserKeys -or ($BrowserKeys -contains ([string]$browser.key))) {
            $browsers.Add($browser)
        }
    }

    # Dev workspaces, monitor layout and remote sessions travel with the plan
    # so both the interactive window and -NoUI restores behave identically.
    $dev = @()
    try { $dev = @($Snapshot.devWorkspaces) } catch { }
    $monitors = $null
    try { $monitors = @($Snapshot.monitors) } catch { }
    $remote = @()
    try { $remote = @($Snapshot.remote) } catch { }

    return [pscustomobject]@{
        apps      = $apps.ToArray()
        explorer  = $explorer.ToArray()
        browsers  = $browsers.ToArray()
        tabMode   = $TabMode
        dev       = $dev
        monitors  = $monitors
        remote    = $remote
    }
}

function Get-SRSnapshotByPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Snapshot not found: $Path" }
    $snapshot = Read-SRSnapshotFile -Path $Path
    return $snapshot
}

# ---------------------------------------------------------------------------
# Snapshot pinning, import and export
# ---------------------------------------------------------------------------

function Test-SRSnapshotPinned {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $config = Get-SRConfig
        $name = Split-Path -Leaf $Path
        return (@($config.pinnedSnapshots) -contains $name)
    } catch {
        return $false
    }
}

function Set-SRSnapshotPinned {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][bool]$Pinned
    )
    $config = Get-SRConfig
    $current = @($config.pinnedSnapshots | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $name = Split-Path -Leaf $Path
    if ($Pinned) {
        if ($current -notcontains $name) { $current = @($current + $name) }
    } else {
        $current = @($current | Where-Object { [string]$_ -ne $name })
    }
    $config.pinnedSnapshots = @($current)
    Save-SRConfig -Config $config
    return $config
}

function Get-SRSnapshotNote {
    param([Parameter(Mandatory = $true)][string]$Path)
    $name = Split-Path -Leaf $Path
    if ([string]::IsNullOrWhiteSpace($name)) { return '' }
    $config = Get-SRConfig
    $notes = ConvertTo-SRNoteTable -Value $config.snapshotNotes
    if ($notes.ContainsKey($name)) { return [string]$notes[$name] }
    return ''
}

function Set-SRSnapshotNote {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyString()][string]$Note = ''
    )
    $name = Split-Path -Leaf $Path
    if ([string]::IsNullOrWhiteSpace($name) -or $name -ne [System.IO.Path]::GetFileName($name)) {
        throw 'The snapshot path is not valid.'
    }
    $config = Get-SRConfig
    $notes = ConvertTo-SRNoteTable -Value $config.snapshotNotes
    $clean = [regex]::Replace([string]$Note, '[\x00-\x08\x0B\x0C\x0E-\x1F]', '').Trim()
    if ($clean.Length -gt 500) { $clean = $clean.Substring(0, 500).Trim() }
    if ([string]::IsNullOrWhiteSpace($clean)) {
        if ($notes.ContainsKey($name)) { $notes.Remove($name) }
        $clean = ''
    } else {
        $notes[$name] = $clean
    }
    $config.snapshotNotes = $notes
    Save-SRConfig -Config $config
    return $clean
}

function Export-SRSnapshotFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Snapshot not found: $Path" }
    $destinationFolder = Split-Path -Parent $Destination
    if (-not [string]::IsNullOrWhiteSpace($destinationFolder) -and -not (Test-Path -LiteralPath $destinationFolder)) {
        New-Item -ItemType Directory -Path $destinationFolder -Force | Out-Null
    }
    Copy-Item -LiteralPath $Path -Destination $Destination -Force -ErrorAction Stop
    return $Destination
}

function Import-SRSnapshotFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Snapshot file not found: $Path" }

    $source = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($source.Length -gt 32MB) {
        throw 'The snapshot file is too large to import (32 MB maximum).'
    }

    # Validate before copying so a random JSON file cannot enter the timeline.
    $snapshot = $null
    try {
        $snapshot = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        throw "The file is not a valid snapshot: $($_.Exception.Message)"
    }
    if ($null -eq $snapshot) {
        throw 'The file does not look like a Session Recovery snapshot.'
    }
    foreach ($requiredProperty in @('capturedAt', 'apps', 'explorer', 'browsers')) {
        if ($null -eq $snapshot.PSObject.Properties[$requiredProperty]) {
            throw ("The file is missing the '{0}' snapshot field." -f $requiredProperty)
        }
    }
    $capturedAt = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse(
            [string]$snapshot.capturedAt,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None,
            [ref]$capturedAt)) {
        throw 'The snapshot has an invalid capturedAt value.'
    }
    $appIndex = 0
    foreach ($app in @($snapshot.apps)) {
        if ($null -eq $app) { throw ("Application entry {0} is empty." -f $appIndex) }
        $exeProperty = $app.PSObject.Properties['exe']
        if ($null -eq $exeProperty -or [string]::IsNullOrWhiteSpace([string]$exeProperty.Value)) {
            throw ("Application entry {0} has no executable path." -f $appIndex)
        }
        $argsProperty = $app.PSObject.Properties['args']
        if ($null -ne $argsProperty -and $null -ne $argsProperty.Value) {
            foreach ($argument in @($argsProperty.Value)) {
                if ($null -eq $argument -or [string]::IsNullOrWhiteSpace([string]$argument)) {
                    throw ("Application entry {0} has an empty argument." -f $appIndex)
                }
            }
        }
        $appIndex++
    }

    if (-not (Test-Path -LiteralPath $script:SRSnapshotDir)) {
        New-Item -ItemType Directory -Path $script:SRSnapshotDir -Force | Out-Null
    }

    $leaf = Split-Path -Leaf $Path
    if ($leaf -notlike 'session-*') { $leaf = '' }
    $targetName = $leaf
    if ([string]::IsNullOrWhiteSpace($targetName) -or (Test-Path -LiteralPath (Join-Path $script:SRSnapshotDir $targetName))) {
        $targetName = 'session-imported-{0}.json' -f (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
        while (Test-Path -LiteralPath (Join-Path $script:SRSnapshotDir $targetName)) {
            $targetName = 'session-imported-{0}.json' -f (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
        }
    }
    $targetPath = Join-Path $script:SRSnapshotDir $targetName

    # Mark the file as imported. Restore-Session shows an explicit program
    # confirmation for these snapshots, and headless restores require the
    # -AllowImportedSnapshot switch. The source path is not written down, so
    # importing never records where the file came from. The source file hash is
    # kept so the imported copy can be tied to the bytes the user selected.
    $sourceHash = ''
    try {
        $sourceHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
    } catch {
        throw ("The snapshot hash could not be calculated: {0}" -f $_.Exception.Message)
    }
    $snapshot | Add-Member -NotePropertyName imported -NotePropertyValue $true -Force
    $snapshot | Add-Member -NotePropertyName importedAt -NotePropertyValue ((Get-Date).ToString('o')) -Force
    $snapshot | Add-Member -NotePropertyName importedFileHash -NotePropertyValue $sourceHash -Force
    $snapshot | Add-Member -NotePropertyName importedFileHashAlgorithm -NotePropertyValue 'SHA256' -Force
    try {
        $json = $snapshot | ConvertTo-Json -Depth 100 -Compress
        [System.IO.File]::WriteAllText($targetPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        Remove-Item -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue
        throw ("The snapshot could not be imported: {0}" -f $_.Exception.Message)
    }
    Write-SRLog -Message "Snapshot imported from $Path as $targetName"
    return $targetPath
}

function Test-SRImportedSnapshot {
    # Returns true for anything restore should treat as untrusted: explicitly
    # imported snapshots, files with no provenance, and snapshots created by a
    # different installation. The name is kept for compatibility with existing
    # scripts and the -AllowImportedSnapshot switch.
    param($Snapshot)
    if ($null -eq $Snapshot) { return $true }
    $importedProperty = $Snapshot.PSObject.Properties['imported']
    if ($null -ne $importedProperty) {
        try {
            if ([bool]$importedProperty.Value) { return $true }
        } catch { return $true }
    }
    $provenanceProperty = $Snapshot.PSObject.Properties['provenance']
    if ($null -eq $provenanceProperty -or $null -eq $provenanceProperty.Value) { return $true }
    $installationProperty = $provenanceProperty.Value.PSObject.Properties['installationId']
    if ($null -eq $installationProperty -or [string]::IsNullOrWhiteSpace([string]$installationProperty.Value)) { return $true }
    try {
        return ([string]$installationProperty.Value -ne (Get-SRInstallationId))
    } catch {
        return $true
    }
}

# ---------------------------------------------------------------------------
# Privacy scan
# ---------------------------------------------------------------------------

function Get-SRPrivacyFindings {
    <#
        Local-only privacy scan. Matches visible application/process names and
        browser tab URLs (never screenshots or page text) against a small set of
        sensitive categories, then proposes wildcard exclusion rules. Supplying
        -Apps or -Tabs skips live capture and is used by the tests.
    #>
    param(
        [object[]]$Apps = $null,
        [object[]]$Tabs = $null,
        [string[]]$ExcludeApps = $null,
        [string[]]$ExcludeUrls = $null
    )

    $explicitInput = $PSBoundParameters.ContainsKey('Apps') -or $PSBoundParameters.ContainsKey('Tabs')
    if (-not $PSBoundParameters.ContainsKey('ExcludeApps')) {
        if ($explicitInput) { $ExcludeApps = @() } else { $ExcludeApps = @((Get-SRConfig).excludeApps) }
    }
    if (-not $PSBoundParameters.ContainsKey('ExcludeUrls')) {
        if ($explicitInput) { $ExcludeUrls = @() } else { $ExcludeUrls = @((Get-SRConfig).excludeUrls) }
    }

    $scanApps = @($Apps)
    $scanTabs = @($Tabs)
    if (-not $explicitInput) {
        $config = Get-SRConfig
        $windows = @([SessionRecovery.WindowEnumerator]::GetVisibleWindows())
        $processMap = Get-SRProcessMap
        $scanApps = @(Get-SRApplications -Windows $windows -ProcessMap $processMap)
        $scanTabs = @()
        if ($null -eq $config.PSObject.Properties['captureBrowserTabs'] -or [bool]$config.captureBrowserTabs) {
            foreach ($browser in @(Get-SRBrowsers -Windows $windows -ProcessMap $processMap -Config $config)) {
                foreach ($profile in @($browser.profiles)) {
                    foreach ($tab in @($profile.tabs)) {
                        $scanTabs += [pscustomobject]@{
                            title = [string]$tab.title
                            url   = [string]$tab.url
                        }
                    }
                }
            }
        }
    }

    $catalog = @(
        [pscustomobject]@{
            Category  = 'PasswordManager'
            ReasonKey = 'PrivacyReasonPasswordManager'
            Keywords  = @('1password', 'bitwarden', 'keepass', 'lastpass', 'dashlane', 'nordpass', 'protonpass', 'proton pass', 'enpass', 'keeper', 'roboform', 'password safe')
        },
        [pscustomobject]@{
            Category  = 'Finance'
            ReasonKey = 'PrivacyReasonFinance'
            Keywords  = @('bank', 'banking', 'hsbc', 'barclays', 'chase', 'wellsfargo', 'wells fargo', 'revolut', 'monzo', 'paypal', 'stripe', 'wise', 'natwest', 'lloyds', 'santander', 'fidelity', 'schwab', 'coinbase', 'binance', 'kraken', 'tax')
        },
        [pscustomobject]@{
            Category  = 'Messaging'
            ReasonKey = 'PrivacyReasonMessaging'
            Keywords  = @('whatsapp', 'telegram', 'signal', 'discord', 'slack', 'teams', 'messenger', 'skype', 'zoom', 'phone link', 'your phone')
        },
        [pscustomobject]@{
            Category  = 'Email'
            ReasonKey = 'PrivacyReasonEmail'
            Keywords  = @('outlook', 'thunderbird', 'mailbird', 'protonmail', 'gmail')
        },
        [pscustomobject]@{
            Category  = 'Health'
            ReasonKey = 'PrivacyReasonHealth'
            Keywords  = @('hospital', 'clinic', 'medical', 'health', 'pharmacy', 'patient')
        },
        [pscustomobject]@{
            Category  = 'Social'
            ReasonKey = 'PrivacyReasonSocial'
            Keywords  = @('facebook', 'instagram', 'twitter', 'tiktok', 'snapchat', 'reddit', 'linkedin', 'mastodon', 'bluesky')
        }
    )

    $findByKeyword = {
        param([string]$Text)
        if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
        foreach ($entry in $catalog) {
            foreach ($keyword in @($entry.Keywords)) {
                if ($Text.Contains($keyword)) { return $entry }
            }
        }
        return $null
    }

    $findings = New-Object System.Collections.Generic.List[object]
    $seenPatterns = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($app in $scanApps) {
        if ($null -eq $app) { continue }
        $nameProperty = $app.PSObject.Properties['name']
        $exeProperty = $app.PSObject.Properties['exe']
        $name = if ($null -ne $nameProperty) { [string]$nameProperty.Value } else { '' }
        $exe = if ($null -ne $exeProperty) { [string]$exeProperty.Value } else { '' }
        if ([string]::IsNullOrWhiteSpace($name) -and [string]::IsNullOrWhiteSpace($exe)) { continue }
        if (Test-SRPatternMatch -Patterns $ExcludeApps -Values @($name, $exe)) { continue }

        $leaf = ''
        if (-not [string]::IsNullOrWhiteSpace($exe)) { $leaf = Split-Path -Leaf $exe }
        $match = & $findByKeyword (($name + ' ' + $leaf).ToLowerInvariant())
        if ($null -eq $match) { continue }

        $label = $name
        if ([string]::IsNullOrWhiteSpace($label)) { $label = $leaf }
        if ([string]::IsNullOrWhiteSpace($label)) { continue }
        $pattern = '*' + $label.ToLowerInvariant() + '*'
        if (-not $seenPatterns.Add($pattern)) { continue }

        $findings.Add([pscustomobject]@{
            Kind        = 'app'
            Pattern     = $pattern
            Label       = $label
            Detail      = $exe
            Category    = [string]$match.Category
            ReasonKey   = [string]$match.ReasonKey
            Reason      = [string]$match.Category
            MatchCount  = 1
        })
    }

    foreach ($tab in $scanTabs) {
        if ($null -eq $tab) { continue }
        $urlProperty = $tab.PSObject.Properties['url']
        $titleProperty = $tab.PSObject.Properties['title']
        $url = if ($null -ne $urlProperty) { [string]$urlProperty.Value } else { '' }
        $title = if ($null -ne $titleProperty) { [string]$titleProperty.Value } else { '' }
        if ([string]::IsNullOrWhiteSpace($url)) { continue }
        if (Test-SRPatternMatch -Patterns $ExcludeUrls -Values @($url)) { continue }

        $uri = $null
        if (-not [System.Uri]::TryCreate($url, [System.UriKind]::Absolute, [ref]$uri)) { continue }
        if ($uri.Scheme -ne 'http' -and $uri.Scheme -ne 'https') { continue }
        $hostName = ([string]$uri.Host).ToLowerInvariant().Trim()
        if ([string]::IsNullOrWhiteSpace($hostName)) { continue }

        $match = & $findByKeyword (($hostName + ' ' + $title + ' ' + $url).ToLowerInvariant())
        if ($null -eq $match) { continue }
        $pattern = '*' + $hostName + '*'

        $existing = $findings | Where-Object { $_.Kind -eq 'url' -and $_.Pattern -eq $pattern } | Select-Object -First 1
        if ($null -ne $existing) {
            $existing.MatchCount = [int]$existing.MatchCount + 1
            continue
        }
        if (-not $seenPatterns.Add($pattern)) { continue }

        $findings.Add([pscustomobject]@{
            Kind        = 'url'
            Pattern     = $pattern
            Label       = $hostName
            Detail      = $title
            Category    = [string]$match.Category
            ReasonKey   = [string]$match.ReasonKey
            Reason      = [string]$match.Category
            MatchCount  = 1
        })
    }

    return [pscustomobject]@{
        ScannedAt   = (Get-Date).ToString('o')
        AppsScanned = @($scanApps).Count
        TabsScanned = @($scanTabs).Count
        Findings    = @($findings | Sort-Object -Property Kind, Category, Label)
    }
}

# ---------------------------------------------------------------------------
# Recovery Kit (portable snapshot, note and exclusion bundle)
# ---------------------------------------------------------------------------

function Copy-SRZipEntryToFile {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$MaxBytes = 32MB
    )
    $inputStream = $null
    $outputStream = $null
    try {
        $inputStream = $Entry.Open()
        $outputStream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $buffer = New-Object byte[] 81920
        $written = 0
        while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $written += $read
            if ($written -gt $MaxBytes) { throw 'A kit entry is larger than the allowed size.' }
            $outputStream.Write($buffer, 0, $read)
        }
        $outputStream.Flush()
        return $written
    } finally {
        if ($null -ne $inputStream) { $inputStream.Dispose() }
        if ($null -ne $outputStream) { $outputStream.Dispose() }
    }
}

function Read-SRZipTextEntry {
    param([Parameter(Mandatory = $true)]$Entry, [int]$MaxBytes = 1MB)
    if ([int64]$Entry.Length -gt $MaxBytes) { throw 'A kit manifest is larger than the allowed size.' }
    $stream = $null
    $reader = $null
    try {
        $stream = $Entry.Open()
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        return $reader.ReadToEnd()
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
    }
}

function Export-SRRecoveryKit {
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [string]$AppVersion = ''
    )
    $destinationFolder = Split-Path -Parent $Destination
    if (-not [string]::IsNullOrWhiteSpace($destinationFolder) -and -not (Test-Path -LiteralPath $destinationFolder)) {
        New-Item -ItemType Directory -Path $destinationFolder -Force | Out-Null
    }

    $entries = @(Get-SRSnapshots)
    $config = Get-SRConfig
    $notes = ConvertTo-SRNoteTable -Value $config.snapshotNotes
    $staging = Join-Path ([System.IO.Path]::GetTempPath()) ('sr-kit-' + [guid]::NewGuid().ToString('N'))
    $snapshotStaging = Join-Path $staging 'snapshots'
    New-Item -ItemType Directory -Path $snapshotStaging -Force | Out-Null
    try {
        $manifestSnapshots = New-Object System.Collections.Generic.List[object]
        $manifestNotes = @{}
        $snapshotCount = 0
        $encryptedCount = 0
        foreach ($entry in $entries) {
            if ($snapshotCount -ge 200) { break }
            $leaf = Split-Path -Leaf $entry.Path
            if ([string]::IsNullOrWhiteSpace($leaf) -or $leaf -ne [System.IO.Path]::GetFileName($leaf)) { continue }
            if ($leaf -notmatch '^session-[0-9A-Za-z][0-9A-Za-z._-]*\.json(\.gz)?$') { continue }
            if (-not (Test-Path -LiteralPath $entry.Path -PathType Leaf)) { continue }
            $size = (Get-Item -LiteralPath $entry.Path).Length
            $encrypted = $false
            try {
                $header = New-Object byte[] 5
                $headerStream = [System.IO.File]::OpenRead($entry.Path)
                try { $read = $headerStream.Read($header, 0, 5) } finally { $headerStream.Dispose() }
                if ($read -eq 5 -and [System.Text.Encoding]::ASCII.GetString($header) -eq 'SRDP1') { $encrypted = $true }
            } catch { }
            if ($encrypted) { $encryptedCount++ }
            Copy-Item -LiteralPath $entry.Path -Destination (Join-Path $snapshotStaging $leaf) -Force -ErrorAction Stop
            $manifestSnapshots.Add([pscustomobject]@{
                name       = $leaf
                capturedAt = [string]$entry.Snapshot.capturedAt
                bytes      = [int64]$size
                encrypted  = [bool]$encrypted
            })
            if ($notes.ContainsKey($leaf)) { $manifestNotes[$leaf] = [string]$notes[$leaf] }
            $snapshotCount++
        }

        $manifest = [pscustomobject]@{
            kind       = 'SessionRecoveryRecoveryKit'
            format     = 1
            product    = 'Session Recovery'
            appVersion = $AppVersion
            createdAt  = (Get-Date).ToString('o')
            snapshots  = @($manifestSnapshots.ToArray())
            notes      = $manifestNotes
            exclusions = [pscustomobject]@{
                apps    = @($config.excludeApps)
                folders = @($config.excludeFolders)
                urls    = @($config.excludeUrls)
            }
        }
        $manifestPath = Join-Path $staging 'manifest.json'
        $manifestJson = $manifest | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($manifestPath, $manifestJson, (New-Object System.Text.UTF8Encoding($false)))

        $readme = @(
            'Session Recovery kit',
            '====================',
            '',
            'This file contains local session snapshots, snapshot notes and exclusion rules.',
            'Snapshot files can contain application names, window titles, folder paths and',
            'browser tab titles and URLs. Treat the kit like a private document.',
            '',
            'Import it from Studio > Recovery Kit. Imported snapshots are marked as',
            'untrusted and ask for confirmation before they restore programs.',
            '',
            'DPAPI-encrypted snapshots can only be read by the Windows account that',
            'created them. The importer skips encrypted entries instead of decrypting them.'
        ) -join "`r`n"
        [System.IO.File]::WriteAllText((Join-Path $staging 'README.txt'), $readme, (New-Object System.Text.UTF8Encoding($false)))

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force -ErrorAction Stop }
        [System.IO.Compression.ZipFile]::CreateFromDirectory($staging, $Destination, [System.IO.Compression.CompressionLevel]::Optimal, $false)
        $bytes = (Get-Item -LiteralPath $Destination).Length
        Write-SRLog -Message ("Recovery kit exported: {0} ({1} snapshots, {2} notes)" -f $Destination, $snapshotCount, $manifestNotes.Count)
        return [pscustomobject]@{
            Path              = $Destination
            SnapshotCount     = [int]$snapshotCount
            NoteCount         = [int]$manifestNotes.Count
            ExclusionCount    = (@($config.excludeApps).Count + @($config.excludeFolders).Count + @($config.excludeUrls).Count)
            EncryptedCount    = [int]$encryptedCount
            Bytes             = [int64]$bytes
        }
    } finally {
        try { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Import-SRRecoveryKit {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Recovery kit not found: $Path" }
    $source = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($source.Length -gt 512MB) { throw 'The recovery kit is too large to import (512 MB maximum).' }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = $null
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('sr-kit-import-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
        if ($zip.Entries.Count -gt 512) { throw 'The recovery kit contains too many entries.' }
        $totalBytes = [int64]0
        $entryMap = @{}
        foreach ($entry in @($zip.Entries)) {
            # Windows ZIP writers may store backslashes. Normalize before any
            # lookup, traversal check or duplicate detection.
            $name = ([string]$entry.FullName).Replace('\', '/')
            if ($name -match '(^|/)\.\.(/|$)' -or $name.StartsWith('/') -or $name -match '^[A-Za-z]:') {
                throw 'The recovery kit contains an unsafe path.'
            }
            $totalBytes += [int64]$entry.Length
            if ($totalBytes -gt 512MB) { throw 'The recovery kit expands to more than 512 MB.' }
            if (-not $entryMap.ContainsKey($name)) { $entryMap[$name] = $entry }
        }

        if (-not $entryMap.ContainsKey('manifest.json')) { throw 'The file is not a Session Recovery kit (manifest.json is missing).' }
        $manifestJson = Read-SRZipTextEntry -Entry $entryMap['manifest.json'] -MaxBytes 1MB
        $manifest = $null
        try { $manifest = $manifestJson | ConvertFrom-Json } catch { throw "The kit manifest is not valid JSON: $($_.Exception.Message)" }
        if ($null -eq $manifest) { throw 'The kit manifest is empty.' }
        $kindProperty = $manifest.PSObject.Properties['kind']
        if ($null -eq $kindProperty -or [string]$kindProperty.Value -ne 'SessionRecoveryRecoveryKit') {
            throw 'The file is not a Session Recovery kit.'
        }
        $formatProperty = $manifest.PSObject.Properties['format']
        if ($null -eq $formatProperty -or [int]$formatProperty.Value -ne 1) {
            throw 'This recovery kit format is not supported.'
        }
        $snapshotProperty = $manifest.PSObject.Properties['snapshots']
        if ($null -eq $snapshotProperty -or $null -eq $snapshotProperty.Value) { throw 'The kit manifest has no snapshot list.' }
        $manifestSnapshots = @($snapshotProperty.Value)
        if ($manifestSnapshots.Count -gt 200) { throw 'The recovery kit lists too many snapshots.' }

        $knownNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($item in $manifestSnapshots) {
            if ($null -eq $item) { continue }
            $nameProperty = $item.PSObject.Properties['name']
            $name = if ($null -ne $nameProperty) { [string]$nameProperty.Value } else { '' }
            if ([string]::IsNullOrWhiteSpace($name) -or $name -ne [System.IO.Path]::GetFileName($name)) {
                throw 'The kit manifest contains an invalid snapshot name.'
            }
            if ($name -notmatch '^session-[0-9A-Za-z][0-9A-Za-z._-]*\.json(\.gz)?$') {
                throw 'The kit manifest contains an unexpected snapshot name.'
            }
            [void]$knownNames.Add($name)
        }

        $config = Get-SRConfig
        $existingApps = @($config.excludeApps | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        $existingFolders = @($config.excludeFolders | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        $existingUrls = @($config.excludeUrls | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })

        $exclusionAdded = 0
        $exclusionsProperty = $manifest.PSObject.Properties['exclusions']
        if ($null -ne $exclusionsProperty -and $null -ne $exclusionsProperty.Value) {
            $categoryMap = @(
                @{ Property = 'excludeApps'; Existing = $existingApps; Values = $null },
                @{ Property = 'excludeFolders'; Existing = $existingFolders; Values = $null },
                @{ Property = 'excludeUrls'; Existing = $existingUrls; Values = $null }
            )
            $mapping = @{ apps = 0; folders = 1; urls = 2 }
            foreach ($key in @($mapping.Keys)) {
                $category = $categoryMap[$mapping[$key]]
                $property = $exclusionsProperty.Value.PSObject.Properties[$key]
                if ($null -eq $property -or $null -eq $property.Value) { continue }
                $values = @($property.Value | Select-Object -First 200)
                $current = @($category.Existing)
                foreach ($value in $values) {
                    $text = [string]$value
                    if ([string]::IsNullOrWhiteSpace($text)) { continue }
                    if ($text.Length -gt 512) { continue }
                    if ([regex]::IsMatch($text, '[\x00-\x1F]')) { continue }
                    if ($current -notcontains $text) {
                        $current += $text
                        $exclusionAdded++
                    }
                }
                $categoryMap[$mapping[$key]].Existing = @($current)
            }
            $config.excludeApps = @($categoryMap[0].Existing)
            $config.excludeFolders = @($categoryMap[1].Existing)
            $config.excludeUrls = @($categoryMap[2].Existing)
        }

        $notes = ConvertTo-SRNoteTable -Value $config.snapshotNotes
        $manifestNotes = $null
        $notesProperty = $manifest.PSObject.Properties['notes']
        if ($null -ne $notesProperty) { $manifestNotes = ConvertTo-SRNoteTable -Value $notesProperty.Value }
        if ($null -eq $manifestNotes) { $manifestNotes = @{} }

        $imported = 0
        $skipped = 0
        $encryptedSkipped = 0
        $notesAdded = 0
        $errors = New-Object System.Collections.Generic.List[string]
        $importedMap = @{}
        $snapshotTemp = Join-Path $tempRoot 'snapshots'
        New-Item -ItemType Directory -Path $snapshotTemp -Force | Out-Null

        foreach ($name in @($knownNames)) {
            $entryName = 'snapshots/' + $name
            if (-not $entryMap.ContainsKey($entryName)) { $skipped++; continue }
            $entry = $entryMap[$entryName]
            if ([int64]$entry.Length -gt 32MB) { $skipped++; $errors.Add(('{0}: entry is too large.' -f $name)); continue }
            $tempFile = Join-Path $snapshotTemp $name
            try {
                [void](Copy-SRZipEntryToFile -Entry $entry -Path $tempFile -MaxBytes 32MB)
                $bytes = [System.IO.File]::ReadAllBytes($tempFile)
                if ($bytes.Length -ge 5 -and [System.Text.Encoding]::ASCII.GetString($bytes, 0, 5) -eq 'SRDP1') {
                    $encryptedSkipped++
                    $skipped++
                    continue
                }
                $importSource = $tempFile
                if ($name -like '*.gz') {
                    # Kits are portable: decompress gzip snapshots before the
                    # normal import validation so another PC can read them.
                    $plainPath = Join-Path $snapshotTemp (($name -replace '\.gz$', '') + '.import')
                    $inputStream = New-Object System.IO.MemoryStream (,$bytes)
                    $outputStream = $null
                    $gzip = $null
                    try {
                        $outputStream = [System.IO.File]::Open($plainPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                        $gzip = New-Object System.IO.Compression.GZipStream($inputStream, [System.IO.Compression.CompressionMode]::Decompress)
                        $buffer = New-Object byte[] 81920
                        $written = 0
                        while (($read = $gzip.Read($buffer, 0, $buffer.Length)) -gt 0) {
                            $written += $read
                            if ($written -gt 32MB) { throw 'The decompressed snapshot is too large.' }
                            $outputStream.Write($buffer, 0, $read)
                        }
                    } finally {
                        if ($null -ne $gzip) { $gzip.Dispose() }
                        if ($null -ne $outputStream) { $outputStream.Dispose() }
                        $inputStream.Dispose()
                    }
                    $importSource = $plainPath
                }
                $target = Import-SRSnapshotFile -Path $importSource
                $targetName = Split-Path -Leaf $target
                $importedMap[$name] = $targetName
                if ($manifestNotes.ContainsKey($name)) {
                    $note = [string]$manifestNotes[$name]
                    if (-not [string]::IsNullOrWhiteSpace($note) -and $note.Length -le 500) {
                        if (-not $notes.ContainsKey($targetName)) {
                            $notes[$targetName] = $note
                            $notesAdded++
                        }
                    }
                }
                $imported++
            } catch {
                $skipped++
                $errors.Add(('{0}: {1}' -f $name, $_.Exception.Message))
            } finally {
                try { if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue } } catch { }
            }
        }

        $config.snapshotNotes = $notes
        Save-SRConfig -Config $config
        Write-SRLog -Message ("Recovery kit imported: {0} snapshot(s), {1} exclusion(s), {2} note(s), {3} skipped." -f $imported, $exclusionAdded, $notesAdded, $skipped)
        return [pscustomobject]@{
            Imported          = [int]$imported
            Skipped           = [int]$skipped
            EncryptedSkipped  = [int]$encryptedSkipped
            ExclusionsAdded   = [int]$exclusionAdded
            NotesAdded        = [int]$notesAdded
            Errors            = @($errors.ToArray())
        }
    } finally {
        if ($null -ne $zip) { $zip.Dispose() }
        try { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

# ---------------------------------------------------------------------------
# Recovery insights
# ---------------------------------------------------------------------------

function Get-SRRecoveryInsights {
    param(
        [object[]]$Entries = $null,
        $Config = $null
    )
    if ($null -eq $Entries) { $Entries = @(Get-SRSnapshots) }
    if ($null -eq $Config) { $Config = Get-SRConfig }

    $appCounts = @{}
    $siteCounts = @{}
    $storageBytes = [int64]0
    $tabCaptures = 0
    $appCaptures = 0
    $oldest = $null
    $newest = $null
    $importedCount = 0

    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) { continue }
        if ($null -eq $oldest -or $entry.CapturedAt -lt $oldest) { $oldest = $entry.CapturedAt }
        if ($null -eq $newest -or $entry.CapturedAt -gt $newest) { $newest = $entry.CapturedAt }
        try { $storageBytes += (Get-Item -LiteralPath $entry.Path).Length } catch { }
        $snapshot = $entry.Snapshot
        if ($null -eq $snapshot) { continue }
        $importedProperty = $snapshot.PSObject.Properties['imported']
        if ($null -ne $importedProperty) {
            try { if ([bool]$importedProperty.Value) { $importedCount++ } } catch { }
        }
        foreach ($app in @($snapshot.apps)) {
            if ($null -eq $app) { continue }
            $name = ''
            $displayProperty = $app.PSObject.Properties['displayName']
            if ($null -ne $displayProperty) { $name = [string]$displayProperty.Value }
            if ([string]::IsNullOrWhiteSpace($name)) {
                $nameProperty = $app.PSObject.Properties['name']
                if ($null -ne $nameProperty) { $name = [string]$nameProperty.Value }
            }
            if ([string]::IsNullOrWhiteSpace($name)) {
                $exeProperty = $app.PSObject.Properties['exe']
                if ($null -ne $exeProperty) { $name = Split-Path -Leaf ([string]$exeProperty.Value) }
            }
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $appCaptures++
            $key = $name.ToLowerInvariant()
            if ($appCounts.ContainsKey($key)) { $appCounts[$key]++ } else { $appCounts[$key] = 1 }
        }
        foreach ($browser in @($snapshot.browsers)) {
            if ($null -eq $browser) { continue }
            foreach ($profile in @($browser.profiles)) {
                if ($null -eq $profile) { continue }
                foreach ($tab in @($profile.tabs)) {
                    if ($null -eq $tab) { continue }
                    $tabCaptures++
                    $urlProperty = $tab.PSObject.Properties['url']
                    $url = if ($null -ne $urlProperty) { [string]$urlProperty.Value } else { '' }
                    if ([string]::IsNullOrWhiteSpace($url)) { continue }
                    $uri = $null
                    if (-not [System.Uri]::TryCreate($url, [System.UriKind]::Absolute, [ref]$uri)) { continue }
                    if ($uri.Scheme -ne 'http' -and $uri.Scheme -ne 'https') { continue }
                    $hostName = ([string]$uri.Host).ToLowerInvariant().Trim()
                    if ([string]::IsNullOrWhiteSpace($hostName)) { continue }
                    if ($siteCounts.ContainsKey($hostName)) { $siteCounts[$hostName]++ } else { $siteCounts[$hostName] = 1 }
                }
            }
        }
    }

    $topApps = @($appCounts.GetEnumerator() |
        Sort-Object -Property @{ Expression = { [int]$_.Value } }, @{ Expression = { [string]$_.Key } } -Descending |
        Select-Object -First 5 | ForEach-Object {
            [pscustomobject]@{ Name = [string]$_.Key; Count = [int]$_.Value }
        })
    $topSites = @($siteCounts.GetEnumerator() |
        Sort-Object -Property @{ Expression = { [int]$_.Value } }, @{ Expression = { [string]$_.Key } } -Descending |
        Select-Object -First 5 | ForEach-Object {
            [pscustomobject]@{ Name = [string]$_.Key; Count = [int]$_.Value }
        })

    $pinned = @($Config.pinnedSnapshots | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count
    $noteTable = ConvertTo-SRNoteTable -Value $Config.snapshotNotes
    $noteCount = 0
    foreach ($entry in @($Entries)) {
        if ($null -ne $entry -and $noteTable.ContainsKey((Split-Path -Leaf $entry.Path))) { $noteCount++ }
    }

    $spanDays = 0
    if ($null -ne $oldest -and $null -ne $newest) { $spanDays = [Math]::Max(0, [Math]::Round(($newest - $oldest).TotalDays, 1)) }
    $averageBytes = 0
    if (@($Entries).Count -gt 0) { $averageBytes = [int64]($storageBytes / @($Entries).Count) }

    return [pscustomobject]@{
        SnapshotCount  = @($Entries).Count
        OldestAt       = if ($null -ne $oldest) { ([datetime]$oldest).ToString('o') } else { $null }
        NewestAt       = if ($null -ne $newest) { ([datetime]$newest).ToString('o') } else { $null }
        SpanDays       = [double]$spanDays
        StorageBytes   = [int64]$storageBytes
        AverageBytes   = [int64]$averageBytes
        AppCaptures    = [int]$appCaptures
        UniqueApps     = [int]$appCounts.Count
        TabCaptures    = [int]$tabCaptures
        UniqueSites    = [int]$siteCounts.Count
        PinnedCount    = [int]$pinned
        NoteCount      = [int]$noteCount
        ImportedCount  = [int]$importedCount
        TopApps        = @($topApps)
        TopSites       = @($topSites)
    }
}

# ---------------------------------------------------------------------------
# Application updates
# ---------------------------------------------------------------------------

$script:SRUpdateRepository = 'Bilalmesk/session-recovery'
$script:SRUpdateUserAgent = 'SessionRecovery-Updater'

function ConvertTo-SRVersion {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $clean = $Value.Trim()
    if ($clean -match '^[vV]?(\d+\.\d+\.\d+(?:\.\d+)?)') {
        try { return [version]$matches[1] } catch { return $null }
    }
    return $null
}

function Hide-SRConsoleWindow {
    # A restore prompt launched by an old scheduled task can briefly own a
    # conhost window even when PowerShell was started with -WindowStyle Hidden.
    # Hide it as soon as the script runs; the native host has no console at all.
    if (-not [string]::IsNullOrWhiteSpace($env:SESSIONRECOVERY_HOST)) { return }
    try {
        if (-not ('SessionRecovery.ConsoleWindow' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace SessionRecovery
{
    public static class ConsoleWindow
    {
        [DllImport("kernel32.dll")]
        private static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        public static void Hide()
        {
            IntPtr handle = GetConsoleWindow();
            if (handle != IntPtr.Zero) { ShowWindow(handle, 0); }
        }
    }
}
'@
        }
        [SessionRecovery.ConsoleWindow]::Hide()
    } catch { }
}

function Get-SRUpdateInfo {
    param([string]$CurrentVersion = '0.0.0')
    $current = ConvertTo-SRVersion -Value $CurrentVersion
    if ($null -eq $current) {
        return [pscustomobject]@{ Ok = $false; Error = "Current version '$CurrentVersion' is invalid." }
    }

    $release = $null
    try {
        # The repository is public: the updater deliberately uses the
        # unauthenticated GitHub API and never reads or forwards local tokens.
        $headers = @{
            'User-Agent' = $script:SRUpdateUserAgent
            'Accept'     = 'application/vnd.github+json'
        }
        $uri = 'https://api.github.com/repos/{0}/releases/latest' -f $script:SRUpdateRepository
        $release = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 45 -ErrorAction Stop
    } catch {
        return [pscustomobject]@{
            Ok    = $false
            Error = ('Could not check GitHub Releases: ' + $_.Exception.Message)
            Hint  = 'Check your internet connection and try again. The release repository is public; no GitHub sign-in is needed.'
        }
    }

    try {
        $tag = [string]$release.tag_name
        $latest = ConvertTo-SRVersion -Value $tag
        if ($null -eq $latest) { throw "Release tag '$tag' is not a version number." }
        $assets = @($release.assets)
        $msi = @($assets | Where-Object { $_.name -match '(?i)^SessionRecovery-.+\.msi$' } | Select-Object -First 1)
        $sha = @($assets | Where-Object { $_.name -match '(?i)^SessionRecovery-.+\.msi\.sha256$' } | Select-Object -First 1)
        return [pscustomobject]@{
            Ok             = $true
            CurrentVersion = $current.ToString()
            LatestVersion  = $latest.ToString()
            Version        = $latest.ToString()
            HasUpdate      = ($latest -gt $current)
            Tag            = $tag
            Name           = [string]$release.name
            Notes          = [string]$release.body
            ReleaseUrl     = [string]$release.html_url
            PublishedAt    = [string]$release.published_at
            MsiName        = if ($msi.Count -gt 0) { [string]$msi[0].name } else { '' }
            MsiDownloadUrl = if ($msi.Count -gt 0) { [string]$msi[0].browser_download_url } else { '' }
            ShaName        = if ($sha.Count -gt 0) { [string]$sha[0].name } else { '' }
            ShaDownloadUrl = if ($sha.Count -gt 0) { [string]$sha[0].browser_download_url } else { '' }
            Source         = 'api'
        }
    } catch {
        return [pscustomobject]@{ Ok = $false; Error = $_.Exception.Message }
    }
}

function Get-SRUpdateSignature {
    param([Parameter(Mandatory = $true)][string]$Path)
    $result = [pscustomobject]@{
        Signed = $false
        Status = 'Unknown'
        Signer = ''
    }
    try {
        $signature = Get-AuthenticodeSignature -FilePath $Path -ErrorAction Stop
        $result.Status = [string]$signature.Status
        if ($signature.Status -eq [System.Management.Automation.SignatureStatus]::Valid -and $null -ne $signature.SignerCertificate) {
            $result.Signed = $true
            $result.Signer = [string]$signature.SignerCertificate.Subject
        }
    } catch {
        $result.Status = 'Unavailable'
    }
    return $result
}

function Save-SRUpdate {
    param(
        [Parameter(Mandatory = $true)][string]$UpdateJson,
        [string]$Destination = ''
    )
    $ProgressPreference = 'SilentlyContinue'
    try {
        $update = $UpdateJson | ConvertFrom-Json
        if ([string]::IsNullOrWhiteSpace([string]$update.MsiName) -or [string]::IsNullOrWhiteSpace([string]$update.ShaName)) {
            throw 'The release does not include both the MSI and its SHA256 file.'
        }
        $version = [string]$update.Version
        $safeVersion = ($version -replace '[^0-9A-Za-z._-]', '_')
        if ([string]::IsNullOrWhiteSpace($Destination)) {
            $Destination = Join-Path (Get-SRRoot) ('updates\' + $safeVersion)
        }
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        $msiPath = Join-Path $Destination ([string]$update.MsiName)
        $shaPath = Join-Path $Destination ([string]$update.ShaName)

        # Public release: download the browser asset URLs without any GitHub
        # token. A token would add nothing here and used to be forwarded by
        # Windows PowerShell on redirects.
        $headers = @{
            'User-Agent' = $script:SRUpdateUserAgent
            'Accept'     = 'application/octet-stream'
        }

        $msiUrl = [string]$update.MsiDownloadUrl
        $shaUrl = [string]$update.ShaDownloadUrl
        foreach ($url in @($msiUrl, $shaUrl)) {
            if ($url -notmatch '^https://(api\.github\.com|github\.com)/') { throw 'The update download URL is not a trusted GitHub URL.' }
        }

        Invoke-WebRequest -Uri $shaUrl -Headers $headers -OutFile $shaPath -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
        Invoke-WebRequest -Uri $msiUrl -Headers $headers -OutFile $msiPath -UseBasicParsing -TimeoutSec 240 -ErrorAction Stop

        $expected = ([string](Get-Content -LiteralPath $shaPath -Raw -ErrorAction Stop)).Trim()
        $match = [regex]::Match($expected, '(?i)\b[0-9a-f]{64}\b')
        if (-not $match.Success) { throw 'The release SHA256 file is not valid.' }
        $expectedHash = $match.Value.ToUpperInvariant()
        $actualHash = (Get-FileHash -LiteralPath $msiPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
        if ($actualHash -ne $expectedHash) {
            Remove-Item -LiteralPath $msiPath -Force -ErrorAction SilentlyContinue
            throw 'The downloaded MSI failed SHA256 verification.'
        }
        $signature = Get-SRUpdateSignature -Path $msiPath
        if (-not $signature.Signed) {
            Write-SRLog -Level WARN -Message 'The downloaded update is not digitally signed. SHA256 matched the release file, which detects corruption but cannot prove who built the release. The installer will show an unsigned-build warning before it runs.'
        }
        return [pscustomobject]@{
            Ok              = $true
            MsiPath         = $msiPath
            Sha256          = $actualHash
            Signed          = [bool]$signature.Signed
            SignatureStatus = [string]$signature.Status
            Signer          = [string]$signature.Signer
            Version         = $version
            ReleaseUrl      = [string]$update.ReleaseUrl
        }
    } catch {
        return [pscustomobject]@{ Ok = $false; Error = $_.Exception.Message }
    }
}

function Repair-SRLegacyTasks {
    # Older installers created logon tasks that launched Windows PowerShell
    # directly. Those tasks can flash a console even with -WindowStyle Hidden.
    # Point them at the native GUI host instead, preserving triggers/settings.
    $hostPath = [string]$env:SESSIONRECOVERY_HOST_EXE
    if ([string]::IsNullOrWhiteSpace($hostPath) -or -not (Test-Path -LiteralPath $hostPath)) {
        $candidate = Join-Path $env:LOCALAPPDATA 'SessionRecovery\app\SessionRecovery.exe'
        if (Test-Path -LiteralPath $candidate) { $hostPath = $candidate }
    }
    if ([string]::IsNullOrWhiteSpace($hostPath) -or -not (Test-Path -LiteralPath $hostPath)) { return @() }
    $workingDirectory = Split-Path -Parent $hostPath
    $repaired = New-Object System.Collections.Generic.List[string]
    $definitions = @(
        @{ Name = 'SessionRecovery-Snapshot'; Argument = '--snapshot-quiet'; Marker = 'Save-Session|RunHidden' },
        @{ Name = 'SessionRecovery-RestorePrompt'; Argument = '--restore-prompt'; Marker = 'Restore-Session' }
    )
    foreach ($definition in $definitions) {
        $name = [string]$definition.Name
        try {
            $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
            if ($null -eq $task) { continue }
            $actions = @($task.Actions)
            $needsRepair = $false
            foreach ($action in $actions) {
                $execute = [string]$action.Execute
                $arguments = [string]$action.Arguments
                if ($execute -match '(?i)powershell(?:\.exe)?$|wscript(?:\.exe)?$' -and $arguments -match ('(?i)' + $definition.Marker)) {
                    $needsRepair = $true
                }
                if ($name -eq 'SessionRecovery-Snapshot' -and $execute -match '(?i)SessionRecovery\.exe$' -and $arguments -match '(?i)--snapshot(?!-quiet)') {
                    $needsRepair = $true
                }
            }
            if (-not $needsRepair) { continue }
            $newAction = New-ScheduledTaskAction -Execute $hostPath -Argument $definition.Argument -WorkingDirectory $workingDirectory
            Set-ScheduledTask -TaskName $name -Action $newAction -ErrorAction Stop | Out-Null
            $repaired.Add($name)
            Write-SRLog -Message "Repaired legacy scheduled task $name to use the native host."
        } catch {
            Write-SRLog -Level WARN -Message "Could not repair scheduled task ${name}: $($_.Exception.Message)"
        }
    }
    return $repaired.ToArray()
}

function Start-SRUpdateInstall {
    param([Parameter(Mandatory = $true)][string]$MsiPath)
    if (-not (Test-Path -LiteralPath $MsiPath -PathType Leaf)) {
        throw "Update package not found: $MsiPath"
    }
    try {
        $trayProcesses = @(Get-CimInstance Win32_Process -Filter "Name='SessionRecovery.exe'" -ErrorAction SilentlyContinue | Where-Object {
            $_.CommandLine -and $_.CommandLine -match '(?i)--tray'
        })
        foreach ($process in $trayProcesses) {
            try { Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop } catch { }
        }
    } catch { }
    $arguments = '/i "' + $MsiPath.Replace('"', '""') + '" /passive /norestart REBOOT=ReallySuppress'
    return (Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -PassThru)
}

function Get-SRScheduledTaskStatus {
    param(
        [string[]]$TaskName = @('SessionRecovery-Snapshot', 'SessionRecovery-RestorePrompt')
    )

    # Schedule.Service is significantly faster than Get-ScheduledTask and works
    # on the Studio UI thread. Only enabled, non-disabled tasks count as active
    # protection so a disabled task does not block the tray snapshot owner.
    $results = New-Object System.Collections.Generic.List[object]
    $service = $null
    $folder = $null
    try {
        $service = New-Object -ComObject Schedule.Service
        $service.Connect()
        $folder = $service.GetFolder('\')
        foreach ($name in @($TaskName)) {
            $task = $null
            try {
                $task = $folder.GetTask([string]$name)
                $stateCode = [int]$task.State
                $state = switch ($stateCode) {
                    1 { 'Disabled' }
                    2 { 'Queued' }
                    3 { 'Ready' }
                    4 { 'Running' }
                    default { 'Unknown' }
                }
                $enabled = $true
                try { $enabled = [bool]$task.Enabled } catch { $enabled = ($stateCode -ne 1) }
                $results.Add([pscustomobject]@{
                    Name      = [string]$name
                    State     = [string]$state
                    StateCode = [int]$stateCode
                    Enabled   = [bool]$enabled
                    Active    = [bool]($enabled -and $stateCode -ne 1)
                })
            } catch {
                # A missing task is not an error; simply leave it out.
            } finally {
                if ($null -ne $task) {
                    try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($task) } catch { }
                }
            }
        }
    } catch {
    } finally {
        if ($null -ne $folder) {
            try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($folder) } catch { }
        }
        if ($null -ne $service) {
            try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($service) } catch { }
        }
    }
    return $results.ToArray()
}

function Get-SRDiagnostics {
    $root = Get-SRRoot
    $snapshotDir = Get-SRSnapshotDirectory
    $logDir = Get-SRLogDirectory
    $configPath = Get-SRConfigPath

    $config = Get-SRConfig
    $configValid = $true
    $configError = $null
    if (Test-Path -LiteralPath $configPath) {
        try {
            Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json | Out-Null
        } catch {
            $configValid = $false
            $configError = $_.Exception.Message
        }
    }

    # Diagnostics only needs the newest snapshot. Parsing the whole timeline
    # was the slowest part of this check on long-running installs.
    $snapshotFiles = @(Get-ChildItem -LiteralPath $snapshotDir -Filter 'session-*.json*' -File -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTime -Descending)
    $snapshotCount = $snapshotFiles.Count
    $latestPath = $null
    $latestAt = $null
    $latestAgeMinutes = $null
    if ($snapshotFiles.Count -gt 0) {
        $latestFile = $snapshotFiles[0]
        $latestPath = [string]$latestFile.FullName
        $latestCaptured = $latestFile.LastWriteTime
        try {
            # Reading just the head of the file is much cheaper than parsing a
            # potentially large snapshot JSON only to read one timestamp.
            # Gzip files fall back to a full read (they are small anyway).
            $nameLower = $latestFile.Name.ToLowerInvariant()
            if ($nameLower.EndsWith('.gz')) {
                $latestSnapshot = Read-SRSnapshotFile -Path $latestFile.FullName
                if (-not [string]::IsNullOrWhiteSpace([string]$latestSnapshot.capturedAt)) {
                    $latestCaptured = [DateTimeOffset]::Parse(
                        [string]$latestSnapshot.capturedAt,
                        [System.Globalization.CultureInfo]::InvariantCulture).LocalDateTime
                }
                $latestAt = $latestCaptured.ToString('o')
                $latestAgeMinutes = [Math]::Round(((Get-Date) - $latestCaptured).TotalMinutes, 1)
                $latestPath = [string]$latestFile.FullName
            }
            $stream = [System.IO.File]::OpenText($latestFile.FullName)
            try {
                $chunk = New-Object System.Text.StringBuilder
                $buffer = New-Object char[] 4096
                while ($chunk.Length -lt 4096) {
                    $read = $stream.Read($buffer, 0, $buffer.Length)
                    if ($read -le 0) { break }
                    [void]$chunk.Append($buffer, 0, $read)
                }
                $match = [regex]::Match($chunk.ToString(), '"capturedAt"\s*:\s*"([^"]+)"')
                if ($match.Success) {
                    $latestCaptured = [DateTimeOffset]::Parse(
                        $match.Groups[1].Value,
                        [System.Globalization.CultureInfo]::InvariantCulture).LocalDateTime
                }
            } finally { $stream.Dispose() }
        } catch { }
        $latestAt = $latestCaptured.ToString('o')
        $latestAgeMinutes = [Math]::Round(((Get-Date) - $latestCaptured).TotalMinutes, 1)
    }

    $snapshotBytes = [int64]0
    if ($snapshotFiles.Count -gt 0) {
        $measured = $snapshotFiles | Measure-Object -Property Length -Sum
        if ($null -ne $measured.Sum) { $snapshotBytes = [int64]$measured.Sum }
    }

    $tasks = @(Get-SRScheduledTaskStatus -TaskName @('SessionRecovery-Snapshot', 'SessionRecovery-RestorePrompt'))
    $activeTasks = @($tasks | Where-Object { $_.Active })

    $watcherPids = @()
    $trayPids = @()
    $nativeProcesses = @(Get-Process -Name 'SessionRecovery' -ErrorAction SilentlyContinue)
    if ($nativeProcesses.Count -gt 0) {
        try {
            $trayPids = @(Get-CimInstance Win32_Process -Filter "Name='SessionRecovery.exe'" -ErrorAction SilentlyContinue | Where-Object {
                $_.CommandLine -and ($_.CommandLine -match '(?i)--tray')
            } | ForEach-Object { [int]$_.ProcessId })
        } catch { }
    }

    # Legacy PowerShell tray/watcher processes only need a slow CIM lookup when
    # no native tray and no active scheduled task already explains the mode.
    if ($trayPids.Count -eq 0 -and $activeTasks.Count -eq 0) {
        try {
            $legacyProcesses = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
                $_.CommandLine -and ($_.CommandLine -match '(?i)Watch-Session\.ps1|Tray-SessionRecovery\.ps1')
            })
            foreach ($process in $legacyProcesses) {
                if ($process.CommandLine -match '(?i)Tray-SessionRecovery\.ps1') {
                    $trayPids += [int]$process.ProcessId
                } else {
                    $watcherPids += [int]$process.ProcessId
                }
            }
        } catch { }
    }

    $browsers = New-Object System.Collections.Generic.List[object]
    try {
        $definitions = @(Get-SRBrowserDefinitions)
        $browserNames = @($definitions | ForEach-Object { $_.processNames } | Sort-Object -Unique)
        $browserProcessMap = @{}
        foreach ($process in @(Get-Process -Name $browserNames -ErrorAction SilentlyContinue)) {
            $executablePath = ''
            try { $executablePath = [string]$process.Path } catch { }
            $browserProcessMap[[int]$process.Id] = [pscustomobject]@{
                ProcessId      = [int]$process.Id
                Name           = [string]$process.ProcessName
                ExecutablePath = $executablePath
                CommandLine    = ''
            }
        }
        foreach ($definition in $definitions) {
            try {
                $exe = Resolve-SRBrowserExe -Definition $definition -ProcessMap $browserProcessMap
                if (-not [string]::IsNullOrWhiteSpace([string]$exe)) {
                    $browsers.Add([pscustomobject]@{
                        Name = [string]$definition.name
                        Key  = [string]$definition.key
                        Exe  = [string]$exe
                    })
                }
            } catch { }
        }
    } catch { }

    $logPath = Join-Path $logDir 'session-recovery.log'
    $recentLog = @()
    if (Test-Path -LiteralPath $logPath) {
        try {
            $recentLog = @(Get-Content -LiteralPath $logPath -Tail 8 -ErrorAction Stop | ForEach-Object { [string]$_ })
        } catch { }
    }

    $scheduleMode = 'Not running'
    if ($activeTasks.Count -gt 0) {
        $scheduleMode = if ($trayPids.Count -gt 0) { 'Scheduled tasks + tray' } else { 'Scheduled tasks' }
    } elseif ($trayPids.Count -gt 0) {
        $scheduleMode = 'Background tray'
    } elseif ($watcherPids.Count -gt 0) {
        $scheduleMode = 'Startup watcher'
    }

    $installed = Test-Path -LiteralPath (Join-Path $root 'app\SessionRecovery.psm1')
    $shutdown = Get-SRLastShutdownReason

    return [pscustomobject]@{
        GeneratedAt              = (Get-Date).ToString('o')
        PowerShellVersion        = $PSVersionTable.PSVersion.ToString()
        OSVersion                = [Environment]::OSVersion.VersionString
        Installed                = [bool]$installed
        Root                     = $root
        ConfigPath               = $configPath
        ConfigValid              = [bool]$configValid
        ConfigError              = $configError
        SnapshotDirectory        = $snapshotDir
        SnapshotCount            = [int]$snapshotCount
        LatestSnapshot           = $latestPath
        LatestSnapshotAt         = $latestAt
        LatestSnapshotAgeMinutes = $latestAgeMinutes
        SnapshotBytes            = $snapshotBytes
        LogPath                  = $logPath
        ScheduleMode             = $scheduleMode
        ShutdownKind             = [string]$shutdown.Kind
        ShutdownReason           = [string]$shutdown.Reason
        ShutdownReasonKey        = [string]$shutdown.ReasonKey
        ShutdownReasonArg        = [string]$shutdown.ReasonArg
        ShutdownAt               = if ($shutdown.At) { ([datetime]$shutdown.At).ToString('o') } else { $null }
        WatcherPids              = @($watcherPids)
        TrayPids                 = @($trayPids)
        ScheduledTasks           = @($tasks)
        Browsers                 = $browsers.ToArray()
        Settings                 = [pscustomobject]@{
            IntervalMinutes     = [int]$config.snapshotIntervalMinutes
            KeepSnapshots       = [int]$config.keepSnapshots
            KeepSnapshotDays    = [int]$config.keepSnapshotDays
            PromptOnLogon       = [string]$config.promptOnLogon
            MaxRestoreAgeHours  = [int]$config.maxRestoreAgeHours
            RestoreBrowsers     = [bool]$config.restoreBrowsers
            DefaultTabMode      = [string]$config.defaultTabMode
            ExcludeApps         = @($config.excludeApps)
            ExcludeFolders      = @($config.excludeFolders)
            ExcludeUrls         = @($config.excludeUrls)
        }
        RecentLog                = @($recentLog)
    }
}


