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

function Get-SRRoot { $script:SRRoot }
function Get-SRSnapshotDirectory { $script:SRSnapshotDir }
function Get-SRLogDirectory { $script:SRLogDir }
function Get-SRConfigPath { $script:SRConfigPath }

function Get-SRDefaultConfig {
    [pscustomobject][ordered]@{
        snapshotIntervalMinutes = 3
        keepSnapshots           = 48
        keepSnapshotDays        = 0
        promptOnLogon           = 'CrashOnly'
        maxRestoreAgeHours      = 72
        restoreBrowsers         = $true
        defaultTabMode          = 'Smart'
        captureBrowserTabs      = $true
        captureApproximateTabs  = $true
        tabHistoryLookbackHours = 24
        showNotifications       = $true
        startWithWindows        = $true
        desktopShortcut         = $true
        theme                   = 'Aurora'
        excludeApps             = @()
        excludeFolders          = @()
        excludeUrls             = @()
    }
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

    $safe = New-Object System.Collections.Generic.List[string]
    for ($i = 1; $i -lt $parts.Count; $i++) {
        $argument = $parts[$i]
        if ([string]::IsNullOrWhiteSpace($argument)) { return @() }
        if ($argument -match '^-') { return @() }
        if ($argument -match '^/') { return @() }
        if ($argument -match '^(?i)https?://') {
            $safe.Add($argument)
            continue
        }
        if (Test-Path -LiteralPath $argument) {
            $safe.Add($argument)
            continue
        }
        return @()
    }
    if ($safe.Count -gt 8) { return @() }
    return $safe.ToArray()
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
    [void][System.Diagnostics.Process]::Start($info)
}

function Start-SRApplication {
    param(
        [Parameter(Mandatory = $true)]$App,
        [switch]$Force
    )
    if (-not $App.exe -or -not (Test-Path -LiteralPath $App.exe)) {
        return [pscustomobject]@{ Started = $false; Message = "Missing executable: $($App.exe)"; App = $App }
    }

    if (-not $Force) {
        $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            try { $_.Path -and ($_.Path -ieq $App.exe) } catch { $false }
        })
        if ($running.Count -gt 0) {
            return [pscustomobject]@{ Started = $false; Message = "Already running: $($App.name)"; App = $App }
        }
    }

    $windowStyle = if ($App.startMinimized) { 'Minimized' } else { 'Normal' }
    try {
        Start-SRDetached -FilePath $App.exe -Arguments @($App.args) -WindowStyle $windowStyle
        return [pscustomobject]@{ Started = $true; Message = "Started: $($App.name)"; App = $App }
    } catch {
        return [pscustomobject]@{ Started = $false; Message = "Failed to start $($App.name): $($_.Exception.Message)"; App = $App }
    }
}

function Open-SRFolder {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return [pscustomobject]@{ Started = $false; Message = "Missing folder: $Path" }
    }
    try {
        Start-SRDetached -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -Arguments @($Path)
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
        'backgroundTaskHost', 'dwm', 'Explorer'
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
    $browserNames = @('chrome', 'msedge', 'brave', 'vivaldi', 'opera', 'firefox')

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
        })
        if (-not $window.Minimized) { $entry.startMinimized = $false }
    }

    foreach ($entry in $groups.Values) {
        if ($entry.windows.Count -gt 0) { $entry.startMinimized = [bool]$entry.startMinimized }
        # Store a plain array. PowerShell 5.1's @() can throw an
        # "Argument types do not match" error for generic List<object> values.
        $entry.windows = $entry.windows.ToArray()
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
            key          = 'opera'
            name         = 'Opera'
            processNames = @('opera')
            kind         = 'chromium'
            userDataDir  = (Join-Path $roaming 'Opera Software\Opera Stable')
            candidates   = @(
                (Join-Path $localAppData 'Programs\Opera\opera.exe'),
                (Join-Path $programFiles 'Opera\opera.exe'),
                (Join-Path $programFilesX86 'Opera\opera.exe')
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
        }
    )
}

