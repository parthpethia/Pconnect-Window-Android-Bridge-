using System.Runtime.Versioning;
using System.Text;
using Pconnect.Agent.Services;

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
            // Second launch: ask the already-running instance to show the dashboard.
            // This lets users reopen the UI to start/stop the server.
            if (!SingleInstanceIpc.TrySendShowDashboard())
            {
                MessageBox.Show(
                    "Pconnect Agent is already running. Check the tray (system notification area).",
                    "Pconnect",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
            }
            Environment.ExitCode = 0;
            return;
        }

        var abnormalExitStreak = StartupCrashTracker.BeginRun();
        Application.ApplicationExit += (_, _) => StartupCrashTracker.MarkCleanExit();

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
            Application.Run(new TrayAppContext(abnormalExitStreak));
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
            CrashLog.Write(ex, null);
        }
        catch
        {
            // ignored
        }
    }
}
