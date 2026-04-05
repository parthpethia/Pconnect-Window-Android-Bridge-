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

  DiscoveredPc({required this.name, required this.address, required this.wsPort});
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

  static const disconnected = ConnectionStatus(connected: false, needsPairing: false);
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

    final results = await DiscoveryClient.discover(timeout: const Duration(milliseconds: 900));

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
      _status = const ConnectionStatus(connected: false, needsPairing: false, error: null);
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
      appBar: AppBar(title: Text(_status.pcName == null ? 'Pconnect' : 'Pconnect • ${_status.pcName}')),
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
                      hintText: '192.168.1.10',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: () async {
                    final host = _manualHostController.text.trim();
                    if (host.isEmpty) return;
                    await _connectHost(host, kWsPortDefault);
                  },
                  child: const Text('Connect'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_discovered.isNotEmpty) ...[
              const Text('Discovered PCs:', style: TextStyle(fontWeight: FontWeight.w600)),
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
              Text(_status.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              const SizedBox(height: 8),
            ],

            if (_status.needsPairing) ...[
              const Text('Pairing required', style: TextStyle(fontWeight: FontWeight.w600)),
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
                    onPressed: connected ? () => _conn?.launchApp('notepad') : null,
                    child: const Text('Notepad'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: connected ? () => _conn?.launchApp('calc') : null,
                    child: const Text('Calculator'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class DiscoveryClient {
  static Future<List<DiscoveredPc>> discover({required Duration timeout}) async {
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
          results.add(DiscoveredPc(name: name, address: dg.address, wsPort: port));
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

  WebSocketChannel? _channel;
  StreamSubscription? _sub;

  String? _host;
  int? _port;
  String? _token;

  Timer? _reconnectTimer;
  int _reconnectDelayMs = 500;

  PcConnection({required this.deviceId});

  Future<void> connect({required String host, required int port, required String? token}) async {
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
        _statusController.add(ConnectionStatus(
          connected: true,
          needsPairing: false,
          pcName: obj['pcName'] as String?,
        ));
        return;
      }

      if (type == 'authRequired') {
        _statusController.add(const ConnectionStatus(
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
        _statusController.add(ConnectionStatus(
          connected: false,
          needsPairing: false,
          error: obj['message'] as String? ?? 'Unknown error',
        ));
      }
    } catch (_) {
      // ignore
    }
  }

  Future<String?> pair({required String code, required String deviceName}) async {
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
    _send({'v': 1, 'type': 'launch', 'command': command, if (args != null) 'args': args});
  }

  void _send(Map<String, dynamic> obj) {
    final ch = _channel;
    if (ch == null) return;
    ch.sink.add(jsonEncode(obj));
  }

  void _scheduleReconnect(String reason) {
    _statusController.add(ConnectionStatus(connected: false, needsPairing: false, error: reason));

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
  }
}

class TextDiff {
  final int backspaces;
  final String inserted;

  TextDiff(this.backspaces, this.inserted);

  static TextDiff compute(String oldText, String newText) {
    if (oldText == newText) return TextDiff(0, '');

    var prefix = 0;
    final minLen = oldText.length < newText.length ? oldText.length : newText.length;
    while (prefix < minLen && oldText.codeUnitAt(prefix) == newText.codeUnitAt(prefix)) {
      prefix++;
    }

    final oldSuffix = oldText.substring(prefix);
    final newSuffix = newText.substring(prefix);

    // Only support backspacing + appending. For edits in the middle, this still works
    // (backspaces to prefix, then insert new suffix).
    return TextDiff(oldSuffix.length, newSuffix);
  }
}
