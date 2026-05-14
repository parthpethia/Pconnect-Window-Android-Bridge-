namespace Pconnect.Agent.Services;

/// <summary>Reduced attack surface and crash-prone paths for recovery launches.</summary>
internal readonly record struct SafeStartupOptions(
    bool IsSafeMode,
    IReadOnlyList<string> Reasons,
    bool DisableScreenCapture,
    bool DisableCustomCommands,
    bool DisableNotificationMirror,
    bool DisableDiscoveryUdp)
{
    public static SafeStartupOptions Normal { get; } = new(false, Array.Empty<string>(), false, false, false, false);

    public static SafeStartupOptions Create(IReadOnlyList<string> reasons)
    {
        var list = reasons.Count == 0
            ? (IReadOnlyList<string>)new[] { "unspecified" }
            : reasons;
        return new SafeStartupOptions(true, list, true, true, true, true);
    }
}
