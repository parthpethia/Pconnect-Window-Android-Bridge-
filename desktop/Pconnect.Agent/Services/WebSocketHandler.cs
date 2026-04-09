using System.Net;
using System.Net.WebSockets;
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
    private readonly Action<string, string?>? _onDeviceAuthed;
    private readonly Action<string>? _onDeviceDisconnected;

    public WebSocketHandler(
        PairingService pairing,
        PairedDevicesStore paired,
        PcActions pc,
        IUiActions ui,
        Action<string, string?>? onDeviceAuthed = null,
        Action<string>? onDeviceDisconnected = null)
    {
        _pairing = pairing;
        _paired = paired;
        _pc = pc;
        _ui = ui;
        _onDeviceAuthed = onDeviceAuthed;
        _onDeviceDisconnected = onDeviceDisconnected;
        _shutdownPassword = Environment.GetEnvironmentVariable("PCONNECT_SHUTDOWN_PIN") ?? "1326";
    }

    public async Task HandleConnectionAsync(WebSocket ws, IPAddress? remoteIp, CancellationToken ct)
    {
        string? deviceId = null;
        var authed = false;

        await SendAsync(ws, new { v = 1, type = "welcome", pcName = Environment.MachineName }, ct);

        while (ws.State == WebSocketState.Open && !ct.IsCancellationRequested)
        {
            var msg = await ReceiveJsonAsync(ws, ct);
            if (msg is null)
            {
                break;
            }

            if (!msg.TryGetValue("type", out var typeEl) || typeEl.ValueKind != JsonValueKind.String)
            {
                await SendAsync(ws, new { v = 1, type = "error", message = "Missing type" }, ct);
                continue;
            }

            var type = typeEl.GetString();
            if (string.IsNullOrEmpty(type))
            {
                continue;
            }

            // Be lenient: clients may vary casing or accidentally include whitespace.
            // The protocol still documents canonical casing, but accepting variants
            // prevents confusing "Unknown type" errors.
            var typeRaw = type;
            type = type.Trim();
            var typeKey = type.ToLowerInvariant();

            if (!authed)
            {
                if (typeKey == "hello")
                {
                    deviceId = msg.GetStringOrNull("deviceId");
                    var token = msg.GetStringOrNull("token");
                    var deviceName = msg.GetStringOrNull("deviceName");

                    if (string.IsNullOrWhiteSpace(deviceName) && deviceId is not null)
                    {
                        deviceName = _paired.GetDeviceName(deviceId);
                    }

                    if (deviceId is not null && token is not null && _paired.IsPaired(deviceId, token))
                    {
                        authed = true;
                        _onDeviceAuthed?.Invoke(deviceId, deviceName);
                        await SendAsync(ws, new
                        {
                            v = 1,
                            type = "helloAck",
                            pcName = Environment.MachineName,
                            capabilities = new[] { "lock", "text", "launch", "show", "mouse", "keyboard", "volume", "brightness", "shutdown", "clipboard", "fileTransfer", "recentFiles" }
                        }, ct);
                    }
                    else
                    {
                        await SendAsync(ws, new { v = 1, type = "authRequired", pairing = new { method = "code" } }, ct);
                    }

                    continue;
                }

                if (typeKey == "pair")
                {
                    deviceId = msg.GetStringOrNull("deviceId") ?? deviceId;
                    var code = msg.GetStringOrNull("code");
                    var deviceName = msg.GetStringOrNull("deviceName");

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

                    _onDeviceAuthed?.Invoke(deviceId, deviceName);

                    await SendAsync(ws, new { v = 1, type = "paired", deviceId, token }, ct);
                    await SendAsync(ws, new { v = 1, type = "helloAck", pcName = Environment.MachineName, capabilities = new[] { "lock", "text", "launch", "show", "mouse", "keyboard", "volume", "brightness", "shutdown", "clipboard", "fileTransfer", "recentFiles" } }, ct);
                    continue;
                }

                await SendAsync(ws, new { v = 1, type = "authRequired", pairing = new { method = "code" } }, ct);
                continue;
            }

            switch (typeKey)
            {
                case "lock":
                    if (_pc.Lock())
                    {
                        await SendAsync(ws, new { v = 1, type = "ok" }, ct);
                    }
                    else
                    {
                        await SendAsync(ws, new { v = 1, type = "error", message = "Lock failed" }, ct);
                    }
                    break;

                case "input":
                    {
                        var backspaces = msg.GetIntOrDefault("backspaces", 0);
                        var text = msg.GetStringOrNull("text") ?? string.Empty;
                        _pc.TypeText(backspaces, text);
                        await SendAsync(ws, new { v = 1, type = "ok" }, ct);
                        break;
                    }

                case "launch":
                    {
                        var command = msg.GetStringOrNull("command");
                        var args = msg.GetStringArrayOrNull("args");
                        if (string.IsNullOrWhiteSpace(command))
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = "Missing command" }, ct);
                            break;
                        }

                        _pc.Launch(command!, args);
                        await SendAsync(ws, new { v = 1, type = "ok" }, ct);
                        break;
                    }

                case "show":
                    _ui.ShowAgentUi();
                    await SendAsync(ws, new { v = 1, type = "ok" }, ct);
                    break;

                case "mousemove":
                    {
                        var dx = msg.GetIntOrDefault("dx", 0);
                        var dy = msg.GetIntOrDefault("dy", 0);
                        _pc.MouseMove(dx, dy);
                        break;
                    }

                case "mousescroll":
                    {
                        var dy = msg.GetIntOrDefault("dy", 0);
                        _pc.MouseScroll(dy);
                        break;
                    }

                case "mousebutton":
                    {
                        var button = msg.GetStringOrNull("button") ?? string.Empty;
                        var action = msg.GetStringOrNull("action") ?? string.Empty;
                        if (string.IsNullOrWhiteSpace(button) || string.IsNullOrWhiteSpace(action))
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = "Missing button/action" }, ct);
                            break;
                        }

                        _pc.MouseButton(button, action);
                        await SendAsync(ws, new { v = 1, type = "ok" }, ct);
                        break;
                    }

                case "key":
                    {
                        var vk = msg.GetIntOrDefault("vk", 0);
                        var action = msg.GetStringOrNull("action") ?? string.Empty;
                        var extended = msg.GetBoolOrDefault("extended", false);

                        if (vk <= 0 || vk > 0xFF)
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = "Invalid vk" }, ct);
                            break;
                        }

                        if (string.IsNullOrWhiteSpace(action))
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = "Missing action" }, ct);
                            break;
                        }

                        _pc.Key((ushort)vk, action, extended);
                        await SendAsync(ws, new { v = 1, type = "ok" }, ct);
                        break;
                    }

                case "setvolume":
                    {
                        var level = msg.GetIntOrDefault("level", -1);
                        if (level < 0 || level > 100)
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = "Invalid level" }, ct);
                            break;
                        }

                        if (_pc.SetVolume(level))
                        {
                            await SendAsync(ws, new { v = 1, type = "ok" }, ct);
                        }
                        else
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = "Volume set failed" }, ct);
                        }
                        break;
                    }

                case "setbrightness":
                    {
                        var level = msg.GetIntOrDefault("level", -1);
                        if (level < 0 || level > 100)
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = "Invalid level" }, ct);
                            break;
                        }

                        if (_pc.SetBrightness(level))
                        {
                            await SendAsync(ws, new { v = 1, type = "ok" }, ct);
                        }
                        else
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = "Brightness set failed" }, ct);
                        }
                        break;
                    }

                case "shutdown":
                    {
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

                        if (_pc.Shutdown())
                        {
                            await SendAsync(ws, new { v = 1, type = "ok" }, ct);
                        }
                        else
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = "Shutdown failed" }, ct);
                        }

                        break;
                    }

                case "clipboardset":
                    {
                        var data = msg.GetStringOrNull("data");
                        if (string.IsNullOrWhiteSpace(data))
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = "Missing clipboard data" }, ct);
                            break;
                        }

                        try
                        {
                            // Decode base64 data
                            var bytes = Convert.FromBase64String(data);
                            var text = System.Text.Encoding.UTF8.GetString(bytes);
                            _pc.SetClipboard(text);
                            await SendAsync(ws, new { v = 1, type = "ok" }, ct);
                        }
                        catch (Exception ex)
                        {
                            await SendAsync(ws, new { v = 1, type = "error", message = $"Clipboard set failed: {ex.Message}" }, ct);
                        }

                        break;
                    }

                default:
                    await SendAsync(ws, new { v = 1, type = "error", message = $"Unknown type: {typeRaw}" }, ct);
                    break;
            }
        }

        try
        {
            await ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "bye", ct);
        }
        catch
        {
            // ignore
        }

        if (authed && deviceId is not null)
        {
            _onDeviceDisconnected?.Invoke(deviceId);
        }
    }

    private static async Task<Dictionary<string, JsonElement>?> ReceiveJsonAsync(WebSocket ws, CancellationToken ct)
    {
        var buffer = new byte[64 * 1024];
        using var ms = new MemoryStream();

        while (true)
        {
            WebSocketReceiveResult result;
            try
            {
                result = await ws.ReceiveAsync(buffer, ct);
            }
            catch
            {
                return null;
            }

            if (result.MessageType == WebSocketMessageType.Close)
            {
                return null;
            }

            ms.Write(buffer, 0, result.Count);

            if (result.EndOfMessage)
            {
                break;
            }
        }

        var json = Encoding.UTF8.GetString(ms.ToArray());
        try
        {
            return JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(json);
        }
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
        if (!dict.TryGetValue(key, out var el))
        {
            return fallback;
        }

        return el.ValueKind switch
        {
            JsonValueKind.Number when el.TryGetInt32(out var v) => v,
            _ => fallback,
        };
    }

    public static bool GetBoolOrDefault(this Dictionary<string, JsonElement> dict, string key, bool fallback)
    {
        if (!dict.TryGetValue(key, out var el))
        {
            return fallback;
        }

        return el.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            _ => fallback,
        };
    }

    public static List<string>? GetStringArrayOrNull(this Dictionary<string, JsonElement> dict, string key)
    {
        if (!dict.TryGetValue(key, out var el) || el.ValueKind != JsonValueKind.Array)
        {
            return null;
        }

        var list = new List<string>();
        foreach (var item in el.EnumerateArray())
        {
            if (item.ValueKind == JsonValueKind.String)
            {
                list.Add(item.GetString()!);
            }
        }

        return list;
    }
}
