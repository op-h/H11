// Noise Protocol Framework (rev 34) — the subset Midad needs:
//   Noise_IK_25519_ChaChaPoly_SHA256       (every normal connection)
//   Noise_IKpsk1_25519_ChaChaPoly_SHA256   (one-time pairing via QR secret)
//
// Pure Dart so it can be unit-tested and checked against an independent
// implementation (see tool/noise_interop.py).
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

final _x25519 = X25519();
final _aead = Chacha20.poly1305Aead();
final _sha256 = Sha256();
final _hmac = Hmac.sha256();

class NoiseError implements Exception {
  final String message;
  NoiseError(this.message);
  @override
  String toString() => 'NoiseError: $message';
}

/// A static or ephemeral X25519 key pair held as raw bytes.
class KeyPair25519 {
  final Uint8List privateKey; // 32-byte seed
  final Uint8List publicKey;
  KeyPair25519(this.privateKey, this.publicKey);

  static Future<KeyPair25519> generate() async {
    final kp = await _x25519.newKeyPair();
    return _fromKp(kp);
  }

  static Future<KeyPair25519> fromPrivate(List<int> seed) async {
    if (seed.length != 32) throw NoiseError('bad private key length');
    final kp = await _x25519.newKeyPairFromSeed(seed);
    return _fromKp(kp);
  }

  static Future<KeyPair25519> _fromKp(SimpleKeyPair kp) async {
    final priv = Uint8List.fromList(await kp.extractPrivateKeyBytes());
    final pub = Uint8List.fromList((await kp.extractPublicKey()).bytes);
    return KeyPair25519(priv, pub);
  }

  Future<Uint8List> dh(List<int> remotePublic) async {
    if (remotePublic.length != 32) throw NoiseError('bad public key length');
    final kp = await _x25519.newKeyPairFromSeed(privateKey);
    final shared = await _x25519.sharedSecretKey(
      keyPair: kp,
      remotePublicKey: SimplePublicKey(remotePublic, type: KeyPairType.x25519),
    );
    final out = Uint8List.fromList(await shared.extractBytes());
    // Reject low-order points (all-zero shared secret): no contributory key.
    if (out.every((b) => b == 0)) throw NoiseError('invalid public key');
    return out;
  }
}

Uint8List _nonce(int n) {
  final b = ByteData(12);
  // 4 zero bytes + 64-bit little-endian counter.
  b.setUint32(4, n & 0xffffffff, Endian.little);
  b.setUint32(8, (n >> 32) & 0xffffffff, Endian.little);
  return b.buffer.asUint8List();
}

Uint8List _concat(List<List<int>> parts) {
  final out = BytesBuilder(copy: false);
  for (final p in parts) {
    out.add(p);
  }
  return out.toBytes();
}

Future<Uint8List> _hash(List<int> data) async =>
    Uint8List.fromList((await _sha256.hash(data)).bytes);

Future<Uint8List> _hmacOf(List<int> key, List<int> data) async =>
    Uint8List.fromList(
      (await _hmac.calculateMac(data, secretKey: SecretKey(key))).bytes,
    );

Future<List<Uint8List>> _hkdf(List<int> ck, List<int> ikm, int n) async {
  final temp = await _hmacOf(ck, ikm);
  final o1 = await _hmacOf(temp, [0x01]);
  final o2 = await _hmacOf(temp, [...o1, 0x02]);
  if (n == 2) return [o1, o2];
  final o3 = await _hmacOf(temp, [...o2, 0x03]);
  return [o1, o2, o3];
}

/// Encrypts with a fixed key and an implicit, strictly increasing nonce.
/// Any reordering, replay or modification fails authentication.
class CipherState {
  Uint8List? _k;
  int _n = 0;
  CipherState([this._k]);

  bool get hasKey => _k != null;

  Future<Uint8List> encrypt(List<int> ad, List<int> plaintext) async {
    final k = _k;
    if (k == null) return Uint8List.fromList(plaintext);
    if (_n >= 0x7fffffffffffffff) throw NoiseError('nonce exhausted');
    final box = await _aead.encrypt(
      plaintext,
      secretKey: SecretKey(k),
      nonce: _nonce(_n),
      aad: ad,
    );
    _n++;
    return _concat([box.cipherText, box.mac.bytes]);
  }

  /// Encrypts many messages (empty AD) on a background isolate, so big
  /// file transfers never block the UI. Nonces stay strictly sequential.
  Future<List<Uint8List>> encryptMany(List<Uint8List> pts) async {
    final k = _k;
    if (k == null) return pts;
    final n0 = _n;
    _n += pts.length;
    return Isolate.run(() => _batch(k, n0, pts, true));
  }

