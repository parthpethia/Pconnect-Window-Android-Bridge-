import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// HKDF-SHA256 + HMAC matching desktop `SessionKeyDerivation` / `CommandIntegrity`.
class SessionCrypto {
  static const _integrityInfo = 'pconnect/v1/integrity';

  static Uint8List deriveIntegrityKeyBytes(Uint8List ikm32, Uint8List salt16) {
    final prk = _hkdfExtract(ikm32, salt16);
    return Uint8List.fromList(_hkdfExpand(prk, utf8.encode(_integrityInfo), 32));
  }

  static List<int> _hkdfExtract(Uint8List ikm, Uint8List salt) {
    final key = salt.isEmpty ? Uint8List(32) : salt;
    final h = Hmac(sha256, key);
    return h.convert(ikm).bytes;
  }

  static List<int> _hkdfExpand(List<int> prk, List<int> info, int length) {
    final out = <int>[];
    var t = <int>[];
    var counter = 0;
    while (out.length < length) {
      counter++;
      final data = <int>[...t, ...info, counter];
      t = Hmac(sha256, Uint8List.fromList(prk)).convert(data).bytes;
      out.addAll(t);
    }
    return out.sublist(0, length);
  }

  static String commandMacSync(Uint8List integrityKey32, int seq, String canon) {
    final h = Hmac(sha256, integrityKey32);
    return base64Encode(h.convert(utf8.encode('$seq|$canon')).bytes);
  }

  static Uint8List? parseSessionNonce(String? hex) {
    if (hex == null || hex.length != 32) return null;
    try {
      final out = Uint8List(16);
      for (var i = 0; i < 16; i++) {
        out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  static Uint8List? parseTokenHex(String? token) {
    if (token == null || token.length != 64) return null;
    try {
      final out = Uint8List(32);
      for (var i = 0; i < 32; i++) {
        out[i] = int.parse(token.substring(i * 2, i * 2 + 2), radix: 16);
      }
      return out;
    } catch (_) {
      return null;
    }
  }
}

String certFingerprintDer(List<int> der) => sha256.convert(der).toString();