function Resolve-SRBrowserExe {
    param(
        [Parameter(Mandatory = $true)]$Definition,
        $ProcessMap
    )

    if ($null -ne $ProcessMap) {
        foreach ($process in $ProcessMap.Values) {
            $processName = ([string]$process.Name) -replace '\.exe$', ''
            if ($Definition.processNames -contains $processName.ToLowerInvariant()) {
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
    foreach ($hive in @('HKCU:', 'HKLM:')) {
        try {
            $key = "$hive\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$exeName"
            $value = (Get-ItemProperty -LiteralPath $key -ErrorAction Stop).'(default)'
            if ($value -and (Test-Path -LiteralPath $value)) { return $value }
        } catch { }
    }
    return $null
}

function Get-SRChromiumProfileNamesInUse {
    param(
        [Parameter(Mandatory = $true)]$Definition,
        [Parameter(Mandatory = $true)]$ProcessMap
    )

    $names = New-Object System.Collections.Generic.List[string]
    foreach ($process in $ProcessMap.Values) {
        $processName = ([string]$process.Name) -replace '\.exe$', ''
        if ($Definition.processNames -notcontains $processName.ToLowerInvariant()) { continue }
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
        $processName = ([string]$process.Name) -replace '\.exe$', ''
        if ($Definition.processNames -notcontains $processName.ToLowerInvariant()) { continue }
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
    $value = $value -replace '\s+-\s+(Google Chrome|Microsoft Edge|Brave|Opera|Vivaldi|Mozilla Firefox)$', ''
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
            $name = ([string]$_.ProcessName).ToLowerInvariant()
            $definition.processNames -contains $name
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
# Snapshot creation
# ---------------------------------------------------------------------------

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

    # Apply the user's capture exclusions before the snapshot is written, so
    # excluded names, folders and URLs never reach the JSON files on disk.

    $excludeApps = @($config.excludeApps)
    if ($excludeApps.Count -gt 0) {
        $apps = @($apps | Where-Object {
            -not (Test-SRPatternMatch -Patterns $excludeApps -Values @([string]$_.name, [string]$_.exe))
        })
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

    return [pscustomobject]@{
        schemaVersion = 1
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
        stats         = [pscustomobject]@{
            windows  = $windows.Count
            apps     = $apps.Count
            folders  = $folders.Count
            browsers = $browsers.Count
            tabs     = $tabCount
        }
    }
}

function Remove-OldSRSnapshots {
    param(
        [int]$Keep = 48,
        [int]$MaxAgeDays = 0
    )
    if ($Keep -lt 1) { $Keep = 1 }

    $files = @(Get-ChildItem -LiteralPath $script:SRSnapshotDir -Filter 'session-*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTime -Descending)

    if ($MaxAgeDays -gt 0) {
        $cutoff = (Get-Date).AddDays(-1 * [Math]::Abs($MaxAgeDays))
        foreach ($file in $files) {
            if ($file.LastWriteTime -lt $cutoff) {
                try { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop } catch { }
            }
        }
        $files = @(Get-ChildItem -LiteralPath $script:SRSnapshotDir -Filter 'session-*.json' -File -ErrorAction SilentlyContinue |
            Sort-Object -Property LastWriteTime -Descending)
    }

    if ($files.Count -le $Keep) { return }
    foreach ($file in $files[$Keep..($files.Count - 1)]) {
        try { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop } catch { }
    }
}

function Save-SRSnapshot {
    $config = Get-SRConfig
    if (-not (Test-Path -LiteralPath $script:SRSnapshotDir)) {
        New-Item -ItemType Directory -Path $script:SRSnapshotDir -Force | Out-Null
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
        $fileName = 'session-{0}.json' -f $captured.ToString('yyyyMMdd-HHmmss-fff')
        $path = Join-Path $script:SRSnapshotDir $fileName
        $json = $snapshot | ConvertTo-Json -Depth 12
        [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
        Remove-OldSRSnapshots -Keep ([int]$config.keepSnapshots) -MaxAgeDays ([int]$config.keepSnapshotDays)
        Write-SRLog -Message ("Snapshot saved: {0} ({1} apps, {2} folders, {3} browsers, {4} tabs)" -f $path, $snapshot.stats.apps, $snapshot.stats.folders, $snapshot.stats.browsers, $snapshot.stats.tabs)
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
    $files = @(Get-ChildItem -LiteralPath $script:SRSnapshotDir -Filter 'session-*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTime -Descending)
    foreach ($file in $files) {
        try {
            $snapshot = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
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
                Start-SRDetached -FilePath $exe -Arguments $args
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
                        Start-SRDetached -FilePath $exe -Arguments @('-new-window', $tab.url)
                        $first = $false
                        Start-Sleep -Milliseconds 600
                    } else {
                        Start-SRDetached -FilePath $exe -Arguments @('-new-tab', $tab.url)
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
                Start-SRDetached -FilePath $exe
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
                Start-SRDetached -FilePath $exe -Arguments $args.ToArray()
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
                    Start-SRDetached -FilePath $exe -Arguments $args.ToArray()
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
        [switch]$Force
    )

    $results = New-Object System.Collections.Generic.List[object]

    foreach ($app in @($Plan.apps)) {
        if ($null -eq $app) { continue }
        $results.Add((Start-SRApplication -App $app -Force:$Force))
    }

    foreach ($folder in @($Plan.explorer)) {
        if ([string]::IsNullOrWhiteSpace([string]$folder)) { continue }
        $results.Add((Open-SRFolder -Path ([string]$folder)))
    }

    $tabMode = 'Smart'
    if ($Plan.tabMode) { $tabMode = [string]$Plan.tabMode }
    foreach ($browser in @($Plan.browsers)) {
        if ($null -eq $browser) { continue }
        foreach ($result in @(Restore-SRBrowser -Browser $browser -TabMode $tabMode -Force:$Force)) {
            $results.Add($result)
        }
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

    return [pscustomobject]@{
        apps      = $apps.ToArray()
        explorer  = $explorer.ToArray()
        browsers  = $browsers.ToArray()
        tabMode   = $TabMode
    }
}

function Get-SRSnapshotByPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Snapshot not found: $Path" }
    $snapshot = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
    return $snapshot
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

    $snapshots = @(Get-SRSnapshots)
    $latest = $null
    if ($snapshots.Count -gt 0) { $latest = $snapshots[0] }

    $latestPath = $null
    $latestAt = $null
    $latestAgeMinutes = $null
    if ($null -ne $latest) {
        $latestPath = [string]$latest.Path
        $latestAt = ([datetimeoffset]$latest.CapturedAt).ToString('o')
        $latestAgeMinutes = [Math]::Round(((Get-Date) - $latest.CapturedAt).TotalMinutes, 1)
    }

    $snapshotFiles = @(Get-ChildItem -LiteralPath $snapshotDir -Filter 'session-*.json' -File -ErrorAction SilentlyContinue)
    $snapshotBytes = [int64]0
    if ($snapshotFiles.Count -gt 0) {
        $measured = $snapshotFiles | Measure-Object -Property Length -Sum
        if ($null -ne $measured.Sum) { $snapshotBytes = [int64]$measured.Sum }
    }

    $watcherPids = @()
    try {
        $watcherPids = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
            $_.CommandLine -and ($_.CommandLine -match '(?i)Watch-Session\.ps1')
        } | ForEach-Object { [int]$_.ProcessId })
    } catch { }

    $trayPids = @()
    try {
        $trayPids = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
            $_.CommandLine -and ($_.CommandLine -match '(?i)Tray-SessionRecovery\.ps1')
        } | ForEach-Object { [int]$_.ProcessId })
    } catch { }

    $tasks = New-Object System.Collections.Generic.List[object]
    foreach ($name in @('SessionRecovery-Snapshot', 'SessionRecovery-RestorePrompt')) {
        try {
            $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
            if ($null -ne $task) {
                $tasks.Add([pscustomobject]@{
                    Name  = [string]$task.TaskName
                    State = [string]$task.State
                })
            }
        } catch { }
    }

    $browsers = New-Object System.Collections.Generic.List[object]
    try {
        $processMap = Get-SRProcessMap
        foreach ($definition in @(Get-SRBrowserDefinitions)) {
            try {
                $exe = Resolve-SRBrowserExe -Definition $definition -ProcessMap $processMap
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
    if ($tasks.Count -gt 0) {
        $scheduleMode = if ($trayPids.Count -gt 0) { 'Scheduled tasks + tray' } else { 'Scheduled tasks' }
    } elseif ($trayPids.Count -gt 0) {
        $scheduleMode = 'Background tray'
    } elseif ($watcherPids.Count -gt 0) {
        $scheduleMode = 'Startup watcher'
    }

    $installed = Test-Path -LiteralPath (Join-Path $root 'app\SessionRecovery.psm1')

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
        SnapshotCount            = $snapshots.Count
        LatestSnapshot           = $latestPath
        LatestSnapshotAt         = $latestAt
        LatestSnapshotAgeMinutes = $latestAgeMinutes
        SnapshotBytes            = $snapshotBytes
        LogPath                  = $logPath
        ScheduleMode             = $scheduleMode
        WatcherPids              = @($watcherPids)
        TrayPids                 = @($trayPids)
        ScheduledTasks           = $tasks.ToArray()
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


