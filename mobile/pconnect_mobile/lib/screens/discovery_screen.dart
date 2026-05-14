import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/connection.dart';

// ─────────────────────────────────────────────────────
//  Connection profiles stored in shared_preferences
// ─────────────────────────────────────────────────────

class ConnectionProfile {
  String name;
  final String ip;
  final int port;
  final int? wssPort;
  String? deviceToken;
  DateTime? lastConnected;

  ConnectionProfile({
    required this.name,
    required this.ip,
    required this.port,
    this.wssPort,
    this.deviceToken,
    this.lastConnected,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'ip': ip,
    'port': port,
    if (wssPort != null) 'wssPort': wssPort,
    'deviceToken': deviceToken,
    'lastConnected': lastConnected?.toIso8601String(),
  };

  factory ConnectionProfile.fromJson(Map<String, dynamic> j) => ConnectionProfile(
    name: j['name'] as String? ?? '',
    ip: j['ip'] as String? ?? '',
    port: (j['port'] as num?)?.toInt() ?? kWsPortDefault,
    wssPort: (j['wssPort'] as num?)?.toInt(),
    deviceToken: j['deviceToken'] as String?,
    lastConnected: j['lastConnected'] != null ? DateTime.tryParse(j['lastConnected'] as String) : null,
  );
}

class ProfileStore {
  static const _key = 'connection_profiles';

  static Future<List<ConnectionProfile>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list.map((j) => ConnectionProfile.fromJson(j as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<ConnectionProfile> profiles) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(profiles.map((p) => p.toJson()).toList()));
  }

  static Future<void> upsert(ConnectionProfile p) async {
    final profiles = await load();
    final idx = profiles.indexWhere((x) => x.ip == p.ip && x.port == p.port);
    if (idx >= 0) {
      profiles[idx] = p;
    } else {
      profiles.insert(0, p);
    }
    await save(profiles);
  }

  static Future<void> remove(String ip, int port) async {
    final profiles = await load();
    profiles.removeWhere((x) => x.ip == ip && x.port == port);
    await save(profiles);
  }
}

// ─────────────────────────────────────────────────────
//  Discovery screen — mDNS scan + manual IP + QR + profiles
// ─────────────────────────────────────────────────────

class DiscoveryScreen extends StatefulWidget {
  final String deviceId;
  final void Function(String host, int port, int? wssPort) onConnect;
  final void Function(String code) onPair;
  final ConnectionStatus status;

  const DiscoveryScreen({
    super.key,
    required this.deviceId,
    required this.onConnect,
    required this.onPair,
    required this.status,
  });

  @override
  State<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends State<DiscoveryScreen> {
  final _ipController = TextEditingController();
  final _portController = TextEditingController(text: kWsPortDefault.toString());
  final _codeController = TextEditingController();

  List<DiscoveredPc> _discovered = [];
  List<ConnectionProfile> _profiles = [];
  bool _scanning = false;
  bool _showPairing = false;

  @override
  void initState() {
    super.initState();
    _loadProfiles();
    _scan();
  }

  @override
  void didUpdateWidget(DiscoveryScreen old) {
    super.didUpdateWidget(old);
    // Auto-dismiss discovery on successful auth, but only if this route is current
    if (widget.status.connected && !old.status.connected) {
      if (mounted) {
        final route = ModalRoute.of(context);
        if (route != null && route.isCurrent) {
          Navigator.of(context).pop();
        }
      }
    }
  }

  Future<void> _loadProfiles() async {
    final profiles = await ProfileStore.load();
    if (mounted) setState(() => _profiles = profiles);
  }

  Future<void> _scan() async {
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      final results = await DiscoveryClient.discover(timeout: const Duration(seconds: 3));
      if (mounted) setState(() => _discovered = results);
    } catch (_) {}
    if (mounted) setState(() => _scanning = false);
  }

