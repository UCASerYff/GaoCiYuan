using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace GaoCiYuan.Smoke
{
    public sealed class TrayWindow
    {
        public IntPtr Handle { get; set; }
        public uint Thread { get; set; }
        public string Class { get; set; }
        public string Title { get; set; }
        public bool Visible { get; set; }
    }

    public sealed class ShellProbeResult
    {
        public bool ExplorerFound { get; set; }
        public bool Added { get; set; }
        public bool HasBounds { get; set; }
        public bool Deleted { get; set; }
        public bool BoundsAfterDelete { get; set; }
    }

    public sealed class TrayDesktop : IDisposable
    {
        const uint DesktopAccess = 0x00c7; // Read/write objects, create windows/menus, enumerate.
        const uint WindowClose = 0x0010;
        const uint KeyDown = 0x0100;
        const uint KeyUp = 0x0101;
        const uint TrayCallback = 0x040b; // pystray 0.19.5 Win32 callback message
        const int LeftButtonUp = 0x0202;
        const int RightButtonUp = 0x0205;
        const uint ErrorInsufficientBuffer = 122;
        const int IPv4 = 2;
        const int TcpOwnerPidListener = 3;
        readonly string name;
        IntPtr desktop;

        public TrayDesktop()
        {
            name = "GaoCiYuanTraySmoke-" + Guid.NewGuid().ToString("N");
            IntPtr original = GetThreadDesktop(GetCurrentThreadId());
            desktop = CreateDesktop(name, IntPtr.Zero, IntPtr.Zero, 0, DesktopAccess, IntPtr.Zero);
            if (desktop == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateDesktopW failed");
            if (GetThreadDesktop(GetCurrentThreadId()) != original && !SetThreadDesktop(original))
            {
                int error = Marshal.GetLastWin32Error();
                CloseDesktop(desktop);
                throw new Win32Exception(error, "Unable to restore the caller's desktop association");
            }
        }

        public Process Launch(string exe, string data)
        {
            var startup = new StartupInfo { Size = Marshal.SizeOf(typeof(StartupInfo)), Desktop = name };
            ProcessInfo info;
            var args = new StringBuilder("\"" + exe + "\" --data-dir \"" + data + "\"");
            if (!CreateProcess(exe, args, IntPtr.Zero, IntPtr.Zero, false, 0, IntPtr.Zero, System.IO.Path.GetDirectoryName(exe), ref startup, out info))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateProcessW failed on the isolated desktop");
            try
            {
                var process = Process.GetProcessById((int)info.ProcessId);
                // Keep the process handle even for a fast secondary activation.
                if (process.SafeHandle.IsInvalid) throw new InvalidOperationException("The launched process handle is invalid");
                return process;
            }
            finally { CloseHandle(info.Thread); CloseHandle(info.Process); }
        }

        public TrayWindow[] Windows(int process)
        {
            var result = new List<TrayWindow>();
            WindowCallback addWindow = delegate(IntPtr window, IntPtr data)
            {
                uint owner;
                uint thread = GetWindowThreadProcessId(window, out owner);
                if (owner != process) return true;
                var title = new StringBuilder(512);
                var windowClass = new StringBuilder(256);
                GetWindowText(window, title, title.Capacity);
                GetClassName(window, windowClass, windowClass.Capacity);
                result.Add(new TrayWindow { Handle = window, Class = windowClass.ToString(), Title = title.ToString(),
                                            Visible = IsWindowVisible(window), Thread = thread });
                return true;
            };
            EnumDesktopWindows(desktop, addWindow, IntPtr.Zero);
            return result.ToArray();
        }

        public static bool OnCurrentDesktop(int process)
        {
            bool found = false;
            EnumWindows(delegate(IntPtr window, IntPtr data) {
                uint owner;
                GetWindowThreadProcessId(window, out owner);
                if (owner == process && IsWindowVisible(window)) found = true;
                return true;
            }, IntPtr.Zero);
            return found;
        }

        public static void CloseMain(IntPtr window) { Post(window, WindowClose, 0, 0); }
        public static void OpenTrayDefault(IntPtr window) { Post(window, TrayCallback, 0, LeftButtonUp); }
        public static void OpenTrayMenu(IntPtr window) { Post(window, TrayCallback, 0, RightButtonUp); }

        public static void ChooseQuitPrompt(IntPtr dialog, bool confirm)
        {
            int choice = confirm ? 1 : 2; // IDOK or IDCANCEL
            IntPtr button = GetDlgItem(dialog, choice);
            if (button == IntPtr.Zero || !PostMessage(dialog, 0x0111, (IntPtr)choice, button))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not choose the native quit confirmation");
        }

        public static string QuitPromptText(IntPtr dialog)
        {
            var texts = new List<string>();
            EnumChildWindows(dialog, delegate(IntPtr control, IntPtr data) {
                var windowClass = new StringBuilder(64);
                GetClassName(control, windowClass, windowClass.Capacity);
                if (windowClass.ToString() == "Static")
                {
                    var message = new StringBuilder(1024);
                    IntPtr length;
                    if (SendMessageTimeout(control, 0x000d, (IntPtr)message.Capacity, message, 0x0002, 800, out length) != IntPtr.Zero)
                        texts.Add(message.ToString());
                }
                return true;
            }, IntPtr.Zero);
            return String.Join(" ", texts);
        }

        public static void SelectLastMenuItem(IntPtr popup)
        {
            const int End = 0x23, Enter = 0x0d;
            Post(popup, KeyDown, End, 1);
            Post(popup, KeyUp, End, unchecked((int)0xc0000001));
            Post(popup, KeyDown, Enter, 1);
            Post(popup, KeyUp, Enter, unchecked((int)0xc0000001));
        }

        public static bool ShellHasIcon(IntPtr window, uint id)
        {
            var icon = new NotifyIdentifier { Size = Marshal.SizeOf(typeof(NotifyIdentifier)), Window = window, Id = id };
            Rectangle bounds;
            return Shell_NotifyIconGetRect(ref icon, out bounds) == 0 && bounds.Right > bounds.Left && bounds.Bottom > bounds.Top;
        }

        public static ShellProbeResult ProbeShell()
        {
            var result = new ShellProbeResult { ExplorerFound = FindWindow("Shell_TrayWnd", null) != IntPtr.Zero };
            if (!result.ExplorerFound) return result;
            const uint NoActivate = 0x08000000, Popup = 0x80000000;
            IntPtr window = CreateWindowEx(NoActivate, "Static", null, Popup, 0, 0, 0, 0,
                                           IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            if (window == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not create the hidden shell probe window");
            try
            {
                if (IsWindowVisible(window)) throw new InvalidOperationException("The shell probe window was visible");
                var icon = new NotifyData { Size = Marshal.SizeOf(typeof(NotifyData)), Window = window, Id = 1,
                                            Flags = 0x07, Callback = TrayCallback,
                                            Icon = LoadIcon(IntPtr.Zero, (IntPtr)32512), Tip = "GaoCiYuan native tray smoke" };
                result.Added = Shell_NotifyIcon(0, ref icon);
                try { result.HasBounds = result.Added && ShellHasIcon(window, icon.Id); }
                finally { if (result.Added) result.Deleted = Shell_NotifyIcon(2, ref icon); }
                result.BoundsAfterDelete = ShellHasIcon(window, icon.Id);
                return result;
            }
            finally { DestroyWindow(window); }
        }

        public static int[] LoopbackPorts(int process)
        {
            int bytes = 0;
            uint status = GetExtendedTcpTable(IntPtr.Zero, ref bytes, false, IPv4, TcpOwnerPidListener, 0);
            if (status != ErrorInsufficientBuffer) throw new Win32Exception((int)status, "GetExtendedTcpTable size failed");
            for (int attempt = 0; attempt < 3; attempt++)
            {
                IntPtr memory = Marshal.AllocHGlobal(bytes);
                try
                {
                    status = GetExtendedTcpTable(memory, ref bytes, false, IPv4, TcpOwnerPidListener, 0);
                    if (status == ErrorInsufficientBuffer) continue;
                    if (status != 0) throw new Win32Exception((int)status, "GetExtendedTcpTable failed");
                    var ports = new List<int>();
                    int count = Marshal.ReadInt32(memory);
                    int stride = Marshal.SizeOf(typeof(TcpOwnerRow));
                    for (int index = 0; index < count; index++)
                    {
                        var row = (TcpOwnerRow)Marshal.PtrToStructure(IntPtr.Add(memory, 4 + index * stride), typeof(TcpOwnerRow));
                        if ((process == -1 || row.Owner == process) && row.LocalAddress == 0x0100007f)
                            ports.Add(((row.LocalPort & 0xff) << 8) | ((row.LocalPort >> 8) & 0xff));
                    }
                    return ports.ToArray();
                }
                finally { Marshal.FreeHGlobal(memory); }
            }
            throw new Win32Exception((int)status, "The TCP listener table did not stabilize");
        }

        public void Dispose()
        {
            if (desktop == IntPtr.Zero) return;
            CloseDesktop(desktop);
            desktop = IntPtr.Zero;
        }

        static void Post(IntPtr window, uint message, int key, int parameter)
        {
            if (!PostMessage(window, message, (IntPtr)key, (IntPtr)parameter))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not post an isolated native smoke message");
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct StartupInfo
        {
            public int Size;
            public string Reserved, Desktop, Title;
            public int X, Y, Width, Height, XChars, YChars, Fill, Flags;
            public short ShowWindow, Reserved2Size;
            public IntPtr Reserved2, StdIn, StdOut, StdErr;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct ProcessInfo { public IntPtr Process, Thread; public uint ProcessId, ThreadId; }
        [StructLayout(LayoutKind.Sequential)]
        struct Rectangle { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)]
        struct NotifyIdentifier { public int Size; public IntPtr Window; public uint Id; public Guid Guid; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct NotifyData
        {
            public int Size;
            public IntPtr Window;
            public uint Id, Flags, Callback;
            public IntPtr Icon;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Tip;
            public uint State, StateMask;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Info;
            public uint TimeoutOrVersion;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string InfoTitle;
            public uint InfoFlags;
            public Guid Guid;
            public IntPtr BalloonIcon;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct TcpOwnerRow { public int State, LocalAddress, LocalPort, RemoteAddress, RemotePort, Owner; }

        delegate bool WindowCallback(IntPtr window, IntPtr data);
        [DllImport("user32.dll", EntryPoint = "CreateDesktopW", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CreateDesktop(string name, IntPtr device, IntPtr devMode, uint flags, uint access, IntPtr attributes);
        [DllImport("user32.dll", SetLastError = true)] static extern bool CloseDesktop(IntPtr desktop);
        [DllImport("user32.dll", SetLastError = true)] static extern bool SetThreadDesktop(IntPtr desktop);
        [DllImport("user32.dll", SetLastError = true)] static extern IntPtr GetThreadDesktop(uint thread);
        [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
        [DllImport("kernel32.dll", EntryPoint = "CreateProcessW", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CreateProcess(string exe, StringBuilder parameters, IntPtr processAttrs, IntPtr threadAttrs, bool inherit,
                                         uint flags, IntPtr environment, string directory, ref StartupInfo startup, out ProcessInfo info);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr handle);
        [DllImport("user32.dll", SetLastError = true)] static extern bool EnumDesktopWindows(IntPtr desktop, WindowCallback callback, IntPtr data);
        [DllImport("user32.dll")] static extern bool EnumWindows(WindowCallback callback, IntPtr data);
        [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, WindowCallback callback, IntPtr data);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
        [DllImport("user32.dll", EntryPoint = "GetWindowTextW", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr window, StringBuilder text, int size);
        [DllImport("user32.dll", EntryPoint = "GetClassNameW", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr window, StringBuilder text, int size);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")] static extern IntPtr GetDlgItem(IntPtr window, int id);
        [DllImport("user32.dll", EntryPoint = "PostMessageW", SetLastError = true)] static extern bool PostMessage(IntPtr window, uint message, IntPtr key, IntPtr data);
        [DllImport("user32.dll", EntryPoint = "SendMessageTimeoutW", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr key, StringBuilder data, uint flags, uint timeout, out IntPtr result);
        [DllImport("user32.dll", EntryPoint = "FindWindowW", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string name, string title);
        [DllImport("user32.dll", EntryPoint = "CreateWindowExW", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CreateWindowEx(uint extendedStyle, string name, string title, uint style,
                                            int x, int y, int width, int height, IntPtr parent, IntPtr menu,
                                            IntPtr instance, IntPtr parameter);
        [DllImport("user32.dll", EntryPoint = "LoadIconW")] static extern IntPtr LoadIcon(IntPtr instance, IntPtr name);
        [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr window);
        [DllImport("shell32.dll", EntryPoint = "Shell_NotifyIconW", CharSet = CharSet.Unicode)] static extern bool Shell_NotifyIcon(uint message, ref NotifyData data);
        [DllImport("shell32.dll")] static extern int Shell_NotifyIconGetRect(ref NotifyIdentifier icon, out Rectangle bounds);
        [DllImport("iphlpapi.dll")] static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool order, int family, int type, int reserved);
    }
}
