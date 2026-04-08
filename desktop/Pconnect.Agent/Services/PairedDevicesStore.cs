using System.Security.Cryptography;
using System.Text.Json;

namespace Pconnect.Agent.Services;

internal sealed class PairedDevicesStore
{
    private readonly object _gate = new();
    private readonly string _path;

    private Dictionary<string, string> _tokensByDeviceId = new(StringComparer.Ordinal);
    private Dictionary<string, string> _namesByDeviceId = new(StringComparer.Ordinal);

    public PairedDevicesStore()
    {
        var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Pconnect");
        Directory.CreateDirectory(dir);
        _path = Path.Combine(dir, "paired-devices.json");
    }

    public void Load()
    {
        lock (_gate)
        {
            if (!File.Exists(_path))
            {
                _tokensByDeviceId = new Dictionary<string, string>(StringComparer.Ordinal);
                _namesByDeviceId = new Dictionary<string, string>(StringComparer.Ordinal);
                return;
            }

            var json = File.ReadAllText(_path);
            var data = JsonSerializer.Deserialize<PairedDevicesFile>(json);
            _tokensByDeviceId = data?.TokensByDeviceId ?? new Dictionary<string, string>(StringComparer.Ordinal);
            _namesByDeviceId = data?.NamesByDeviceId ?? new Dictionary<string, string>(StringComparer.Ordinal);
        }
    }

    public void Save()
    {
        lock (_gate)
        {
            var json = JsonSerializer.Serialize(new PairedDevicesFile
            {
                TokensByDeviceId = _tokensByDeviceId,
                NamesByDeviceId = _namesByDeviceId,
            }, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(_path, json);
        }
    }

    public string? GetDeviceName(string deviceId)
    {
        lock (_gate)
        {
            return _namesByDeviceId.TryGetValue(deviceId, out var name) ? name : null;
        }
    }

    public bool IsPaired(string deviceId, string token)
    {
        lock (_gate)
        {
            if (!_tokensByDeviceId.TryGetValue(deviceId, out var stored))
            {
                return false;
            }

            var a = System.Text.Encoding.UTF8.GetBytes(stored);
            var b = System.Text.Encoding.UTF8.GetBytes(token);
            return a.Length == b.Length && CryptographicOperations.FixedTimeEquals(a, b);
        }
    }

    public string PairNewDevice(string deviceId, string? deviceName)
    {
        var token = GenerateToken();
        lock (_gate)
        {
            _tokensByDeviceId[deviceId] = token;

            if (!string.IsNullOrWhiteSpace(deviceName))
            {
                _namesByDeviceId[deviceId] = deviceName.Trim();
            }

            Save();
        }

        return token;
    }

    private static string GenerateToken()
    {
        var bytes = RandomNumberGenerator.GetBytes(32);
        return Convert.ToHexString(bytes);
    }

    private sealed class PairedDevicesFile
    {
        public Dictionary<string, string>? TokensByDeviceId { get; set; }
        public Dictionary<string, string>? NamesByDeviceId { get; set; }
    }
}
