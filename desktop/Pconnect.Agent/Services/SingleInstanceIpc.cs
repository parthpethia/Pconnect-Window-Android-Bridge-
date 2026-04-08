using System.IO.Pipes;
using System.Runtime.Versioning;
using System.Text;

namespace Pconnect.Agent.Services;

[SupportedOSPlatform("windows")]
internal static class SingleInstanceIpc
{
    private const string PipeName = "pconnect-agent-ipc-v1";
    private const string CmdShowDashboard = "show-dashboard";

    public static bool TrySendShowDashboard(int timeoutMs = 500)
    {
        try
        {
            using var client = new NamedPipeClientStream(".", PipeName, PipeDirection.Out, PipeOptions.Asynchronous);
            client.Connect(timeoutMs);
            using var writer = new StreamWriter(client, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false))
            {
                AutoFlush = true
            };
            writer.WriteLine(CmdShowDashboard);
            return true;
        }
        catch
        {
            return false;
        }
    }

    public static Task RunServerAsync(Action showDashboard, CancellationToken ct)
    {
        return Task.Run(async () =>
        {
            while (!ct.IsCancellationRequested)
            {
                NamedPipeServerStream? server = null;
                try
                {
                    server = new NamedPipeServerStream(
                        PipeName,
                        PipeDirection.In,
                        maxNumberOfServerInstances: 1,
                        PipeTransmissionMode.Message,
                        PipeOptions.Asynchronous);

                    await server.WaitForConnectionAsync(ct);

                    using var reader = new StreamReader(server, Encoding.UTF8);
                    var line = await reader.ReadLineAsync(ct);
                    if (string.Equals(line?.Trim(), CmdShowDashboard, StringComparison.OrdinalIgnoreCase))
                    {
                        showDashboard();
                    }
                }
                catch (OperationCanceledException)
                {
                    break;
                }
                catch
                {
                    // ignore and keep server alive
                }
                finally
                {
                    try
                    {
                        server?.Dispose();
                    }
                    catch
                    {
                        // ignore
                    }
                }
            }
        }, ct);
    }
}
