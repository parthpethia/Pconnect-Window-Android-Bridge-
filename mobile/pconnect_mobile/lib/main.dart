import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
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

class AppThemeController extends ValueNotifier<ThemeMode> {
  static const String _prefsKey = 'theme_mode';

  AppThemeController() : super(ThemeMode.light);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    value = switch (raw) {
      'dark' => ThemeMode.dark,
      'light' => ThemeMode.light,
      _ => ThemeMode.light,
    };
  }

  Future<void> toggle() async {
    value = value == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _prefsKey, value == ThemeMode.dark ? 'dark' : 'light');
  }
}

class ThemeControllerScope extends InheritedWidget {
  final AppThemeController controller;

  const ThemeControllerScope({
    super.key,
    required this.controller,
    required super.child,
  });

  static AppThemeController of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<ThemeControllerScope>();
    assert(scope != null, 'ThemeControllerScope not found in widget tree');
    return scope!.controller;
  }

  @override
  bool updateShouldNotify(ThemeControllerScope oldWidget) =>
      controller != oldWidget.controller;
}

class ThemeToggleButton extends StatelessWidget {
  const ThemeToggleButton({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = ThemeControllerScope.of(context);
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: controller,
      builder: (context, mode, _) {
        final isDark = mode == ThemeMode.dark;
        return IconButton(
          tooltip: isDark ? 'Light mode' : 'Dark mode',
          icon: Icon(isDark ? Icons.light_mode : Icons.dark_mode),
          onPressed: () => unawaited(controller.toggle()),
        );
      },
    );
  }
}

class PconnectApp extends StatefulWidget {
  const PconnectApp({super.key});

  @override
  State<PconnectApp> createState() => _PconnectAppState();
}

class _PconnectAppState extends State<PconnectApp> {
  final AppThemeController _themeController = AppThemeController();

  @override
  void initState() {
    super.initState();
    unawaited(_themeController.load());
  }

  @override
  void dispose() {
    _themeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: _themeController,
      builder: (context, themeMode, _) {
        return ThemeControllerScope(
          controller: _themeController,
          child: MaterialApp(
            title: 'Pconnect',
            theme: ThemeData(useMaterial3: true, brightness: Brightness.light),
            darkTheme:
                ThemeData(useMaterial3: true, brightness: Brightness.dark),
            themeMode: themeMode,
            home: const HomeScreen(),
          ),
        );
      },
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
            : 'Pconnect • ${_status.pcName}'),
        actions: const [ThemeToggleButton()],
      ),
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
            FilledButton.tonal(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ConnectivityScreen()),
                );
              },
              child: const Text('Wi‑Fi / Bluetooth'),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: connected ? () => _conn?.lockPc() : null,
              child: const Text('Lock PC'),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: connected
                  ? () async {
                      final conn = _conn;
                      if (conn == null) return;

                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (context) {
                          return AlertDialog(
                            title: const Text('Shut down PC?'),
                            content: const Text(
                                'Are you sure you want to shut down this PC?'),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.of(context).pop(false),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                onPressed: () =>
                                    Navigator.of(context).pop(true),
                                child: const Text('Shut down'),
                              ),
                            ],
                          );
                        },
                      );

                      if (confirmed == true) {
                        final pinController = TextEditingController();
                        final pin = await showDialog<String>(
                          context: context,
                          builder: (context) {
                            return AlertDialog(
                              title: const Text('Enter shutdown password'),
                              content: TextField(
                                controller: pinController,
                                keyboardType: TextInputType.number,
                                obscureText: true,
                                decoration: const InputDecoration(
                                  labelText: 'Password',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(context).pop(),
                                  child: const Text('Cancel'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.of(context)
                                      .pop(pinController.text.trim()),
                                  child: const Text('Continue'),
                                ),
                              ],
                            );
                          },
                        );

                        if (pin != null && pin.isNotEmpty) {
                          conn.shutdownPc(password: pin);
                        }
                      }
                    }
                  : null,
              child: const Text('Shut down PC'),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: connected
                  ? () {
                      final conn = _conn;
                      if (conn == null) return;
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => VolumeBrightnessScreen(
                          conn: conn,
                          pcName: _status.pcName,
                          enabled: connected,
                        ),
                      ));
                    }
                  : null,
              child: const Text('Volume / Brightness'),
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
              onPressed: connected ? () => _conn?.launchApp('code') : null,
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
            const SizedBox(height: 12),
            FilledButton(
              onPressed: connected
                  ? () {
                      final conn = _conn;
                      if (conn == null) return;
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => ClipboardSyncScreen(
                          conn: conn,
                          pcName: _status.pcName,
                        ),
                      ));
                    }
                  : null,
              child: const Text('Clipboard Sync'),
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
        title: Text(pcName == null ? 'Keyboard' : 'Keyboard • $pcName'),
        actions: const [ThemeToggleButton()],
      ),
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

