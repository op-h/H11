import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'model.dart';
import 'noise.dart';

/// Where secrets live. The app uses the OS keystore (Android Keystore /
/// Windows DPAPI); tests use [FileVault].
abstract class Vault {
  Future<String?> read(String key);
  Future<void> write(String key, String? value);
}

class FileVault implements Vault {
  final File file;
  FileVault(this.file);
  Future<Map<String, dynamic>> _all() async {
    if (!await file.exists()) return {};
    return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  }

  @override
  Future<String?> read(String key) async => (await _all())[key] as String?;
  @override
  Future<void> write(String key, String? value) async {
    final m = await _all();
    value == null ? m.remove(key) : m[key] = value;
    await file.writeAsString(jsonEncode(m));
  }
}

class Identity {
  final KeyPair25519 keys;
  final String deviceId;
  Identity(this.keys, this.deviceId);

  static Future<Identity> load(Vault v) async {
    final raw = await v.read('identity');
    if (raw != null) {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return Identity(
        await KeyPair25519.fromPrivate(base64.decode(j['sk'] as String)),
        j['id'] as String,
      );
    }
    final kp = await KeyPair25519.generate();
    final id = Identity(kp, randomHex(8));
    await v.write(
      'identity',
      jsonEncode({'sk': base64.encode(kp.privateKey), 'id': id.deviceId}),
    );
    return id;
  }

  /// Short human-checkable fingerprint, e.g. "4F2A·91C0·7E3B".
  Future<String> fingerprint() => fingerprintOf(keys.publicKey);
}

Future<String> fingerprintOf(List<int> pub) async {
  final h = hexOf(await sha256Of(pub)).toUpperCase();
  return '${h.substring(0, 4)}·${h.substring(4, 8)}·${h.substring(8, 12)}';
}

String hexOf(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
Uint8List unhex(String s) => Uint8List.fromList(
  List.generate(
    s.length ~/ 2,
    (i) => int.parse(s.substring(i * 2, i * 2 + 2), radix: 16),
  ),
);

/// A device paired with this one.
class Peer {
  final String pub; // hex X25519 static key
  final String name;
  final int pairedAt;
  // Phone side only:
  final String? disc; // base64 discovery key
  final String? host;
  final int? port;

  Peer({
    required this.pub,
    required this.name,
    required this.pairedAt,
    this.disc,
    this.host,
    this.port,
  });

  Peer copyWith({String? host, int? port, String? name}) => Peer(
    pub: pub,
    name: name ?? this.name,
    pairedAt: pairedAt,
    disc: disc,
    host: host ?? this.host,
    port: port ?? this.port,
  );

  Map<String, Object?> toJson() => {
    'pub': pub,
    'name': name,
    'at': pairedAt,
    'disc': disc,
    'host': host,
    'port': port,
  };
  static Peer fromJson(Map<String, dynamic> j) => Peer(
    pub: j['pub'] as String,
    name: j['name'] as String,
    pairedAt: j['at'] as int,
    disc: j['disc'] as String?,
    host: j['host'] as String?,
    port: j['port'] as int?,
  );
}

class PeerList {
  final Vault vault;
  final List<Peer> items = [];
  PeerList(this.vault);

  Future<void> load() async {
    final raw = await vault.read('peers');
    if (raw == null) return;
    items
      ..clear()
      ..addAll(
        (jsonDecode(raw) as List).map(
          (e) => Peer.fromJson(e as Map<String, dynamic>),
        ),
      );
  }

  Future<void> save() =>
      vault.write('peers', jsonEncode(items.map((e) => e.toJson()).toList()));

  Peer? byPub(List<int> pub) {
    final h = hexOf(pub);
    for (final p in items) {
      if (constantTimeEquals(p.pub.codeUnits, h.codeUnits)) return p;
    }
    return null;
  }

  Future<void> upsert(Peer p) async {
    items.removeWhere((e) => e.pub == p.pub);
    items.add(p);
    await save();
  }

  Future<void> remove(String pub) async {
    items.removeWhere((e) => e.pub == pub);
    await save();
  }
}