  void _connectTo(String host, int port, {int? wssPort}) {
    widget.onConnect(host, port, wssPort);
    // Save / update profile
    ProfileStore.upsert(ConnectionProfile(
      name: host,
      ip: host,
      port: port,
      wssPort: wssPort,
      lastConnected: DateTime.now(),
    ));
    _showPairingOrPop();
  }

  void _showPairingOrPop() {
    // If already paired, pop back. Otherwise show pairing entry.
    Future.delayed(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      if (widget.status.connected) {
        Navigator.of(context).pop();
      } else if (widget.status.needsPairing) {
        setState(() => _showPairing = true);
      }
    });
  }

  void _submitCode() {
    final code = _codeController.text.trim();
    if (code.isEmpty) return;
    widget.onPair(code);
    _codeController.clear();
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted && widget.status.connected) {
        Navigator.of(context).pop();
      }
    });
  }

  void _openQrScanner() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _QrScanPage(
        onResult: (ip, port, code) {
          Navigator.of(context).pop();
          _ipController.text = ip;
          _portController.text = port.toString();
          _connectTo(ip, port, wssPort: kDefaultWssPort);
          if (code != null && code.isNotEmpty) {
            Future.delayed(const Duration(milliseconds: 600), () {
              if (mounted) widget.onPair(code);
            });
          }
        },
      ),
    ));
  }

  @override
  void dispose() {
    _ipController.dispose();
    _portController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Connect to PC'),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_scanner_rounded),
            tooltip: 'Scan QR Code',
            onPressed: _openQrScanner,
          ),
          IconButton(
            icon: _scanning
                ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary))
                : const Icon(Icons.refresh_rounded),
            tooltip: 'Scan network',
            onPressed: _scan,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Pairing section ──
          if (_showPairing || widget.status.needsPairing) ...[
            Card(
              color: cs.tertiaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Enter Pairing Code', style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: cs.onTertiaryContainer,
                    )),
                    const SizedBox(height: 4),
                    Text(
                      'Check the pairing code shown on the PC tray popup.',
                      style: TextStyle(fontSize: 12, color: cs.onTertiaryContainer.withOpacity(0.7)),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _codeController,
                            keyboardType: TextInputType.number,
                            maxLength: 6,
                            decoration: InputDecoration(
                              counterText: '',
                              hintText: '000000',
                              border: const OutlineInputBorder(),
                              filled: true,
                              fillColor: cs.surface,
                            ),
                            onSubmitted: (_) => _submitCode(),
                          ),
                        ),
                        const SizedBox(width: 12),
                        FilledButton(
                          onPressed: _submitCode,
                          child: const Text('Pair'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],

          // ── Discovered PCs ──
          if (_discovered.isNotEmpty) ...[
            Text('Discovered on Network', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            ...List.generate(_discovered.length, (i) {
              final pc = _discovered[i];
              return Card(
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: cs.primaryContainer,
                    child: Icon(Icons.computer_rounded, color: cs.onPrimaryContainer),
                  ),
                  title: Text(pc.name),
                  subtitle: Text('${pc.address.address}:${pc.wsPort}'),
                  trailing: FilledButton.tonal(
                    onPressed: () => _connectTo(pc.address.address, pc.wsPort, wssPort: pc.wssPort),
                    child: const Text('Connect'),
                  ),
                ),
              );
            }),
            const SizedBox(height: 20),
          ],

          // ── Saved profiles ──
          if (_profiles.isNotEmpty) ...[
            Text('Saved Profiles', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            ...List.generate(_profiles.length, (i) {
              final p = _profiles[i];
              return Card(
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: cs.secondaryContainer,
                    child: Icon(Icons.bookmark_rounded, color: cs.onSecondaryContainer),
                  ),
                  title: Text(p.name.isEmpty ? p.ip : p.name),
                  subtitle: Text('${p.ip}:${p.port}'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: Icon(Icons.delete_outline, color: cs.error),
                        onPressed: () async {
                          await ProfileStore.remove(p.ip, p.port);
                          await _loadProfiles();
                        },
                      ),
                      FilledButton.tonal(
                        onPressed: () => _connectTo(p.ip, p.port, wssPort: p.wssPort),
                        child: const Text('Connect'),
                      ),
                    ],
                  ),
                ),
              );
            }),
            const SizedBox(height: 20),
          ],

          // ── Manual IP entry ──
          Text('Manual Connection', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: _ipController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'IP Address',
                            hintText: '192.168.1.100',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _portController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Port',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () {
                        final ip = _ipController.text.trim();
                        final port = int.tryParse(_portController.text.trim()) ?? kWsPortDefault;
                        if (ip.isNotEmpty) _connectTo(ip, port, wssPort: kDefaultWssPort);
                      },
                      icon: const Icon(Icons.link_rounded),
                      label: const Text('Connect'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 32),

          // ── Status ──
          if (widget.status.error != null)
            Card(
              color: cs.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, color: cs.onErrorContainer, size: 20),
                    const SizedBox(width: 8),
                    Expanded(child: Text(widget.status.error!, style: TextStyle(color: cs.onErrorContainer, fontSize: 13))),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────