class ConnectivityScreen extends StatefulWidget {
  const ConnectivityScreen({super.key});

  @override
  State<ConnectivityScreen> createState() => _ConnectivityScreenState();
}

class _ConnectivityScreenState extends State<ConnectivityScreen> {
  static const MethodChannel _channel = MethodChannel('pconnect/connectivity');

  final Connectivity _connectivity = Connectivity();
  final NetworkInfo _networkInfo = NetworkInfo();

  StreamSubscription<List<ConnectivityResult>>? _connSub;

  List<ConnectivityResult> _results = const [];
  String? _wifiName;
  String? _wifiIp;
  String? _wifiError;

  bool? _bluetoothEnabled;
  List<Map<String, String>> _bluetoothBonded = const [];
  List<Map<String, String>> _bluetoothConnected = const [];
  String? _bluetoothError;

  @override
  void initState() {
    super.initState();
    _connSub = _connectivity.onConnectivityChanged.listen((results) {
      setState(() => _results = results);
      unawaited(_refreshWifiInfo());
    });
    unawaited(_refreshAll());
  }

  @override
  void dispose() {
    _connSub?.cancel();
    super.dispose();
  }

  Future<void> _refreshAll() async {
    await _refreshConnectivity();
    await _refreshWifiInfo();
    await _refreshBluetoothInfo();
  }

  Future<void> _refreshConnectivity() async {
    try {
      final results = await _connectivity.checkConnectivity();
      if (!mounted) return;
      setState(() => _results = results);
    } catch (e) {
      // ignore
    }
  }

  Future<void> _refreshWifiInfo() async {
    if (!mounted) return;

    if (!_results.contains(ConnectivityResult.wifi)) {
      setState(() {
        _wifiName = null;
        _wifiIp = null;
        _wifiError = null;
      });
      return;
    }

    // SSID access is permission-gated on Android.
    if (Platform.isAndroid) {
      final statuses = await <Permission>[
        Permission.locationWhenInUse,
        Permission.nearbyWifiDevices,
      ].request();

      final anyGranted = statuses.values.any((s) => s.isGranted);
      if (!anyGranted) {
        setState(() {
          _wifiName = null;
          _wifiIp = null;
          _wifiError = 'Permission denied (needed to read Wi‑Fi name).';
        });
        return;
      }
    }

    try {
      var name = await _networkInfo.getWifiName();
      final ip = await _networkInfo.getWifiIP();
      name = _stripQuotes(name);
      if (!mounted) return;
      setState(() {
        _wifiName = name;
        _wifiIp = ip;
        _wifiError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _wifiName = null;
        _wifiIp = null;
        _wifiError = 'Wi‑Fi info unavailable: $e';
      });
    }
  }

  Future<void> _refreshBluetoothInfo() async {
    if (!Platform.isAndroid) {
      setState(() {
        _bluetoothEnabled = null;
        _bluetoothBonded = const [];
        _bluetoothConnected = const [];
        _bluetoothError = 'Bluetooth info is only implemented on Android.';
      });
      return;
    }

    final statuses = await <Permission>[
      Permission.bluetoothConnect,
    ].request();
    if (!statuses.values.any((s) => s.isGranted)) {
      setState(() {
        _bluetoothEnabled = null;
        _bluetoothBonded = const [];
        _bluetoothConnected = const [];
        _bluetoothError =
            'Permission denied (needed to read Bluetooth status).';
      });
      return;
    }

    try {
      final res = await _channel.invokeMethod<Map>('getBluetoothInfo');
      final map = (res ?? <dynamic, dynamic>{}).cast<dynamic, dynamic>();

      bool? enabled;
      if (map['enabled'] is bool) enabled = map['enabled'] as bool;

      List<Map<String, String>> parseDeviceList(dynamic v) {
        if (v is! List) return const [];
        return v
            .whereType<Map>()
            .map((e) => e.cast<dynamic, dynamic>())
            .map((e) => {
                  'name': (e['name'] as String?) ?? '',
                  'address': (e['address'] as String?) ?? '',
                })
            .toList(growable: false);
      }

      final bonded = parseDeviceList(map['bonded']);
      final connected = parseDeviceList(map['connected']);

      if (!mounted) return;
      setState(() {
        _bluetoothEnabled = enabled;
        _bluetoothBonded = bonded;
        _bluetoothConnected = connected;
        _bluetoothError = null;
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _bluetoothEnabled = null;
        _bluetoothBonded = const [];
        _bluetoothConnected = const [];
        _bluetoothError = e.message ?? e.toString();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _bluetoothEnabled = null;
        _bluetoothBonded = const [];
        _bluetoothConnected = const [];
        _bluetoothError = e.toString();
      });
    }
  }

