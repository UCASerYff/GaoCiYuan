using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace GaoCiYuan.Smoke
{
    public static class ExplorerProbeNative
    {
        public sealed class Window
        {
            public IntPtr Handle { get; set; }
            public string Class { get; set; }
            public string Title { get; set; }
            public bool Visible { get; set; }
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct Rectangle { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)]
        private struct NotifyId { public int Size; public IntPtr Window; public uint Id; public Guid Guid; }
        [StructLayout(LayoutKind.Sequential)]
        private struct IconInfo { public int IsIcon; public uint X, Y; public IntPtr Mask, Color; }
        [StructLayout(LayoutKind.Sequential)]
        private struct Bitmap
        {
            public int Type, Width, Height, Stride;
            public ushort Planes, Bits;
            public IntPtr Pixels;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct MouseInput
        {
            public int X, Y;
            public uint Data, Flags, Time;
            public UIntPtr Extra;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct Input { public uint Type; public MouseInput Mouse; }

        public static IntPtr Taskbar() { return FindWindow("Shell_TrayWnd", null); }
        public static int Owner(IntPtr window) { uint pid; GetWindowThreadProcessId(window, out pid); return (int)pid; }
        public static Window[] Windows(int pid)
        {
            var result = new List<Window>();
            EnumWindows((handle, unused) => {
                if (Owner(handle) != pid) return true;
                var title = new StringBuilder(512);
                var type = new StringBuilder(256);
                GetWindowText(handle, title, title.Capacity);
                GetClassName(handle, type, type.Capacity);
                result.Add(new Window { Handle = handle, Class = type.ToString(), Title = title.ToString(), Visible = IsWindowVisible(handle) });
                return true;
            }, IntPtr.Zero);
            return result.ToArray();
        }
        public static Rectangle? NotifyBounds(IntPtr window, uint uid)
        {
            Rectangle rect;
            if (NotifyStatus(window, uid, out rect) != 0 || rect.Right <= rect.Left || rect.Bottom <= rect.Top) return null;
            return rect;
        }

        public static int NotifyStatus(IntPtr window, uint uid, out Rectangle bounds)
        {
            var key = new NotifyId { Size = Marshal.SizeOf<NotifyId>(), Window = window, Id = uid };
            return Shell_NotifyIconGetRect(ref key, out bounds);
        }

        public static uint Dpi(IntPtr window) { return GetDpiForWindow(window); }
        public static bool PointerClick(int x, int y, bool right)
        {
            if (!SetCursorPos(x, y)) return false;
            var press = new Input { Mouse = new MouseInput { Flags = right ? 0x0008u : 0x0002u } };
            var release = new Input { Mouse = new MouseInput { Flags = right ? 0x0010u : 0x0004u } };
            return SendInput(2, new[] { press, release }, Marshal.SizeOf<Input>()) == 2;
        }
        public static int[] NativeIcon(IntPtr window, int kind)
        {
            IntPtr icon;
            if (SendMessageTimeout(window, 0x007f, (IntPtr)kind, (IntPtr)Dpi(window), 0x22, 800, out icon) == IntPtr.Zero || icon == IntPtr.Zero) return null;
            IconInfo info;
            if (!GetIconInfo(icon, out info)) return null;
            try
            {
                Bitmap image;
                if (info.Color == IntPtr.Zero || GetObject(info.Color, Marshal.SizeOf<Bitmap>(), out image) == 0) return null;
                return new[] { image.Width, image.Height, (int)image.Bits };
            }
            finally
            {
                if (info.Color != IntPtr.Zero) DeleteObject(info.Color);
                if (info.Mask != IntPtr.Zero) DeleteObject(info.Mask);
            }
        }
        public static int[] ExpectedIcon(uint dpi, bool small)
        {
            return new[] { GetSystemMetricsForDpi(small ? 49 : 11, dpi), GetSystemMetricsForDpi(small ? 50 : 12, dpi), 32 };
        }

        [DllImport("user32.dll", EntryPoint = "FindWindowW", CharSet = CharSet.Unicode)] private static extern IntPtr FindWindow(string type, string title);
        private delegate bool WindowCallback(IntPtr window, IntPtr data);
        [DllImport("user32.dll")] private static extern bool EnumWindows(WindowCallback callback, IntPtr data);
        [DllImport("user32.dll", EntryPoint = "GetWindowTextW", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr window, StringBuilder value, int size);
        [DllImport("user32.dll", EntryPoint = "GetClassNameW", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder value, int size);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
        [DllImport("user32.dll")] private static extern uint GetDpiForWindow(IntPtr window);
        [DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
        [DllImport("user32.dll")] private static extern uint SendInput(uint count, Input[] inputs, int size);
        [DllImport("user32.dll")] private static extern int GetSystemMetricsForDpi(int metric, uint dpi);
        [DllImport("shell32.dll")] private static extern int Shell_NotifyIconGetRect(ref NotifyId key, out Rectangle rect);
        [DllImport("user32.dll", EntryPoint = "SendMessageTimeoutW")] private static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr key, IntPtr value, uint flags, uint timeout, out IntPtr result);
        [DllImport("user32.dll")] private static extern bool GetIconInfo(IntPtr icon, out IconInfo info);
        [DllImport("gdi32.dll", EntryPoint = "GetObjectW")] private static extern int GetObject(IntPtr handle, int length, out Bitmap data);
        [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr handle);
    }
}
