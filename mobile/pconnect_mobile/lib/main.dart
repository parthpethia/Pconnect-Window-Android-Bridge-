import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const int kWsPortDefault = 47821;
const int kDiscoveryPort = 47822;
const String kDiscoverProbe = 'PCONNECT_DISCOVER_V1';

const String kVsCodeExePath =
    r'C:\Users\Atul\AppData\Local\Programs\Microsoft VS Code\Code.exe';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PconnectApp());
}

class PconnectApp extends StatelessWidget {
  const PconnectApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pconnect',
      theme: ThemeData(useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}

class DiscoveredPc {
  final String name;
  final InternetAddress address;
  final int wsPort;

  DiscoveredPc(
      {required this.name, required this.address, required this.wsPort});
}

class ConnectionStatus {
  final bool connected;
  final bool needsPairing;
  final String? pcName;
  final String? error;

  const ConnectionStatus({
    required this.connected,
    required this.needsPairing,
    this.pcName,
    this.error,
  });

  static const disconnected =
      ConnectionStatus(connected: false, needsPairing: false);
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _uuid = const Uuid();

  final _manualHostController = TextEditingController();
  final _pairingCodeController = TextEditingController();
  final _textController = TextEditingController();

  final List<DiscoveredPc> _discovered = [];
  ConnectionStatus _status = ConnectionStatus.disconnected;

  PcConnection? _conn;
  String _deviceId = '';
  String? _token;
  String? _lastHost;
  int _lastPort = kWsPortDefault;

  String _lastText = '';

  @override
  void initState() {
    super.initState();
    _bootstrap();

    _textController.addListener(() {
      if (_conn == null || !_status.connected) return;
      _sendTextDiff(_textController.text);
    });
  }

  Future<void> _bootstrap() async {
    final prefs = await SharedPreferences.getInstance();

    _deviceId = prefs.getString('device_id') ?? _uuid.v4();
    await prefs.setString('device_id', _deviceId);

    _token = prefs.getString('token');
    _lastHost = prefs.getString('last_pc_host');
    _lastPort = prefs.getInt('last_pc_port') ?? kWsPortDefault;

    if (_lastHost != null && _token != null) {
      unawaited(_connectHost(_lastHost!, _lastPort));
    }
  }

  @override
  void dispose() {
    _conn?.dispose();
    _manualHostController.dispose();
    _pairingCodeController.dispose();
    _textController.dispose();
    super.dispose();
  }

  Future<void> _discover() async {
    setState(() {
      _discovered.clear();
    });

    final results = await DiscoveryClient.discover(
        timeout: const Duration(milliseconds: 900));

    if (!mounted) return;
    setState(() {
      _discovered
        ..clear()
        ..addAll(results);
    });
  }

  Future<void> _connectHost(String host, int port) async {
    _conn?.dispose();

    final conn = PcConnection(deviceId: _deviceId);
    setState(() {
      _status = const ConnectionStatus(
          connected: false, needsPairing: false, error: null);
      _conn = conn;
    });

    conn.statusStream.listen((s) {
      if (!mounted) return;
      setState(() => _status = s);
    });

    await conn.connect(host: host, port: port, token: _token);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_pc_host', host);
    await prefs.setInt('last_pc_port', port);

    _lastHost = host;
    _lastPort = port;

    // Reset diff baseline once connected.
    _lastText = '';
  }

  ({String host, int port})? _parseManualHost(String input) {
    final raw = input.trim();
    if (raw.isEmpty) return null;

    // Allow pasting full WebSocket URLs like: ws://192.168.1.10:47821/ws
    if (raw.startsWith('ws://') || raw.startsWith('wss://')) {
      final uri = Uri.tryParse(raw);
      if (uri == null || uri.host.isEmpty) return null;
      final port = uri.hasPort ? uri.port : kWsPortDefault;
      return (host: uri.host, port: port);
    }

    // Allow host:port.
    final idx = raw.lastIndexOf(':');
    if (idx > 0 && idx < raw.length - 1) {
      final host = raw.substring(0, idx).trim();
      final portStr = raw.substring(idx + 1).trim();
      final port = int.tryParse(portStr);
      if (host.isEmpty || port == null) return null;
      return (host: host, port: port);
    }

    // Default: host only.
    return (host: raw, port: kWsPortDefault);
  }