  void _openWifiPanel() {
    if (!Platform.isAndroid) return;
    unawaited(const AndroidIntent(action: 'android.settings.panel.action.WIFI')
        .launch());
  }

  void _openBluetoothPanel() {
    if (!Platform.isAndroid) return;
    unawaited(
        const AndroidIntent(action: 'android.settings.panel.action.BLUETOOTH')
            .launch());
  }

  static String? _stripQuotes(String? s) {
    if (s == null) return null;
    final t = s.trim();
    if (t.length >= 2 && t.startsWith('"') && t.endsWith('"')) {
      return t.substring(1, t.length - 1);
    }
    return t;
  }

  @override
  Widget build(BuildContext context) {
    final wifiConnected = _results.contains(ConnectivityResult.wifi);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Wi‑Fi / Bluetooth'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => unawaited(_refreshAll()),
            icon: const Icon(Icons.refresh),
          ),
          const ThemeToggleButton(),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Wi‑Fi', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(wifiConnected ? 'Connected' : 'Not connected'),
          if (_wifiName != null) Text('Network: ${_wifiName!}'),
          if (_wifiIp != null) Text('Phone IP: ${_wifiIp!}'),
          if (_wifiError != null) ...[
            const SizedBox(height: 6),
            Text(
              _wifiError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 8),
          FilledButton.tonal(
            onPressed: Platform.isAndroid ? _openWifiPanel : null,
            child: const Text('Open Wi‑Fi panel'),
          ),
          const SizedBox(height: 24),
          Text('Bluetooth', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_bluetoothEnabled != null)
            Text(_bluetoothEnabled! ? 'Enabled' : 'Disabled')
          else
            const Text('Unknown'),
          if (_bluetoothConnected.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text('Connected devices:',
                style: TextStyle(fontWeight: FontWeight.w600)),
            for (final d in _bluetoothConnected)
              Text(
                  '${d['name']!.isEmpty ? '(unnamed)' : d['name']} • ${d['address']}'),
          ],
          if (_bluetoothBonded.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('Paired devices:',
                style: TextStyle(fontWeight: FontWeight.w600)),
            for (final d in _bluetoothBonded.take(8))
              Text(
                  '${d['name']!.isEmpty ? '(unnamed)' : d['name']} • ${d['address']}'),
            if (_bluetoothBonded.length > 8)
              Text('+${_bluetoothBonded.length - 8} more'),
          ],
          if (_bluetoothError != null) ...[
            const SizedBox(height: 6),
            Text(
              _bluetoothError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 8),
          FilledButton.tonal(
            onPressed: Platform.isAndroid ? _openBluetoothPanel : null,
            child: const Text('Open Bluetooth panel'),
          ),
        ],
      ),
    );
  }
}

class VolumeBrightnessScreen extends StatefulWidget {
  final PcConnection conn;
  final String? pcName;
  final bool enabled;

  const VolumeBrightnessScreen({
    super.key,
    required this.conn,
    required this.pcName,
    required this.enabled,
  });

  @override
  State<VolumeBrightnessScreen> createState() => _VolumeBrightnessScreenState();
}

class _VolumeBrightnessScreenState extends State<VolumeBrightnessScreen> {
  static const _prefsVolumeKey = 'last_volume_level';
  static const _prefsBrightnessKey = 'last_brightness_level';

