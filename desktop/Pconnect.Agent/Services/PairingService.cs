using System.Security.Cryptography;

namespace Pconnect.Agent.Services;

internal sealed class PairingService : IDisposable
{
    private readonly object _gate = new();
    private readonly System.Threading.Timer _timer;
    private string _currentCode = GenerateCode();

    public string CurrentCode
    {
        get { lock (_gate) { return _currentCode; } }
    }

    public PairingService()
    {
        // Rotate every 5 minutes by default.
        _timer = new System.Threading.Timer(_ => Rotate(), null, Timeout.Infinite, Timeout.Infinite);
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
            _currentCode = GenerateCode();
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
