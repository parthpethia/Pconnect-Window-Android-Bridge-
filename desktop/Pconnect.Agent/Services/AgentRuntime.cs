using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Hosting;

namespace Pconnect.Agent.Services;

internal sealed class AgentRuntime : IDisposable
{
    public const int DefaultWsPort = 47821;
    public const int DefaultWssPort = 47824;
    public const int DefaultDiscoveryPort = 47822;

    private readonly IUiActions _ui;
    private readonly object _stateGate = new();
    private Task? _runTask;
    private IHost? _host;
    private CancellationTokenSource? _serverCts;
    private bool _isServerRunning;

    private readonly Dictionary<string, (string? Name, int Count)> _authedDevicesById = new(StringComparer.Ordinal);

    public event EventHandler? StateChanged;

    public PairingService Pairing { get; }
    public PairedDevicesStore PairedDevices { get; }

    private readonly PcActions _pc;
    private readonly WebSocketHandler _ws;
    private readonly DiscoveryResponder _discovery;
    private readonly int _abnormalExitStreak;

    public SafeStartupOptions SafeStartup { get; private set; } = SafeStartupOptions.Normal;

    public bool IsDiscoveryEnabled { get; private set; }
    public string? DiscoveryStartError { get; private set; }

    public bool IsServerRunning
    {
        get
        {
            lock (_stateGate)
            {
                return _isServerRunning;
            }
        }
    }

    public string ConnectedDeviceDisplay
    {
        get
        {
            lock (_stateGate)
            {
                if (_authedDevicesById.Count == 0)
                {
                    return "Not connected";
                }

                if (_authedDevicesById.Count == 1)
                {
                    var only = _authedDevicesById.First();
                    return string.IsNullOrWhiteSpace(only.Value.Name) ? only.Key : only.Value.Name!;
                }

                var total = _authedDevicesById.Values.Sum(v => v.Count);
                return total <= 1 ? "Connected" : $"Multiple devices ({total})";
            }
        }
    }

    public AgentRuntime(IUiActions ui, int abnormalExitStreak = 0)
    {
        _ui = ui;
        _abnormalExitStreak = abnormalExitStreak;
        Pairing = new PairingService();
        PairedDevices = new PairedDevicesStore();
        _pc = new PcActions();
        _ws = new WebSocketHandler(Pairing, PairedDevices, _pc, _ui, OnDeviceAuthed, OnDeviceDisconnected,
            () => (IsServerRunning, IsDiscoveryEnabled));
        _discovery = new DiscoveryResponder(DefaultDiscoveryPort, DefaultWsPort, DefaultWssPort);
    }

    public void Start()
    {
        CrashRetention.Sweep();
        OperationalConfigRuntime.Reload();

        var pairedOk = PairedDevices.TryLoad(out _);
        SafeStartup = SafeStartupResolver.Resolve(Environment.GetCommandLineArgs(), _abnormalExitStreak, !pairedOk);
        _ws.ConfigureSafeMode(SafeStartup);

        Pairing.StartRotation();
        StartServer();
    }

    public void StartServer()
    {
        lock (_stateGate)
        {
            if (_isServerRunning)
            {
                return;
            }

            _isServerRunning = true;
            _serverCts = new CancellationTokenSource();
        }

        try
        {
            if (!SafeStartup.DisableDiscoveryUdp)
            {
                _discovery.Start();
                IsDiscoveryEnabled = true;
                DiscoveryStartError = null;
            }
            else
            {
                IsDiscoveryEnabled = false;
                DiscoveryStartError = "Safe mode: UDP discovery is disabled. Use manual IP or Copy WebSocket URL from the tray menu.";
            }
        }
        catch (SocketException ex) when (ex.SocketErrorCode == SocketError.AddressAlreadyInUse)
        {
            // Keep the agent running (WebSocket server still works); only discovery is disabled.
            IsDiscoveryEnabled = false;
            DiscoveryStartError = $"Discovery is disabled because UDP port {DefaultDiscoveryPort} is already in use. Close other Pconnect instances (tray) or free the port, then restart.";
        }

        CancellationToken token;
        lock (_stateGate)
        {
            token = _serverCts!.Token;
        }

        _runTask = Task.Run(() => RunWebHostAsync(token));
        RaiseStateChanged();
    }

