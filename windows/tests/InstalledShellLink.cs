using System;
using System.Collections.Generic;
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

        // Keep the native vtable order through GetIconLocation.
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
            [PreserveSig] int SetArguments([MarshalAs(UnmanagedType.LPWStr)] string value);
            [PreserveSig] int GetHotkey(out ushort value);
            [PreserveSig] int SetHotkey(ushort value);
            [PreserveSig] int GetShowCmd(out int value);
            [PreserveSig] int SetShowCmd(int value);
            [PreserveSig] int GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int size, out int index);
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PropertyKey
        {
            public Guid FormatId;
            public int Id;
        }

        // PROPVARIANT is 24 bytes on the x64 test runner; read only VT_LPWSTR.
        [StructLayout(LayoutKind.Explicit, Size = 24)]
        private struct PropertyValue
        {
            [FieldOffset(0)] public ushort Type;
            [FieldOffset(8)] public IntPtr String;
        }

        [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IPropertyStore
        {
            void GetCount(out uint count);
            void GetAt(uint index, out PropertyKey key);
            void GetValue(ref PropertyKey key, out PropertyValue value);
        }

        public sealed class Link
        {
            public string TargetPath { get; }
            public string RawTargetPath { get; }
            public string ItemTargetPath { get; }
            public string Arguments { get; }
            public string IconPath { get; }
            public int IconIndex { get; }
            public string AppUserModelId { get; }

            internal Link(string targetPath, string rawTargetPath, string itemTargetPath, string arguments,
                          string iconPath, int iconIndex, string appUserModelId)
            {
                TargetPath = targetPath;
                RawTargetPath = rawTargetPath;
                ItemTargetPath = itemTargetPath;
                Arguments = arguments;
                IconPath = iconPath;
                IconIndex = iconIndex;
                AppUserModelId = appUserModelId;
            }
        }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SHGetPathFromIDListEx(IntPtr idList, StringBuilder path, uint size, uint flags);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandleW(SafeFileHandle file, StringBuilder path, uint size, uint flags);

        [DllImport("kernel32.dll", ExactSpelling = true)]
        public static extern uint GetACP();

        [DllImport("ole32.dll", ExactSpelling = true)]
        private static extern int PropVariantClear(ref PropertyValue value);

        [return: MarshalAs(UnmanagedType.Bool)]
        private delegate bool EnumerateResourceName(IntPtr module, IntPtr type, IntPtr name, IntPtr parameter);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        private static extern IntPtr LoadLibraryExW(string path, IntPtr file, uint flags);

        [DllImport("kernel32.dll", ExactSpelling = true)]
        private static extern bool FreeLibrary(IntPtr module);

        [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
        private static extern bool EnumResourceNamesW(IntPtr module, IntPtr type, EnumerateResourceName callback, IntPtr parameter);

        [DllImport("kernel32.dll", ExactSpelling = true)]
        private static extern IntPtr FindResourceW(IntPtr module, IntPtr name, IntPtr type);

        [DllImport("kernel32.dll", ExactSpelling = true)]
        private static extern IntPtr LoadResource(IntPtr module, IntPtr resource);

        [DllImport("kernel32.dll", ExactSpelling = true)]
        private static extern IntPtr LockResource(IntPtr resource);

        [DllImport("kernel32.dll", ExactSpelling = true)]
        private static extern uint SizeofResource(IntPtr module, IntPtr resource);

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
                var icon = new StringBuilder(BufferSize);
                Marshal.ThrowExceptionForHR(link.GetIconLocation(icon, icon.Capacity, out int index));
                var key = new PropertyKey { FormatId = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), Id = 5 };
                ((IPropertyStore)instance).GetValue(ref key, out PropertyValue modelId);
                try
                {
                    var appId = modelId.Type == 31 ? Marshal.PtrToStringUni(modelId.String) : string.Empty;
                    return new Link(ReadPath(link, 0), ReadPath(link, RawPath), ReadItemPath(link), arguments.ToString(),
                                    icon.ToString(), index, appId);
                }
                finally { PropVariantClear(ref modelId); }
            }
            finally { Marshal.FinalReleaseComObject(instance); }
        }

        public static int[] ReadExecutableIconSizes(string path)
        {
            var module = LoadLibraryExW(Path.GetFullPath(path), IntPtr.Zero, 0x22); // Data and image resource only.
            if (module == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            try
            {
                var sizes = new List<int>();
                var groupType = new IntPtr(14); // RT_GROUP_ICON
                bool found = EnumResourceNamesW(module, groupType, (handle, type, name, parameter) =>
                {
                    var resource = FindResourceW(handle, name, type);
                    if (resource == IntPtr.Zero) return true;
                    var info = LockResource(LoadResource(handle, resource));
                    uint bytes = SizeofResource(handle, resource);
                    if (info == IntPtr.Zero || bytes < 6 || Marshal.ReadInt16(info, 2) != 1) return true;
                    int count = (ushort)Marshal.ReadInt16(info, 4);
                    if (bytes < 6 + 14 * count) return true;
                    // Icon index zero selects the first group. Require real RT_ICON images for its sizes.
                    for (int i = 0; i < count; i++)
                    {
                        int entry = 6 + i * 14;
                        int width = Marshal.ReadByte(info, entry);
                        int height = Marshal.ReadByte(info, entry + 1);
                        var id = new IntPtr((ushort)Marshal.ReadInt16(info, entry + 12));
                        var image = FindResourceW(handle, id, new IntPtr(3));
                        if (width == height && image != IntPtr.Zero && SizeofResource(handle, image) > 0)
                            sizes.Add(width == 0 ? 256 : width);
                    }
                    return false;
                }, IntPtr.Zero);
                if (!found && sizes.Count == 0) throw new InvalidDataException($"No usable icon group in '{path}'.");
                return sizes.ToArray();
            }
            finally { FreeLibrary(module); }
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
