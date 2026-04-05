using System.Net;
using System.Net.NetworkInformation;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Hosting;

namespace Pconnect.Agent.Services;

internal sealed class AgentRuntime : IDisposable
{
    public const int DefaultWsPort = 47821;
    public const int DefaultDiscoveryPort = 47822;

    private readonly IUiActions _ui;
    private readonly CancellationTokenSource _cts = new();
    private Task? _runTask;
    private IHost? _host;

    public PairingService Pairing { get; }
    public PairedDevicesStore PairedDevices { get; }

    private readonly PcActions _pc;
    private readonly WebSocketHandler _ws;
    private readonly DiscoveryResponder _discovery;

    public AgentRuntime(IUiActions ui)
    {
        _ui = ui;
        Pairing = new PairingService();
        PairedDevices = new PairedDevicesStore();
        _pc = new PcActions();
        _ws = new WebSocketHandler(Pairing, PairedDevices, _pc, _ui);
        _discovery = new DiscoveryResponder(DefaultDiscoveryPort, DefaultWsPort);
    }

    public void Start()
    {
        if (_runTask is not null)
        {
            return;
        }

        PairedDevices.Load();
        Pairing.StartRotation();
        _discovery.Start();

        _runTask = Task.Run(() => RunWebHostAsync(_cts.Token));
    }

    public string? GetLikelyWebSocketUrl()
    {
        var ip = GetLikelyLanIPv4();
        if (ip is null)
        {
            return null;
        }

        return $"ws://{ip}:{DefaultWsPort}/ws";
    }

    private static string? GetLikelyLanIPv4()
    {
        foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (ni.OperationalStatus != OperationalStatus.Up)
            {
                continue;
            }

            if (ni.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel)
            {
                continue;
            }

            var ipProps = ni.GetIPProperties();
            foreach (var ua in ipProps.UnicastAddresses)
            {
                if (ua.Address.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork)
                {
                    continue;
                }

                if (IPAddress.IsLoopback(ua.Address))
                {
                    continue;
                }

                var ip = ua.Address.ToString();
                // Skip link-local (169.254.x.x)
                if (ip.StartsWith("169.254.", StringComparison.Ordinal))
                {
                    continue;
                }

                return ip;
            }
        }

        return null;
    }

    private async Task RunWebHostAsync(CancellationToken ct)
    {
        var builder = WebApplication.CreateBuilder();
        builder.WebHost.UseKestrel(options => { options.ListenAnyIP(DefaultWsPort); });

        var app = builder.Build();

        app.UseWebSockets(new WebSocketOptions { KeepAliveInterval = TimeSpan.FromSeconds(20) });

        app.MapGet("/health", () => Results.Text("ok"));

        app.Map("/ws", async context =>
        {
            if (!context.WebSockets.IsWebSocketRequest)
            {
                context.Response.StatusCode = 400;
                await context.Response.WriteAsync("WebSocket expected", ct);
                return;
            }

            using var webSocket = await context.WebSockets.AcceptWebSocketAsync();
            var remoteIp = context.Connection.RemoteIpAddress;
            await _ws.HandleConnectionAsync(webSocket, remoteIp, ct);
        });

        _host = app;
        await app.RunAsync(ct);
    }

    public void Dispose()
    {
        _cts.Cancel();

        try
        {
            _host?.StopAsync(TimeSpan.FromSeconds(2)).GetAwaiter().GetResult();
        }
        catch
        {
            // ignored
        }

        _host?.Dispose();
        _discovery.Dispose();
        Pairing.Dispose();
        _cts.Dispose();
    }
}