//  QR Scanner Page
// ─────────────────────────────────────────────────────

class _QrScanPage extends StatefulWidget {
  final void Function(String ip, int port, String? pairingCode) onResult;
  const _QrScanPage({required this.onResult});
  @override
  State<_QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<_QrScanPage> {
  MobileScannerController? _controller;
  bool _handled = false;
  bool _permissionGranted = false;
  bool _permissionDenied = false;
  bool _permissionPermanentlyDenied = false;
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    _requestCameraPermission();
  }

  Future<void> _requestCameraPermission() async {
    final status = await Permission.camera.request();
    if (!mounted) return;

    if (status.isGranted) {
      setState(() {
        _permissionGranted = true;
        _checking = false;
        _controller = MobileScannerController();
      });
    } else if (status.isPermanentlyDenied) {
      setState(() {
        _permissionPermanentlyDenied = true;
        _checking = false;
      });
    } else {
      setState(() {
        _permissionDenied = true;
        _checking = false;
      });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;
      try {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        final ip = json['ip'] as String?;
        final port = (json['port'] as num?)?.toInt() ?? kWsPortDefault;
        final code = json['pairingCode'] as String?;
        if (ip == null || ip.isEmpty) continue;
        _handled = true;
        widget.onResult(ip, port, code);
        return;
      } catch (_) {
        // Not our QR format, ignore
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Scan QR Code')),
      body: _checking
          ? const Center(child: CircularProgressIndicator())
          : _permissionPermanentlyDenied
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.camera_alt_outlined, size: 64, color: cs.error),
                        const SizedBox(height: 16),
                        Text(
                          'Camera Permission Required',
                          style: Theme.of(context).textTheme.titleLarge,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Camera access was permanently denied.\nPlease enable it in app settings to scan QR codes.',
                          style: TextStyle(color: cs.onSurfaceVariant),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 24),
                        FilledButton.icon(
                          onPressed: () => openAppSettings(),
                          icon: const Icon(Icons.settings),
                          label: const Text('Open Settings'),
                        ),
                      ],
                    ),
                  ),
                )
              : _permissionDenied
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.no_photography_outlined, size: 64, color: cs.error),
                            const SizedBox(height: 16),
                            Text(
                              'Camera Access Denied',
                              style: Theme.of(context).textTheme.titleLarge,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Camera permission is needed to scan QR codes.',
                              style: TextStyle(color: cs.onSurfaceVariant),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 24),
                            FilledButton.icon(
                              onPressed: _requestCameraPermission,
                              icon: const Icon(Icons.refresh),
                              label: const Text('Try Again'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : Stack(
                      children: [
                        MobileScanner(
                          controller: _controller!,
                          onDetect: _onDetect,
                        ),
                        Positioned(
                          bottom: 32,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: Card(
                              color: Colors.black54,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                child: Text(
                                  'Point at the QR code on the PC tray window',
                                  style: TextStyle(color: Colors.white.withOpacity(0.9)),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
    );
  }
}