  /// Decrypts many messages (empty AD) on a background isolate.
  /// Throws [NoiseError] if any one of them fails authentication.
  Future<List<Uint8List>> decryptMany(List<Uint8List> cts) async {
    final k = _k;
    if (k == null) return cts;
    final n0 = _n;
    final out = await Isolate.run(() => _batch(k, n0, cts, false));
    _n += cts.length;
    return out;
  }

  Future<Uint8List> decrypt(List<int> ad, List<int> ciphertext) async {
    final k = _k;
    if (k == null) return Uint8List.fromList(ciphertext);
    if (ciphertext.length < 16) throw NoiseError('ciphertext too short');
    if (_n >= 0x7fffffffffffffff) throw NoiseError('nonce exhausted');
    final ct = ciphertext.sublist(0, ciphertext.length - 16);
    final tag = ciphertext.sublist(ciphertext.length - 16);
    try {
      final pt = await _aead.decrypt(
        SecretBox(ct, nonce: _nonce(_n), mac: Mac(tag)),
        secretKey: SecretKey(k),
        aad: ad,
      );
      _n++;
      return Uint8List.fromList(pt);
    } on SecretBoxAuthenticationError {
      throw NoiseError('authentication failed');
    }
  }
}

Future<List<Uint8List>> _batch(
  Uint8List k,
  int n0,
  List<Uint8List> items,
  bool enc,
) async {
  final aead = Chacha20.poly1305Aead();
  final key = SecretKey(k);
  final out = <Uint8List>[];
  for (var i = 0; i < items.length; i++) {
    final nonce = _nonce(n0 + i);
    if (enc) {
      final box = await aead.encrypt(items[i], secretKey: key, nonce: nonce);
      out.add(_concat([box.cipherText, box.mac.bytes]));
    } else {
      final c = items[i];
      if (c.length < 16) throw NoiseError('ciphertext too short');
      try {
        out.add(
          Uint8List.fromList(
            await aead.decrypt(
              SecretBox(
                c.sublist(0, c.length - 16),
                nonce: nonce,
                mac: Mac(c.sublist(c.length - 16)),
              ),
              secretKey: key,
            ),
          ),
        );
      } on SecretBoxAuthenticationError {
        throw NoiseError('authentication failed');
      }
    }
  }
  return out;
}

class _SymmetricState {
  late Uint8List h;
  late Uint8List ck;
  final CipherState cs = CipherState();

  Future<void> init(String protocolName) async {
    final name = ascii.encode(protocolName);
    if (name.length <= 32) {
      h = Uint8List(32)..setRange(0, name.length, name);
    } else {
      h = await _hash(name);
    }
    ck = Uint8List.fromList(h);
  }

  Future<void> mixHash(List<int> data) async =>
      h = await _hash([...h, ...data]);

  Future<void> mixKey(List<int> ikm) async {
    final o = await _hkdf(ck, ikm, 2);
    ck = o[0];
    cs._k = o[1];
    cs._n = 0;
  }

  Future<void> mixKeyAndHash(List<int> ikm) async {
    final o = await _hkdf(ck, ikm, 3);
    ck = o[0];
    await mixHash(o[1]);
    cs._k = o[2];
    cs._n = 0;
  }

  Future<Uint8List> encryptAndHash(List<int> p) async {
    final c = await cs.encrypt(h, p);
    await mixHash(c);
    return c;
  }

  Future<Uint8List> decryptAndHash(List<int> c) async {
    final p = await cs.decrypt(h, c);
    await mixHash(c);
    return p;
  }

  Future<List<CipherState>> split() async {
    final o = await _hkdf(ck, const [], 2);
    return [CipherState(o[0]), CipherState(o[1])];
  }
}

/// Result of a finished handshake.
class NoiseSession {
  final CipherState send;
  final CipherState recv;
  final Uint8List remoteStatic;
  final Uint8List handshakeHash;
  NoiseSession(this.send, this.recv, this.remoteStatic, this.handshakeHash);
}

/// IK (optionally IKpsk1) handshake. Message flow:
///   <- s
///   ...
///   -> e, es, s, ss [, psk]
///   <- e, ee, se
class IKHandshake {
  final bool initiator;
  final KeyPair25519 s;
  Uint8List? rs; // initiator: known in advance; responder: learned from msg 1
  final Uint8List? psk;
  final List<int> prologue;
  KeyPair25519? _e;
  Uint8List? _re;
  final _ss = _SymmetricState();
  bool _ready = false;
  KeyPair25519? _fixedEphemeral; // test vectors only

