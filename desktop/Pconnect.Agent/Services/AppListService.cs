using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.Versioning;

namespace Pconnect.Agent.Services;

/// <summary>
/// Reads installed applications from Start Menu shortcuts and extracts
/// their names, executable paths, and icons as base64 PNGs.
/// </summary>
[SupportedOSPlatform("windows")]
internal static class AppListService
{
    public sealed class AppInfo
    {
        public string Name { get; set; } = string.Empty;
        public string ExePath { get; set; } = string.Empty;
        public string? IconBase64 { get; set; }
    }

    /// <summary>
    /// Scans Start Menu directories for .lnk files, resolves targets,
    /// extracts icons, and returns a deduplicated sorted list.
    /// </summary>
    public static List<AppInfo> GetInstalledApps()
    {
        var apps = new Dictionary<string, AppInfo>(StringComparer.OrdinalIgnoreCase);

        var paths = new[]
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonStartMenu), "Programs"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.StartMenu), "Programs"),
        };

        foreach (var basePath in paths)
        {
            if (!Directory.Exists(basePath)) continue;

            try
            {
                foreach (var lnkFile in Directory.EnumerateFiles(basePath, "*.lnk", SearchOption.AllDirectories))
                {
                    try
                    {
                        var info = ResolveShortcut(lnkFile);
                        if (info == null) continue;
                        if (string.IsNullOrWhiteSpace(info.ExePath)) continue;

                        // Skip uninstallers and system utilities
                        var nameLower = info.Name.ToLowerInvariant();
                        if (nameLower.Contains("uninstall") || nameLower.Contains("readme") ||
                            nameLower.Contains("help") || nameLower.Contains("license"))
                        {
                            continue;
                        }

                        if (!apps.ContainsKey(info.ExePath))
                        {
                            info.IconBase64 = ExtractIconBase64(info.ExePath);
                            apps[info.ExePath] = info;
                        }
                    }
                    catch
                    {
                        // Skip individual shortcut errors
                    }
                }
            }
            catch
            {
                // Skip directory errors
            }
        }

        var result = apps.Values.OrderBy(a => a.Name, StringComparer.OrdinalIgnoreCase).ToList();
        return result;
    }

    private static AppInfo? ResolveShortcut(string lnkPath)
    {
        try
        {
            // Use WScript.Shell COM to resolve .lnk targets
            // This avoids needing a Shell32 COM reference in the project
            var wshShellType = Type.GetTypeFromProgID("WScript.Shell");
            if (wshShellType == null) return null;

            var wshShell = Activator.CreateInstance(wshShellType);
            if (wshShell == null) return null;

            dynamic shortcut = ((dynamic)wshShell).CreateShortcut(lnkPath);
            string targetPath = shortcut.TargetPath;

            if (string.IsNullOrWhiteSpace(targetPath) || !File.Exists(targetPath))
                return null;

            // Only include .exe targets
            if (!targetPath.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
                return null;

            var name = Path.GetFileNameWithoutExtension(lnkPath);
            return new AppInfo { Name = name, ExePath = targetPath };
        }
        catch
        {
            return null;
        }
    }

    private static string? ExtractIconBase64(string exePath)
    {
        try
        {
            using var icon = Icon.ExtractAssociatedIcon(exePath);
            if (icon == null) return null;

            using var bitmap = icon.ToBitmap();
            // Resize to 48x48 for consistency
            using var resized = new Bitmap(48, 48);
            using (var g = Graphics.FromImage(resized))
            {
                g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                g.DrawImage(bitmap, 0, 0, 48, 48);
            }

            using var ms = new MemoryStream();
            resized.Save(ms, ImageFormat.Png);
            return Convert.ToBase64String(ms.ToArray());
        }
        catch
        {
            return null;
        }
    }
}