  Future<void> _pair() async {
    final code = _pairingCodeController.text.trim();
    final conn = _conn;
    if (conn == null || code.isEmpty) return;

    final token = await conn.pair(code: code, deviceName: 'Android');
    if (token == null) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('token', token);
    _token = token;

    if (!mounted) return;
    setState(() {
      _pairingCodeController.text = '';
    });
  }

  void _sendTextDiff(String current) {
    final conn = _conn;
    if (conn == null) return;

    final diff = TextDiff.compute(_lastText, current);
    _lastText = current;

    if (diff.backspaces == 0 && diff.inserted.isEmpty) return;
    conn.sendInput(backspaces: diff.backspaces, text: diff.inserted);
  }

  @override
  Widget build(BuildContext context) {
    final connected = _status.connected;

    return Scaffold(
      appBar: AppBar(
          title: Text(_status.pcName == null
              ? 'Pconnect'
              : 'Pconnect • ${_status.pcName}')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            FilledButton(
              onPressed: () async {
                await _discover();
                if (_discovered.isNotEmpty) {
                  final pc = _discovered.first;
                  await _connectHost(pc.address.address, pc.wsPort);
                } else if (_lastHost != null) {
                  await _connectHost(_lastHost!, _lastPort);
                }
              },
              child: const Text('Connect to PC'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _manualHostController,
                    decoration: const InputDecoration(
                      labelText: 'Manual IP (fallback)',
                      hintText: '192.168.1.10  (or :47821 / ws://...)',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.url,
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: () async {
                    final parsed = _parseManualHost(_manualHostController.text);
                    if (parsed == null) return;
                    await _connectHost(parsed.host, parsed.port);
                  },
                  child: const Text('Connect'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_discovered.isNotEmpty) ...[
              const Text('Discovered PCs:',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              for (final pc in _discovered)
                ListTile(
                  title: Text(pc.name),
                  subtitle: Text('${pc.address.address}:${pc.wsPort}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _connectHost(pc.address.address, pc.wsPort),
                ),
              const Divider(),
            ],
            if (_status.error != null) ...[
              Text(_status.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
              const SizedBox(height: 8),
            ],
            if (_status.needsPairing) ...[
              const Text('Pairing required',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              TextField(
                controller: _pairingCodeController,
                decoration: const InputDecoration(
                  labelText: 'Pairing code (from PC tray app)',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 8),
              FilledButton(onPressed: _pair, child: const Text('Pair')),
              const Divider(),
            ],
            FilledButton(
              onPressed: connected ? () => _conn?.lockPc() : null,
              child: const Text('Lock PC'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _textController,
              enabled: connected,
              decoration: const InputDecoration(
                labelText: 'Type on phone → PC active window',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed:
                        connected ? () => _conn?.launchApp('notepad') : null,
                    child: const Text('Notepad'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed:
                        connected ? () => _conn?.launchApp('calc') : null,
                    child: const Text('Calculator'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed:
                  connected ? () => _conn?.launchApp(kVsCodeExePath) : null,
              child: const Text('VS Code'),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: connected
                  ? () {
                      final conn = _conn;
                      if (conn == null) return;
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => TrackpadScreen(
                          conn: conn,
                          pcName: _status.pcName,
                          enabled: connected,
                        ),
                      ));
                    }
                  : null,
              child: const Text('Trackpad'),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: connected
                  ? () {
                      final conn = _conn;
                      if (conn == null) return;
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => KeyboardScreen(
                          conn: conn,
                          pcName: _status.pcName,
                          enabled: connected,
                        ),
                      ));
                    }
                  : null,
              child: const Text('Keyboard'),
            ),
          ],
        ),
      ),
    );
  }
}

class KeyboardScreen extends StatelessWidget {
  final PcConnection conn;
  final String? pcName;
  final bool enabled;

  const KeyboardScreen(
      {super.key,
      required this.conn,
      required this.pcName,
      required this.enabled});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(pcName == null ? 'Keyboard' : 'Keyboard • $pcName')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: ValueListenableBuilder<ConnectionStatus>(
          valueListenable: conn.statusNotifier,
          builder: (context, status, _) {
            final connected = status.connected;
            return Column(
              children: [
                if (status.error != null) ...[
                  Text(
                    status.error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                ],
                Expanded(
                  child: (enabled && connected)
                      ? LaptopKeyboard(conn: conn)
                      : const Center(child: Text('Not connected')),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _KeySpec {
  final String label;
  final int? vk;
  final bool extended;
  final int flex;
  final bool isModifier;
  final bool localOnly;

  const _KeySpec({
    required this.label,
    this.vk,
    this.extended = false,
    this.flex = 1,
    this.isModifier = false,
    this.localOnly = false,
  });
}

class LaptopKeyboard extends StatefulWidget {
  final PcConnection conn;

  const LaptopKeyboard({super.key, required this.conn});

  @override
  State<LaptopKeyboard> createState() => _LaptopKeyboardState();
}

class _LaptopKeyboardState extends State<LaptopKeyboard> {
  bool _fn = false;
  bool _ctrl = false;
  bool _shift = false;
  bool _alt = false;
  bool _win = false;

  @override
  void dispose() {
    // Ensure we don't leave modifiers stuck.
    if (_ctrl) widget.conn.keyUp(vk: 0x11);
    if (_shift) widget.conn.keyUp(vk: 0x10);
    if (_alt) widget.conn.keyUp(vk: 0x12);
    if (_win) widget.conn.keyUp(vk: 0x5B, extended: true);
    super.dispose();
  }

  void _toggleModifier(_KeySpec k) {
    if (k.label == 'Fn') {
      setState(() => _fn = !_fn);
      return;
    }

    if (k.vk == null) return;

    bool nowOn;
    switch (k.label) {
      case 'Ctrl':
        nowOn = !_ctrl;
        setState(() => _ctrl = nowOn);
        break;
      case 'Shift':
        nowOn = !_shift;
        setState(() => _shift = nowOn);
        break;
      case 'Alt':
        nowOn = !_alt;
        setState(() => _alt = nowOn);
        break;
      case 'Win':
        nowOn = !_win;
        setState(() => _win = nowOn);
        break;
      default:
        return;
    }

    if (nowOn) {
      widget.conn.keyDown(vk: k.vk!, extended: k.extended);
    } else {
      widget.conn.keyUp(vk: k.vk!, extended: k.extended);
    }
  }

  bool _isModifierOn(String label) {
    switch (label) {
      case 'Fn':
        return _fn;
      case 'Ctrl':
        return _ctrl;
      case 'Shift':
        return _shift;
      case 'Alt':
        return _alt;
      case 'Win':
        return _win;
      default:
        return false;
    }
  }

  void _pressKey(_KeySpec k) {
    if (k.localOnly) {
      _toggleModifier(k);
      return;
    }

    if (k.isModifier) {
      _toggleModifier(k);
      return;
    }

    if (k.vk == null) return;
    widget.conn.keyPress(vk: k.vk!, extended: k.extended);
  }

  Widget _keyButton(_KeySpec k) {
    final isOn = k.isModifier ? _isModifierOn(k.label) : false;

    return Expanded(
      flex: k.flex,
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: SizedBox(
          height: 44,
          child: isOn
              ? FilledButton(
                  onPressed: () => _pressKey(k),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(k.label),
                  ),
                )
              : FilledButton.tonal(
                  onPressed: () => _pressKey(k),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(k.label),
                  ),
                ),
        ),
      ),
    );
  }

  Widget _row(List<_KeySpec> keys) {
    return Row(children: keys.map(_keyButton).toList());
  }

  @override
  Widget build(BuildContext context) {
    // NOTE: A full laptop layout is wider than most phones.
    // We keep rows horizontal and allow sideways scrolling.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 980),
        child: Column(
          children: [
            _row(const [
              _KeySpec(label: 'Esc', vk: 0x1B),
              _KeySpec(label: 'F1', vk: 0x70),
              _KeySpec(label: 'F2', vk: 0x71),
              _KeySpec(label: 'F3', vk: 0x72),
              _KeySpec(label: 'F4', vk: 0x73),
              _KeySpec(label: 'F5', vk: 0x74),
              _KeySpec(label: 'F6', vk: 0x75),
              _KeySpec(label: 'F7', vk: 0x76),
              _KeySpec(label: 'F8', vk: 0x77),
              _KeySpec(label: 'F9', vk: 0x78),
              _KeySpec(label: 'F10', vk: 0x79),
              _KeySpec(label: 'F11', vk: 0x7A),
              _KeySpec(label: 'F12', vk: 0x7B),
            ]),
            _row(const [
              _KeySpec(label: 'Fn', isModifier: true, localOnly: true),
              _KeySpec(label: '1', vk: 0x31),
              _KeySpec(label: '2', vk: 0x32),
              _KeySpec(label: '3', vk: 0x33),
              _KeySpec(label: '4', vk: 0x34),
              _KeySpec(label: '5', vk: 0x35),
              _KeySpec(label: '6', vk: 0x36),
              _KeySpec(label: '7', vk: 0x37),
              _KeySpec(label: '8', vk: 0x38),
              _KeySpec(label: '9', vk: 0x39),
              _KeySpec(label: '0', vk: 0x30),
              _KeySpec(label: 'Backspace', vk: 0x08, flex: 2),
            ]),
            _row(const [
              _KeySpec(label: 'Tab', vk: 0x09, flex: 2),
              _KeySpec(label: 'Q', vk: 0x51),
              _KeySpec(label: 'W', vk: 0x57),
              _KeySpec(label: 'E', vk: 0x45),
              _KeySpec(label: 'R', vk: 0x52),
              _KeySpec(label: 'T', vk: 0x54),
              _KeySpec(label: 'Y', vk: 0x59),
              _KeySpec(label: 'U', vk: 0x55),
              _KeySpec(label: 'I', vk: 0x49),
              _KeySpec(label: 'O', vk: 0x4F),
              _KeySpec(label: 'P', vk: 0x50),
              _KeySpec(label: 'Enter', vk: 0x0D, flex: 2),
            ]),
            _row(const [
              _KeySpec(label: 'Caps', vk: 0x14, flex: 2),
              _KeySpec(label: 'A', vk: 0x41),
              _KeySpec(label: 'S', vk: 0x53),
              _KeySpec(label: 'D', vk: 0x44),
              _KeySpec(label: 'F', vk: 0x46),
              _KeySpec(label: 'G', vk: 0x47),
              _KeySpec(label: 'H', vk: 0x48),
              _KeySpec(label: 'J', vk: 0x4A),
              _KeySpec(label: 'K', vk: 0x4B),
              _KeySpec(label: 'L', vk: 0x4C),
              _KeySpec(label: '←', vk: 0x25, extended: true),
              _KeySpec(label: '→', vk: 0x27, extended: true),
            ]),
            _row(const [
              _KeySpec(label: 'Shift', vk: 0x10, flex: 2, isModifier: true),
              _KeySpec(label: 'Z', vk: 0x5A),
              _KeySpec(label: 'X', vk: 0x58),
              _KeySpec(label: 'C', vk: 0x43),
              _KeySpec(label: 'V', vk: 0x56),
              _KeySpec(label: 'B', vk: 0x42),
              _KeySpec(label: 'N', vk: 0x4E),
              _KeySpec(label: 'M', vk: 0x4D),
              _KeySpec(label: '↑', vk: 0x26, extended: true),
              _KeySpec(label: '↓', vk: 0x28, extended: true),
              _KeySpec(label: 'Del', vk: 0x2E, extended: true),
            ]),
            _row(const [
              _KeySpec(label: 'Ctrl', vk: 0x11, flex: 2, isModifier: true),
              _KeySpec(
                  label: 'Win',
                  vk: 0x5B,
                  flex: 2,
                  isModifier: true,
                  extended: true),
              _KeySpec(label: 'Alt', vk: 0x12, flex: 2, isModifier: true),
              _KeySpec(label: 'Space', vk: 0x20, flex: 6),
              _KeySpec(label: 'Alt', vk: 0x12, flex: 2, isModifier: true),
              _KeySpec(label: 'Ctrl', vk: 0x11, flex: 2, isModifier: true),
            ]),
          ],
        ),
      ),
    );
  }
}

class TrackpadScreen extends StatelessWidget {
  final PcConnection conn;
  final String? pcName;
  final bool enabled;

  const TrackpadScreen(
      {super.key,
      required this.conn,
      required this.pcName,
      required this.enabled});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(pcName == null ? 'Trackpad' : 'Trackpad • $pcName')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ValueListenableBuilder<ConnectionStatus>(
          valueListenable: conn.statusNotifier,
          builder: (context, status, _) {
            final connected = status.connected;
            return Column(
              children: [
                if (status.error != null) ...[
                  Text(
                    status.error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                ],
                Expanded(
                  child: (enabled && connected)
                      ? TrackpadSurface(conn: conn)
                      : const Center(child: Text('Not connected')),
                ),
                const SizedBox(height: 12),
                const Text(
                  'One finger: move • Tap: click • Long press: drag • Two fingers: scroll',
                  textAlign: TextAlign.center,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _PointerInfo {
  final Offset downPos;
  Offset lastPos;
  final DateTime downTime;

  _PointerInfo(
      {required this.downPos, required this.lastPos, required this.downTime});
}

class TrackpadSurface extends StatefulWidget {
  final PcConnection conn;

  const TrackpadSurface({super.key, required this.conn});

  @override
  State<TrackpadSurface> createState() => _TrackpadSurfaceState();
}

class _TrackpadSurfaceState extends State<TrackpadSurface> {
  static const double _tapSlopPx = 10;
  static const int _tapMaxMs = 220;
  static const int _longPressMs = 350;
  static const double _longPressMoveCancelPx = 8;

  // Tunables
  static const double _pointerToMouseScale = 1.4;
  static const double _scrollWheelPerPx = 2.0; // 60px -> ~120 wheel delta

  final Map<int, _PointerInfo> _pointers = {};
  Offset? _lastCentroid;

  double _accumDx = 0;
  double _accumDy = 0;
  double _accumWheel = 0;
  Timer? _flushTimer;

  Timer? _longPressTimer;
  bool _dragging = false;
  int? _dragPointer;

  @override
  void dispose() {
    _flushTimer?.cancel();
    _longPressTimer?.cancel();
    if (_dragging) {
      widget.conn.mouseButton(button: 'left', action: 'up');
    }
    super.dispose();
  }

  void _ensureFlushTimer() {
    _flushTimer ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
      // Convert to integers but keep the fractional remainder so small movements
      // don't get rounded away (can otherwise feel like "cursor doesn't move").
      final dx = _accumDx.truncate();
      final dy = _accumDy.truncate();
      final wheel = _accumWheel.truncate();
      _accumDx -= dx;
      _accumDy -= dy;
      _accumWheel -= wheel;

      if (dx != 0 || dy != 0) {
        widget.conn.mouseMove(dx: dx, dy: dy);
      }
      if (wheel != 0) {
        widget.conn.mouseScroll(dy: wheel);
      }

      if (_pointers.isEmpty) {
        _flushTimer?.cancel();
        _flushTimer = null;
      }
    });
  }

  Offset _centroid() {
    var sum = Offset.zero;
    for (final p in _pointers.values) {
      sum += p.lastPos;
    }
    return sum / _pointers.length.toDouble();
  }

  void _startLongPressTimer(int pointer) {
    _longPressTimer?.cancel();
    _longPressTimer = Timer(const Duration(milliseconds: _longPressMs), () {
      if (_pointers.length != 1) return;
      final info = _pointers[pointer];
      if (info == null) return;

      final moved = (info.lastPos - info.downPos).distance;
      if (moved > _longPressMoveCancelPx) return;

      if (!_dragging) {
        _dragging = true;
        _dragPointer = pointer;
        widget.conn.mouseButton(button: 'left', action: 'down');
      }
    });
  }

  void _cancelLongPressTimer() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
  }

  @override
  Widget build(BuildContext context) {
    final surfaceColor = Theme.of(context).colorScheme.surfaceContainerHighest;

    return Listener(
      onPointerDown: (e) {
        _pointers[e.pointer] = _PointerInfo(
          downPos: e.localPosition,
          lastPos: e.localPosition,
          downTime: DateTime.now(),
        );

        if (_pointers.length == 1) {
          _startLongPressTimer(e.pointer);
        } else {
          _cancelLongPressTimer();
          _lastCentroid = _centroid();
        }

        _ensureFlushTimer();
      },
      onPointerMove: (e) {
        final info = _pointers[e.pointer];
        if (info == null) return;

        final prev = info.lastPos;
        info.lastPos = e.localPosition;

        if (_pointers.length == 1) {
          final delta = info.lastPos - prev;

          // Cancel long-press if user clearly started moving.
          if ((info.lastPos - info.downPos).distance > _longPressMoveCancelPx) {
            _cancelLongPressTimer();
          }

          _accumDx += (delta.dx * _pointerToMouseScale);
          _accumDy += (delta.dy * _pointerToMouseScale);
        } else {
          // Two+ fingers: treat as scroll based on centroid movement.
          final c = _centroid();
          final last = _lastCentroid;
          _lastCentroid = c;
          if (last != null) {
            final d = c - last;
            _accumWheel += (-d.dy * _scrollWheelPerPx);
          }
        }

        _ensureFlushTimer();
      },
      onPointerUp: (e) {
        final info = _pointers.remove(e.pointer);
        _lastCentroid = _pointers.length >= 2 ? _centroid() : null;

        _cancelLongPressTimer();

        if (_dragging && _dragPointer == e.pointer) {
          widget.conn.mouseButton(button: 'left', action: 'up');
          _dragging = false;
          _dragPointer = null;
          return;
        }

        // Tap-to-click (only when no other fingers are down)
        if (info != null && _pointers.isEmpty) {
          final dt = DateTime.now().difference(info.downTime).inMilliseconds;
          final dist = (info.lastPos - info.downPos).distance;
          if (dt <= _tapMaxMs && dist <= _tapSlopPx) {
            widget.conn.mouseButton(button: 'left', action: 'click');
          }
        }
      },
      onPointerCancel: (e) {
        _pointers.remove(e.pointer);
        _cancelLongPressTimer();
        if (_dragging && _dragPointer == e.pointer) {
          widget.conn.mouseButton(button: 'left', action: 'up');
          _dragging = false;
          _dragPointer = null;
        }
      },
      child: Container(
        decoration: BoxDecoration(
          color: surfaceColor,
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Center(
          child: Text('Trackpad'),
        ),
      ),
    );
  }
}

class DiscoveryClient {
  static Future<List<DiscoveredPc>> discover(
      {required Duration timeout}) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;

    final results = <DiscoveredPc>[];
    final seen = <String>{};

    void onData() {
      final dg = socket.receive();
      if (dg == null) return;
      try {
        final obj = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
        if (obj['type'] != 'discoverResponse') return;
        final name = (obj['pcName'] as String?) ?? dg.address.address;
        final port = (obj['wsPort'] as num?)?.toInt() ?? kWsPortDefault;
        final key = '${dg.address.address}:$port';
        if (seen.add(key)) {
          results
              .add(DiscoveredPc(name: name, address: dg.address, wsPort: port));
        }
      } catch (_) {
        // ignore
      }
    }

    socket.listen((event) {
      if (event == RawSocketEvent.read) onData();
    });

    final probeBytes = utf8.encode(kDiscoverProbe);
    socket.send(probeBytes, InternetAddress('255.255.255.255'), kDiscoveryPort);

    await Future<void>.delayed(timeout);
    socket.close();

    return results;
  }
}

class PcConnection {
  final String deviceId;

  final _statusController = StreamController<ConnectionStatus>.broadcast();
  Stream<ConnectionStatus> get statusStream => _statusController.stream;

  final ValueNotifier<ConnectionStatus> statusNotifier =
      ValueNotifier(ConnectionStatus.disconnected);
  ConnectionStatus get currentStatus => statusNotifier.value;

  WebSocketChannel? _channel;
  StreamSubscription? _sub;

  String? _host;
  int? _port;
  String? _token;

  Timer? _reconnectTimer;
  int _reconnectDelayMs = 500;

  DateTime? _lastSendFailure;

  PcConnection({required this.deviceId});

  void _setStatus(ConnectionStatus s) {
    statusNotifier.value = s;
    _statusController.add(s);
  }

  Future<void> connect(
      {required String host, required int port, required String? token}) async {
    _host = host;
    _port = port;
    _token = token;

    await _connectInternal();
  }

  Future<void> _connectInternal() async {
    _reconnectTimer?.cancel();

    final host = _host;
    final port = _port;
    if (host == null || port == null) return;

    final uri = Uri.parse('ws://$host:$port/ws');

    try {
      final channel = WebSocketChannel.connect(uri);
      _channel = channel;

      _sub?.cancel();
      _sub = channel.stream.listen(
        (event) => _onMessage(event),
        onError: (e) => _scheduleReconnect('WebSocket error: $e'),
        onDone: () => _scheduleReconnect('Disconnected'),
        cancelOnError: true,
      );

      // hello
      _send({
        'v': 1,
        'type': 'hello',
        'deviceId': deviceId,
        if (_token != null) 'token': _token,
      });
    } catch (e) {
      _scheduleReconnect('Connect failed: $e');
    }
  }

  void _onMessage(dynamic event) {
    try {
      final obj = jsonDecode(event as String) as Map<String, dynamic>;
      final type = obj['type'];

      if (type == 'helloAck') {
        _reconnectDelayMs = 500;
        _setStatus(ConnectionStatus(
          connected: true,
          needsPairing: false,
          pcName: obj['pcName'] as String?,
        ));
        return;
      }

      if (type == 'authRequired') {
        _setStatus(const ConnectionStatus(
          connected: false,
          needsPairing: true,
        ));
        return;
      }

      if (type == 'paired') {
        final token = obj['token'] as String?;
        if (token != null) {
          _token = token;
        }
        return;
      }

      if (type == 'error') {
        // Non-fatal: keep current connection state, surface the error.
        final msg = obj['message'] as String? ?? 'Unknown error';
        final cur = currentStatus;
        _setStatus(ConnectionStatus(
          connected: cur.connected,
          needsPairing: cur.needsPairing,
          pcName: cur.pcName,
          error: msg,
        ));
      }
    } catch (_) {
      // ignore
    }
  }

  Future<String?> pair(
      {required String code, required String deviceName}) async {
    final ch = _channel;
    if (ch == null) return null;

    _send({
      'v': 1,
      'type': 'pair',
      'deviceId': deviceId,
      'deviceName': deviceName,
      'code': code,
    });

    // Wait briefly for token to arrive.
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (_token != null) return _token;
    }

    return null;
  }

  void lockPc() => _send({'v': 1, 'type': 'lock'});

  void sendInput({required int backspaces, required String text}) {
    _send({'v': 1, 'type': 'input', 'backspaces': backspaces, 'text': text});
  }

  void launchApp(String command, {List<String>? args}) {
    _send({
      'v': 1,
      'type': 'launch',
      'command': command,
      if (args != null) 'args': args
    });
  }

  void mouseMove({required int dx, required int dy}) {
    if (dx == 0 && dy == 0) return;
    _send({'v': 1, 'type': 'mouseMove', 'dx': dx, 'dy': dy});
  }

  void mouseScroll({required int dy}) {
    if (dy == 0) return;
    _send({'v': 1, 'type': 'mouseScroll', 'dy': dy});
  }

  void mouseButton({required String button, required String action}) {
    _send({'v': 1, 'type': 'mouseButton', 'button': button, 'action': action});
  }

  void keyPress({required int vk, bool extended = false}) {
    _send({
      'v': 1,
      'type': 'key',
      'vk': vk,
      'action': 'press',
      if (extended) 'extended': true,
    });
  }

  void keyDown({required int vk, bool extended = false}) {
    _send({
      'v': 1,
      'type': 'key',
      'vk': vk,
      'action': 'down',
      if (extended) 'extended': true,
    });
  }

  void keyUp({required int vk, bool extended = false}) {
    _send({
      'v': 1,
      'type': 'key',
      'vk': vk,
      'action': 'up',
      if (extended) 'extended': true,
    });
  }

  void _send(Map<String, dynamic> obj) {
    final ch = _channel;
    if (ch == null) {
      _scheduleReconnect('Not connected');
      return;
    }

    try {
      ch.sink.add(jsonEncode(obj));
    } catch (e) {
      _scheduleReconnect('Send failed: $e');
    }
  }

  void _scheduleReconnect(String reason) {
    final now = DateTime.now();
    final last = _lastSendFailure;
    if (last != null && now.difference(last).inMilliseconds < 400) {
      // Throttle spammy failures (trackpad sends frequently).
    } else {
      _lastSendFailure = now;
    }

    _setStatus(ConnectionStatus(
      connected: false,
      needsPairing: false,
      error: reason,
      pcName: currentStatus.pcName,
    ));

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: _reconnectDelayMs), () {
      _reconnectDelayMs = (_reconnectDelayMs * 2).clamp(500, 5000);
      unawaited(_connectInternal());
    });
  }

  void dispose() {
    _reconnectTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    _statusController.close();
    statusNotifier.dispose();
  }
}

class TextDiff {
  final int backspaces;
  final String inserted;

  TextDiff(this.backspaces, this.inserted);

  static TextDiff compute(String oldText, String newText) {
    if (oldText == newText) return TextDiff(0, '');

    var prefix = 0;
    final minLen =
        oldText.length < newText.length ? oldText.length : newText.length;
    while (prefix < minLen &&
        oldText.codeUnitAt(prefix) == newText.codeUnitAt(prefix)) {
      prefix++;
    }

    final oldSuffix = oldText.substring(prefix);
    final newSuffix = newText.substring(prefix);

    // Only support backspacing + appending. For edits in the middle, this still works
    // (backspaces to prefix, then insert new suffix).
    return TextDiff(oldSuffix.length, newSuffix);
  }
}
