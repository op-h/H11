// Attack suite. Every test plays an attacker against a real computer-side
// engine listening on a real socket.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:midad/core/identity.dart';
import 'package:midad/core/model.dart';
import 'package:midad/core/noise.dart';
import 'package:midad/core/sync.dart';
import 'package:midad/core/wire.dart';

import 'helpers.dart';

Map<String, dynamic> _decodeOffer(String code) =>
    jsonDecode(utf8.decode(base64Url.decode(code.substring(8)))) as Map<String, dynamic>;

String _loopback(String code) {
  final j = _decodeOffer(code)..['h'] = ['127.0.0.1'];
  return 'midad:1:${base64Url.encode(utf8.encode(jsonEncode(j)))}';
}

/// A computer with one legitimately paired phone.
Future<(Node<HostEngine>, Node<ClientEngine>)> pairedPair() async {
  final pc = await makeHost();
  final phone = await makeClient();
  await phone.engine.pair(_loopback((await pc.engine.beginPairing()).code));
  await phone.engine.stop(); // tests drive the channel by hand
  return (pc, phone);
}

Session _session(String device, String body) =>
    Session.create(device)..body = body;

Future<bool> _closesSoon(Socket s, {Duration within = const Duration(seconds: 8)}) async {
  final done = Completer<bool>();
  s.listen((_) {}, onDone: () => done.complete(true), onError: (_) => done.complete(true));
  return done.future.timeout(within, onTimeout: () => false);
}

