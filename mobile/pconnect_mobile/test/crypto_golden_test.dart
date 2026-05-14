import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pconnect_mobile/services/session_crypto.dart';

String _hex(Uint8List b) => b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

Uint8List _fromHex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

void main() {
  test('HKDF integrity key matches desktop golden (pconnect/v1)', () {
    final ikm = Uint8List.fromList(List<int>.generate(32, (i) => i));
    final salt = Uint8List.fromList(List<int>.generate(16, (i) => i + 0x40));
    final key = SessionCrypto.deriveIntegrityKeyBytes(ikm, salt);
    expect(_hex(key).toLowerCase(), 'ea55716a99cf6b48d8d5129b256226a6f2464efd7112b06d850a719c5f7eec5b');
  });

  test('HMAC command MAC matches desktop golden', () {
    final integrity = _fromHex('EA55716A99CF6B48D8D5129B256226A6F2464EFD7112B06D850A719C5F7EEC5B');
    final mac = SessionCrypto.commandMacSync(integrity, 1, 'shutdown|1326');
    expect(mac, '3nT4/roLH63Dd20w7/2x/aIh6PnNR9QHG9NcL/giUmI=');
  });
}
