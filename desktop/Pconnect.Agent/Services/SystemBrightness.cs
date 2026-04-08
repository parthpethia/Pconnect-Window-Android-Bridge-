using System.Management;
using System.Runtime.InteropServices;

namespace Pconnect.Agent.Services;

internal static class SystemBrightness
{
    // Works for many laptop internal displays via WMI. External monitors may not support this.
    public static bool TrySetPercent(int level)
    {
        try
        {
            level = Math.Clamp(level, 0, 100);
            // 1) WMI method (typical for internal laptop panels)
            if (TrySetViaWmi(level))
            {
                return true;
            }

            // 2) DDC/CI fallback (many external monitors that support DDC/CI)
            return TrySetViaDdcCi(level);
        }
        catch
        {
            return false;
        }
    }

    private static bool TrySetViaWmi(int level)
    {
        try
        {
            var brightness = (byte)level;

            var scope = new ManagementScope("\\\\.\\root\\WMI");
            scope.Connect();

            using var searcher = new ManagementObjectSearcher(scope,
                new ObjectQuery("SELECT * FROM WmiMonitorBrightnessMethods"));

            using var results = searcher.Get();
            foreach (ManagementObject method in results)
            {
                // Params: timeout, brightness (0-100)
                // Different drivers interpret timeout differently; try a few safe values.
                foreach (var timeout in new object[] { 0u, 1u, 100u, 500u })
                {
                    try
                    {
                        method.InvokeMethod("WmiSetBrightness", new[] { timeout, brightness });
                        return true;
                    }
                    catch
                    {
                        // try next
                    }
                }

                return false;
            }

            return false;
        }
        catch
        {
            return false;
        }
    }

    private static bool TrySetViaDdcCi(int level)
    {
        try
        {
            var anySucceeded = false;

            bool MonitorEnumCallback(nint hMonitor, nint hdcMonitor, nint lprcMonitor, nint dwData)
            {
                try
                {
                    if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hMonitor, out var count) || count == 0)
                    {
                        return true; // continue
                    }

                    var physical = new PHYSICAL_MONITOR[count];
                    if (!GetPhysicalMonitorsFromHMONITOR(hMonitor, count, physical))
                    {
                        return true;
                    }

                    try
                    {
                        for (var i = 0; i < physical.Length; i++)
                        {
                            var handle = physical[i].hPhysicalMonitor;
                            if (handle == nint.Zero) continue;

                            if (GetMonitorBrightness(handle, out _, out _, out _))
                            {
                                // DDC/CI brightness is also 0-100
                                if (SetMonitorBrightness(handle, (uint)level))
                                {
                                    anySucceeded = true;
                                }
                            }
                        }
                    }
                    finally
                    {
                        DestroyPhysicalMonitors(count, physical);
                    }
                }
                catch
                {
                    // ignore, continue enumerating
                }

                return true; // continue
            }

            EnumDisplayMonitors(nint.Zero, nint.Zero, MonitorEnumCallback, nint.Zero);
            return anySucceeded;
        }
        catch
        {
            return false;
        }
    }

    private delegate bool MonitorEnumProc(nint hMonitor, nint hdcMonitor, nint lprcMonitor, nint dwData);

    [DllImport("user32.dll")]
    private static extern bool EnumDisplayMonitors(nint hdc, nint lprcClip, MonitorEnumProc lpfnEnum, nint dwData);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    private struct PHYSICAL_MONITOR
    {
        public nint hPhysicalMonitor;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szPhysicalMonitorDescription;
    }

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(nint hMonitor, out uint pdwNumberOfPhysicalMonitors);

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool GetPhysicalMonitorsFromHMONITOR(nint hMonitor, uint dwPhysicalMonitorArraySize, [Out] PHYSICAL_MONITOR[] pPhysicalMonitorArray);

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool DestroyPhysicalMonitors(uint dwPhysicalMonitorArraySize, [In] PHYSICAL_MONITOR[] pPhysicalMonitorArray);

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool GetMonitorBrightness(nint hMonitor, out uint pdwMinimumBrightness, out uint pdwCurrentBrightness, out uint pdwMaximumBrightness);

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool SetMonitorBrightness(nint hMonitor, uint dwNewBrightness);
}
