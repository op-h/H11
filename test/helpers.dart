import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:midad/core/identity.dart';
import 'package:midad/core/store.dart';
import 'package:midad/core/sync.dart';

var _port = 47400;
int nextPort() => _port++;

class Node<E extends SyncEngine> {
  final Directory dir;
  final Store store;
  final E engine;
  final Vault vault;
  Node(this.dir, this.store, this.engine, this.vault);
}

Future<Directory> tempDir(String tag) => Directory.systemTemp.createTemp('midad_$tag');

Future<Node<HostEngine>> makeHost({int? port}) async {
  final d = await tempDir('host');
  final v = FileVault(File('${d.path}/vault.json'));
  final id = await Identity.load(v);
  final st = Store(Directory('${d.path}/data'), id.deviceId);
  await st.open();
  final peers = PeerList(v);
  await peers.load();
  final e = HostEngine(st, id, peers, v, 'Test-PC', port: port ?? 0);
  await e.start();
  return Node(d, st, e, v);
}

Future<Node<ClientEngine>> makeClient() async {
  final d = await tempDir('phone');
  final v = FileVault(File('${d.path}/vault.json'));
  final id = await Identity.load(v);
  final st = Store(Directory('${d.path}/data'), id.deviceId);
  await st.open();
  final peers = PeerList(v);
  await peers.load();
  final e = ClientEngine(st, id, peers, v, 'Test-Phone');
  await e.start();
  return Node(d, st, e, v);
}

Future<void> eventually(FutureOr<bool> Function() cond,
    {Duration timeout = const Duration(seconds: 15), String? reason}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (await cond()) return;
    await Future.delayed(const Duration(milliseconds: 50));
  }
  throw TimeoutException(reason ?? 'condition not met');
}

/// TCP man-in-the-middle used by the attack tests: records every byte and
/// can rewrite traffic in either direction.
class Proxy {
  final ServerSocket server;
  final int target;
  final BytesBuilder c2s = BytesBuilder();
  final BytesBuilder s2c = BytesBuilder();
  Uint8List Function(Uint8List data, int offset)? mutateC2S;
  int _c2sOffset = 0;

  final InternetAddress? source;
  Proxy._(this.server, this.target, this.source) {
    server.listen((client) async {
      final up = await Socket.connect('127.0.0.1', target, sourceAddress: source);
      client.listen((d) {
        final m = mutateC2S?.call(d, _c2sOffset) ?? d;
        _c2sOffset += d.length;
        c2s.add(m);
        up.add(m);
      }, onDone: () => up.destroy(), onError: (_) => up.destroy());
      up.listen((d) {
        s2c.add(d);
        client.add(d);
      }, onDone: () => client.destroy(), onError: (_) => client.destroy());
    });
  }

  int get port => server.port;

  static Future<Proxy> start(int target, {InternetAddress? source}) async =>
      Proxy._(await ServerSocket.bind('127.0.0.1', 0), target, source);

  Future<void> close() => server.close();
}

bool containsBytes(List<int> hay, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= hay.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}
