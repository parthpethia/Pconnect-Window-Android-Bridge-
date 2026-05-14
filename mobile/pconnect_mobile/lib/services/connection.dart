import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../utils/notifications.dart';
import 'pc_websocket.dart';
import 'session_crypto.dart';

const int kWsPortDefault = 47821;
const int kDefaultWssPort = 47824;
const int kDiscoveryPort = 47822;
const String kDiscoverProbe = 'PCONNECT_DISCOVER_V1';

class DiscoveredPc {
  final String name;
  final InternetAddress address;
  final int wsPort;
  final int? wssPort;
  DiscoveredPc({required this.name, required this.address, required this.wsPort, this.wssPort});
}

class ConnectionStatus {
  final bool connected;
  final bool needsPairing;
  final String? pcName;
  final String? error;
  final String? role;

  const ConnectionStatus({
    required this.connected,
    required this.needsPairing,
    this.pcName,
    this.error,
    this.role,
  });

  static const disconnected = ConnectionStatus(connected: false, needsPairing: false);
}

class FileTransferProgress {
  final String filename;
  final int totalBytes;
  int transferredBytes;
  final DateTime startTime;
  final bool isDownload;

  FileTransferProgress({
    required this.filename,
    required this.totalBytes,
    required this.isDownload,
  })  : transferredBytes = 0,
        startTime = DateTime.now();

  double get progress => totalBytes > 0 ? transferredBytes / totalBytes : 0;
  int get elapsedSeconds => DateTime.now().difference(startTime).inSeconds;
  int get bytesPerSecond => elapsedSeconds > 0 ? transferredBytes ~/ elapsedSeconds : 0;
  int get etaSeconds => bytesPerSecond > 0 ? (totalBytes - transferredBytes) ~/ bytesPerSecond : 0;
  String get progressStr => '${(progress * 100).toStringAsFixed(1)}%';
}

class RemoteFile {
  final String path;
  final String name;
  final int modified;
  final int size;
  RemoteFile({required this.path, required this.name, required this.modified, required this.size});

