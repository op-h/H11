// Emits a deterministic IK / IKpsk1 transcript as JSON so an independent
// Noise implementation (tool/noise_interop.py) can check it byte-for-byte.
import 'dart:convert';
import 'dart:typed_data';

import 'package:midad/core/noise.dart';

String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
Uint8List fill(int v) => Uint8List.fromList(List.filled(32, v));

Future<Map<String, Object?>> run(bool withPsk) async {
  final iS = await KeyPair25519.fromPrivate(fill(1));
  final rS = await KeyPair25519.fromPrivate(fill(2));
  final iE = await KeyPair25519.fromPrivate(fill(3));
  final rE = await KeyPair25519.fromPrivate(fill(4));
  final psk = withPsk ? fill(9) : null;
  final prologue = utf8.encode('midad/1');

  final ini = IKHandshake.initiator(
      s: iS, responderStatic: rS.publicKey, psk: psk, prologue: prologue)
    ..setEphemeralForTest(iE);
  final res = IKHandshake.responder(s: rS, psk: psk, prologue: prologue)
    ..setEphemeralForTest(rE);

  final m1 = await ini.writeMessage1(utf8.encode('hello'));
  final p1 = await res.readMessage1(m1);
  final (m2, rSess) = await res.writeMessage2(utf8.encode('world'));
  final (p2, iSess) = await ini.readMessage2(m2);
  final t1 = await iSess.send.encrypt(const [], utf8.encode('transport-1'));
  final d1 = await rSess.recv.decrypt(const [], t1);
  final t2 = await rSess.send.encrypt(const [], utf8.encode('transport-2'));
  final d2 = await iSess.recv.decrypt(const [], t2);
  return {
    'protocol': ini.protocolName,
    'p1': utf8.decode(p1),
    'p2': utf8.decode(p2),
    'd1': utf8.decode(d1),
    'd2': utf8.decode(d2),
    'msg1': hex(m1),
    'msg2': hex(m2),
    't1': hex(t1),
    't2': hex(t2),
    'hash': hex(iSess.handshakeHash),
    'hash_match': hex(iSess.handshakeHash) == hex(rSess.handshakeHash),
  };
}

Future<void> main() async {
  print(jsonEncode([await run(false), await run(true)]));
}
