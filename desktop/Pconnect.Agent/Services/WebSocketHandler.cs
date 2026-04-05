using System.Net;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;

namespace Pconnect.Agent.Services;

internal sealed class WebSocketHandler
{
    private readonly PairingService _pairing;
    private readonly PairedDevicesStore _paired;
    private readonly PcActions _pc;
    private readonly IUiActions _ui;

    public WebSocketHandler(PairingService pairing, PairedDevicesStore paired, PcActions pc, IUiActions ui)
    {
        _pairing = pairing;
        _paired = paired;
        _pc = pc;
        _ui = ui;
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

            if (!authed)
            {
                if (type == "hello")
                {
                    deviceId = msg.GetStringOrNull("deviceId");
                    var token = msg.GetStringOrNull("token");

                    if (deviceId is not null && token is not null && _paired.IsPaired(deviceId, token))
                    {
                        authed = true;
                        await SendAsync(ws, new
                        {
                            v = 1,
                            type = "helloAck",
                            pcName = Environment.MachineName,
                            capabilities = new[] { "lock", "text", "launch", "show" }
                        }, ct);
                    }
                    else
                    {
                        await SendAsync(ws, new { v = 1, type = "authRequired", pairing = new { method = "code" } }, ct);
                    }

                    continue;
                }

                if (type == "pair")
                {
                    deviceId = msg.GetStringOrNull("deviceId") ?? deviceId;
                    var code = msg.GetStringOrNull("code");

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

                    var token = _paired.PairNewDevice(deviceId);
                    authed = true;

                    await SendAsync(ws, new { v = 1, type = "paired", deviceId, token }, ct);
                    await SendAsync(ws, new { v = 1, type = "helloAck", pcName = Environment.MachineName, capabilities = new[] { "lock", "text", "launch", "show" } }, ct);
                    continue;
                }

                await SendAsync(ws, new { v = 1, type = "authRequired", pairing = new { method = "code" } }, ct);
                continue;
            }

            switch (type)
            {
                case "lock":
                    _pc.Lock();
                    await SendAsync(ws, new { v = 1, type = "ok" }, ct);
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

                default:
                    await SendAsync(ws, new { v = 1, type = "error", message = $"Unknown type: {type}" }, ct);
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
