using System.Net;
using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Pconnect.Agent.Services;

internal sealed class WebSocketHandler
{
    private readonly string _shutdownPassword;
    private readonly PairingService _pairing;
    private readonly PairedDevicesStore _paired;
    private readonly PcActions _pc;
    private readonly IUiActions _ui;
    private readonly FileTransferManager _fileTransfer = new();
    private readonly CustomCommandService _customCommands = new();
    private readonly AuditLogService _auditLog = new();
    private NotificationListenerService? _notificationListener;
    private readonly Action<string, string?>? _onDeviceAuthed;
    private readonly Action<string>? _onDeviceDisconnected;
    private SafeStartupOptions _safe = SafeStartupOptions.Normal;
    private readonly Func<(bool WsServing, bool DiscoveryUdp)>? _networkBindingState;

    // Capabilities list sent during handshake
    private static readonly string[] Capabilities =
    {
        "lock", "text", "launch", "show", "mouse", "keyboard", "volume",
        "brightness", "shutdown", "clipboard", "fileTransfer", "recentFiles",
        "keyCombo", "mediaKey", "screenCapture", "appList", "customCommands",
        "auditLog", "notification"
    };

    internal void ConfigureSafeMode(SafeStartupOptions safe) => _safe = safe;

    private IReadOnlyList<string> AdvertisedCapabilities =>
        !_safe.IsSafeMode
            ? Capabilities
            : Capabilities.Where(static c => c is not ("screenCapture" or "customCommands")).ToArray();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool LockWorkStation();

    public WebSocketHandler(
        PairingService pairing,
        PairedDevicesStore paired,
        PcActions pc,
        IUiActions ui,
        Action<string, string?>? onDeviceAuthed = null,
        Action<string>? onDeviceDisconnected = null,
        Func<(bool WsServing, bool DiscoveryUdp)>? networkBindingState = null)
    {
        _pairing = pairing;
        _paired = paired;
        _pc = pc;
        _ui = ui;
        _onDeviceAuthed = onDeviceAuthed;
        _onDeviceDisconnected = onDeviceDisconnected;
        _networkBindingState = networkBindingState;
        _shutdownPassword = Environment.GetEnvironmentVariable("PCONNECT_SHUTDOWN_PIN") ?? "1326";
    }

