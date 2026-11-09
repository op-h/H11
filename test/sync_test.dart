import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:midad/core/model.dart';
import 'package:midad/core/sync.dart';

import 'helpers.dart';

void main() {
  test('pair, live-sync text and files both ways, local-only delete', () async {
    final pc = await makeHost();
    final phone = await makeClient();
    final offer = await pc.engine.beginPairing();
    // Point the QR at loopback for the test.
    final name = await phone.engine.pair(_withHost(offer.code, '127.0.0.1'));
    expect(name, 'Test-PC');
    expect(pc.engine.peers.items.single.name, 'Test-Phone');

    await eventually(() => phone.engine.status.state == LinkState.connected,
        reason: 'phone connects');

    // Phone writes an idea with a 3 MB "video" attached.
    final rnd = Random(7);
    final video = Uint8List.fromList(List.generate(3 * 1024 * 1024 + 17, (_) => rnd.nextInt(256)));
    final src = File('${phone.dir.path}/clip.mp4')..writeAsBytesSync(video);
    final s = Session.create(phone.store.deviceId)
      ..title = 'فكرة جديدة'
      ..body = 'A complete idea, written on the phone.';
    s.attachments.add(await phone.store.importFile(src));
    await phone.store.saveLocal(s);

    await eventually(() async {
      final got = pc.store.get(s.id);
      return got != null && await pc.store.hasBlob(got.attachments.single.sha);
    }, reason: 'session + file reach the computer');
    final onPc = pc.store.get(s.id)!;
    expect(onPc.title, 'فكرة جديدة');
    final f = await pc.store.findBlob(onPc.attachments.single.sha);
    expect(await f!.readAsBytes(), video, reason: 'file arrives byte-identical');
    expect(f.path.endsWith('clip.mp4'), isTrue, reason: 'original name and format kept');

    // Computer edits; phone sees it live.
    onPc.body = 'Edited on the computer.';
    await pc.store.saveLocal(onPc);
    await eventually(() => phone.store.get(s.id)?.body == 'Edited on the computer.');

    // Delete on the phone: the computer keeps it, and the phone does not get it back.
    await phone.store.deleteLocal(s.id);
    phone.engine.links.first.ch.close(); // force a full re-sync
    await eventually(() => phone.engine.status.state == LinkState.connected);
    await Future.delayed(const Duration(seconds: 1));
    expect(pc.store.get(s.id), isNotNull);
    expect(phone.store.get(s.id), isNull);

    // Revoking the phone on the computer disconnects it for good.
    await pc.engine.removePeer(pc.engine.peers.items.single.pub);
    await eventually(() => phone.engine.status.state != LinkState.connected);
    await Future.delayed(const Duration(seconds: 3));
    expect(phone.engine.status.state, isNot(LinkState.connected));

    await phone.engine.stop();
    await pc.engine.stop();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('authenticated discovery finds the computer', () async {
    final pc = await makeHost();
    final phone = await makeClient();
    final offer = await pc.engine.beginPairing();
    await phone.engine.pair(_withHost(offer.code, '127.0.0.1'));
    final found = await phone.engine.discover(phone.engine.computer!);
    expect(found.map((e) => e.$2), contains(pc.engine.port));
    await phone.engine.stop();
    await pc.engine.stop();
  });
}

String _withHost(String code, String host) {
  final raw = utf8.decode(base64Url.decode(code.substring(8)));
  final j = jsonDecode(raw) as Map<String, dynamic>;
  j['h'] = [host];
  return 'midad:1:${base64Url.encode(utf8.encode(jsonEncode(j)))}';
}
