using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Pconnect.Agent.Services;

internal static class OperationalConfigRuntime
{
    private static readonly object Gate = new();
    private static RSA? _rsaPub;
    private static DateTimeOffset _lastLoadUtc;

    public static bool RequireSensitiveMac { get; private set; }
    public static string? MinMobileSemver { get; private set; }
    public static int MinClientProto { get; private set; } = 1;
    public static bool EmergencyDisableRemote { get; private set; }

    public static void Reload()
    {
        lock (Gate)
        {
            RequireSensitiveMac = false;
            MinMobileSemver = null;
            MinClientProto = 1;
            EmergencyDisableRemote = false;

            var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Pconnect", "operational.json");
            if (!File.Exists(path))
            {
                return;
            }

            try
            {
                var json = File.ReadAllText(path);
                using var doc = JsonDocument.Parse(json);
                var root = doc.RootElement;
                if (!root.TryGetProperty("payloadB64", out var pEl) || !root.TryGetProperty("sig", out var sEl))
                {
                    return;
                }

                var payloadB64 = pEl.GetString();
                var sigB64 = sEl.GetString();
                if (string.IsNullOrEmpty(payloadB64) || string.IsNullOrEmpty(sigB64))
                {
                    return;
                }

                var payloadBytes = Convert.FromBase64String(payloadB64);
                var sig = Convert.FromBase64String(sigB64);
                _rsaPub ??= LoadEmbeddedPub();
                if (_rsaPub is null)
                {
                    return;
                }

                if (!_rsaPub.VerifyData(payloadBytes, sig, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1))
                {
                    return;
                }

                using var inner = JsonDocument.Parse(Encoding.UTF8.GetString(payloadBytes));
                var p = inner.RootElement;
                RequireSensitiveMac = p.TryGetProperty("requireSensitiveMac", out var r) && r.ValueKind == JsonValueKind.True;
                EmergencyDisableRemote = p.TryGetProperty("emergencyDisableRemote", out var e) && e.ValueKind == JsonValueKind.True;
                if (p.TryGetProperty("minMobileSemver", out var m) && m.ValueKind == JsonValueKind.String)
                {
                    MinMobileSemver = m.GetString();
                }

                if (p.TryGetProperty("minClientProto", out var mp) && mp.ValueKind == JsonValueKind.Number && mp.TryGetInt32(out var mpi) && mpi >= 1 && mpi <= 10)
                {
                    MinClientProto = mpi;
                }

                _lastLoadUtc = DateTimeOffset.UtcNow;
            }
            catch
            {
                // keep last safe defaults
            }
        }
    }

    public static DateTimeOffset LastLoadUtc
    {
        get
        {
            lock (Gate) return _lastLoadUtc;
        }
    }

    private static RSA? LoadEmbeddedPub()
    {
        var asm = Assembly.GetExecutingAssembly();
        var name = asm.GetManifestResourceNames().FirstOrDefault(n => n.EndsWith("opconfig-pub.pem", StringComparison.OrdinalIgnoreCase));
        if (name is null)
        {
            return null;
        }

        using var s = asm.GetManifestResourceStream(name);
        if (s is null)
        {
            return null;
        }

        using var ms = new MemoryStream();
        s.CopyTo(ms);
        var rsa = RSA.Create();
        rsa.ImportFromPem(Encoding.UTF8.GetString(ms.ToArray()));
        return rsa;
    }
}
