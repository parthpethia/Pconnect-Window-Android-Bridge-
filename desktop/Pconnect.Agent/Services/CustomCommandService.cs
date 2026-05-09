using System.Diagnostics;
using System.Text.Json;

namespace Pconnect.Agent.Services;

internal sealed class CustomCommandService
{
    private readonly string _configPath;
    private List<CommandEntry> _commands = new();

    public sealed class CommandEntry
    {
        public string Label { get; set; } = string.Empty;
        public string Command { get; set; } = string.Empty;
    }

    public CustomCommandService()
    {
        var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Pconnect");
        Directory.CreateDirectory(dir);
        _configPath = Path.Combine(dir, "commands.json");
        Reload();
    }

    public void Reload()
    {
        try
        {
            if (!File.Exists(_configPath))
            {
                var sample = new[]
                {
                    new CommandEntry { Label = "Open Downloads", Command = "explorer %UserProfile%\\Downloads" },
                    new CommandEntry { Label = "Task Manager", Command = "taskmgr" }
                };
                var json = JsonSerializer.Serialize(sample, new JsonSerializerOptions { WriteIndented = true });
                File.WriteAllText(_configPath, json);
                _commands = sample.ToList();
                return;
            }

            var content = File.ReadAllText(_configPath);
            _commands = JsonSerializer.Deserialize<List<CommandEntry>>(content, new JsonSerializerOptions
            {
                PropertyNameCaseInsensitive = true
            }) ?? new List<CommandEntry>();
        }
        catch
        {
            _commands = new List<CommandEntry>();
        }
    }

    public IReadOnlyList<CommandEntry> GetCommands() => _commands;

    public bool RunCommand(int index)
    {
        if (index < 0 || index >= _commands.Count) return false;
        var entry = _commands[index];
        if (string.IsNullOrWhiteSpace(entry.Command)) return false;

        try
        {
            var command = Environment.ExpandEnvironmentVariables(entry.Command);
            var parts = command.Split(' ', 2, StringSplitOptions.RemoveEmptyEntries);
            using var process = Process.Start(new ProcessStartInfo
            {
                FileName = parts[0],
                Arguments = parts.Length > 1 ? parts[1] : string.Empty,
                UseShellExecute = true,
            });
            return true;
        }
        catch { return false; }
    }
}