    public async Task HandleConnectionAsync(WebSocket ws, IPAddress? remoteIp, CancellationToken ct)
    {
        string? deviceId = null;
        string? deviceName = null;
        string deviceRole = "admin";
        var authed = false;
        ScreenCaptureService? screenCapture = null;
        System.Threading.Timer? autoLockTimer = null;
        var sessionNonceBytes = RandomNumberGenerator.GetBytes(16);
        byte[]? integrityKey = null;
        var lastCmdSeq = 0;

        bool PassesClientPolicy(Dictionary<string, JsonElement> m, out string? err)
        {
            err = null;
            var ver = m.GetStringOrNull("clientVersion") ?? "0.0.0";
            if (!SemverUtility.IsAtLeast(ver, OperationalConfigRuntime.MinMobileSemver))
            {
                err = $"Mobile app update required (minimum {OperationalConfigRuntime.MinMobileSemver}).";
                return false;
            }

            var proto = m.GetIntOrDefault("proto", 1);
            if (proto < OperationalConfigRuntime.MinClientProto)
            {
                err = $"Mobile app update required (protocol version {OperationalConfigRuntime.MinClientProto} or newer).";
                return false;
            }

            return true;
        }

        // Helper to start notification mirroring after auth
        async Task StartNotificationListenerAsync()
        {
            if (_safe.DisableNotificationMirror)
            {
                return;
            }

            try
            {
                var listener = new NotificationListenerService(
                    async json =>
                    {
                        if (ws.State == WebSocketState.Open)
                        {
                            var bytes = Encoding.UTF8.GetBytes(json);
                            await ws.SendAsync(bytes, WebSocketMessageType.Text, true, ct);
                        }
                    },
                    _auditLog);

                if (await listener.RequestAccessAsync())
                {
                    listener.Start();
                    _notificationListener = listener;
                }
                else
                {
                    Console.WriteLine("[WebSocketHandler] Notification listener access denied by user.");
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[WebSocketHandler] Failed to start notification listener: {ex.Message}");
            }
        }

        await SendAsync(ws, new
        {
            v = 1,
            type = "welcome",
            pcName = Environment.MachineName,
            sessionNonce = Convert.ToHexString(sessionNonceBytes),
            wssPort = AgentRuntime.DefaultWssPort,
        }, ct);

        try
        {
            while (ws.State == WebSocketState.Open && !ct.IsCancellationRequested)
            {
                var msg = await ReceiveJsonAsync(ws, ct);
                if (msg is null) break;

                if (!msg.TryGetValue("type", out var typeEl) || typeEl.ValueKind != JsonValueKind.String)
                {
                    await SendAsync(ws, new { v = 1, type = "error", message = "Missing type" }, ct);
                    continue;
                }

                var type = typeEl.GetString();
                if (string.IsNullOrEmpty(type)) continue;

                var typeRaw = type;
                type = type.Trim();
                var typeKey = type.ToLowerInvariant();

                if (!authed)
                {
                    if (typeKey == "hello")
                    {
                        if (!PassesClientPolicy(msg, out var policyErr))
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = policyErr }, ct);
                            continue;
                        }

                        deviceId = msg.GetStringOrNull("deviceId");
                        var token = msg.GetStringOrNull("token");
                        deviceName = msg.GetStringOrNull("deviceName");

                        if (string.IsNullOrWhiteSpace(deviceName) && deviceId is not null)
                            deviceName = _paired.GetDeviceName(deviceId);

                        if (deviceId is not null && token is not null && _paired.IsPaired(deviceId, token))
                        {
                            authed = true;
                            deviceRole = _paired.GetRole(deviceId);
                            var proto = msg.GetIntOrDefault("proto", 1);
                            if (proto >= 2)
                            {
                                integrityKey = CommandIntegrity.TryDeriveIntegrityKey(token, sessionNonceBytes);
                            }

                            _onDeviceAuthed?.Invoke(deviceId, deviceName);
                            _auditLog.Log(deviceName, "connected");
                            await SendAsync(ws, new
                            {
                                v = 1, type = "helloAck",
                                pcName = Environment.MachineName,
                                role = deviceRole,
                                capabilities = AdvertisedCapabilities
                            }, ct);
                            await StartNotificationListenerAsync();
                        }
                        else
                        {
                            await SendAsync(ws, new { v = 1, type = "authRequired", pairing = new { method = "code" } }, ct);
                        }
                        continue;
                    }

                    if (typeKey == "pair")
                    {
                        if (!PassesClientPolicy(msg, out var policyErrPair))
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = policyErrPair }, ct);
                            continue;
                        }

                        deviceId = msg.GetStringOrNull("deviceId") ?? deviceId;
                        var code = msg.GetStringOrNull("code");
                        deviceName = msg.GetStringOrNull("deviceName");

