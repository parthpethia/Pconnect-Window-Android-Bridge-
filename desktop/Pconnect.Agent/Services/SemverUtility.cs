namespace Pconnect.Agent.Services;

internal static class SemverUtility
{
    /// <summary>True if <paramref name="clientVersion"/> is &gt;= <paramref name="minimum"/> (major.minor.patch only; ignores prerelease after first '-').</summary>
    public static bool IsAtLeast(string? clientVersion, string? minimum)
    {
        if (string.IsNullOrWhiteSpace(minimum))
        {
            return true;
        }

        if (string.Equals(Environment.GetEnvironmentVariable("PCONNECT_BYPASS_MIN_CLIENT"), "1", StringComparison.Ordinal))
        {
            return true;
        }

        if (string.IsNullOrWhiteSpace(clientVersion))
        {
            return false;
        }

        if (!TryParseCore(clientVersion, out var cMaj, out var cMin, out var cPat))
        {
            return false;
        }

        if (!TryParseCore(minimum, out var mMaj, out var mMin, out var mPat))
        {
            return true;
        }

        if (cMaj != mMaj) return cMaj > mMaj;
        if (cMin != mMin) return cMin > mMin;
        return cPat >= mPat;
    }

    private static bool TryParseCore(string raw, out int maj, out int min, out int pat)
    {
        maj = min = pat = 0;
        var s = raw.Trim();
        var plus = s.IndexOf('+', StringComparison.Ordinal);
        if (plus >= 0)
        {
            s = s[..plus];
        }

        var dash = s.IndexOf('-', StringComparison.Ordinal);
        if (dash >= 0)
        {
            s = s[..dash];
        }

        var parts = s.Split('.', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0)
        {
            return false;
        }

        if (!int.TryParse(parts[0], out maj))
        {
            return false;
        }

        if (parts.Length > 1 && !int.TryParse(parts[1], out min))
        {
            return false;
        }

        if (parts.Length > 2 && !int.TryParse(parts[2], out pat))
        {
            return false;
        }

        return true;
    }
}
