import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'session_crypto.dart';

/// Trust-on-first-use for LAN WSS. Callback must be synchronous for [HttpClient.badCertificateCallback].
class TofuPinStore {
  static final Map<String, String> _mem = {};

  static String _prefsKey(String host, int port) => 'tofu_cert_${host}_$port';

  static String _memKey(String host, int port) => '$host:$port';

  static Future<void> primeFromDisk() async {
    final p = await SharedPreferences.getInstance();
    final keys = p.getKeys().where((k) => k.startsWith('tofu_cert_'));
    for (final k in keys) {
      final v = p.getString(k);
      if (v == null) continue;
      final rest = k.substring('tofu_cert_'.length);
      final idx = rest.lastIndexOf('_');
      if (idx <= 0 || idx >= rest.length - 1) continue;
      final host = rest.substring(0, idx);
      final port = int.tryParse(rest.substring(idx + 1));
      if (port == null) continue;
      _mem[_memKey(host, port)] = v;
    }
  }

  static Future<void> savePin(String host, int port, String fingerprintHex) async {
    _mem[_memKey(host, port)] = fingerprintHex;
    final p = await SharedPreferences.getInstance();
    await p.setString(_prefsKey(host, port), fingerprintHex);
  }

  static Future<void> clearPin(String host, int port) async {
    _mem.remove(_memKey(host, port));
    final p = await SharedPreferences.getInstance();
    await p.remove(_prefsKey(host, port));
  }

  /// Clears all TOFU pins (e.g. after PC cert rotation). Next WSS connect re-pins.
  static Future<void> clearAllTrust() async {
    _mem.clear();
    final p = await SharedPreferences.getInstance();
    final keys = p.getKeys().where((k) => k.startsWith('tofu_cert_')).toList();
    for (final k in keys) {
      await p.remove(k);
    }
  }

  static void clearMemoryOnly() => _mem.clear();

  /// Sync callback for [HttpClient.badCertificateCallback].
  static bool verifyServerCertSync(X509Certificate cert, String host, int port) {
    final fp = certFingerprintDer(cert.der);
    final key = _memKey(host, port);
    final existing = _mem[key];
    if (existing == null) {
      _mem[key] = fp;
      SharedPreferences.getInstance().then((p) => p.setString(_prefsKey(host, port), fp));
      return true;
    }
    return existing == fp;
  }
}
