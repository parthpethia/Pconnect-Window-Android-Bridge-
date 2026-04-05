# Pconnect protocol (v1)

Transport: WebSocket over local LAN.

- Default URL: `ws://<pc-ip>:47821/ws`
- Discovery (UDP broadcast): phone broadcasts `PCONNECT_DISCOVER_V1` to `255.255.255.255:47822`, PC replies with `discoverResponse`

All messages are UTF-8 JSON objects:

- `type`: string (required)
- `v`: number protocol version (required, currently `1`)
- `requestId`: string (optional, client-generated)

## Authentication

A client must authenticate before sending control commands.

### `hello`

Client → PC

```json
{ "v": 1, "type": "hello", "deviceId": "<uuid>", "token": "<optional>" }
```

PC → Client (if token valid)

```json
{
  "v": 1,
  "type": "helloAck",
  "pcName": "<name>",
  "capabilities": ["lock", "text", "launch", "show"]
}
```

PC → Client (if not paired)

```json
{ "v": 1, "type": "authRequired", "pairing": { "method": "code" } }
```

### `pair`

Client → PC

```json
{
  "v": 1,
  "type": "pair",
  "deviceId": "<uuid>",
  "code": "123456",
  "deviceName": "Phone"
}
```

PC → Client

```json
{ "v": 1, "type": "paired", "deviceId": "<uuid>", "token": "<random-token>" }
```

## Commands (require auth)

### Lock PC

Client → PC

```json
{ "v": 1, "type": "lock" }
```

PC → Client

```json
{ "v": 1, "type": "ok" }
```

### Text input (low latency)

Client → PC

```json
{ "v": 1, "type": "input", "backspaces": 2, "text": "hello" }
```

- The PC will send `backspaces` times the Backspace key, then type `text` as Unicode.

### Keyboard (virtual-key events)

Use this for modifier keys (Ctrl/Shift/Alt/Win) and key combos.

Client → PC

```json
{ "v": 1, "type": "key", "vk": 65, "action": "press" }
```

```json
{ "v": 1, "type": "key", "vk": 17, "action": "down" }
```

```json
{ "v": 1, "type": "key", "vk": 17, "action": "up" }
```

- `vk`: Win32 virtual-key code (integer)
- `action`: `press` | `down` | `up`
- Optional: `extended`: boolean (for extended keys like arrows)

### Launch an application

Client → PC

```json
{ "v": 1, "type": "launch", "command": "notepad", "args": ["C:/temp/a.txt"] }
```

### Show agent UI (bring to front)

Client → PC

```json
{ "v": 1, "type": "show" }
```

### Mouse / Trackpad control

These messages are designed to be sent frequently (especially `mouseMove`).

#### Move mouse (relative)

Client → PC

```json
{ "v": 1, "type": "mouseMove", "dx": 12, "dy": -4 }
```

- `dx`, `dy` are relative deltas (pixels).

#### Scroll (vertical mouse wheel)

Client → PC

```json
{ "v": 1, "type": "mouseScroll", "dy": -120 }
```

- `dy` is the wheel delta (same convention as Win32 wheel delta; a common notch is `120`).

#### Mouse button

Client → PC

```json
{ "v": 1, "type": "mouseButton", "button": "left", "action": "click" }
```

```json
{ "v": 1, "type": "mouseButton", "button": "left", "action": "down" }
```

```json
{ "v": 1, "type": "mouseButton", "button": "left", "action": "up" }
```

- `button`: `left` | `right` | `middle`
- `action`: `click` | `down` | `up`

## Error

PC → Client

```json
{ "v": 1, "type": "error", "message": "..." }
```

## Discovery (UDP broadcast)

Phone → LAN broadcast (`255.255.255.255:47822`)

```text
PCONNECT_DISCOVER_V1
```

PC → Phone (unicast reply)

```json
{ "v": 1, "type": "discoverResponse", "pcName": "<name>", "wsPort": 47821 }
```