  IKHandshake.initiator({
    required this.s,
    required Uint8List responderStatic,
    this.psk,
    this.prologue = const [],
  }) : initiator = true,
       rs = responderStatic;

  IKHandshake.responder({required this.s, this.psk, this.prologue = const []})
    : initiator = false;

  /// Only for deterministic interoperability tests.
  void setEphemeralForTest(KeyPair25519 e) => _fixedEphemeral = e;

  String get protocolName =>
      psk == null
          ? 'Noise_IK_25519_ChaChaPoly_SHA256'
          : 'Noise_IKpsk1_25519_ChaChaPoly_SHA256';

  Future<void> _init() async {
    if (_ready) return;
    if (psk != null && psk!.length != 32)
      throw NoiseError('psk must be 32 bytes');
    await _ss.init(protocolName);
    await _ss.mixHash(prologue);
    // Pre-message: responder static.
    await _ss.mixHash(initiator ? rs! : s.publicKey);
    _ready = true;
  }

  Future<KeyPair25519> _newEphemeral() async =>
      _fixedEphemeral ?? await KeyPair25519.generate();

  /// Initiator: build message 1.
  Future<Uint8List> writeMessage1([List<int> payload = const []]) async {
    if (!initiator) throw NoiseError('wrong role');
    await _init();
    final e = _e = await _newEphemeral();
    await _ss.mixHash(e.publicKey);
    if (psk != null) await _ss.mixKey(e.publicKey);
    await _ss.mixKey(await e.dh(rs!)); // es
    final encS = await _ss.encryptAndHash(s.publicKey); // s
    await _ss.mixKey(await s.dh(rs!)); // ss
    if (psk != null) await _ss.mixKeyAndHash(psk!); // psk
    final encP = await _ss.encryptAndHash(payload);
    return _concat([e.publicKey, encS, encP]);
  }

  /// Responder: consume message 1. Returns the decrypted payload.
  /// After this, [rs] holds the initiator's static key, which the caller
  /// MUST check against its list of paired devices.
  Future<Uint8List> readMessage1(List<int> msg) async {
    if (initiator) throw NoiseError('wrong role');
    await _init();
    if (msg.length < 32 + 48 + 16) throw NoiseError('message 1 too short');
    final re = _re = Uint8List.fromList(msg.sublist(0, 32));
    await _ss.mixHash(re);
    if (psk != null) await _ss.mixKey(re);
    await _ss.mixKey(await s.dh(re)); // es
    rs = await _ss.decryptAndHash(msg.sublist(32, 80)); // s
    await _ss.mixKey(await s.dh(rs!)); // ss
    if (psk != null) await _ss.mixKeyAndHash(psk!);
    return _ss.decryptAndHash(msg.sublist(80));
  }

  /// Responder: build message 2 and finish.
  Future<(Uint8List, NoiseSession)> writeMessage2([
    List<int> payload = const [],
  ]) async {
    if (initiator || _re == null) throw NoiseError('wrong state');
    final e = _e = await _newEphemeral();
    await _ss.mixHash(e.publicKey);
    if (psk != null) await _ss.mixKey(e.publicKey);
    await _ss.mixKey(await e.dh(_re!)); // ee
    await _ss.mixKey(await e.dh(rs!)); // se
    final encP = await _ss.encryptAndHash(payload);
    final cs = await _ss.split();
    return (
      _concat([e.publicKey, encP]),
      NoiseSession(cs[1], cs[0], rs!, _ss.h),
    );
  }

  /// Initiator: consume message 2 and finish.
  Future<(Uint8List, NoiseSession)> readMessage2(List<int> msg) async {
    if (!initiator || _e == null) throw NoiseError('wrong state');
    if (msg.length < 32 + 16) throw NoiseError('message 2 too short');
    final re = _re = Uint8List.fromList(msg.sublist(0, 32));
    await _ss.mixHash(re);
    if (psk != null) await _ss.mixKey(re);
    await _ss.mixKey(await _e!.dh(re)); // ee
    await _ss.mixKey(await s.dh(re)); // se
    final p = await _ss.decryptAndHash(msg.sublist(32));
    final cs = await _ss.split();
    return (p, NoiseSession(cs[0], cs[1], rs!, _ss.h));
  }
}

/// Constant-time byte comparison.
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var r = 0;
  for (var i = 0; i < a.length; i++) {
    r |= a[i] ^ b[i];
  }
  return r == 0;
}

Future<Uint8List> hmacSha256(List<int> key, List<int> data) =>
    _hmacOf(key, data);
Future<Uint8List> sha256Of(List<int> data) => _hash(data);
