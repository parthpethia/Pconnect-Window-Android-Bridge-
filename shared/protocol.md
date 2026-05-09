# Pconnect protocol (v1)

Transport: WebSocket over local LAN.

- Default URL: `ws://<pc-ip>:47821/ws`
- Discovery (UDP broadcast): phone broadcasts `PCONNECT_DISCOVER_V1` to `255.255.255.255:47822`, PC replies with `discoverResponse`

All messages are UTF-8 JSON objects:

- `type`: string (required)
- `v`: number protocol version (required, currently `1`)
- `requestId`: string (optional, client-generated)

Unknown message types MUST be silently ignored for forward-compatibility.

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
  "role": "admin",
  "capabilities": ["lock", "text", "launch", "show", "mouse", "keyboard", "volume", "brightness", "shutdown", "clipboard", "fileTransfer", "recentFiles", "keyCombo", "mediaKey", "screenCapture", "notification", "appList", "customCommands", "auditLog"]
}
```

- `role`: `"admin"` | `"media_only"` | `"readonly"` — the device's permission role

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
{ "v": 1, "type": "paired", "deviceId": "<uuid>", "token": "<random-token>", "role": "admin" }
```

- New devices are assigned `"admin"` role by default.

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

### Key Combo (named-key shortcut)

Client → PC

```json
{ "v": 1, "type": "keyCombo", "keys": ["ctrl", "shift", "esc"] }
```

- `keys`: array of named keys. Supported names:
  `ctrl`, `shift`, `alt`, `win`, `enter`, `tab`, `esc`, `space`, `backspace`, `delete`,
  `up`, `down`, `left`, `right`, `home`, `end`, `pageup`, `pagedown`,
  `f1`–`f12`, `a`–`z`, `0`–`9`,
  and any single character.
- The PC presses all modifier keys down, presses the last key, then releases all.
- **Role**: requires `admin`.

PC → Client

```json
{ "v": 1, "type": "ok" }
```

### Media Keys

Client → PC

```json
{ "v": 1, "type": "mediaKey", "key": "play_pause" }
```

- `key`: `"play_pause"` | `"next"` | `"prev"` | `"stop"` | `"mute"` | `"vol_up"` | `"vol_down"`
- **Role**: requires `admin` or `media_only`.

PC → Client

```json
{ "v": 1, "type": "ok" }
```

### Set system volume

Client → PC

```json
{ "v": 1, "type": "setVolume", "level": 35 }
```

- `level`: integer `0..100`
- **Role**: requires `admin` or `media_only`.

PC → Client

```json
{ "v": 1, "type": "ok" }
```

### Set screen brightness

Client → PC

```json
{ "v": 1, "type": "setBrightness", "level": 60 }
```

- `level`: integer `0..100`

PC → Client

```json
{ "v": 1, "type": "ok" }
```

### Launch an application

Client → PC

```json
{ "v": 1, "type": "launch", "command": "notepad", "args": ["C:/temp/a.txt"] }
```

### Launch app (by path from app list)

Client → PC

```json
{ "v": 1, "type": "launchApp", "exePath": "C:\\Program Files\\..." }
```

PC → Client

```json
{ "v": 1, "type": "ok" }
```

### Show agent UI (bring to front)

Client → PC

```json
{ "v": 1, "type": "show" }
```

### Shut down PC

Client → PC

```json
{ "v": 1, "type": "shutdown", "password": "1326" }
```

- `password`: required (configured on PC; currently `1326`)

PC → Client

```json
{ "v": 1, "type": "ok" }
```

### Clipboard sync

#### Set clipboard (from phone to PC)

Client → PC

```json
{
  "v": 1,
  "type": "clipboardSet",
  "data": "<base64-encoded-utf8>",
  "format": "text/plain"
}
```

- `data`: Base64-encoded text content
- `format`: MIME type (currently `text/plain`)

PC → Client

```json
{ "v": 1, "type": "ok" }
```

#### Clipboard update (from PC to phone, unsolicited)

PC → Client (pushed when system clipboard changes on PC)

```json
{
  "v": 1,
  "type": "clipboardUpdate",
  "data": "<base64-encoded-utf8>",
  "format": "text/plain",
  "source": "system"
}
```

