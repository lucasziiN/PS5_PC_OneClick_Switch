using System;
using System.Runtime.InteropServices;

// Uses the active Windows display device, not a primary-monitor alias.
public static class SwitchDisplayModes
{
    private const uint DisplayFrequencyField = 0x00400000;
    private const int CurrentSettings = -1;
    private const uint IncludeRotatedModes = 4;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DeviceMode
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string DeviceName;
        public ushort SpecVersion, DriverVersion, Size, DriverExtra;
        public uint Fields;
        public int PositionX, PositionY;
        public uint Orientation, FixedOutput;
        public short Color, Duplex, YResolution, TTOption, Collate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string FormName;
        public ushort LogPixels;
        public uint BitsPerPixel, Width, Height, DisplayFlags, Frequency;
        public uint ICMMethod, ICMIntent, MediaType, DitherType;
        public uint Reserved1, Reserved2, PanningWidth, PanningHeight;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumDisplaySettingsEx(
        string deviceName, int modeNumber, ref DeviceMode mode, uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int ChangeDisplaySettingsEx(
        string deviceName, ref DeviceMode mode, IntPtr window, uint flags, IntPtr parameter);

    private static DeviceMode ReadCurrent(string deviceName)
    {
        DeviceMode mode = new DeviceMode();
        mode.Size = (ushort)Marshal.SizeOf(typeof(DeviceMode));
        if (!EnumDisplaySettingsEx(deviceName, CurrentSettings, ref mode, 0))
            throw new InvalidOperationException("Cannot read current display mode for " + deviceName);
        return mode;
    }

    public static uint CurrentRefreshRate(string deviceName)
    {
        return ReadCurrent(deviceName).Frequency;
    }

    public static uint HighestRefreshRate(string deviceName)
    {
        DeviceMode current = ReadCurrent(deviceName);
        DeviceMode candidate = new DeviceMode();
        candidate.Size = current.Size;
        uint highest = 0;
        for (int index = 0; EnumDisplaySettingsEx(deviceName, index, ref candidate, IncludeRotatedModes); index++)
        {
            // Do not trade resolution, colour depth, rotation or progressive scan for a higher Hz value.
            if (candidate.Width == current.Width && candidate.Height == current.Height &&
                candidate.BitsPerPixel == current.BitsPerPixel && candidate.Orientation == current.Orientation &&
                candidate.DisplayFlags == current.DisplayFlags && candidate.Frequency > highest)
                highest = candidate.Frequency;
        }
        if (highest <= 1)
            throw new InvalidOperationException("No explicit supported refresh rate for " + deviceName);
        return highest;
    }

    public static void SetRefreshRate(string deviceName, uint frequency)
    {
        DeviceMode current = ReadCurrent(deviceName);
        if (current.Frequency == frequency)
            return;
        // Change only refresh rate; leave all other layout settings untouched.
        current.Fields = DisplayFrequencyField;
        current.Frequency = frequency;
        int result = ChangeDisplaySettingsEx(deviceName, ref current, IntPtr.Zero, 0, IntPtr.Zero);
        if (result != 0)
            throw new InvalidOperationException("Refresh rate change for " + deviceName + " failed (Windows code " + result + ")");
    }
}
