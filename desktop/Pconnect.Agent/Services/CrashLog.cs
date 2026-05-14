using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Pconnect.Agent.Services;

internal static class CrashLog
{
    private static readonly JsonSerializerOptions JsonOpts = new() { WriteIndented = true };

    public static void Write(Exception ex, SafeStartupOptions? safe)
    {
        try
        {
            var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Pconnect", "crashes");
            Directory.CreateDirectory(root);
            var name = $"{DateTimeOffset.UtcNow:yyyyMMdd-HHmmss}-{Guid.NewGuid():N}.json";
            var asm = Assembly.GetExecutingAssembly().GetName();
            var fp = ComputeFingerprint(ex);
            var payload = new
            {
                ts = DateTimeOffset.UtcNow,
                app = asm.Name,
                version = asm.Version?.ToString(),
                fingerprint = fp,
                os = Environment.OSVersion.ToString(),
                clr = Environment.Version.ToString(),
                safeMode = safe?.IsSafeMode ?? false,
                safeReasons = safe?.Reasons,
                exception = ex.ToString(),
            };
            File.WriteAllText(Path.Combine(root, name), JsonSerializer.Serialize(payload, JsonOpts));
        }
        catch
        {
            // ignored
        }
    }

    /// <summary>16-char hex prefix of SHA256(type + first stack line) for dedupe.</summary>
    public static string ComputeFingerprint(Exception ex)
    {
        var first = ex.ToString().Split('\n').FirstOrDefault()?.Trim() ?? ex.GetType().FullName ?? "ex";
        var src = $"{ex.GetType().FullName}|{first}";
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(src));
        return Convert.ToHexString(hash.AsSpan(0, 8));
    }
}