                        if (deviceId is null)
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = "Missing deviceId" }, ct);
                            continue;
                        }

                        if (!_pairing.ValidateCode(code))
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = "Invalid pairing code" }, ct);
                            continue;
                        }

                        var token = _paired.PairNewDevice(deviceId, deviceName);
                        authed = true;
                        deviceRole = _paired.GetRole(deviceId);
                        var proto = msg.GetIntOrDefault("proto", 1);
                        if (proto >= 2)
                        {
                            integrityKey = CommandIntegrity.TryDeriveIntegrityKey(token, sessionNonceBytes);
                        }

                        _onDeviceAuthed?.Invoke(deviceId, deviceName);
                        _auditLog.Log(deviceName, "paired");

                        await SendAsync(ws, new { v = 1, type = "paired", deviceId, token, role = deviceRole }, ct);
                        await SendAsync(ws, new
                        {
                            v = 1, type = "helloAck",
                            pcName = Environment.MachineName,
                            role = deviceRole,
                            capabilities = AdvertisedCapabilities
                        }, ct);
                        await StartNotificationListenerAsync();
                        continue;
                    }

                    await SendAsync(ws, new { v = 1, type = "authRequired", pairing = new { method = "code" } }, ct);
                    continue;
                }

                // ── Role checking helpers ──
                bool RequireAdmin()
                {
                    return deviceRole == "admin";
                }
                bool RequireMediaOrAdmin()
                {
                    return deviceRole is "admin" or "media_only";
                }

                if (OperationalConfigRuntime.EmergencyDisableRemote)
                {
                    await SendAsync(ws, new { v = 1, type = "error", message = "Agent paused by operator policy" }, ct);
                    continue;
                }

                bool TryConsumeMac(string canon, out string? err)
                {
                    err = null;
                    var seq = msg.GetIntOrDefault("cmdSeq", 0);
                    var mac = msg.GetStringOrNull("cmdMac");
                    var require = OperationalConfigRuntime.RequireSensitiveMac || integrityKey is not null;
                    if (!require)
                    {
                        return true;
                    }

                    if (integrityKey is null)
                    {
                        err = "Upgrade mobile app for verified commands";
                        return false;
                    }

                    if (seq <= lastCmdSeq)
                    {
                        err = "Stale cmdSeq";
                        return false;
                    }

                    if (!CommandIntegrity.TryVerifyMac(integrityKey, seq, canon, mac))
                    {
                        err = "Invalid cmdMac";
                        return false;
                    }

                    lastCmdSeq = seq;
                    return true;
                }

                // ── Authenticated command dispatch ──
                switch (typeKey)
                {
                    case "lock":
                        if (!RequireAdmin()) { await SendRoleError(ws, ct); break; }
                        _auditLog.Log(deviceName, "lock");
                        await SendAsync(ws, _pc.Lock()
                            ? new { v = 1, type = "ok" }
                            : (object)new { v = 1, type = "error", message = "Lock failed" }, ct);
                        break;

                    case "input":
                        if (!RequireAdmin()) { await SendRoleError(ws, ct); break; }
                        var backspaces = msg.GetIntOrDefault("backspaces", 0);
                        var text = msg.GetStringOrNull("text") ?? string.Empty;
                        _pc.TypeText(backspaces, text);
                        _auditLog.Log(deviceName, "input");
                        await SendAsync(ws, new { v = 1, type = "ok" }, ct);
                        break;

                    case "launch":
                        if (!RequireAdmin()) { await SendRoleError(ws, ct); break; }
                        var command = msg.GetStringOrNull("command");
                        var args = msg.GetStringArrayOrNull("args");
                        if (string.IsNullOrWhiteSpace(command))
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = "Missing command" }, ct);
                            break;
                        }

                        var argCanon = args is null ? "" : string.Join('\x1e', args);
                        if (!TryConsumeMac($"launch|{command}|{argCanon}", out var macErrL))
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = macErrL ?? "Command verification failed" }, ct);
                            break;
                        }

                        _pc.Launch(command!, args);
                        _auditLog.Log(deviceName, $"launch:{command}");
                        await SendAsync(ws, new { v = 1, type = "ok" }, ct);
                        break;

                    case "launchapp":
                        if (!RequireAdmin()) { await SendRoleError(ws, ct); break; }
                        var exePath = msg.GetStringOrNull("exePath");
                        if (string.IsNullOrWhiteSpace(exePath))
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = "Missing exePath" }, ct);
                            break;
                        }

                        if (!TryConsumeMac($"launchapp|{exePath}", out var macErrLa))
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = macErrLa ?? "Command verification failed" }, ct);
                            break;
                        }

                        _pc.Launch(exePath!, null);
                        _auditLog.Log(deviceName, $"launchApp:{exePath}");
                        await SendAsync(ws, new { v = 1, type = "ok" }, ct);
                        break;

                    case "show":
                        _ui.ShowAgentUi();
                        await SendAsync(ws, new { v = 1, type = "ok" }, ct);
                        break;

                    case "mousemove":
                        if (!RequireAdmin()) break; // silent for perf
                        _pc.MouseMove(msg.GetIntOrDefault("dx", 0), msg.GetIntOrDefault("dy", 0));
                        break;

                    case "mousescroll":
                        if (!RequireAdmin()) break;
                        _pc.MouseScroll(msg.GetIntOrDefault("dy", 0));
                        break;

                    case "mousebutton":
                        if (!RequireAdmin()) { await SendRoleError(ws, ct); break; }
                        var btn = msg.GetStringOrNull("button") ?? "";
                        var act = msg.GetStringOrNull("action") ?? "";
                        if (string.IsNullOrWhiteSpace(btn) || string.IsNullOrWhiteSpace(act))
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = "Missing button/action" }, ct);
                            break;
                        }
                        _pc.MouseButton(btn, act);
                        await SendAsync(ws, new { v = 1, type = "ok" }, ct);
                        break;

                    case "key":
                        if (!RequireAdmin()) { await SendRoleError(ws, ct); break; }
                        var vk = msg.GetIntOrDefault("vk", 0);
                        var keyAction = msg.GetStringOrNull("action") ?? "";
                        var extended = msg.GetBoolOrDefault("extended", false);
                        if (vk <= 0 || vk > 0xFF)
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = "Invalid vk" }, ct);
                            break;
                        }
                        if (string.IsNullOrWhiteSpace(keyAction))
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = "Missing action" }, ct);
                            break;
                        }
                        _pc.Key((ushort)vk, keyAction, extended);
                        await SendAsync(ws, new { v = 1, type = "ok" }, ct);
                        break;

                    case "keycombo":
                        if (!RequireAdmin()) { await SendRoleError(ws, ct); break; }
                        var keys = msg.GetStringArrayOrNull("keys");
                        if (keys == null || keys.Count == 0)
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = "Missing keys" }, ct);
                            break;
                        }
                        var comboOk = KeyComboService.Execute(keys);
                        _auditLog.Log(deviceName, $"keyCombo:{string.Join("+", keys)}");
                        await SendAsync(ws, comboOk
                            ? new { v = 1, type = "ok" }
                            : (object)new { v = 1, type = "error", message = "Key combo failed" }, ct);
                        break;

                    case "mediakey":
                        if (!RequireMediaOrAdmin()) { await SendRoleError(ws, ct); break; }
                        var mediaKey = msg.GetStringOrNull("key") ?? "";
                        var mediaOk = MediaKeyService.Send(mediaKey);
                        _auditLog.Log(deviceName, $"mediaKey:{mediaKey}");
                        await SendAsync(ws, mediaOk
                            ? new { v = 1, type = "ok" }
                            : (object)new { v = 1, type = "error", message = "Unknown media key" }, ct);
                        break;

                    case "setvolume":
                        if (!RequireMediaOrAdmin()) { await SendRoleError(ws, ct); break; }
                        var volLevel = msg.GetIntOrDefault("level", -1);
                        if (volLevel < 0 || volLevel > 100)
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = "Invalid level" }, ct);
                            break;
                        }
                        await SendAsync(ws, _pc.SetVolume(volLevel)
                            ? new { v = 1, type = "ok" }
                            : (object)new { v = 1, type = "error", message = "Volume set failed" }, ct);
                        break;

                    case "setbrightness":
                        if (!RequireAdmin()) { await SendRoleError(ws, ct); break; }
                        var brLevel = msg.GetIntOrDefault("level", -1);
                        if (brLevel < 0 || brLevel > 100)
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = "Invalid level" }, ct);
                            break;
                        }
                        await SendAsync(ws, _pc.SetBrightness(brLevel)
                            ? new { v = 1, type = "ok" }
                            : (object)new { v = 1, type = "error", message = "Brightness set failed" }, ct);
                        break;

                    case "shutdown":
                        if (!RequireAdmin()) { await SendRoleError(ws, ct); break; }
                        var password = msg.GetStringOrNull("password") ?? msg.GetStringOrNull("pin");
                        if (string.IsNullOrWhiteSpace(password))
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = "Shutdown password required" }, ct);
                            break;
                        }
                        if (!string.Equals(password.Trim(), _shutdownPassword, StringComparison.Ordinal))
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = "Invalid shutdown password" }, ct);
                            break;
                        }

                        if (!TryConsumeMac($"shutdown|{password.Trim()}", out var macErrS))
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = macErrS ?? "Command verification failed" }, ct);
                            break;
                        }

                        _auditLog.Log(deviceName, "shutdown");
                        await SendAsync(ws, _pc.Shutdown()
                            ? new { v = 1, type = "ok" }
                            : (object)new { v = 1, type = "error", message = "Shutdown failed" }, ct);
                        break;

                    case "clipboardset":
                        if (!RequireAdmin()) { await SendRoleError(ws, ct); break; }
                        var clipData = msg.GetStringOrNull("data");
                        if (string.IsNullOrWhiteSpace(clipData))
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = "Missing clipboard data" }, ct);
                            break;
                        }
                        try
                        {
                            var bytes = Convert.FromBase64String(clipData);
                            var clipText = Encoding.UTF8.GetString(bytes);
                            _pc.SetClipboard(clipText);
                            _auditLog.Log(deviceName, "clipboardSet");
                            await SendAsync(ws, new { v = 1, type = "ok" }, ct);
                        }
                        catch (Exception ex)
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = $"Clipboard set failed: {ex.Message}" }, ct);
                        }
                        break;

                    case "filetransferstart":
                        if (!RequireAdmin()) { await SendRoleError(ws, ct); break; }
                        var ftId = msg.GetStringOrNull("id");
                        var ftFile = msg.GetStringOrNull("filename");
                        var ftSize = msg.GetLongOrDefault("size", 0L);
                        if (string.IsNullOrWhiteSpace(ftId) || string.IsNullOrWhiteSpace(ftFile) || ftSize <= 0)
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = "Invalid transfer parameters" }, ct);
                            break;
                        }
                        var ftResult = _fileTransfer.StartTransfer(ftId, ftFile, ftSize);
                        _auditLog.Log(deviceName, $"fileTransferStart:{ftFile}");
                        await SendAsync(ws, ftResult != null
                            ? (object)new { v = 1, type = "fileTransferAck", id = ftId, ready = true }
                            : new { v = 1, type = "error", message = "Failed to start transfer" }, ct);
                        break;

                    case "filetransferchunk":
                        if (!RequireAdmin()) break;
                        var chId = msg.GetStringOrNull("id");
                        var chIdx = msg.GetIntOrDefault("chunkIndex", -1);
                        var chData = msg.GetStringOrNull("data");
                        if (string.IsNullOrWhiteSpace(chId) || chIdx < 0 || string.IsNullOrWhiteSpace(chData))
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = "Invalid chunk parameters" }, ct);
                            break;
                        }
                        try
                        {
                            var chBytes = Convert.FromBase64String(chData);
                            if (_fileTransfer.WriteChunk(chId, chIdx, chBytes))
                            {
                                var prog = _fileTransfer.GetProgress(chId);
                                await SendAsync(ws, new
                                {
                                    v = 1, type = "fileTransferProgress", id = chId,
                                    chunkIndex = chIdx, received = prog?.received ?? 0, total = prog?.total ?? 0
                                }, ct);
                            }
                            else
                            {
                                await SendAsync(ws, new { v = 1, type = "error", message = "Failed to write chunk" }, ct);
                            }
                        }
                        catch (Exception ex)
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = $"Chunk write error: {ex.Message}" }, ct);
                        }
                        break;

                    case "filetransfercomplete":
                        if (!RequireAdmin()) break;
                        var fcId = msg.GetStringOrNull("id");
                        if (string.IsNullOrWhiteSpace(fcId))
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = "Missing transfer id" }, ct);
                            break;
                        }
                        await SendAsync(ws, _fileTransfer.CompleteTransfer(fcId)
                            ? (object)new { v = 1, type = "fileTransferComplete", id = fcId, status = "success" }
                            : new { v = 1, type = "error", message = "Failed to complete transfer" }, ct);
                        break;

                    case "filetransferabort":
                        var faId = msg.GetStringOrNull("id");
                        if (!string.IsNullOrWhiteSpace(faId)) _fileTransfer.AbortTransfer(faId);
                        await SendAsync(ws, new { v = 1, type = "ok" }, ct);
                        break;

                    case "listrecentfiles":
                        var limit = msg.GetIntOrDefault("limit", 20);
                        var recentFiles = RecentFilesHelper.GetRecentFiles(limit);
                        await SendAsync(ws, new
                        {
                            v = 1, type = "recentFilesList",
                            files = recentFiles.Select(f => new { path = f.Path, name = f.Name, modified = f.Modified, size = f.Size }).ToList(),
                            status = "ok"
                        }, ct);
                        break;

                    // ── New: Screen capture ──
                    case "screencapturestart":
                        if (!RequireAdmin()) { await SendRoleError(ws, ct); break; }
                        if (_safe.DisableScreenCapture)
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = "Screen capture disabled (safe mode)" }, ct);
                            break;
                        }
                        screenCapture?.Dispose();
                        var interval = msg.GetIntOrDefault("intervalMs", 1000);
                        var captureWidth = msg.GetIntOrDefault("width", 720);
                        var captureQuality = msg.GetIntOrDefault("quality", 65);
                        screenCapture = new ScreenCaptureService(async (b64, w, h) =>
                        {
                            try
                            {
                                if (ws.State == WebSocketState.Open)
                                    await SendAsync(ws, new { v = 1, type = "screenFrame", data = b64, width = w, height = h }, ct);
                            }
                            catch { /* connection may have closed */ }
                        });
                        screenCapture.Start(interval, captureWidth, captureQuality);
                        _auditLog.Log(deviceName, "screenCaptureStart");
                        await SendAsync(ws, new { v = 1, type = "ok" }, ct);
                        break;

                    case "screencapturestop":
                        screenCapture?.Dispose();
                        screenCapture = null;
                        await SendAsync(ws, new { v = 1, type = "ok" }, ct);
                        break;

                    // ── New: App list ──
                    case "getapplist":
                        var apps = AppListService.GetInstalledApps();
                        await SendAsync(ws, new
                        {
                            v = 1, type = "appList",
                            apps = apps.Select(a => new { name = a.Name, iconBase64 = a.IconBase64, exePath = a.ExePath }).ToList()
                        }, ct);
                        break;

                    // ── New: Custom commands ──
                    case "getcommands":
                        if (_safe.DisableCustomCommands)
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = "Custom commands disabled (safe mode)" }, ct);
                            break;
                        }
                        _customCommands.Reload();
                        var cmds = _customCommands.GetCommands();
                        await SendAsync(ws, new
                        {
                            v = 1, type = "commandList",
                            commands = cmds.Select(c => new { label = c.Label, command = c.Command }).ToList()
                        }, ct);
                        break;

                    case "runcommand":
                        if (!RequireAdmin()) { await SendRoleError(ws, ct); break; }
                        if (_safe.DisableCustomCommands)
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = "Custom commands disabled (safe mode)" }, ct);
                            break;
                        }
                        var cmdIdx = msg.GetIntOrDefault("index", -1);
                        if (cmdIdx < 0)
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = "Invalid index" }, ct);
                            break;
                        }

                        if (!TryConsumeMac($"runcommand|{cmdIdx}", out var macErrR))
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = macErrR ?? "Command verification failed" }, ct);
                            break;
                        }

                        var cmdOk = _customCommands.RunCommand(cmdIdx);
                        _auditLog.Log(deviceName, $"runCommand:{cmdIdx}");
                        await SendAsync(ws, cmdOk
                            ? new { v = 1, type = "ok" }
                            : (object)new { v = 1, type = "error", message = "Command failed" }, ct);
                        break;

                    case "networkdiagnostics":
                        if (!RequireAdmin()) { await SendRoleError(ws, ct); break; }
                        var flags = _networkBindingState?.Invoke() ?? (false, false);
                        var nd = NetworkDiagnostics.Collect(AgentRuntime.DefaultWsPort, AgentRuntime.DefaultDiscoveryPort, flags.WsServing, flags.DiscoveryUdp);
                        await SendAsync(ws, new
                        {
                            v = 1,
                            type = "networkDiagnostics",
                            lanIpv4 = nd.LanIpv4Candidates,
                            vpnOrTunnelLikely = nd.VpnOrTunnelLikely,
                            ipv6OnlyRisk = nd.Ipv6OnlyRisk,
                            webSocketPortInUse = nd.WebSocketPortConflict,
                            discoveryPortInUse = nd.DiscoveryPortConflict,
                            hints = nd.ActionHints,
                        }, ct);
                        break;

                    // ── New: Settings sync ──
                    case "settingssync":
                    {
                        var autoLock = msg.GetBoolOrDefault("autoLockOnDisconnect", false);
                        if (!TryConsumeMac($"settingsSync|{deviceId ?? ""}|{autoLock}", out var macErrSt))
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = macErrSt ?? "Command verification failed" }, ct);
                            break;
                        }

                        if (deviceId is not null)
                        {
                            _paired.SetAutoLockOnDisconnect(deviceId, autoLock);
                        }

                        await SendAsync(ws, new { v = 1, type = "ok" }, ct);
                        break;
                    }

                    // ── New: Audit logs ──
                    case "getlogs":
                        var logDate = msg.GetStringOrNull("date") ?? DateTimeOffset.Now.ToString("yyyy-MM-dd");
                        var logEntries = _auditLog.GetLogs(logDate);
                        await SendAsync(ws, new
                        {
                            v = 1, type = "logEntries",
                            entries = logEntries.Select(e => new { time = e.Time, device = e.Device, action = e.Action }).ToList()
                        }, ct);
                        break;

                    default:
                        // Gracefully ignore unknown types for forward-compatibility
                        break;
                }
            }
        }
        finally
        {
            screenCapture?.Dispose();
            _notificationListener?.Stop();
            _notificationListener = null;

            try
            {
                if (ws.State == WebSocketState.Open)
                    await ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "bye", CancellationToken.None);
            }
            catch { /* ignore */ }

            if (authed && deviceId is not null)
            {
                _auditLog.Log(deviceName, "disconnected");
                _onDeviceDisconnected?.Invoke(deviceId);

                // Auto-lock on disconnect
                if (_paired.GetAutoLockOnDisconnect(deviceId))
                {
                    autoLockTimer = new System.Threading.Timer(_ =>
                    {
                        try { LockWorkStation(); } catch { /* ignore */ }
                    }, null, TimeSpan.FromSeconds(10), Timeout.InfiniteTimeSpan);

                    // Timer will self-dispose after firing once
                    _ = Task.Delay(TimeSpan.FromSeconds(12)).ContinueWith(_ => autoLockTimer?.Dispose());
                }
            }
        }
    }

    private static async Task SendRoleError(WebSocket ws, CancellationToken ct)
    {
        await SendAsync(ws, new { v = 1, type = "error", message = "Insufficient permissions for this action" }, ct);
    }

    private static async Task<Dictionary<string, JsonElement>?> ReceiveJsonAsync(WebSocket ws, CancellationToken ct)
    {
        var buffer = new byte[256 * 1024];
        using var ms = new MemoryStream();

        while (true)
        {
            WebSocketReceiveResult result;
            try { result = await ws.ReceiveAsync(buffer, ct); }
            catch { return null; }

            if (result.MessageType == WebSocketMessageType.Close) return null;
            ms.Write(buffer, 0, result.Count);
            if (result.EndOfMessage) break;
        }

        var json = Encoding.UTF8.GetString(ms.ToArray());
        try { return JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(json); }
        catch
        {
            return new Dictionary<string, JsonElement>(StringComparer.Ordinal)
            {
                ["type"] = JsonDocument.Parse("\"invalid\"").RootElement
            };
        }
    }

    private static Task SendAsync(WebSocket ws, object obj, CancellationToken ct)
    {
        var json = JsonSerializer.Serialize(obj);
        var bytes = Encoding.UTF8.GetBytes(json);
        return ws.SendAsync(bytes, WebSocketMessageType.Text, true, ct);
    }
}

