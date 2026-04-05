using System.Runtime.Versioning;
using System.Text;

namespace Pconnect.Agent;

[SupportedOSPlatform("windows")]
internal static class Program
{
    [STAThread]
    private static void Main()
    {
        using var singleInstanceMutex = new Mutex(initiallyOwned: true, name: "Local\\Pconnect.Agent", createdNew: out var createdNew);
        if (!createdNew)
        {
            MessageBox.Show(
                "Pconnect Agent is already running. Check the tray (system notification area).",
                "Pconnect",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
            Environment.ExitCode = 0;
            return;
        }

        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
        {
            if (e.ExceptionObject is Exception ex)
            {
                LogFatal(ex);
            }
        };

        Application.ThreadException += (_, e) => LogFatal(e.Exception);

        try
        {
            ApplicationConfiguration.Initialize();
            Application.Run(new TrayAppContext());
        }
        catch (Exception ex)
        {
            LogFatal(ex);
            MessageBox.Show(ex.ToString(), "Pconnect Agent crashed", MessageBoxButtons.OK, MessageBoxIcon.Error);
            Environment.ExitCode = 1;
        }
    }

    private static void LogFatal(Exception ex)
    {
        try
        {
            var path = Path.Combine(Path.GetTempPath(), "pconnect-agent.log");
            var sb = new StringBuilder();
            sb.AppendLine("---- Pconnect.Agent fatal ----");
            sb.AppendLine(DateTimeOffset.Now.ToString("O"));
            sb.AppendLine(ex.ToString());
            sb.AppendLine();
            File.AppendAllText(path, sb.ToString());
        }
        catch
        {
            // ignored
        }
    }
}
