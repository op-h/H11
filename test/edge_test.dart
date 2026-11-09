// Edge cases and "unlikely" situations, end to end.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:midad/core/identity.dart';
import 'package:midad/core/model.dart';
import 'package:midad/core/noise.dart';
import 'package:midad/core/store.dart';
import 'package:midad/core/sync.dart';
import 'package:midad/core/translate.dart';
import 'package:midad/core/wire.dart';

import 'helpers.dart';

String _loopback(String code) {
  final j = jsonDecode(utf8.decode(base64Url.decode(code.substring(8)))) as Map<String, dynamic>;
  j['h'] = ['127.0.0.1'];
  return 'midad:1:${base64Url.encode(utf8.encode(jsonEncode(j)))}';
}

Future<(Node<HostEngine>, Node<ClientEngine>)> linked() async {
  final pc = await makeHost();
  final phone = await makeClient();
  await phone.engine.pair(_loopback((await pc.engine.beginPairing()).code));
  await eventually(() => phone.engine.status.state == LinkState.connected);
  return (pc, phone);
}

Future<void> down(Node a, Node b) async {
  await a.engine.stop();
  await b.engine.stop();
}

Uint8List randomBytes(int n, [int seed = 1]) {
  final r = Random(seed);
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    b[i] = r.nextInt(256);
  }
  return b;
}

Future<Store> freshStore([String id = 'aaaaaaaaaaaaaaaa']) async {
  final d = await tempDir('store');
  final s = Store(Directory('${d.path}/data'), id);
  await s.open();
  return s;
}

