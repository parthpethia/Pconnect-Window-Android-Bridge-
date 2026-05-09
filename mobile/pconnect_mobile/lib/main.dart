import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'services/connection.dart';
import 'screens/home_screen.dart';
import 'screens/control_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/logs_screen.dart';
import 'screens/discovery_screen.dart';

/// Global notification plugin instance used by utils/notifications.dart.
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize local notifications
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const initSettings = InitializationSettings(android: androidInit);
  await flutterLocalNotificationsPlugin.initialize(initSettings);

  // Request POST_NOTIFICATIONS permission on Android 13+ (API 33)
  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();

  runApp(const PconnectApp());
}

// ── Theme ──

class AppThemeController extends ValueNotifier<ThemeMode> {
  static const String _prefsKey = 'theme_mode';
  AppThemeController() : super(ThemeMode.dark);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    value = switch (raw) {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    };
  }

  Future<void> setMode(ThemeMode mode) async {
    value = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, mode == ThemeMode.dark ? 'dark' : mode == ThemeMode.light ? 'light' : 'system');
  }

  Future<void> toggle() async {
    await setMode(value == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark);
  }
}

class ThemeControllerScope extends InheritedWidget {
  final AppThemeController controller;
  const ThemeControllerScope({super.key, required this.controller, required super.child});
  static AppThemeController of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<ThemeControllerScope>()!.controller;
  }
  @override
  bool updateShouldNotify(ThemeControllerScope oldWidget) => controller != oldWidget.controller;
}

// ── App ──

class PconnectApp extends StatefulWidget {
  const PconnectApp({super.key});
  @override
  State<PconnectApp> createState() => _PconnectAppState();
}

class _PconnectAppState extends State<PconnectApp> {
  final _themeController = AppThemeController();

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

  static const _seed = Color(0xFF6C5CE7);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: _themeController,
      builder: (context, themeMode, _) {
        return ThemeControllerScope(
          controller: _themeController,
          child: MaterialApp(
            title: 'Pconnect',
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              useMaterial3: true,
              colorSchemeSeed: _seed,
              brightness: Brightness.light,
            ),
            darkTheme: ThemeData(
              useMaterial3: true,
              colorSchemeSeed: _seed,
              brightness: Brightness.dark,
            ),
            themeMode: themeMode,
            home: const MainShell(),
          ),
        );
      },
    );
  }
}

// ── Main Shell with bottom nav ──

class MainShell extends StatefulWidget {
  const MainShell({super.key});
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  final _uuid = const Uuid();
  int _currentIndex = 0;

  PcConnection? _conn;
  String _deviceId = '';
  String? _token;
  String? _lastHost;
  int _lastPort = kWsPortDefault;
  ConnectionStatus _status = ConnectionStatus.disconnected;

  @override
  void initState() {
    super.initState();
    _bootstrap();
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
    super.dispose();
  }

  Future<void> _connectHost(String host, int port) async {
    _conn?.dispose();
    final conn = PcConnection(deviceId: _deviceId);
    setState(() { _conn = conn; _status = ConnectionStatus.disconnected; });

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
  }

  Future<void> _pair(String code) async {
    final conn = _conn;
    if (conn == null || code.isEmpty) return;
    final token = await conn.pair(code: code, deviceName: 'Android');
    if (token == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('token', token);
    _token = token;
  }

  void _openDiscovery() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DiscoveryScreen(
        deviceId: _deviceId,
        onConnect: (host, port) => _connectHost(host, port),
        onPair: (code) => _pair(code),
        status: _status,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final conn = _conn;

    final screens = [
      HomeScreen(
        conn: conn,
        status: _status,
        onOpenDiscovery: _openDiscovery,
      ),
      ControlScreen(conn: conn, status: _status),
      SettingsScreen(
        conn: conn,
        status: _status,
        onDisconnect: () {
          _conn?.dispose();
          setState(() { _conn = null; _status = ConnectionStatus.disconnected; });
        },
      ),
      LogsScreen(conn: conn, status: _status),
    ];

    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (i) => setState(() => _currentIndex = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_rounded), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.gamepad_rounded), label: 'Control'),
          NavigationDestination(icon: Icon(Icons.settings_rounded), label: 'Settings'),
          NavigationDestination(icon: Icon(Icons.receipt_long_rounded), label: 'Logs'),
        ],
      ),
    );
  }
}
