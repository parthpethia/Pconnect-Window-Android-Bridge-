using System.Security.Cryptography;

namespace Pconnect.Agent.Services;

internal sealed class PairingService : IDisposable
{
    private readonly object _gate = new();
    private readonly Timer _timer;

    public string CurrentCode { get; private set; } = GenerateCode();

    public PairingService()
    {
        // Rotate every 5 minutes by default.
        _timer = new Timer(_ => Rotate(), null, Timeout.Infinite, Timeout.Infinite);
    }

    public void StartRotation(TimeSpan? interval = null)
    {
        var actual = interval ?? TimeSpan.FromMinutes(5);
        _timer.Change(TimeSpan.Zero, actual);
    }

    public bool ValidateCode(string? code)
    {
        if (string.IsNullOrWhiteSpace(code))
        {
            return false;
        }

        lock (_gate)
        {
            return string.Equals(CurrentCode, code.Trim(), StringComparison.Ordinal);
        }
    }

    private void Rotate()
    {
        lock (_gate)
        {
            CurrentCode = GenerateCode();
        }
    }

    private static string GenerateCode()
    {
        // 6-digit numeric code
        var value = RandomNumberGenerator.GetInt32(0, 1_000_000);
        return value.ToString("D6");
    }

    public void Dispose() => _timer.Dispose();
}