internal static class JsonDictExtensions
{
    public static string? GetStringOrNull(this Dictionary<string, JsonElement> dict, string key)
    {
        return dict.TryGetValue(key, out var el) && el.ValueKind == JsonValueKind.String ? el.GetString() : null;
    }

    public static int GetIntOrDefault(this Dictionary<string, JsonElement> dict, string key, int fallback)
    {
        if (!dict.TryGetValue(key, out var el)) return fallback;
        return el.ValueKind switch
        {
            JsonValueKind.Number when el.TryGetInt32(out var v) => v,
            _ => fallback,
        };
    }

    public static long GetLongOrDefault(this Dictionary<string, JsonElement> dict, string key, long fallback)
    {
        if (!dict.TryGetValue(key, out var el)) return fallback;
        return el.ValueKind switch
        {
            JsonValueKind.Number when el.TryGetInt64(out var v) => v,
            _ => fallback,
        };
    }

    public static bool GetBoolOrDefault(this Dictionary<string, JsonElement> dict, string key, bool fallback)
    {
        if (!dict.TryGetValue(key, out var el)) return fallback;
        return el.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            _ => fallback,
        };
    }

    public static List<string>? GetStringArrayOrNull(this Dictionary<string, JsonElement> dict, string key)
    {
        if (!dict.TryGetValue(key, out var el) || el.ValueKind != JsonValueKind.Array) return null;
        var list = new List<string>();
        foreach (var item in el.EnumerateArray())
        {
            if (item.ValueKind == JsonValueKind.String) list.Add(item.GetString()!);
        }
        return list;
    }
}