void main() {
  group('crypto batches', () {
    test('batch encryption equals one-by-one, and the two can interleave', () async {
      final k = Uint8List.fromList(List.generate(32, (i) => i));
      final a = CipherState(k), b = CipherState(k);
      final msgs = [for (var i = 0; i < 20; i++) randomBytes(1000 + i * 37, i)];
      final batched = await a.encryptMany(msgs.sublist(0, 10));
      final single = [for (final m in msgs.sublist(0, 10)) await b.encrypt(const [], m)];
      expect(batched, single);
      // Continue: single on a, batch on b — nonces must still line up.
      final s2 = [for (final m in msgs.sublist(10)) await a.encrypt(const [], m)];
      final b2 = await b.encryptMany(msgs.sublist(10));
      expect(s2, b2);
      final r = CipherState(k);
      final back = await r.decryptMany([...batched, ...s2]);
      expect(back, msgs);
    });

    test('one flipped bit in a batch fails the whole batch', () async {
      final k = Uint8List(32)..[0] = 9;
      final tx = CipherState(k), rx = CipherState(k);
      final cts = await tx.encryptMany([randomBytes(500), randomBytes(500, 2), randomBytes(500, 3)]);
      cts[1][7] ^= 1;
      expect(() => rx.decryptMany(cts), throwsA(isA<NoiseError>()));
    });

    test('reordered messages are rejected', () async {
      final k = Uint8List(32)..[5] = 1;
      final tx = CipherState(k), rx = CipherState(k);
      final cts = await tx.encryptMany([randomBytes(100), randomBytes(100, 2)]);
      expect(() => rx.decryptMany([cts[1], cts[0]]), throwsA(isA<NoiseError>()));
    });

    test('empty messages and too-short ciphertexts', () async {
      final k = Uint8List(32);
      final tx = CipherState(k), rx = CipherState(k);
      final cts = await tx.encryptMany([Uint8List(0), Uint8List(0)]);
      expect((await rx.decryptMany(cts)).every((e) => e.isEmpty), isTrue);
      expect(() => CipherState(k).decryptMany([Uint8List(5)]), throwsA(isA<NoiseError>()));
    });

    test('low-order (all-zero) public key is refused', () async {
      final kp = await KeyPair25519.generate();
      expect(() => kp.dh(Uint8List(32)), throwsA(isA<NoiseError>()));
    });
  });

  group('file names', () {
    test('sanitizer handles hostile and unusual names', () {
      expect(sanitizeFileName(r'..\..\evil.exe'), 'evil.exe');
      expect(sanitizeFileName('../../etc/passwd'), 'passwd');
      expect(sanitizeFileName('CON.txt'), '_CON.txt');
      expect(sanitizeFileName('aux'), '_aux');
      expect(sanitizeFileName('a<b>c:d"e|f?g*h.png'), 'a_b_c_d_e_f_g_h.png');
      expect(sanitizeFileName('   .hidden  '), 'hidden');
      expect(sanitizeFileName(''), 'file');
      expect(sanitizeFileName('...'), 'file');
      expect(sanitizeFileName('تقرير الربع الأول.pdf'), 'تقرير الربع الأول.pdf');
      expect(sanitizeFileName('photo 😀.jpg'), 'photo 😀.jpg');
      final long = sanitizeFileName('${'x' * 300}.mp4');
      expect(long.length, 120);
      expect(long.endsWith('.mp4'), isTrue);
      expect(sanitizeFileName('bell\x07name.txt'), 'bell_name.txt');
    });
  });

  group('store', () {
    test('empty file, duplicate content, move vs copy', () async {
      final st = await freshStore();
      final d = await tempDir('src');
      final empty = File('${d.path}/empty.txt')..writeAsBytesSync([]);
      final a = await st.importFile(empty);
      expect(a.size, 0);
      expect(a.sha, 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
      expect(empty.existsSync(), isTrue, reason: 'copy keeps the original');

      final one = File('${d.path}/one.bin')..writeAsBytesSync(randomBytes(5000));
      final two = File('${d.path}/two.bin')..writeAsBytesSync(randomBytes(5000));
      final a1 = await st.importFile(one);
      final a2 = await st.importFile(two, move: true);
      expect(a1.sha, a2.sha, reason: 'same bytes, same id');
      expect(two.existsSync(), isFalse, reason: 'move consumes the temp copy');
      final blobs = Directory('${st.root.path}/blobs/${a1.sha}').listSync();
      expect(blobs.length, 1, reason: 'stored once');
    });

    test('corrupt session file does not stop the app opening', () async {
      final st = await freshStore();
      final s = Session.create(st.deviceId)..body = 'ok';
      await st.saveLocal(s);
      File('${st.root.path}/sessions/${'f' * 32}.json').writeAsStringSync('{not json');
      File('${st.root.path}/sessions/${'e' * 32}.json').writeAsStringSync('{"id":"x"}');
      final again = Store(st.root, st.deviceId);
      await again.open();
      expect(again.sessions.length, 1);
    });

    test('tombstones survive restart; shared files survive deleting one page', () async {
      final st = await freshStore();
      final d = await tempDir('src');
      final f = File('${d.path}/shared.png')..writeAsBytesSync(randomBytes(300));
      final att = await st.importFile(f);
      final s1 = Session.create(st.deviceId)..attachments.add(att);
      final s2 = Session.create(st.deviceId)..attachments.add(att);
      await st.saveLocal(s1);
      await st.saveLocal(s2);
      await st.deleteLocal(s1.id);
      expect(await st.hasBlob(att.sha), isTrue, reason: 'still used by s2');
      await st.deleteLocal(s2.id);
      expect(await st.hasBlob(att.sha), isFalse, reason: 'no longer used');
      final again = Store(st.root, st.deviceId);
      await again.open();
      expect(again.tombstones, containsAll([s1.id, s2.id]));
      expect(await again.applyRemote(Session.fromJson(s1.toJson())), isFalse);
    });

    test('revisions always move forward, even within one millisecond', () async {
      final st = await freshStore();
      final s = Session.create(st.deviceId);
      var last = s.rev;
      for (var i = 0; i < 50; i++) {
        await st.saveLocal(s);
        expect(s.rev > last, isTrue);
        last = s.rev;
      }
    });

    test('last writer wins: older/equal ignored, ties broken by device id', () async {
      final st = await freshStore('bbbbbbbbbbbbbbbb');
      final base = Session(id: 'a' * 32, created: 1, rev: const Rev(1000, 'cccccccccccccccc'));
      expect(await st.applyRemote(base), isTrue);
      expect(await st.applyRemote(Session(id: 'a' * 32, created: 1, body: 'old',
          rev: const Rev(999, 'cccccccccccccccc'))), isFalse);
      expect(await st.applyRemote(Session(id: 'a' * 32, created: 1, body: 'same',
          rev: const Rev(1000, 'cccccccccccccccc'))), isFalse);
      expect(await st.applyRemote(Session(id: 'a' * 32, created: 1, body: 'tie-win',
          rev: const Rev(1000, 'dddddddddddddddd'))), isTrue);
      expect(st.get('a' * 32)!.body, 'tie-win');
    });
  });

  group('validation of incoming pages', () {
    Map<String, dynamic> good() => Session.create('aaaaaaaaaaaaaaaa').toJson()..['body'] = 'x';
    test('accepts a well-formed page', () {
      expect(Session.fromJson(good()).body, 'x');
    });
    for (final (name, mutate) in <(String, void Function(Map<String, dynamic>))>[
      ('missing body', (j) => j.remove('body')),
      ('body wrong type', (j) => j['body'] = 5),
      ('title too long', (j) => j['title'] = 'x' * (maxTitle + 1)),
      ('body too long', (j) => j['body'] = 'x' * (maxBody + 1)),
      ('bad id', (j) => j['id'] = 'XYZ'),
      ('bad rev device', (j) => j['rev'] = {'u': 1, 'd': 'not hex!'}),
      ('negative rev time', (j) => j['rev'] = {'u': -1, 'd': 'aaaaaaaaaaaaaaaa'}),
      ('too many files', (j) => j['att'] = List.generate(maxAttachments + 1,
          (i) => {'sha': 'a' * 64, 'name': 'f', 'size': 1, 'added': 1})),
      ('negative file size', (j) => j['att'] = [{'sha': 'a' * 64, 'name': 'f', 'size': -1, 'added': 1}]),
      ('huge file size', (j) => j['att'] = [{'sha': 'a' * 64, 'name': 'f', 'size': maxBlobSize + 1, 'added': 1}]),
      ('bad file hash', (j) => j['att'] = [{'sha': 'zz', 'name': 'f', 'size': 1, 'added': 1}]),
      ('translation in French', (j) => j['tr'] = {'text': 'x', 'to': 'fr', 'src': 'x', 'at': 1}),
      ('not a map', (j) => j['att'] = 'nope'),
    ]) {
      test('rejects: $name', () {
        final j = good();
        mutate(j);
        expect(() => Session.fromJson(j), throwsA(anything));
      });
    }
  });

  group('text splitting for translation', () {
    test('empty, newlines only, one giant word, Arabic punctuation', () {
      expect(splitText('', 100), ['']);
      expect(splitText('\n\n\n', 100).join(), '\n\n\n');
      final giant = 'a' * 1050;
      final parts = splitText(giant, 100);
      expect(parts.every((p) => p.length <= 100), isTrue);
      expect(parts.join(), giant);
      final ar = List.generate(80, (i) => 'هل هذا سؤال رقم $i؟').join(' ');
      final arParts = splitText(ar, 200);
      expect(arParts.every((p) => p.length <= 200), isTrue);
      expect(arParts.join(), ar);
    });
  });

  group('sync, unusual situations', () {
    test('64 MB video moves without freezing the app, byte-identical', () async {
      final (pc, phone) = await linked();
      final dir = await tempDir('big');
      final f = File('${dir.path}/big video.mp4');
      final raf = f.openSync(mode: FileMode.write);
      for (var i = 0; i < 64; i++) {
        raf.writeFromSync(randomBytes(1024 * 1024, i));
      }
      raf.closeSync();

      // Measure how long the event loop (the UI thread) is ever blocked.
      var worst = Duration.zero;
      var last = DateTime.now();
      final probe = Timer.periodic(const Duration(milliseconds: 10), (_) {
        final now = DateTime.now();
        final gap = now.difference(last);
        if (gap > worst) worst = gap;
        last = now;
      });
      final sw = Stopwatch()..start();
      final a = await phone.store.importFile(f);
      final s = Session.create(phone.store.deviceId)..attachments.add(a);
      await phone.store.saveLocal(s);
      await eventually(() => pc.store.hasBlob(a.sha), timeout: const Duration(minutes: 3));
      probe.cancel();
      final got = await pc.store.findBlob(a.sha);
      expect(await got!.length(), 64 * 1024 * 1024);
      expect(hexOf(await hashFile(got.path)), a.sha);
      // ignore: avoid_print
      print('64 MB: ${sw.elapsed.inMilliseconds} ms, longest UI stall ${worst.inMilliseconds} ms');
      expect(worst.inMilliseconds, lessThan(400), reason: 'UI must stay responsive');
      await down(pc, phone);
    }, timeout: const Timeout(Duration(minutes: 4)));

    test('transfer cut in the middle resumes where it stopped', () async {
      final (pc, phone) = await linked();
      final dir = await tempDir('resume');
      final bytes = randomBytes(24 * 1024 * 1024, 42);
      final f = File('${dir.path}/clip.mov')..writeAsBytesSync(bytes);
      final a = await pc.store.importFile(f);
      final seen = <double>[];
      final sub = phone.engine.progressStream.listen((_) {
        final p = phone.engine.progress[a.sha];
        if (p != null) seen.add(p);
      });
      final s = Session.create(pc.store.deviceId)..attachments.add(a);
      await pc.store.saveLocal(s);
      await eventually(() => (phone.engine.progress[a.sha] ?? 0) > .3);
      phone.engine.links.first.ch.close(); // Wi-Fi drops
      final cut = seen.last;
      seen.clear();
      await eventually(() => phone.store.hasBlob(a.sha), timeout: const Duration(minutes: 2));
      await sub.cancel();
      expect(seen.first, greaterThanOrEqualTo(cut - .05), reason: 'resumed, not restarted');
      expect(await (await phone.store.findBlob(a.sha))!.readAsBytes(), bytes);
      await down(pc, phone);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('both edit the same page while apart: newest edit wins on both', () async {
      final (pc, phone) = await linked();
      final s = Session.create(phone.store.deviceId)..body = 'v1';
      await phone.store.saveLocal(s);
      await eventually(() => pc.store.get(s.id) != null);
      await phone.engine.stop();
      await eventually(() => pc.engine.links.isEmpty);
      final onPc = pc.store.get(s.id)!..body = 'edited on pc';
      await pc.store.saveLocal(onPc);
      await Future.delayed(const Duration(milliseconds: 20));
      final onPhone = phone.store.get(s.id)!..body = 'edited on phone, later';
      await phone.store.saveLocal(onPhone);
      await phone.engine.start();
      await eventually(() => pc.store.get(s.id)!.body == 'edited on phone, later');
      expect(phone.store.get(s.id)!.body, 'edited on phone, later');
      await down(pc, phone);
    });

    test('300 pages and 40 files in one page all arrive', () async {
      final (pc, phone) = await linked();
      for (var i = 0; i < 300; i++) {
        await phone.store.saveLocal(Session.create(phone.store.deviceId)..body = 'note $i');
      }
      final dir = await tempDir('many');
      final s = Session.create(phone.store.deviceId)..title = 'many files';
      for (var i = 0; i < 40; i++) {
        final f = File('${dir.path}/f$i.txt')..writeAsBytesSync(randomBytes(2000 + i, i));
        s.attachments.add(await phone.store.importFile(f));
      }
      await phone.store.saveLocal(s);
      await eventually(() async {
        if (pc.store.sessions.length != 301) return false;
        for (final a in s.attachments) {
          if (!await pc.store.hasBlob(a.sha)) return false;
        }
        return true;
      }, timeout: const Duration(minutes: 2));
      await down(pc, phone);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('the same file in two pages is sent once; empty files work', () async {
      final (pc, phone) = await linked();
      final dir = await tempDir('dup');
      final f = File('${dir.path}/same.jpg')..writeAsBytesSync(randomBytes(200000));
      final e = File('${dir.path}/empty.txt')..writeAsBytesSync([]);
      final a = await phone.store.importFile(f);
      final z = await phone.store.importFile(e);
      var wants = 0;
      final sub = pc.engine.progressStream.listen((_) {
        if (pc.engine.progress.containsKey(a.sha)) wants++;
      });
      await phone.store.saveLocal(Session.create(phone.store.deviceId)..attachments.addAll([a, z]));
      await phone.store.saveLocal(Session.create(phone.store.deviceId)..attachments.add(a));
      await eventually(() async => await pc.store.hasBlob(a.sha) && await pc.store.hasBlob(z.sha));
      await sub.cancel();
      expect(Directory('${pc.store.root.path}/blobs/${a.sha}').listSync().length, 1);
      expect(wants, greaterThan(0));
      await down(pc, phone);
    });

    test('a page written offline arrives when the link comes back', () async {
      final (pc, phone) = await linked();
      await pc.engine.stop(); // computer closed
      await eventually(() => phone.engine.status.state != LinkState.connected);
      final s = Session.create(phone.store.deviceId)..body = 'written on the train';
      await phone.store.saveLocal(s);
      expect(await phone.engine.fetchMissing(s), isFalse, reason: 'nothing to fetch from');
      // Computer opens again on the same port with the same identity.
      final again = HostEngine(pc.store, pc.engine.identity, pc.engine.peers, pc.vault, 'Test-PC',
          port: pc.engine.port);
      await again.start();
      phone.engine.poke();
      await eventually(() => pc.store.get(s.id)?.body == 'written on the train',
          timeout: const Duration(seconds: 30));
      await again.stop();
      await phone.engine.stop();
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('translation and its engine name travel with the page', () async {
      final (pc, phone) = await linked();
      final s = Session.create(phone.store.deviceId)
        ..body = 'hello'
        ..translation = const Translation(text: 'مرحبا', to: 'ar', sourceHash: 'x', at: 1, by: 'Google');
      await phone.store.saveLocal(s);
      await eventually(() => pc.store.get(s.id)?.translation?.by == 'Google');
      expect(pc.store.get(s.id)!.translation!.text, 'مرحبا');
      await down(pc, phone);
    });

    test('unknown messages are ignored; bad keys are refused, good ones kept', () async {
      final (pc, phone) = await linked();
      final ch = phone.engine.links.first.ch;
      await ch.sendJson({'t': 'from-the-future', 'x': 1});
      await ch.sendJson({'t': 'key', 'kind': 'claude', 'v': 'not-a-key'});
      await ch.sendJson({'t': 'key', 'kind': 'deepl', 'v': 'bad key with spaces'});
      await ch.sendJson({'t': 'key', 'kind': 'evil', 'v': 'sk-whatever-123'});
      await Future.delayed(const Duration(milliseconds: 500));
      expect(ch.isClosed, isFalse, reason: 'link survives harmless oddities');
      expect(await pc.vault.read('apikey'), isNull);
      expect(await pc.vault.read('deeplkey'), isNull);
      await ch.sendJson({'t': 'key', 'kind': 'deepl', 'v': '0123456789abcdef-0123:fx'});
      await eventually(() async => await pc.vault.read('deeplkey') == '0123456789abcdef-0123:fx');
      // Assistant setup: a safe one is stored, one pointing at plain http is refused.
      await ch.sendJson({'t': 'key', 'kind': 'ai',
          'v': '{"p":"openai","m":"x","k":"k","b":"http://evil.example.com/v1"}'});
      await ch.sendJson({'t': 'key', 'kind': 'ai', 'v': 'not json at all'});
      await Future.delayed(const Duration(milliseconds: 300));
      expect(await pc.vault.read('ai'), isNull);
      await ch.sendJson({'t': 'key', 'kind': 'ai',
          'v': '{"p":"openai","m":"deepseek-chat","k":"sk-1","b":"https://api.deepseek.com/v1"}'});
      await eventually(() async => (await pc.vault.read('ai'))?.contains('deepseek-chat') ?? false);
      await down(pc, phone);
    });

    test('a malformed hello closes only that link; the computer keeps serving', () async {
      final (pc, phone) = await linked();
      final ch = phone.engine.links.first.ch;
      await ch.sendJson({'t': 'hello', 'have': 'nope', 'dead': 3});
      await eventually(() => ch.isClosed);
      await eventually(() => phone.engine.status.state == LinkState.connected,
          reason: 'phone reconnects normally');
      await down(pc, phone);
    });

    test('a page deleted here is not brought back by the other device', () async {
      final (pc, phone) = await linked();
      final s = Session.create(pc.store.deviceId)..body = 'keep on pc';
      await pc.store.saveLocal(s);
      await eventually(() => phone.store.get(s.id) != null);
      await phone.store.deleteLocal(s.id);
      final again = pc.store.get(s.id)!..body = 'pc edits it later';
      await pc.store.saveLocal(again);
      await Future.delayed(const Duration(seconds: 1));
      expect(phone.store.get(s.id), isNull);
      await down(pc, phone);
    });

    test('delete on both devices: live, and later for a device that was offline', () async {
      final (pc, phone) = await linked();
      final a = Session.create(phone.store.deviceId)..body = 'a';
      final b = Session.create(phone.store.deviceId)..body = 'b';
      await phone.store.saveLocal(a);
      await phone.store.saveLocal(b);
      await eventually(() => pc.store.get(a.id) != null && pc.store.get(b.id) != null);
      // Live: both connected.
      await phone.store.purgeEverywhere(a.id);
      await eventually(() => pc.store.get(a.id) == null, reason: 'computer deletes it too');
      expect(phone.store.get(a.id), isNull);
      // Offline: the computer is closed when the phone deletes.
      await pc.engine.stop();
      await eventually(() => phone.engine.status.state != LinkState.connected);
      await phone.store.purgeEverywhere(b.id);
      expect(pc.store.get(b.id), isNotNull, reason: 'not reachable yet');
      final again = HostEngine(pc.store, pc.engine.identity, pc.engine.peers, pc.vault, 'Test-PC',
          port: pc.engine.port);
      await again.start();
      phone.engine.poke();
      await eventually(() => pc.store.get(b.id) == null, timeout: const Duration(seconds: 30),
          reason: 'deleted as soon as it connects');
      // An old copy coming back can never resurrect it.
      expect(await pc.store.applyRemote(Session.fromJson(b.toJson()..['body'] = 'zombie')), isFalse);
      await again.stop();
      await phone.engine.stop();
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('purge from the computer reaches the phone; junk ids are ignored', () async {
      final (pc, phone) = await linked();
      final s = Session.create(pc.store.deviceId)..body = 'x';
      await pc.store.saveLocal(s);
      await eventually(() => phone.store.get(s.id) != null);
      final ch = phone.engine.links.first.ch;
      await ch.sendJson({'t': 'purge', 'ids': ['../../etc', 'ZZ', 42, null]});
      await Future.delayed(const Duration(milliseconds: 300));
      expect(pc.store.purged, isEmpty, reason: 'invalid ids dropped');
      expect(ch.isClosed, isFalse);
      await pc.store.purgeEverywhere(s.id);
      await eventually(() => phone.store.get(s.id) == null);
      expect(phone.store.purged, contains(s.id));
      await down(pc, phone);
    });

    test('very long page (1.5 million characters) syncs in fragments', () async {
      final (pc, phone) = await linked();
      final body = List.generate(30000, (i) => 'سطر $i — line $i').join('\n');
      expect(body.length, greaterThan(500000));
      final s = Session.create(phone.store.deviceId)..body = body.substring(0, min(body.length, maxBody));
      await phone.store.saveLocal(s);
      await eventually(() => pc.store.get(s.id)?.body.length == s.body.length,
          timeout: const Duration(seconds: 30));
      expect(pc.store.get(s.id)!.body, s.body);
      await down(pc, phone);
    });
  });
}
