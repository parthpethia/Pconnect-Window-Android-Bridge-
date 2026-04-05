using System.Runtime.Versioning;
using System.Text;

namespace Pconnect.Agent;

[SupportedOSPlatform("windows")]
internal static class Program
{
    [STAThread]
    private static void Main()
    {
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
