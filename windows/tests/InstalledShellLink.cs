using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace GaoCiYuan.Smoke
{
    public static class InstalledShellLink
    {
        private const int BufferSize = 32768;
        private const uint VolumeNameNt = 2;
        private const uint RawPath = 4;
        private const int ReadOnlyStorage = 0;

        // The vtable order includes every IShellLinkW method through GetArguments.
        [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IShellLinkW
        {
            [PreserveSig] int GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int size, IntPtr findData, uint flags);
            [PreserveSig] int GetIDList(out IntPtr idList);
            [PreserveSig] int SetIDList(IntPtr idList);
            [PreserveSig] int GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder value, int size);
            [PreserveSig] int SetDescription([MarshalAs(UnmanagedType.LPWStr)] string value);
            [PreserveSig] int GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder value, int size);
            [PreserveSig] int SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string value);
            [PreserveSig] int GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder value, int size);
        }

        public sealed class Link
        {
            public string TargetPath { get; }
            public string RawTargetPath { get; }
            public string ItemTargetPath { get; }
            public string Arguments { get; }

            internal Link(string targetPath, string rawTargetPath, string itemTargetPath, string arguments)
            {
                TargetPath = targetPath;
                RawTargetPath = rawTargetPath;
                ItemTargetPath = itemTargetPath;
                Arguments = arguments;
            }
        }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SHGetPathFromIDListEx(IntPtr idList, StringBuilder path, uint size, uint flags);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandleW(SafeFileHandle file, StringBuilder path, uint size, uint flags);

        [DllImport("kernel32.dll", ExactSpelling = true)]
        public static extern uint GetACP();

        public static Link Read(string fileName)
        {
            var type = Type.GetTypeFromCLSID(new Guid("00021401-0000-0000-C000-000000000046"), throwOnError: true);
            object instance = Activator.CreateInstance(type);
            try
            {
                ((IPersistFile)instance).Load(fileName, ReadOnlyStorage);
                var link = (IShellLinkW)instance;
                var arguments = new StringBuilder(BufferSize);
                int status = link.GetArguments(arguments, arguments.Capacity);
                if (status != 0)
                {
                    throw new InvalidDataException($"IShellLinkW.GetArguments returned 0x{status:X8}.");
                }
                return new Link(ReadPath(link, 0), ReadPath(link, RawPath), ReadItemPath(link), arguments.ToString());
            }
            finally { Marshal.FinalReleaseComObject(instance); }
        }

        private static string ReadPath(IShellLinkW link, uint flags)
        {
            var path = new StringBuilder(BufferSize);
            int status = link.GetPath(path, path.Capacity, IntPtr.Zero, flags);
            Marshal.ThrowExceptionForHR(status);
            return status == 0 ? path.ToString() : string.Empty;
        }

        private static string ReadItemPath(IShellLinkW link)
        {
            int status = link.GetIDList(out IntPtr idList);
            try
            {
                Marshal.ThrowExceptionForHR(status);
                if (idList == IntPtr.Zero) return string.Empty;
                var path = new StringBuilder(BufferSize);
                return SHGetPathFromIDListEx(idList, path, (uint)path.Capacity, 0) ? path.ToString() : string.Empty;
            }
            finally { Marshal.FreeCoTaskMem(idList); }
        }

        public static string ResolveFile(string path)
        {
            using (var file = File.OpenHandle(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                var resolved = new StringBuilder(BufferSize);
                uint length = GetFinalPathNameByHandleW(file, resolved, (uint)resolved.Capacity, VolumeNameNt);
                if (length == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
                if (length >= resolved.Capacity) throw new PathTooLongException(path);
                return resolved.ToString();
            }
        }
    }
}