  String get sizeStr {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

class AppEntry {
  final String name;
  final String? iconBase64;
  final String exePath;
  AppEntry({required this.name, this.iconBase64, required this.exePath});
}

class CustomCommand {
  final String label;
  final String command;
  CustomCommand({required this.label, required this.command});
}

class LogEntry {
  final String time;
  final String device;
  final String action;
  LogEntry({required this.time, required this.device, required this.action});
}

class PcConnection {
  final String deviceId;

  final _statusController = StreamController<ConnectionStatus>.broadcast();
  Stream<ConnectionStatus> get statusStream => _statusController.stream;

  final ValueNotifier<ConnectionStatus> statusNotifier = ValueNotifier(ConnectionStatus.disconnected);
  ConnectionStatus get currentStatus => statusNotifier.value;

  final ValueNotifier<List<String>> clipboardHistoryNotifier = ValueNotifier([]);
  final ValueNotifier<Map<String, FileTransferProgress>> activeTransfersNotifier = ValueNotifier({});
  final ValueNotifier<List<RemoteFile>> recentFilesNotifier = ValueNotifier([]);
  final ValueNotifier<List<AppEntry>> appListNotifier = ValueNotifier([]);
  final ValueNotifier<List<CustomCommand>> commandListNotifier = ValueNotifier([]);
  final ValueNotifier<List<LogEntry>> logEntriesNotifier = ValueNotifier([]);
  final ValueNotifier<Uint8List?> screenFrameNotifier = ValueNotifier(null);

  WebSocketChannel? _channel;
  StreamSubscription? _sub;

  String? _host;
  int? _port;
  int? _wssPort;
  String? _token;
  String? _lastClipboardContent;
  bool _disposed = false;

  Uint8List? _sessionNonceBytes;
  Uint8List? _integrityKeyBytes;
  int _cmdSeq = 0;
  String? _lastTransportTrace;

  Timer? _reconnectTimer;
  int _reconnectDelayMs = 500;

  Completer<Map<String, dynamic>>? _diagCompleter;

  PcConnection({required this.deviceId});

  void _setStatus(ConnectionStatus s) {
    if (_disposed) return;
    statusNotifier.value = s;
    if (!_statusController.isClosed) {
      _statusController.add(s);
    }
  }

  Future<void> connect({required String host, required int port, required String? token, int? wssPort}) async {
    _host = host;
    _port = port;
    _wssPort = wssPort;
    _token = token;
    await _connectInternal();
  }

  Future<void> _connectInternal() async {
    _reconnectTimer?.cancel();
    final host = _host;
    final port = _port;
    if (host == null || port == null) return;

    _integrityKeyBytes = null;
    _cmdSeq = 0;

    try {
      final channel = await PcWebSocket.connectPreferred(
        host: host,
        wsPort: port,
      wssPort: _wssPort ?? kDefaultWssPort,
        preferTls: !kIsWeb && Platform.isAndroid,
        onTrace: (t, d) => _lastTransportTrace = '$t $d',
      );
      if (channel == null) {
        _scheduleReconnect('Connect failed (no channel)');
        return;
      }
      _channel = channel;
      _sub?.cancel();
      _sub = channel.stream.listen(
        (event) => unawaited(_onMessage(event)),
        onError: (e) => _scheduleReconnect('WebSocket error: $e'),
        onDone: () => _scheduleReconnect('Disconnected'),
        cancelOnError: true,
      );
      _send({
        'v': 1,
        'type': 'hello',
        'proto': 2,
        'clientVersion': '0.2.0+1',
        'deviceId': deviceId,
        if (_token != null) 'token': _token,
      });
    } catch (e) {
      _scheduleReconnect('Connect failed: $e');
    }
  }

  Future<void> _armIntegrityKey() async {
    _integrityKeyBytes = null;
    final tok = _token;
    final nonce = _sessionNonceBytes;
    if (tok == null || nonce == null) return;
    final tb = SessionCrypto.parseTokenHex(tok);
    if (tb == null) return;
    try {
      _integrityKeyBytes = SessionCrypto.deriveIntegrityKeyBytes(tb, nonce);
    } catch (_) {}
  }

  Map<String, dynamic> _withMac(String canon, Map<String, dynamic> payload) {
    final k = _integrityKeyBytes;
    if (k == null) return payload;
    _cmdSeq++;
    final mac = SessionCrypto.commandMacSync(k, _cmdSeq, canon);
    return {...payload, 'cmdSeq': _cmdSeq, 'cmdMac': mac};
  }

  Future<void> _onMessage(dynamic event) async {
    try {
      final obj = jsonDecode(event as String) as Map<String, dynamic>;
      final type = obj['type'];

      switch (type) {
        case 'welcome':
          _sessionNonceBytes = SessionCrypto.parseSessionNonce(obj['sessionNonce'] as String?);
          break;

        case 'helloAck':
          await _armIntegrityKey();
          _reconnectDelayMs = 500;
          _setStatus(ConnectionStatus(
            connected: true,
            needsPairing: false,
            pcName: obj['pcName'] as String?,
            role: obj['role'] as String?,
          ));
          break;

        case 'authRequired':
          _setStatus(const ConnectionStatus(connected: false, needsPairing: true));
          break;

        case 'paired':
          final token = obj['token'] as String?;
          if (token != null) _token = token;
          await _armIntegrityKey();
          break;

        case 'clipboardUpdate':
          try {
            final data = obj['data'] as String?;
            if (data != null && data.isNotEmpty) {
              final bytes = base64Decode(data);
              final text = utf8.decode(bytes);
              _lastClipboardContent = text;
              final history = clipboardHistoryNotifier.value;
              if (!history.contains(text)) {
                clipboardHistoryNotifier.value = [text, ...history.take(9)];
              }
            }
          } catch (_) {}
          break;

        case 'recentFilesList':
          try {
            final files = obj['files'] as List<dynamic>?;
            if (files != null) {
              recentFilesNotifier.value = files.map((f) => RemoteFile(
                path: f['path'] as String? ?? '',
                name: f['name'] as String? ?? '',
                modified: (f['modified'] as num?)?.toInt() ?? 0,
                size: (f['size'] as num?)?.toInt() ?? 0,
              )).toList();
            }
          } catch (_) {}
          break;

        case 'screenFrame':
          try {
            final data = obj['data'] as String?;
            if (data != null) {
              screenFrameNotifier.value = base64Decode(data);
            }
          } catch (_) {}
          break;

        case 'appList':
          try {
            final apps = obj['apps'] as List<dynamic>?;
            if (apps != null) {
              appListNotifier.value = apps.map((a) => AppEntry(
                name: a['name'] as String? ?? '',
                iconBase64: a['iconBase64'] as String?,
                exePath: a['exePath'] as String? ?? '',
              )).toList();
            }
          } catch (_) {}
          break;

        case 'commandList':
          try {
            final cmds = obj['commands'] as List<dynamic>?;
            if (cmds != null) {
              commandListNotifier.value = cmds.map((c) => CustomCommand(
                label: c['label'] as String? ?? '',
                command: c['command'] as String? ?? '',
              )).toList();
            }
          } catch (_) {}
          break;

        case 'logEntries':
          try {
            final entries = obj['entries'] as List<dynamic>?;
            if (entries != null) {
              logEntriesNotifier.value = entries.map((e) => LogEntry(
                time: e['time'] as String? ?? '',
                device: e['device'] as String? ?? '',
                action: e['action'] as String? ?? '',
              )).toList();
            }
          } catch (_) {}
          break;

        case 'notification':
          final notifAppName = obj['appName'] as String? ?? '';
          final notifTitle = obj['title'] as String? ?? '';
          final notifBody = obj['body'] as String? ?? '';
          showMirroredNotification(
            appName: notifAppName,
            title: notifTitle,
            body: notifBody,
          );
          _onNotification?.call(notifTitle, notifBody, notifAppName);
          break;

        case 'networkDiagnostics':
          if (_diagCompleter != null && !_diagCompleter!.isCompleted) {
            _diagCompleter!.complete(obj);
          }
          break;

        case 'error':
          final msg = obj['message'] as String? ?? 'Unknown error';
          final cur = currentStatus;
          _setStatus(ConnectionStatus(
            connected: cur.connected,
            needsPairing: cur.needsPairing,
            pcName: cur.pcName,
            error: msg,
            role: cur.role,
          ));
          break;
      }
    } catch (_) {}
  }

  String? get lastTransportTrace => _lastTransportTrace;

  Future<Map<String, dynamic>?> fetchNetworkDiagnostics() async {
    if (!currentStatus.connected) return null;
    final c = Completer<Map<String, dynamic>>();
    _diagCompleter = c;
    _send({'v': 1, 'type': 'networkDiagnostics'});
    try {
      return await c.future.timeout(const Duration(seconds: 8));
    } catch (_) {
      return null;
    } finally {
      if (_diagCompleter == c) {
        _diagCompleter = null;
      }
    }
  }

  // Notification callback
  void Function(String title, String body, String appName)? _onNotification;
  set onNotification(void Function(String title, String body, String appName)? cb) {
    _onNotification = cb;
  }

  Future<String?> pair({required String code, required String deviceName}) async {
    final tokenBefore = _token;
    _send({
      'v': 1, 'type': 'pair',
      'deviceId': deviceId, 'deviceName': deviceName, 'code': code,
    });
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (_token != null && _token != tokenBefore) return _token;
    }
    return null;
  }

  // ── Input Control ──
  void lockPc() => _send({'v': 1, 'type': 'lock'});

  void sendInput({required int backspaces, required String text}) {
    _send({'v': 1, 'type': 'input', 'backspaces': backspaces, 'text': text});
  }

  void launchApp(String command, {List<String>? args}) {
    final argCanon = (args == null || args.isEmpty) ? '' : args.join('\x1e');
    _send(_withMac('launch|$command|$argCanon', {'v': 1, 'type': 'launch', 'command': command, if (args != null) 'args': args}));
  }

  void launchAppByPath(String exePath) {
    _send(_withMac('launchapp|$exePath', {'v': 1, 'type': 'launchApp', 'exePath': exePath}));
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
    _send({'v': 1, 'type': 'key', 'vk': vk, 'action': 'press', if (extended) 'extended': true});
  }

  void keyDown({required int vk, bool extended = false}) {
    _send({'v': 1, 'type': 'key', 'vk': vk, 'action': 'down', if (extended) 'extended': true});
  }

  void keyUp({required int vk, bool extended = false}) {
    _send({'v': 1, 'type': 'key', 'vk': vk, 'action': 'up', if (extended) 'extended': true});
  }

  void keyCombo(List<String> keys) {
    _send({'v': 1, 'type': 'keyCombo', 'keys': keys});
  }

  void mediaKey(String key) {
    _send({'v': 1, 'type': 'mediaKey', 'key': key});
  }

  void setVolume({required int level}) {
    _send({'v': 1, 'type': 'setVolume', 'level': level.clamp(0, 100)});
  }

  void setBrightness({required int level}) {
    _send({'v': 1, 'type': 'setBrightness', 'level': level.clamp(0, 100)});
  }

  void shutdownPc({required String password}) {
    _send(_withMac('shutdown|$password', {'v': 1, 'type': 'shutdown', 'password': password}));
  }

  // ── Clipboard ──
  void setClipboard({required String text}) {
    if (text == _lastClipboardContent) return;
    _lastClipboardContent = text;
    final encoded = base64Encode(utf8.encode(text));
    _send({'v': 1, 'type': 'clipboardSet', 'data': encoded, 'format': 'text/plain'});
  }

  // ── Screen Capture ──
  void startScreenCapture({int intervalMs = 1000, int width = 720, int quality = 65}) {
    _send({'v': 1, 'type': 'screenCaptureStart', 'intervalMs': intervalMs, 'width': width, 'quality': quality});
  }

  void stopScreenCapture() {
    _send({'v': 1, 'type': 'screenCaptureStop'});
    screenFrameNotifier.value = null;
  }

  // ── App List ──
  void requestAppList() {
    _send({'v': 1, 'type': 'getAppList'});
  }

  // ── Custom Commands ──
  void requestCommands() {
    _send({'v': 1, 'type': 'getCommands'});
  }

  void runCommand(int index) {
    _send(_withMac('runcommand|$index', {'v': 1, 'type': 'runCommand', 'index': index}));
  }

  // ── Settings ──
  void settingsSync({required bool autoLockOnDisconnect}) {
    _send(_withMac('settingsSync|$deviceId|$autoLockOnDisconnect', {
      'v': 1,
      'type': 'settingsSync',
      'autoLockOnDisconnect': autoLockOnDisconnect,
    }));
  }

  // ── Audit Log ──
  void requestLogs(String date) {
    _send({'v': 1, 'type': 'getLogs', 'date': date});
  }

  // ── File Transfer ──
  void requestRecentFiles({int limit = 20}) {
    _send({'v': 1, 'type': 'listRecentFiles', 'limit': limit});
  }

  Future<void> uploadFile(String filePath, {required Function(FileTransferProgress) onProgress}) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return;
      final bytes = await file.readAsBytes();
      // Use Uri to correctly extract filename on both Windows and Unix paths
      final filename = file.uri.pathSegments.last;
      final transferId = const Uuid().v4();

      final progress = FileTransferProgress(filename: filename, totalBytes: bytes.length, isDownload: false);
      activeTransfersNotifier.value = {...activeTransfersNotifier.value, transferId: progress};

      _send({'v': 1, 'type': 'fileTransferStart', 'id': transferId, 'filename': filename, 'size': bytes.length, 'direction': 'upload'});
      await Future<void>.delayed(const Duration(milliseconds: 200));

      const chunkSize = 50 * 1024;
      final totalChunks = (bytes.length / chunkSize).ceil();
      for (int i = 0; i < totalChunks; i++) {
        final start = i * chunkSize;
        final end = (start + chunkSize).clamp(0, bytes.length);
        final chunk = bytes.sublist(start, end);
        _send({'v': 1, 'type': 'fileTransferChunk', 'id': transferId, 'chunkIndex': i, 'totalChunks': totalChunks, 'data': base64Encode(chunk), 'size': chunk.length});
        progress.transferredBytes = end;
        onProgress(progress);
        activeTransfersNotifier.value = {...activeTransfersNotifier.value, transferId: progress};
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      _send({'v': 1, 'type': 'fileTransferComplete', 'id': transferId});
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final updated = Map<String, FileTransferProgress>.from(activeTransfersNotifier.value);
      updated.remove(transferId);
      activeTransfersNotifier.value = updated;
    } catch (_) {}
  }

