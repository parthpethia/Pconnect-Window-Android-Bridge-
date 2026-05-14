using System.Diagnostics.CodeAnalysis;
using System.Security.Cryptography;
using System.Text.Json;

namespace Pconnect.Agent.Services;

internal sealed class PairedDevicesStore
{
    private readonly object _gate = new();
    private readonly string _path;

    private Dictionary<string, string> _tokensByDeviceId = new(StringComparer.Ordinal);
    private Dictionary<string, string> _namesByDeviceId = new(StringComparer.Ordinal);
    private Dictionary<string, string> _rolesByDeviceId = new(StringComparer.Ordinal);
    private Dictionary<string, bool> _autoLockByDeviceId = new(StringComparer.Ordinal);

    public PairedDevicesStore()
    {
        var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Pconnect");
        Directory.CreateDirectory(dir);
        _path = Path.Combine(dir, "paired-devices.json");
    }

    public void Load()
    {
        TryLoad(out _);
    }

    public bool TryLoad([NotNullWhen(false)] out string? error)
    {
        error = null;
        lock (_gate)
        {
            try
            {
                if (!File.Exists(_path))
                {
                    _tokensByDeviceId = new Dictionary<string, string>(StringComparer.Ordinal);
                    _namesByDeviceId = new Dictionary<string, string>(StringComparer.Ordinal);
                    _rolesByDeviceId = new Dictionary<string, string>(StringComparer.Ordinal);
                    _autoLockByDeviceId = new Dictionary<string, bool>(StringComparer.Ordinal);
                    return true;
                }

                var json = File.ReadAllText(_path);
                var data = JsonSerializer.Deserialize<PairedDevicesFile>(json);
                _tokensByDeviceId = data?.TokensByDeviceId ?? new Dictionary<string, string>(StringComparer.Ordinal);
                _namesByDeviceId = data?.NamesByDeviceId ?? new Dictionary<string, string>(StringComparer.Ordinal);
                _rolesByDeviceId = data?.RolesByDeviceId ?? new Dictionary<string, string>(StringComparer.Ordinal);
                _autoLockByDeviceId = data?.AutoLockByDeviceId ?? new Dictionary<string, bool>(StringComparer.Ordinal);
                return true;
            }
            catch (Exception ex)
            {
                error = ex.Message;
                _tokensByDeviceId = new Dictionary<string, string>(StringComparer.Ordinal);
                _namesByDeviceId = new Dictionary<string, string>(StringComparer.Ordinal);
                _rolesByDeviceId = new Dictionary<string, string>(StringComparer.Ordinal);
                _autoLockByDeviceId = new Dictionary<string, bool>(StringComparer.Ordinal);
                return false;
            }
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
                RolesByDeviceId = _rolesByDeviceId,
                AutoLockByDeviceId = _autoLockByDeviceId,
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

    /// <summary>
    /// Returns the role for a device. Defaults to "admin" if not set.
    /// Valid roles: "admin", "media_only", "readonly"
    /// </summary>
    public string GetRole(string deviceId)
    {
        lock (_gate)
        {
            if (_rolesByDeviceId.TryGetValue(deviceId, out var role) && !string.IsNullOrWhiteSpace(role))
            {
                return role;
            }
            return "admin";
        }
    }

    /// <summary>
    /// Returns whether auto-lock on disconnect is enabled for this device.
    /// </summary>
    public bool GetAutoLockOnDisconnect(string deviceId)
    {
        lock (_gate)
        {
            return _autoLockByDeviceId.TryGetValue(deviceId, out var v) && v;
        }
    }

    /// <summary>
    /// Sets the auto-lock on disconnect setting for a device.
    /// </summary>
    public void SetAutoLockOnDisconnect(string deviceId, bool enabled)
    {
        lock (_gate)
        {
            _autoLockByDeviceId[deviceId] = enabled;
            Save();
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

            // New devices get admin role by default
            if (!_rolesByDeviceId.ContainsKey(deviceId))
            {
                _rolesByDeviceId[deviceId] = "admin";
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
        public Dictionary<string, string>? RolesByDeviceId { get; set; }
        public Dictionary<string, bool>? AutoLockByDeviceId { get; set; }
    }
}