- Phone receives this when user copies on PC
- `source`: always `"system"` (for future extension to other sources)

### File Transfer

#### Initiate transfer

Client → PC

```json
{
  "v": 1,
  "type": "fileTransferStart",
  "id": "<uuid>",
  "filename": "document.pdf",
  "size": 1048576,
  "direction": "upload"
}
```

- `id`: Unique transfer ID
- `filename`: Desired filename
- `size`: Total file size in bytes
- `direction`: `"upload"` (phone→PC) or `"download"` (PC→phone)

PC → Client (ack)

```json
{ "v": 1, "type": "fileTransferAck", "id": "<uuid>", "ready": true }
```

#### Transfer chunk

Client → PC

```json
{
  "v": 1,
  "type": "fileTransferChunk",
  "id": "<uuid>",
  "chunkIndex": 0,
  "totalChunks": 20,
  "data": "<base64-chunk>",
  "size": 52428
}
```

- `data`: Base64-encoded chunk (50KB recommended)
- `chunkIndex`: 0-indexed chunk number
- `totalChunks`: Total number of chunks

PC → Client (progress)

```json
{
  "v": 1,
  "type": "fileTransferProgress",
  "id": "<uuid>",
  "chunkIndex": 0,
  "received": 52428,
  "total": 1048576
}
```

#### Complete transfer

Client → PC

```json
{ "v": 1, "type": "fileTransferComplete", "id": "<uuid>" }
```

PC → Client

```json
{ "v": 1, "type": "fileTransferComplete", "id": "<uuid>", "status": "success" }
```

#### Abort transfer

Client → PC

```json
{ "v": 1, "type": "fileTransferAbort", "id": "<uuid>" }
```

PC → Client

```json
{ "v": 1, "type": "ok" }
```

### Recent Files

Client → PC

```json
{ "v": 1, "type": "listRecentFiles", "limit": 20 }
```

PC → Client

```json
{
  "v": 1,
  "type": "recentFilesList",
  "files": [
    {
      "path": "C:\\Users\\User\\Documents\\report.docx",
      "name": "report.docx",
      "modified": 1712700000000,
      "size": 102400
    }
  ],
  "status": "ok"
}
```

- `files`: Array of {path, name, modified (timestamp ms), size}

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

### Screen Capture (low-fps preview)

#### Enable/disable capture

Client → PC

```json
{ "v": 1, "type": "screenCaptureStart", "intervalMs": 2000 }
```

```json
{ "v": 1, "type": "screenCaptureStop" }
```

#### Screen frame (pushed by PC while capture active)

PC → Client

```json
{
  "v": 1,
  "type": "screenFrame",
  "data": "<base64-jpeg>",
  "width": 480,
  "height": 270
}
```

### App List

Client → PC

```json
{ "v": 1, "type": "getAppList" }
```

PC → Client

```json
{
  "v": 1,
  "type": "appList",
  "apps": [
    {
      "name": "Notepad",
      "iconBase64": "<base64-png>",
      "exePath": "C:\\Windows\\notepad.exe"
    }
  ]
}
```

### Custom Commands

Client → PC

```json
{ "v": 1, "type": "getCommands" }
```

PC → Client

```json
{
  "v": 1,
  "type": "commandList",
  "commands": [
    { "label": "Start OBS", "command": "cmd /c start obs64.exe" }
  ]
}
```

Client → PC

```json
{ "v": 1, "type": "runCommand", "index": 0 }
```

PC → Client

```json
{ "v": 1, "type": "ok" }
```

### Notification Mirror

PC → Client (pushed when a toast notification appears on PC)

```json
{
  "v": 1,
  "type": "notification",
  "title": "New email",
  "body": "You have a new email from ...",
  "appName": "Microsoft Outlook"
}
```

### Settings Sync

Client → PC

```json
{ "v": 1, "type": "settingsSync", "autoLockOnDisconnect": true }
```

PC → Client

```json
{ "v": 1, "type": "ok" }
```

### Audit Log

Client → PC

```json
{ "v": 1, "type": "getLogs", "date": "2026-05-09" }
```

PC → Client

```json
{
  "v": 1,
  "type": "logEntries",
  "entries": [
    { "time": "2026-05-09T14:30:00+05:30", "device": "Android Phone", "action": "lock" }
  ]
}
```

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
