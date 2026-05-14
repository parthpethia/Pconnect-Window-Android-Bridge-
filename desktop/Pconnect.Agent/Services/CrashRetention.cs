namespace Pconnect.Agent.Services;

internal static class CrashRetention
{
    private const int MaxFiles = 40;
    private const int MaxAgeDays = 30;

    public static void Sweep()
    {
        try
        {
            var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Pconnect", "crashes");
            if (!Directory.Exists(root))
            {
                return;
            }

            var files = new DirectoryInfo(root).GetFiles("*.json").OrderByDescending(f => f.LastWriteTimeUtc).ToList();
            var cutoff = DateTime.UtcNow.AddDays(-MaxAgeDays);

            for (var i = 0; i < files.Count; i++)
            {
                var f = files[i];
                if (i >= MaxFiles || f.LastWriteTimeUtc < cutoff)
                {
                    try
                    {
                        f.Delete();
                    }
                    catch
                    {
                        // ignore
                    }
                }
            }
        }
        catch
        {
            // ignore
        }
    }
}
