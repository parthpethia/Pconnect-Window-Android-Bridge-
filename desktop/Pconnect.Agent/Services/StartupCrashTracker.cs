using System.Text.Json;

namespace Pconnect.Agent.Services;

/// <summary>Detects crash / fast-fail loops via a dirty-run marker in LocalApplicationData.</summary>
internal static class StartupCrashTracker
{
    private static readonly JsonSerializerOptions JsonOpts = new() { WriteIndented = false };

    private static string StatePath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Pconnect", "startup-recovery.json");

    private static string DirtyPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Pconnect", "run.dirty");

    /// <summary>Returns consecutive abnormal-exit count after this process start (increment if previous run left dirty marker).</summary>
    public static int BeginRun()
    {
        var dir = Path.GetDirectoryName(StatePath)!;
        Directory.CreateDirectory(dir);

        var prev = ReadState();
        var streak = File.Exists(DirtyPath) ? prev.AbnormalExitStreak + 1 : 0;

        try
        {
            File.WriteAllText(DirtyPath, DateTimeOffset.UtcNow.ToString("O"));
            File.WriteAllText(StatePath, JsonSerializer.Serialize(new RecoveryState(streak), JsonOpts));
        }
        catch
        {
            // ignore
        }

        return streak;
    }

    public static void MarkCleanExit()
    {
        try
        {
            if (File.Exists(DirtyPath))
            {
                File.Delete(DirtyPath);
            }

            File.WriteAllText(StatePath, JsonSerializer.Serialize(new RecoveryState(0), JsonOpts));
        }
        catch
        {
            // ignore
        }
    }

    private static RecoveryState ReadState()
    {
        if (!File.Exists(StatePath))
        {
            return new RecoveryState(0);
        }

        try
        {
            var json = File.ReadAllText(StatePath);
            return JsonSerializer.Deserialize<RecoveryState>(json, JsonOpts) ?? new RecoveryState(0);
        }
        catch
        {
            return new RecoveryState(0);
        }
    }

    private sealed record RecoveryState(int AbnormalExitStreak);
}