    public void StopServer()
    {
        CancellationTokenSource? cts;
        IHost? host;
        lock (_stateGate)
        {
            if (!_isServerRunning)
            {
                return;
            }

            _isServerRunning = false;
            cts = _serverCts;
            _serverCts = null;
            host = _host;
            _host = null;
            _runTask = null;
            _authedDevicesById.Clear();
        }

        try
        {
            cts?.Cancel();
        }
        catch
        {
            // ignore
        }

        try
        {
            host?.StopAsync(TimeSpan.FromSeconds(2)).GetAwaiter().GetResult();
        }
        catch
        {
            // ignore
        }

        try
        {
            host?.Dispose();
        }
        catch
        {
            // ignore
        }

        try
        {
            cts?.Dispose();
        }
        catch
        {
            // ignore
        }

        _discovery.Stop();
        IsDiscoveryEnabled = false;
        RaiseStateChanged();
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
        try
        {
            var builder = WebApplication.CreateBuilder();
            var tlsCert = LanCertificateProvider.GetOrCreate();
            builder.WebHost.ConfigureKestrel(options =>
            {
                options.ListenAnyIP(DefaultWsPort);
                try
                {
                    options.ListenAnyIP(DefaultWssPort, listen => listen.UseHttps(tlsCert));
                }
                catch
                {
                    // WSS bind failed (port conflict); cleartext WS remains.
                }
            });

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

            lock (_stateGate)
            {
                _host = app;
            }

            await app.RunAsync(ct);
        }
        catch (OperationCanceledException)
        {
            // normal when StopServer() cancels
        }
        catch
        {
            // keep agent alive; UI will reflect server as stopped
        }
        finally
        {
            CancellationTokenSource? ctsToDispose = null;
            var shouldRaise = false;

            lock (_stateGate)
            {
                // If the server loop exits unexpectedly while the runtime still thinks it's running,
                // flip state to stopped so the dashboard button is correct.
                if (_isServerRunning)
                {
                    _isServerRunning = false;
                    ctsToDispose = _serverCts;
                    _serverCts = null;
                    _host = null;
                    _runTask = null;
                    _authedDevicesById.Clear();
                    shouldRaise = true;
                }
            }

            try
            {
                ctsToDispose?.Dispose();
            }
            catch
            {
                // ignore
            }

            if (shouldRaise)
            {
                try
                {
                    _discovery.Stop();
                }
                catch
                {
                    // ignore
                }

                IsDiscoveryEnabled = false;
                RaiseStateChanged();
            }
        }
    }

    private void OnDeviceAuthed(string deviceId, string? deviceName)
    {
        if (string.IsNullOrWhiteSpace(deviceId))
        {
            return;
        }

        lock (_stateGate)
        {
            if (!_authedDevicesById.TryGetValue(deviceId, out var entry))
            {
                entry = (Name: deviceName, Count: 0);
            }

            if (!string.IsNullOrWhiteSpace(deviceName))
            {
                entry.Name = deviceName;
            }

            entry.Count++;
            _authedDevicesById[deviceId] = entry;
        }

        RaiseStateChanged();
    }

    private void OnDeviceDisconnected(string deviceId)
    {
        if (string.IsNullOrWhiteSpace(deviceId))
        {
            return;
        }

        lock (_stateGate)
        {
            if (!_authedDevicesById.TryGetValue(deviceId, out var entry))
            {
                return;
            }

            entry.Count--;
            if (entry.Count <= 0)
            {
                _authedDevicesById.Remove(deviceId);
            }
            else
            {
                _authedDevicesById[deviceId] = entry;
            }
        }

        RaiseStateChanged();
    }

    private void RaiseStateChanged()
    {
        try
        {
            StateChanged?.Invoke(this, EventArgs.Empty);
        }
        catch
        {
            // ignore UI listener exceptions
        }
    }

    public void Dispose()
    {
        StopServer();
        _discovery.Dispose();
        Pairing.Dispose();
        _serverCts?.Dispose();
    }
}
