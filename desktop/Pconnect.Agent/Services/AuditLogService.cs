using System.Globalization;
using System.Text;

namespace Pconnect.Agent.Services;

/// <summary>
/// Writes daily rotating audit log files to %AppData%\Pconnect\logs\YYYY-MM-DD.log.
/// Each entry: timestamp | device name | action performed.
/// Thread-safe.
/// </summary>
internal sealed class AuditLogService
{
    private readonly string _logDir;
    private readonly object _gate = new();

    public AuditLogService()
    {
        _logDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "Pconnect", "logs");
        Directory.CreateDirectory(_logDir);
    }

    public void Log(string? deviceName, string action)
    {
        var now = DateTimeOffset.Now;
        var date = now.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        var time = now.ToString("O", CultureInfo.InvariantCulture);
        var device = string.IsNullOrWhiteSpace(deviceName) ? "unknown" : deviceName.Trim();
        var line = $"{time} | {device} | {action}";

        lock (_gate)
        {
            try
            {
                var path = Path.Combine(_logDir, $"{date}.log");
                File.AppendAllText(path, line + Environment.NewLine, Encoding.UTF8);
            }
            catch
            {
                // Fail silently — logging should never crash the agent
            }
        }
    }

    public List<LogEntry> GetLogs(string date)
    {
        var entries = new List<LogEntry>();
        var path = Path.Combine(_logDir, $"{date}.log");

        if (!File.Exists(path)) return entries;

        try
        {
            var lines = File.ReadAllLines(path, Encoding.UTF8);
            foreach (var line in lines)
            {
                if (string.IsNullOrWhiteSpace(line)) continue;

                var parts = line.Split('|', 3, StringSplitOptions.TrimEntries);
                if (parts.Length < 3) continue;

                entries.Add(new LogEntry
                {
                    Time = parts[0],
                    Device = parts[1],
                    Action = parts[2],
                });
            }
        }
        catch
        {
            // Return whatever we managed to parse
        }

        return entries;
    }

    public sealed class LogEntry
    {
        public string Time { get; set; } = string.Empty;
        public string Device { get; set; } = string.Empty;
        public string Action { get; set; } = string.Empty;
    }
}
