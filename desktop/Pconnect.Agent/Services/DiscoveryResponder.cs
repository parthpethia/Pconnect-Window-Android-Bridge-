using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace Pconnect.Agent.Services;

internal sealed class DiscoveryResponder : IDisposable
{
    private const string DiscoverProbe = "PCONNECT_DISCOVER_V1";

    private readonly int _listenPort;
    private readonly int _wsPort;
    private readonly int _wssPort;
    private UdpClient? _udp;
    private CancellationTokenSource? _cts;
    private Task? _task;

    public DiscoveryResponder(int listenPort, int wsPort, int wssPort)
    {
        _listenPort = listenPort;
        _wsPort = wsPort;
        _wssPort = wssPort;
    }

    public void Start()
    {
        if (_task is not null)
        {
            return;
        }

        _cts = new CancellationTokenSource();
        try
        {
            _udp = new UdpClient(_listenPort);
            _udp.EnableBroadcast = true;
            _task = Task.Run(() => RunAsync(_cts.Token));
        }
        catch
        {
            try
            {
                _cts.Cancel();
            }
            catch
            {
                // ignore
            }

            _udp?.Dispose();
            _udp = null;
            _cts.Dispose();
            _cts = null;
            throw;
        }
    }

    public void Stop()
    {
        if (_task is null)
        {
            return;
        }

        try
        {
            _cts?.Cancel();
        }
        catch
        {
            // ignore
        }

        try
        {
            _udp?.Dispose();
        }
        catch
        {
            // ignore
        }

        try
        {
            _cts?.Dispose();
        }
        catch
        {
            // ignore
        }

        _udp = null;
        _cts = null;
        _task = null;
    }

    private async Task RunAsync(CancellationToken ct)
    {
        if (_udp is null)
        {
            return;
        }

        while (!ct.IsCancellationRequested)
        {
            UdpReceiveResult result;
            try
            {
                result = await _udp.ReceiveAsync(ct);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch
            {
                continue;
            }

            var msg = Encoding.UTF8.GetString(result.Buffer);
            if (!string.Equals(msg.Trim(), DiscoverProbe, StringComparison.Ordinal))
            {
                continue;
            }

            var payload = JsonSerializer.Serialize(new
            {
                v = 1,
                type = "discoverResponse",
                pcName = Environment.MachineName,
                wsPort = _wsPort,
                wssPort = _wssPort,
            });

            var bytes = Encoding.UTF8.GetBytes(payload);
            try
            {
                await _udp.SendAsync(bytes, bytes.Length, result.RemoteEndPoint);
            }
            catch
            {
                // ignore
            }
        }
    }

    public void Dispose()
    {
        Stop();
    }
}