  void _send(Map<String, dynamic> obj) {
    if (_disposed) return;
    final ch = _channel;
    if (ch == null) { _scheduleReconnect('Not connected'); return; }
    try { ch.sink.add(jsonEncode(obj)); }
    catch (e) { _scheduleReconnect('Send failed: $e'); }
  }

  void _scheduleReconnect(String reason) {
    if (_disposed) return;
    _setStatus(ConnectionStatus(
      connected: false, needsPairing: false, error: reason,
      pcName: currentStatus.pcName, role: currentStatus.role,
    ));
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: _reconnectDelayMs), () {
      if (_disposed) return;
      _reconnectDelayMs = (_reconnectDelayMs * 2).clamp(500, 5000);
      unawaited(_connectInternal());
    });
  }

  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    _statusController.close();
    statusNotifier.dispose();
  }
}

class DiscoveryClient {
  static Future<List<DiscoveredPc>> discover({required Duration timeout}) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    final results = <DiscoveredPc>[];
    final seen = <String>{};

    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = socket.receive();
      if (dg == null) return;
      try {
        final obj = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
        if (obj['type'] != 'discoverResponse') return;
        final name = (obj['pcName'] as String?) ?? dg.address.address;
        final port = (obj['wsPort'] as num?)?.toInt() ?? kWsPortDefault;
        final wssPort = (obj['wssPort'] as num?)?.toInt();
        final key = '${dg.address.address}:$port';
        if (seen.add(key)) {
          results.add(DiscoveredPc(name: name, address: dg.address, wsPort: port, wssPort: wssPort));
        }
      } catch (_) {}
    });

    socket.send(utf8.encode(kDiscoverProbe), InternetAddress('255.255.255.255'), kDiscoveryPort);
    await Future<void>.delayed(timeout);
    socket.close();
    return results;
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
    return TextDiff(oldText.substring(prefix).length, newText.substring(prefix));
  }
}
