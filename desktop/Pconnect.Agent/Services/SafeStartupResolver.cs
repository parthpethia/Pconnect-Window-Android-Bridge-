using System.Runtime.InteropServices;

namespace Pconnect.Agent.Services;

internal static class SafeStartupResolver
{
    private const int VkShift = 0x10;
    private const int FastFailThreshold = 2;

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int nVirtKey);

    public static SafeStartupOptions Resolve(string[] args, int consecutiveAbnormalExits, bool pairedDevicesLoadFailed)
    {
        var reasons = new List<string>();

        foreach (var a in args)
        {
            if (string.Equals(a, "--safe-mode", StringComparison.OrdinalIgnoreCase))
            {
                reasons.Add("cli--safe-mode");
            }
        }

        if (IsShiftHeld())
        {
            reasons.Add("shift-held-at-launch");
        }

        if (consecutiveAbnormalExits >= FastFailThreshold)
        {
            reasons.Add($"abnormal-exit-streak>={FastFailThreshold}");
        }

        if (pairedDevicesLoadFailed)
        {
            reasons.Add("paired-devices-corrupt");
        }

        return reasons.Count > 0 ? SafeStartupOptions.Create(reasons) : SafeStartupOptions.Normal;
    }

    private static bool IsShiftHeld() => (GetAsyncKeyState(VkShift) & 0x8000) != 0;
}