void main() {
  late Node<HostEngine> pc;
  late Node<ClientEngine> phone;
  late Uint8List pcPub;

  setUp(() async {
    (pc, phone) = await pairedPair();
    pcPub = pc.engine.identity.keys.publicKey;
  });
  tearDown(() async {
    await pc.engine.stop();
  });

  test('A1 unpaired device with the right server key is rejected', () async {
    final stranger = await KeyPair25519.generate();
    await expectLater(
        SecureChannel.connect('127.0.0.1', pc.engine.port,
            identity: stranger, serverStatic: pcPub),
        throwsA(anything));
    expect(pc.engine.links, isEmpty);
  });

  test('A2 impersonating the computer (MITM with its own key) fails', () async {
    // Attacker runs a fake "computer" and the phone is redirected to it.
    final fake = await makeHost();
    await expectLater(
        SecureChannel.connect('127.0.0.1', fake.engine.port,
            identity: phone.engine.identity.keys, serverStatic: pcPub),
        throwsA(anything),
        reason: 'phone pins the real computer key from the QR');
    await fake.engine.stop();
  });

  test('A3 pairing: closed when no QR is shown, wrong secret, reuse, expiry', () async {
    final k = await KeyPair25519.generate();
    final rnd = Uint8List.fromList(List.generate(32, (_) => Random.secure().nextInt(256)));
    // No QR shown.
    await expectLater(
        SecureChannel.connect('127.0.0.1', pc.engine.port,
            identity: k, serverStatic: pcPub, psk: rnd),
        throwsA(anything));
    // QR shown, attacker guesses the secret.
    final offer = await pc.engine.beginPairing();
    await expectLater(
        SecureChannel.connect('127.0.0.1', pc.engine.port,
            identity: k, serverStatic: pcPub, psk: rnd),
        throwsA(anything));
    // Legit scan works once...
    final other = await makeClient();
    await other.engine.pair(_loopback(offer.code));
    // ...and the same QR cannot be used again.
    final third = await makeClient();
    await expectLater(third.engine.pair(_loopback(offer.code)), throwsA(anything));
    // Expired QR.
    final short = await pc.engine.beginPairing(validFor: const Duration(milliseconds: 300));
    await Future.delayed(const Duration(milliseconds: 500));
    await expectLater(third.engine.pair(_loopback(short.code)), throwsA(anything));
    await other.engine.stop();
    await third.engine.stop();
  });

  test('A4 passive eavesdropper sees no text and no file bytes', () async {
    final proxy = await Proxy.start(pc.engine.port);
    const secret = 'TOP-SECRET-IDEA-7f3a';
    final fileBytes = utf8.encode('FILE-CONTENT-MARKER-91b2' * 100);
    final ch = await SecureChannel.connect('127.0.0.1', proxy.port,
        identity: phone.engine.identity.keys, serverStatic: pcPub);
    final src = File('${phone.dir.path}/n.txt')..writeAsBytesSync(fileBytes);
    final s = _session(phone.store.deviceId, secret)
      ..attachments.add(await phone.store.importFile(src));
    await phone.store.saveLocal(s);
    // Act as the phone: send the session, then answer the computer's want.
    final sub = ch.messages.listen((m) async {
      if (m is JsonMessage && m.body['t'] == 'want') {
        await ch.sendJson({'t': 'blob_begin', 'sha': m.body['sha'], 'from': 0});
        await ch.sendChunk(unhex(m.body['sha'] as String), fileBytes);
        await ch.sendJson({'t': 'blob_end', 'sha': m.body['sha']});
      }
    });
    await ch.sendJson({'t': 'session', 's': s.toJson()});
    await eventually(() => pc.store.hasBlob(s.attachments.single.sha));
    final wire = [...proxy.c2s.toBytes(), ...proxy.s2c.toBytes()];
    expect(wire.length, greaterThan(fileBytes.length));
    expect(containsBytes(wire, utf8.encode(secret)), isFalse);
    expect(containsBytes(wire, utf8.encode('FILE-CONTENT-MARKER')), isFalse);
    expect(containsBytes(wire, utf8.encode('"body"')), isFalse);
    await sub.cancel();
    ch.close();
    await proxy.close();
  });

  test('A5 replaying a recorded connection changes nothing', () async {
    final proxy = await Proxy.start(pc.engine.port);
    final ch = await SecureChannel.connect('127.0.0.1', proxy.port,
        identity: phone.engine.identity.keys, serverStatic: pcPub);
    final s = _session(phone.store.deviceId, 'original');
    await ch.sendJson({'t': 'session', 's': s.toJson()});
    await eventually(() => pc.store.get(s.id) != null);
    ch.close();
    final recorded = proxy.c2s.toBytes();
    // Now the computer's copy is changed and deleted, then the attacker
    // replays the captured bytes hoping to bring the old content back.
    await pc.store.deleteLocal(s.id);
    final raw = await Socket.connect('127.0.0.1', pc.engine.port);
    raw.add(recorded);
    await raw.flush();
    expect(await _closesSoon(raw), isTrue, reason: 'server drops the replay');
    await Future.delayed(const Duration(milliseconds: 300));
    expect(pc.store.get(s.id), isNull);
    await proxy.close();
  });

  test('A6 tampering with a single bit kills the connection, nothing applied', () async {
    final proxy = await Proxy.start(pc.engine.port);
    var handshakeBytes = 1 + 2 + 96; // mode + frame header + message 1
    proxy.mutateC2S = (d, off) {
      final end = off + d.length;
      // Flip one bit in the first transport frame, after the handshake.
      if (end > handshakeBytes + 40 && off <= handshakeBytes + 40) {
        final c = Uint8List.fromList(d);
        c[handshakeBytes + 40 - off] ^= 0x01;
        handshakeBytes = 1 << 30;
        return c;
      }
      return d;
    };
    final ch = await SecureChannel.connect('127.0.0.1', proxy.port,
        identity: phone.engine.identity.keys, serverStatic: pcPub);
    final s = _session(phone.store.deviceId, 'tampered?');
    await ch.sendJson({'t': 'session', 's': s.toJson()});
    await Future.delayed(const Duration(seconds: 1));
    expect(pc.store.get(s.id), isNull);
    expect(pc.engine.links, isEmpty);
    ch.close();
    await proxy.close();
  });

  test('A7 fuzzing: random garbage never crashes the computer', () async {
    final rnd = Random(1);
    for (var i = 0; i < 60; i++) {
      final s = await Socket.connect('127.0.0.1', pc.engine.port);
      final n = rnd.nextInt(400);
      final mode = [0, 1, 2, 3, 255][rnd.nextInt(5)];
      s.add([mode, ...List.generate(n, (_) => rnd.nextInt(256))]);
      await s.flush();
      s.destroy();
    }
    // The garbage got 127.0.0.1 banned, but the computer is still alive and
    // serves the real phone from another address.
    final p = await Proxy.start(pc.engine.port, source: InternetAddress('127.0.0.2'));
    final ch = await SecureChannel.connect('127.0.0.1', p.port,
        identity: phone.engine.identity.keys, serverStatic: pcPub);
    final s = _session(phone.store.deviceId, 'still alive');
    await ch.sendJson({'t': 'session', 's': s.toJson()});
    await eventually(() => pc.store.get(s.id) != null);
    ch.close();
    await p.close();
  });

  test('A8 slowloris: a stalled handshake is cut off', () async {
    final s = await Socket.connect('127.0.0.1', pc.engine.port);
    s.add([modeSync, 0xff, 0xff]); // announce 64 KB, send nothing
    await s.flush();
    final sw = Stopwatch()..start();
    expect(await _closesSoon(s, within: const Duration(seconds: 10)), isTrue);
    expect(sw.elapsed.inSeconds, lessThanOrEqualTo(8));
  });

  test('A9 brute force: an IP is banned after repeated failures', () async {
    final k = await KeyPair25519.generate();
    for (var i = 0; i < 5; i++) {
      try {
        await SecureChannel.connect('127.0.0.1', pc.engine.port, identity: k, serverStatic: pcPub);
      } catch (_) {}
    }
    // Even the legitimate key is refused from that address for a while.
    await expectLater(
        SecureChannel.connect('127.0.0.1', pc.engine.port,
            identity: phone.engine.identity.keys, serverStatic: pcPub),
        throwsA(anything));
  });

  test('A10 a paired-but-malicious device cannot escape the data folder', () async {
    final ch = await SecureChannel.connect('127.0.0.1', pc.engine.port,
        identity: phone.engine.identity.keys, serverStatic: pcPub);
    final payload = utf8.encode('evil');
    final sha = hexOf(await sha256Of(payload));
    final s = _session(phone.store.deviceId, 'x');
    final j = s.toJson();
    j['att'] = [
      {'sha': sha, 'name': r'..\..\..\Windows\evil.exe', 'size': payload.length, 'added': 1}
    ];
    final sub = ch.messages.listen((m) async {
      if (m is JsonMessage && m.body['t'] == 'want') {
        await ch.sendJson({'t': 'blob_begin', 'sha': sha, 'from': 0});
        await ch.sendChunk(unhex(sha), payload);
        await ch.sendJson({'t': 'blob_end', 'sha': sha});
      }
    }, onError: (_) {});
    await ch.sendJson({'t': 'session', 's': j});
    await eventually(() => pc.store.hasBlob(sha));
    final f = (await pc.store.findBlob(sha))!;
    expect(f.uri.pathSegments.last, 'evil.exe');
    expect(File(f.path).absolute.path.startsWith(pc.dir.absolute.path), isTrue);
    // Invalid ids are refused outright.
    final bad = s.toJson()..['id'] = '../../x';
    await ch.sendJson({'t': 'session', 's': bad});
    await eventually(() => ch.isClosed, reason: 'protocol violation closes link');
    await sub.cancel();
  });

  test('A11 a file whose bytes do not match its hash is rejected', () async {
    final ch = await SecureChannel.connect('127.0.0.1', pc.engine.port,
        identity: phone.engine.identity.keys, serverStatic: pcPub);
    final real = utf8.encode('the real file');
    final sha = hexOf(await sha256Of(real));
    final fake = utf8.encode('a swapped file');
    final s = _session(phone.store.deviceId, 'x')
      ..attachments.add(Attachment(sha: sha, name: 'a.txt', size: fake.length, added: 1));
    var wants = 0;
    final sub = ch.messages.listen((m) async {
      if (m is JsonMessage && m.body['t'] == 'want') {
        wants++;
        await ch.sendJson({'t': 'blob_begin', 'sha': sha, 'from': 0});
        await ch.sendChunk(unhex(sha), fake);
        await ch.sendJson({'t': 'blob_end', 'sha': sha});
      }
    });
    await ch.sendJson({'t': 'session', 's': s.toJson()});
    await eventually(() => wants >= 2, reason: 'computer retries once after mismatch');
    await Future.delayed(const Duration(milliseconds: 500));
    expect(await pc.store.hasBlob(sha), isFalse);
    await sub.cancel();
    ch.close();
  });

  test('A12 sending more bytes than declared kills the link', () async {
    final ch = await SecureChannel.connect('127.0.0.1', pc.engine.port,
        identity: phone.engine.identity.keys, serverStatic: pcPub);
    final sha = 'ab' * 32;
    final s = _session(phone.store.deviceId, 'x')
      ..attachments.add(Attachment(sha: sha, name: 'a.bin', size: 10, added: 1));
    final sub = ch.messages.listen((m) async {
      if (m is JsonMessage && m.body['t'] == 'want') {
        await ch.sendJson({'t': 'blob_begin', 'sha': sha, 'from': 0});
        await ch.sendChunk(unhex(sha), Uint8List(5000));
      }
    }, onError: (_) {});
    await ch.sendJson({'t': 'session', 's': s.toJson()});
    await eventually(() => ch.isClosed);
    await sub.cancel();
  });

  test('A13 discovery answers only probes signed with the pairing key', () async {
    final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final replies = <Datagram>[];
    sock.listen((_) {
      final d = sock.receive();
      if (d != null) replies.add(d);
    });
    final forged = [...ascii.encode('MDDP'), ...List.filled(48, 7)];
    sock.send(forged, InternetAddress.loopbackIPv4, discoveryPort);
    await Future.delayed(const Duration(milliseconds: 600));
    expect(replies, isEmpty);
    sock.close();
    // The genuine phone does get an answer.
    final found = await phone.engine.discover(phone.engine.computer!);
    expect(found, isNotEmpty);
  });

  test('A14 handshake flood is capped', () async {
    final socks = <Socket>[];
    for (var i = 0; i < 12; i++) {
      final s = await Socket.connect('127.0.0.1', pc.engine.port);
      s.add([modeSync]); // open a handshake and stall
      socks.add(s);
    }
    final closed = await Future.wait(
        socks.skip(HostEngine.maxHandshakes).map((s) => _closesSoon(s, within: const Duration(seconds: 2))));
    expect(closed.every((c) => c), isTrue, reason: 'extra handshakes dropped immediately');
    for (final s in socks) {
      s.destroy();
    }
  });

  test('A15 forward secrecy: every connection uses fresh keys', () async {
    final p1 = await Proxy.start(pc.engine.port);
    final a = await SecureChannel.connect('127.0.0.1', p1.port,
        identity: phone.engine.identity.keys, serverStatic: pcPub);
    a.close();
    final p2 = await Proxy.start(pc.engine.port);
    final b = await SecureChannel.connect('127.0.0.1', p2.port,
        identity: phone.engine.identity.keys, serverStatic: pcPub);
    b.close();
    final e1 = p1.c2s.toBytes().sublist(3, 35);
    final e2 = p2.c2s.toBytes().sublist(3, 35);
    expect(e1, isNot(equals(e2)), reason: 'new ephemeral key each time');
    expect(containsBytes(p1.c2s.toBytes(), phone.engine.identity.keys.publicKey), isFalse,
        reason: 'phone identity is encrypted on the wire');
    await p1.close();
    await p2.close();
  });
}