  double _volume = 50;
  double _brightness = 50;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    unawaited(_loadLast());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _loadLast() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getInt(_prefsVolumeKey);
    final b = prefs.getInt(_prefsBrightnessKey);
    if (!mounted) return;
    setState(() {
      _volume = (v ?? 50).clamp(0, 100).toDouble();
      _brightness = (b ?? 50).clamp(0, 100).toDouble();
    });
  }

  void _sendDebounced({int? volume, int? brightness}) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 80), () async {
      if (!widget.enabled || !widget.conn.currentStatus.connected) return;

      final prefs = await SharedPreferences.getInstance();
      if (volume != null) {
        widget.conn.setVolume(level: volume);
        await prefs.setInt(_prefsVolumeKey, volume);
      }
      if (brightness != null) {
        widget.conn.setBrightness(level: brightness);
        await prefs.setInt(_prefsBrightnessKey, brightness);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.pcName == null
        ? 'Volume / Brightness'
        : 'Volume / Brightness • ${widget.pcName}';

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: const [ThemeToggleButton()],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ValueListenableBuilder<ConnectionStatus>(
          valueListenable: widget.conn.statusNotifier,
          builder: (context, status, _) {
            final connected = status.connected;
            final enabled = widget.enabled && connected;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (status.error != null) ...[
                  Text(
                    status.error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                ],
                Expanded(
                  child: Row(
                    children: [
                      Expanded(
                        child: _VerticalPercentSlider(
                          label: 'Volume',
                          value: _volume,
                          enabled: enabled,
                          onChanged: (v) {
                            setState(() => _volume = v);
                            _sendDebounced(volume: v.round());
                          },
                        ),
                      ),
                      const SizedBox(width: 24),
                      Expanded(
                        child: _VerticalPercentSlider(
                          label: 'Brightness',
                          value: _brightness,
                          enabled: enabled,
                          onChanged: (v) {
                            setState(() => _brightness = v);
                            _sendDebounced(brightness: v.round());
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  enabled ? 'Tip: drag the bars to adjust.' : 'Not connected.',
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

class _VerticalPercentSlider extends StatelessWidget {
  final String label;
  final double value;
  final bool enabled;
  final ValueChanged<double> onChanged;

  const _VerticalPercentSlider({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final slider = Slider(
      value: value,
      min: 0,
      max: 100,
      divisions: 100,
      label: '${value.round()}%',
      onChanged: enabled ? onChanged : null,
    );

    return Column(
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Expanded(
          child: Center(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 10,
              ),
              child: RotatedBox(
                quarterTurns: -1,
                child: slider,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text('${value.round()}%'),
      ],
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
        title: Text(pcName == null ? 'Trackpad' : 'Trackpad • $pcName'),
        actions: const [ThemeToggleButton()],
      ),
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

class ClipboardSyncScreen extends StatelessWidget {
  final PcConnection conn;
  final String? pcName;

  const ClipboardSyncScreen({
    required this.conn,
    required this.pcName,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(pcName ?? 'Clipboard Sync'),
      ),
      body: ValueListenableBuilder<ConnectionStatus>(
        valueListenable: conn.statusNotifier,
        builder: (context, status, _) {
          if (!status.connected) {
            return const Center(
              child: Text('Not connected to PC'),
            );
          }

          return ValueListenableBuilder<List<String>>(
            valueListenable: conn.clipboardHistoryNotifier,
            builder: (context, history, _) {
              return history.isEmpty
                  ? const Center(
                      child: Text('No clipboard sync yet'),
                    )
                  : ListView.builder(
                      itemCount: history.length,
                      itemBuilder: (context, index) {
                        final text = history[index];
                        return ListTile(
                          title: Text(
                            text.length > 100 ? '${text.substring(0, 100)}...' : text,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.copy),
                            onPressed: () {
                              conn.setClipboard(text: text);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Copied to PC clipboard')),
                              );
                            },
                          ),
                        );
                      },
                    );
            },
          );
        },
      ),
    );
  }
}

class PcConnection {
  final String deviceId;

  final _statusController = StreamController<ConnectionStatus>.broadcast();
  Stream<ConnectionStatus> get statusStream => _statusController.stream;

  final ValueNotifier<ConnectionStatus> statusNotifier =
      ValueNotifier(ConnectionStatus.disconnected);
  ConnectionStatus get currentStatus => statusNotifier.value;

  final ValueNotifier<List<String>> clipboardHistoryNotifier =
      ValueNotifier([]);

  WebSocketChannel? _channel;
  StreamSubscription? _sub;

  String? _host;
  int? _port;
  String? _token;
  String? _lastClipboardContent;

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

      if (type == 'clipboardUpdate') {
        try {
          final data = obj['data'] as String?;
          if (data != null && data.isNotEmpty) {
            final bytes = base64Decode(data);
            final text = utf8.decode(bytes);
            _lastClipboardContent = text;
            final history = clipboardHistoryNotifier.value;
            if (!history.contains(text)) {
              final newHistory = [text, ...history.take(9)];
              clipboardHistoryNotifier.value = newHistory;
            }
          }
        } catch (_) {
          // ignore
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

  void setVolume({required int level}) {
    _send({'v': 1, 'type': 'setVolume', 'level': level.clamp(0, 100)});
  }

  void setBrightness({required int level}) {
    _send({'v': 1, 'type': 'setBrightness', 'level': level.clamp(0, 100)});
  }

  void shutdownPc({required String password}) {
    _send({'v': 1, 'type': 'shutdown', 'password': password});
  }

  void setClipboard({required String text}) {
    if (text == _lastClipboardContent) return;
    _lastClipboardContent = text;

    final bytes = utf8.encode(text);
    final encoded = base64Encode(bytes);

    _send({
      'v': 1,
      'type': 'clipboardSet',
      'data': encoded,
      'format': 'text/plain',
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
