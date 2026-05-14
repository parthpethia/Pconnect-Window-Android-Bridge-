using System.Security.Cryptography;
using System.Text;

namespace Pconnect.Agent.Services;

internal static class CommandIntegrity
{
    public static byte[]? TryDeriveIntegrityKey(string? tokenHex, ReadOnlySpan<byte> sessionNonce16)
    {
        if (string.IsNullOrEmpty(tokenHex) || tokenHex.Length != 64)
        {
            return null;
        }

        try
        {
            var tokenBytes = Convert.FromHexString(tokenHex);
            if (tokenBytes.Length != 32)
            {
                return null;
            }

            var sub = SessionKeyDerivation.DeriveSubkeys(tokenBytes.AsSpan(), sessionNonce16);
            var copy = (byte[])sub.IntegrityKey.Clone();
            sub.Dispose();
            return copy;
        }
        catch
        {
            return null;
        }
    }

    public static bool TryVerifyMac(byte[] key, int seq, string canon, string? macB64)
    {
        if (macB64 is null || macB64.Length == 0)
        {
            return false;
        }

        byte[] macBytes;
        try
        {
            macBytes = Convert.FromBase64String(macB64);
        }
        catch
        {
            return false;
        }

        using var h = new HMACSHA256(key);
        var expected = h.ComputeHash(Encoding.UTF8.GetBytes($"{seq}|{canon}"));
        return expected.Length == macBytes.Length && CryptographicOperations.FixedTimeEquals(expected, macBytes);
    }
}
