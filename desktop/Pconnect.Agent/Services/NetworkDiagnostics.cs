using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace Pconnect.Agent.Services;

internal static class NetworkDiagnostics
{
    /// <param name="webSocketServerRunning">When true, TCP listen on wsPort is expected (avoids false positive).</param>
    /// <param name="discoveryUdpRunning">When true, UDP bind on discoveryPort is expected.</param>
    public static NetworkDiagnosticsReport Collect(int wsPort, int discoveryPort, bool webSocketServerRunning, bool discoveryUdpRunning)
    {
        var vpnTunnelUp = false;
        var ipv4Candidates = new List<string>();
        foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (ni.OperationalStatus != OperationalStatus.Up) continue;
            if (ni.NetworkInterfaceType == NetworkInterfaceType.Tunnel)
            {
                vpnTunnelUp = true;
            }

            if (ni.NetworkInterfaceType is NetworkInterfaceType.Loopback) continue;

            foreach (var ua in ni.GetIPProperties().UnicastAddresses)
            {
                if (ua.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                if (IPAddress.IsLoopback(ua.Address)) continue;
                var s = ua.Address.ToString();
                if (s.StartsWith("169.254.", StringComparison.Ordinal)) continue;
                if (!ipv4Candidates.Contains(s, StringComparer.Ordinal))
                {
                    ipv4Candidates.Add(s);
                }
            }
        }

        var wsPortConflict = !webSocketServerRunning && IsTcpPortInUse(wsPort);
        var discoveryPortConflict = !discoveryUdpRunning && IsUdpPortInUse(discoveryPort);
        var ipv6OnlyRisk = !ipv4Candidates.Any();

        var hints = new List<string>();
        if (vpnTunnelUp)
        {
            hints.Add("A VPN or tunnel interface is active; phones may not reach the PC's LAN IP. Pause VPN for LAN pairing.");
        }

        if (ipv4Candidates.Count > 1)
        {
            hints.Add("Multiple LAN IPv4 addresses detected; pick the subnet that matches your phone's Wi‑Fi.");
        }

        if (ipv6OnlyRisk)
        {
            hints.Add("No routable IPv4 found; ensure Wi‑Fi has an IPv4 address or disable IPv6-only isolation on the router.");
        }

        if (discoveryPortConflict)
        {
            hints.Add($"UDP {discoveryPort} is in use; discovery broadcast may be disabled. Close duplicate agents or change the port.");
        }

        if (wsPortConflict)
        {
            hints.Add($"TCP {wsPort} is in use; the agent cannot bind until the port is free.");
        }

        return new NetworkDiagnosticsReport(
            ipv4Candidates,
            vpnTunnelUp,
            ipv6OnlyRisk,
            wsPortConflict,
            discoveryPortConflict,
            hints);
    }

    private static bool IsTcpPortInUse(int port)
    {
        try
        {
            var props = IPGlobalProperties.GetIPGlobalProperties();
            return props.GetActiveTcpListeners().Any(e => e.Port == port);
        }
        catch
        {
            return false;
        }
    }

    private static bool IsUdpPortInUse(int port)
    {
        try
        {
            using var c = new UdpClient(new IPEndPoint(IPAddress.Any, port));
        }
        catch (SocketException ex) when (ex.SocketErrorCode == SocketError.AddressAlreadyInUse)
        {
            return true;
        }
        catch
        {
            return false;
        }

        return false;
    }
}

internal sealed record NetworkDiagnosticsReport(
    IReadOnlyList<string> LanIpv4Candidates,
    bool VpnOrTunnelLikely,
    bool Ipv6OnlyRisk,
    bool WebSocketPortConflict,
    bool DiscoveryPortConflict,
    IReadOnlyList<string> ActionHints);
