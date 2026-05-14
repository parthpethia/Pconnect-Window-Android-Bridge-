using System.Runtime.Versioning;

namespace Pconnect.Agent.Services;

[SupportedOSPlatform("windows")]
internal sealed class RecentFilesHelper
{
    /// <summary>
    /// Gets recently accessed files from Windows Recent folder.
    /// </summary>
    public static List<RecentFileInfo> GetRecentFiles(int limit = 20)
    {
        var results = new List<RecentFileInfo>();

        try
        {
            var recentFolder = Environment.GetFolderPath(Environment.SpecialFolder.Recent);

            if (!Directory.Exists(recentFolder))
            {
                return results;
            }

            // Get all files in Recent folder, sorted by last access time (newest first)
            var files = new DirectoryInfo(recentFolder)
                .GetFiles("*", SearchOption.TopDirectoryOnly)
                .Where(f => !f.Name.StartsWith("."))
                .OrderByDescending(f => f.LastAccessTime)
                .Take(limit);

            foreach (var file in files)
            {
                try
                {
                    var targetPath = ExtractTargetPath(file.FullName);
                    if (!string.IsNullOrEmpty(targetPath) && File.Exists(targetPath))
                    {
                        var fileInfo = new FileInfo(targetPath);
                        results.Add(new RecentFileInfo
                        {
                            Path = targetPath,
                            Name = Path.GetFileName(targetPath),
                            Modified = (long)fileInfo.LastWriteTime.Subtract(DateTime.UnixEpoch).TotalMilliseconds,
                            Size = fileInfo.Length
                        });
                    }
                }
                catch
                {
                    // Skip files that can't be read
                }
            }
        }
        catch
        {
            // Fail gracefully
        }

        return results;
    }

    /// <summary>
    /// Extracts the target file path from a Windows shell link (.lnk) file.
    /// </summary>
    private static string? ExtractTargetPath(string linkPath)
    {
        try
        {
            // If not a .lnk file, return null (only process shortcuts)
            if (!linkPath.EndsWith(".lnk", StringComparison.OrdinalIgnoreCase))
            {
                return null;
            }

            // Try using Windows Shell.Link COM interface
            try
            {
                var shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell")!) as dynamic;
                if (shell == null) return null;

                var link = shell.CreateShortCut(linkPath) as dynamic;
                if (link == null) return null;

                string? targetPath = link.TargetPath;
                return !string.IsNullOrEmpty(targetPath) ? targetPath : null;
            }
            catch
            {
                return null;
            }
        }
        catch
        {
            return null;
        }
    }
}

internal sealed class RecentFileInfo
{
    public string Path { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public long Modified { get; set; }
    public long Size { get; set; }
}
