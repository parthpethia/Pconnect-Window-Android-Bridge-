using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;

namespace Pconnect.Agent.Services;

/// <summary>Stable self-signed TLS cert for LAN WSS (TOFU on clients).</summary>
internal static class LanCertificateProvider
{
    private static readonly object Gate = new();
    private static X509Certificate2? _cached;

    public static X509Certificate2 GetOrCreate()
    {
        lock (Gate)
        {
            if (_cached is not null)
            {
                return _cached;
            }

            var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Pconnect");
            Directory.CreateDirectory(dir);
            var pfxPath = Path.Combine(dir, "lan-agent.pfx");
            var dpapiPath = Path.Combine(dir, "lan-agent.pfx.dpapi");

            if (File.Exists(pfxPath) && File.Exists(dpapiPath))
            {
                _cached = LoadPfx(pfxPath, dpapiPath);
                return _cached;
            }

            using var rsa = RSA.Create(2048);
            var subject = new X500DistinguishedName("CN=Pconnect LAN Agent");
            var req = new CertificateRequest(subject, rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
            req.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, critical: true));
            req.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment, critical: true));
            req.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(
                new OidCollection { new Oid("1.3.6.1.5.5.7.3.1") }, critical: false));

            var san = new SubjectAlternativeNameBuilder();
            san.AddDnsName("localhost");
            san.AddDnsName(Environment.MachineName);
            foreach (var ip in EnumerateLanIPv4())
            {
                san.AddIpAddress(ip);
            }

            req.CertificateExtensions.Add(san.Build());
            using var cert = req.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(8));

            var pwdText = Convert.ToHexString(RandomNumberGenerator.GetBytes(16));
            var pwdUtf8 = Encoding.UTF8.GetBytes(pwdText);
            try
            {
                var pfx = cert.Export(X509ContentType.Pfx, pwdText);
                File.WriteAllBytes(pfxPath, pfx);
                File.WriteAllBytes(dpapiPath, ProtectedData.Protect(pwdUtf8, optionalEntropy: null, DataProtectionScope.CurrentUser));
            }
            finally
            {
                CryptographicOperations.ZeroMemory(pwdUtf8);
            }

            _cached = LoadPfx(pfxPath, dpapiPath);
            return _cached;
        }
    }

    private static X509Certificate2 LoadPfx(string pfxPath, string dpapiPath)
    {
        var secret = ProtectedData.Unprotect(File.ReadAllBytes(dpapiPath), optionalEntropy: null, DataProtectionScope.CurrentUser);
        try
        {
            var pwd = Encoding.UTF8.GetString(secret);
            return new X509Certificate2(File.ReadAllBytes(pfxPath), pwd, X509KeyStorageFlags.EphemeralKeySet);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(secret);
        }
    }

    private static IEnumerable<IPAddress> EnumerateLanIPv4()
    {
        foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (ni.OperationalStatus != OperationalStatus.Up) continue;
            if (ni.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel) continue;

            foreach (var ua in ni.GetIPProperties().UnicastAddresses)
            {
                if (ua.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                if (IPAddress.IsLoopback(ua.Address)) continue;
                if (ua.Address.ToString().StartsWith("169.254.", StringComparison.Ordinal)) continue;
                yield return ua.Address;
            }
        }
    }
}
