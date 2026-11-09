import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'assistant.dart';
import 'identity.dart';
import 'model.dart';
import 'noise.dart';
import 'store.dart';
import 'wire.dart';

const defaultPort = 47321;
const discoveryPort = 47322;
final _shaRe = RegExp(r'^[0-9a-f]{64}$');

enum LinkState { unpaired, searching, connected }

class LinkStatus {
  final LinkState state;
  final String? peerName;
  const LinkStatus(this.state, [this.peerName]);
}

class _Incoming {
  final Attachment a;
  final File part;
  IOSink sink;
  int received;
  bool retried;
  _Incoming(
    this.a,
    this.part,
    this.sink,
    this.received, {
    this.retried = false,
  });
}

/// One live conversation with a paired device.
class Link {
  final SecureChannel ch;
  final SyncEngine eng;
  final Peer peer;
  final Map<String, _Incoming> _rx = {};
  final Queue<(String, int)> _txQueue = Queue();
  bool _txBusy = false;
  Timer? _ping;
  DateTime _lastSeen = DateTime.now();
  final _done = Completer<void>();

  Link(this.ch, this.eng, this.peer);

  Store get store => eng.store;
  Future<void> get done => _done.future;

  Future<void> run() async {
    _ping = Timer.periodic(const Duration(seconds: 20), (_) {
      if (DateTime.now().difference(_lastSeen) > const Duration(seconds: 65)) {
        ch.close();
      } else {
        _send({'t': 'ping'});
      }
    });
    _send({
      't': 'hello',
      'v': 1,
      'name': eng.deviceName,
      'have': {for (final s in store.sessions) s.id: s.rev.toJson()},
      'dead': store.tombstones.toList(),
      'purge': store.purged.toList(),
    });
    try {
      await for (final m in ch.messages) {
        _lastSeen = DateTime.now();
        await _handle(m);
      }
    } catch (_) {
      // Channel failure: fall through to cleanup.
    } finally {
      _ping?.cancel();
      ch.close();
      for (final r in _rx.values) {
        await r.sink.close().catchError((_) {});
      }
      for (final sha in _rx.keys) {
        eng._setProgress(sha, null);
      }
      _rx.clear();
      if (!_done.isCompleted) _done.complete();
    }
  }

  void _send(Map<String, Object?> m) {
    ch.sendJson(m).catchError((_) => ch.close());
  }

  void sendSession(Session s) {
    if (!ch.isClosed) _send({'t': 'session', 's': s.toJson()});
  }

  Future<void> _handle(WireMessage m) async {
    if (m is ChunkMessage) return _onChunk(m);
    final b = (m as JsonMessage).body;
    switch (b['t']) {
      case 'hello':
        final have = b['have'];
        final dead = b['dead'];
        if (have is! Map || dead is! List) throw FormatError('hello');
        final purge = b['purge'];
        if (purge is List && purge.length <= 100000) {
          await store.applyPurge(purge.whereType<String>());
        }
        final deadSet = dead.whereType<String>().toSet();
        for (final s in store.sessions) {
          if (deadSet.contains(s.id)) continue;
          final theirs = have[s.id];
          if (theirs == null || s.rev > Rev.fromJson(theirs)) sendSession(s);
        }
        for (final s in store.sessions.toList()) {
          await _requestMissing(s);
        }
      case 'session':
        final s = Session.fromJson(b['s']);
        if (await store.applyRemote(s)) {
          eng._relay(s, except: this);
          await _requestMissing(s);
        }
      case 'want':
        final sha = b['sha'];
        final from = b['from'];
        if (sha is! String ||
            !_shaRe.hasMatch(sha) ||
            from is! int ||
            from < 0) {
          throw FormatError('want');
        }
        _txQueue.add((sha, from));
        _pumpTx();
      case 'blob_begin':
        final r = _rx[b['sha']];
        final from = b['from'];
        if (r == null || from is! int || from < 0 || from > r.received) break;
        if (from != r.received) {
          await r.sink.close();
          final raf = await r.part.open(mode: FileMode.append);
          await raf.truncate(from);
          await raf.close();
          r.sink = r.part.openWrite(mode: FileMode.append);
          r.received = from;
        }
      case 'blob_end':
        await _finishBlob(b['sha']);
      case 'nohave':
        final r = _rx.remove(b['sha']);
        if (r != null) {
          await r.sink.close();
          eng._setProgress(r.a.sha, null);
        }
      case 'key':
        final v = b['v'];
        final kind = b['kind'] ?? 'claude';
        if (v is! String || v.length > 1200) break;
        if (kind == 'claude' && v.startsWith('sk-')) {
          await eng._receivedApiKey('apikey', v, peer.name);
        } else if (kind == 'deepl' &&
            RegExp(r'^[A-Za-z0-9:\-]{20,100}$').hasMatch(v)) {
          await eng._receivedApiKey('deeplkey', v, peer.name);
        } else if (kind == 'ai') {
          try {
            final cfg = AiConfig.fromJson(jsonDecode(v));
            if (cfg != null) {
              await eng._receivedApiKey('ai', jsonEncode(cfg.toJson()), peer.name);
            }
          } catch (_) {}
        }
      case 'purge':
        final ids = b['ids'];
        if (ids is List && ids.length <= 10000) {
          await store.applyPurge(ids.whereType<String>());
        }
      case 'ping':
        _send({'t': 'pong'});
      case 'pong':
        break;
      default:
        break; // unknown messages from newer versions are ignored
    }
  }

  Future<void> _requestMissing(Session s) async {
    for (final a in s.attachments) {
      if (_rx.containsKey(a.sha) || await store.hasBlob(a.sha)) continue;
      final part = store.partFile(a.sha);
      var from = await part.exists() ? await part.length() : 0;
      if (from > a.size) {
        await part.delete();
        from = 0;
      }
      _rx[a.sha] = _Incoming(
        a,
        part,
        part.openWrite(mode: FileMode.append),
        from,
      );
      eng._setProgress(a.sha, a.size == 0 ? 0 : from / a.size);
      _send({'t': 'want', 'sha': a.sha, 'from': from});
    }
  }

  Future<void> _onChunk(ChunkMessage m) async {
    final r = _rx[m.sha];
    if (r == null) return;
    if (r.received + m.data.length > r.a.size) {
      throw FormatError('blob longer than declared');
    }
    r.sink.add(m.data);
    r.received += m.data.length;
    eng._setProgress(r.a.sha, r.a.size == 0 ? 1 : r.received / r.a.size);
  }

  Future<void> _finishBlob(Object? sha) async {
    final r = _rx.remove(sha);
    if (r == null) return;
    await r.sink.flush();
    await r.sink.close();
    final path = r.part.path;
    final digest = await Isolate.run(() => hashFile(path));
    final ok = await store.acceptReceivedBlob(r.part, r.a, digest);
    eng._setProgress(r.a.sha, null);
    if (!ok && !r.retried) {
      // Corrupt or tampered file: discard and fetch again from zero, once.
      _rx[r.a.sha] = _Incoming(
        r.a,
        r.part,
        r.part.openWrite(),
        0,
        retried: true,
      );
      _send({'t': 'want', 'sha': r.a.sha, 'from': 0});
    }
  }

  Future<void> _pumpTx() async {
    if (_txBusy) return;
    _txBusy = true;
    try {
      while (_txQueue.isNotEmpty && !ch.isClosed) {
        final (sha, from) = _txQueue.removeFirst();
        // Only serve files that belong to a session on this device.
        final referenced = store.sessions.any(
          (s) => s.attachments.any((a) => a.sha == sha),
        );
        final f = referenced ? await store.findBlob(sha) : null;
        if (f == null) {
          _send({'t': 'nohave', 'sha': sha});
          continue;
        }
        final len = await f.length();
        final start = from <= len ? from : 0;
        await ch.sendJson({'t': 'blob_begin', 'sha': sha, 'from': start});
        final raw = unhex(sha);
        final raf = await f.open();
        try {
          await raf.setPosition(start);
          while (true) {
            final run = <Uint8List>[];
            for (var i = 0; i < 16; i++) {
              final buf = await raf.read(SecureChannel.chunkSize);
              if (buf.isEmpty) break;
              run.add(buf);
            }
            if (run.isEmpty) break;
            await ch.sendChunks(raw, run);
          }
        } finally {
          await raf.close();
        }
        await ch.sendJson({'t': 'blob_end', 'sha': sha});
      }
    } catch (_) {
      ch.close();
    } finally {
      _txBusy = false;
    }
  }
}

/// Shared logic for both sides.
abstract class SyncEngine {
  final Store store;
  final Identity identity;
  final PeerList peers;
  final Vault vault;
  final String deviceName;
  final List<Link> links = [];
  final _status = StreamController<LinkStatus>.broadcast();
  LinkStatus _current = const LinkStatus(LinkState.unpaired);
  final Map<String, double> progress = {};
  final _progress = StreamController<void>.broadcast();
  final _keys = StreamController<String>.broadcast();
  StreamSubscription? _localSub;
  StreamSubscription? _purgeSub;
  bool running = false;

  SyncEngine(
    this.store,
    this.identity,
    this.peers,
    this.vault,
    this.deviceName,
  );

  Stream<LinkStatus> get statusStream => _status.stream;
  LinkStatus get status => _current;
  Stream<void> get progressStream => _progress.stream;

  /// Emits the name of the device that sent a translation key.
  Stream<String> get apiKeyReceived => _keys.stream;

  void _setStatus(LinkStatus s) {
    _current = s;
    if (!_status.isClosed) _status.add(s);
  }

  void _setProgress(String sha, double? v) {
    v == null ? progress.remove(sha) : progress[sha] = v;
    if (!_progress.isClosed) _progress.add(null);
  }

  void _relay(Session s, {Link? except}) {
    for (final l in links) {
      if (l != except) l.sendSession(s);
    }
  }

  Future<void> _receivedApiKey(String slot, String key, String from) async {
    await vault.write(slot, key);
    _keys.add(from);
  }

  /// Sends translation keys to the connected device(s) over the encrypted
  /// channel. [kind] is 'claude' or 'deepl'. Returns false if nothing is
  /// connected.
  Future<bool> shareApiKey(String key, {String kind = 'claude'}) async {
    if (links.isEmpty) return false;
    for (final l in links) {
      await l.ch.sendJson({'t': 'key', 'kind': kind, 'v': key});
    }
    return true;
  }

  Future<void> start() async {
    running = true;
    _localSub = store.localChanges.listen((s) => _relay(s));
    _purgeSub = store.purges.listen((ids) {
      for (final l in links) {
        if (!l.ch.isClosed) l._send({'t': 'purge', 'ids': ids});
      }
    });
  }

  Future<void> stop() async {
    running = false;
    await _localSub?.cancel();
    await _purgeSub?.cancel();
    for (final l in links.toList()) {
      l.ch.close();
    }
  }

  /// Asks the connected device(s) for any file of [s] missing here.
  /// Returns false when no device is connected.
  Future<bool> fetchMissing(Session s) async {
    if (links.isEmpty) return false;
    for (final l in links) {
      await l._requestMissing(s);
    }
    return true;
  }

  void _refreshStatus();

  Future<void> _runLink(SecureChannel ch, Peer p) async {
    final l = Link(ch, this, p);
    links.add(l);
    _refreshStatus();
    await l.run();
    links.remove(l);
    _refreshStatus();
  }
}

// ---------------------------------------------------------------------------
// Computer: listens for the phone.

class PairingOffer {
  final String code; // what goes into the QR
  final DateTime expires;
  PairingOffer(this.code, this.expires);
}

class HostEngine extends SyncEngine {
  int port;
  ServerSocket? _server;
  RawDatagramSocket? _udp;
  Uint8List? _psk;
  DateTime? _pskExpires;
  late Uint8List _discKey;
  int _handshaking = 0;
  final Map<String, List<DateTime>> _failures = {};
  final Map<String, DateTime> _banned = {};
  int _udpBudget = 0;
  Timer? _udpTimer;
  final _paired = StreamController<String>.broadcast();

  static const maxHandshakes = 4;
  static const maxLinks = 4;

  HostEngine(
    super.store,
    super.identity,
    super.peers,
    super.vault,
    super.deviceName, {
    this.port = defaultPort,
  });

  /// Emits the name of a newly paired device.
  Stream<String> get pairedStream => _paired.stream;

  @override
  Future<void> start() async {
    await super.start();
    final d = await vault.read('disc');
    if (d != null) {
      _discKey = base64.decode(d);
    } else {
      _discKey = Uint8List.fromList(unhex(randomHex(32)));
      await vault.write('disc', base64.encode(_discKey));
    }
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    port = _server!.port; // when 0 was requested
    _server!.listen(_onSocket);
    try {
      _udp = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
      );
      _udp!.listen((_) => _onUdp());
      _udpTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _udpBudget = 0,
      );
    } catch (_) {
      // Discovery is a convenience; direct addresses still work without it.
    }
    _refreshStatus();
  }

  @override
  Future<void> stop() async {
    await super.stop();
    await _server?.close();
    _udp?.close();
    _udpTimer?.cancel();
  }

  @override
  void _refreshStatus() {
    if (links.isNotEmpty) {
      _setStatus(LinkStatus(LinkState.connected, links.first.peer.name));
    } else {
      _setStatus(
        LinkStatus(
          peers.items.isEmpty ? LinkState.unpaired : LinkState.searching,
        ),
      );
    }
  }

  bool _isBanned(String ip) {
    final until = _banned[ip];
    if (until == null) return false;
    if (DateTime.now().isAfter(until)) {
      _banned.remove(ip);
      return false;
    }
    return true;
  }

  void _fail(String ip) {
    final now = DateTime.now();
    final l = (_failures[ip] ??= [])..add(now);
    l.removeWhere((t) => now.difference(t) > const Duration(minutes: 1));
    if (l.length >= 5) {
      _banned[ip] = now.add(const Duration(minutes: 5));
      _failures.remove(ip);
    }
  }

  Uint8List? _activePsk() {
    if (_psk == null || DateTime.now().isAfter(_pskExpires!)) return null;
    return _psk;
  }

  Future<void> _onSocket(Socket s) async {
    final ip = s.remoteAddress.address;
    if (_isBanned(ip) ||
        _handshaking >= maxHandshakes ||
        links.length >= maxLinks) {
      s.destroy();
      return;
    }
    _handshaking++;
    SecureChannel ch;
    try {
      ch = await SecureChannel.accept(
        s,
        identity: identity.keys,
        allow: (pub) => peers.byPub(pub) != null,
        pairingPsk: _activePsk,
      );
    } catch (_) {
      _fail(ip);
      return;
    } finally {
      _handshaking--;
    }
    if (ch.mode == modePair) {
      await _completePairing(ch);
      return;
    }
    final p = peers.byPub(ch.remoteStatic)!;
    // A reconnect from the same device replaces the stale link.
    for (final l in links.where((l) => l.peer.pub == p.pub).toList()) {
      l.ch.close();
    }
    await _runLink(ch, p);
  }

  Future<void> _completePairing(SecureChannel ch) async {
    // Single use: the QR secret stops working the moment it is used.
    _psk = null;
    _pskExpires = null;
    try {
      final first = await ch.messages.first.timeout(
        const Duration(seconds: 10),
      );
      if (first is! JsonMessage || first.body['t'] != 'pair')
        throw FormatError('pair');
      final rawName = first.body['name'];
      final name =
          (rawName is String && rawName.trim().isNotEmpty)
              ? rawName.trim().substring(0, rawName.trim().length.clamp(0, 60))
              : 'Phone';
      await peers.upsert(
        Peer(
          pub: hexOf(ch.remoteStatic),
          name: name,
          pairedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await ch.sendJson({
        't': 'paired',
        'name': deviceName,
        'disc': base64.encode(_discKey),
      });
      await Future.delayed(const Duration(milliseconds: 200));
      _paired.add(name);
      _refreshStatus();
    } catch (_) {
    } finally {
      ch.close();
    }
  }

  /// Shows a QR for [validFor]. Only the device that scans it can pair.
  Future<PairingOffer> beginPairing({
    Duration validFor = const Duration(minutes: 3),
  }) async {
    _psk = Uint8List.fromList(unhex(randomHex(32)));
    _pskExpires = DateTime.now().add(validFor);
    final addrs = <String>[];
    for (final i in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    )) {
      for (final a in i.addresses) {
        if (!a.isLoopback && !a.isLinkLocal) addrs.add(a.address);
      }
    }
    final payload = {
      'k': hexOf(identity.keys.publicKey),
      's': base64Url.encode(_psk!),
      'h': addrs,
      'p': port,
      'n': deviceName,
    };
    return PairingOffer(
      'midad:1:${base64Url.encode(utf8.encode(jsonEncode(payload)))}',
      _pskExpires!,
    );
  }

  void cancelPairing() {
    _psk = null;
    _pskExpires = null;
  }

  Future<void> removePeer(String pub) async {
    await peers.remove(pub);
    for (final l in links.where((l) => l.peer.pub == pub).toList()) {
      l.ch.close();
    }
    _refreshStatus();
  }

  Future<void> _onUdp() async {
    final d = _udp?.receive();
    if (d == null || d.data.length != 52) return;
    if (_udpBudget++ > 20 || peers.items.isEmpty) return;
    final b = d.data;
    if (ascii.decode(b.sublist(0, 4), allowInvalid: true) != 'MDDP') return;
    final nonce = b.sublist(4, 20);
    final mac = await hmacSha256(_discKey, [
      ...ascii.encode('probe'),
      ...nonce,
    ]);
    if (!constantTimeEquals(mac, b.sublist(20, 52))) return;
    final portB = [port >> 8, port & 0xff];
    final rmac = await hmacSha256(_discKey, [
      ...ascii.encode('reply'),
      ...nonce,
      ...portB,
    ]);
    _udp?.send(
      [...ascii.encode('MDDR'), ...nonce, ...portB, ...rmac],
      d.address,
      d.port,
    );
  }
}

// ---------------------------------------------------------------------------
// Phone: finds and connects to the computer.

class ClientEngine extends SyncEngine {
  Completer<void>? _wake;
  bool _loopRunning = false;

  ClientEngine(
    super.store,
    super.identity,
    super.peers,
    super.vault,
    super.deviceName,
  );

  Peer? get computer => peers.items.isEmpty ? null : peers.items.first;

  @override
  void _refreshStatus() {
    if (links.isNotEmpty) {
      _setStatus(LinkStatus(LinkState.connected, links.first.peer.name));
    } else {
      _setStatus(
        LinkStatus(
          computer == null ? LinkState.unpaired : LinkState.searching,
          computer?.name,
        ),
      );
    }
  }

  @override
  Future<void> start() async {
    await super.start();
    _refreshStatus();
    if (!_loopRunning) _loop();
  }

  @override
  Future<void> stop() async {
    await super.stop();
    poke();
  }

  /// Try again now (app resumed, network changed, user pulled to refresh).
  void poke() {
    final w = _wake;
    _wake = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<void> _sleep(Duration d) async {
    _wake = Completer<void>();
    await Future.any([_wake!.future, Future.delayed(d)]);
  }

  Future<void> _loop() async {
    _loopRunning = true;
    var backoff = 2;
    while (running) {
      final pc = computer;
      if (pc == null) {
        _refreshStatus();
        await _sleep(const Duration(seconds: 30));
        continue;
      }
      _refreshStatus();
      final candidates = <(String, int)>[
        if (pc.host != null) (pc.host!, pc.port ?? defaultPort),
        ...await discover(pc),
      ];
      var connected = false;
      for (final (host, port) in candidates.toSet()) {
        try {
          final ch = await SecureChannel.connect(
            host,
            port,
            identity: identity.keys,
            serverStatic: unhex(pc.pub),
          );
          connected = true;
          backoff = 2;
          if (host != pc.host || port != pc.port) {
            await peers.upsert(pc.copyWith(host: host, port: port));
          }
          await _runLink(ch, pc);
          break;
        } catch (_) {}
      }
      if (!running) break;
      if (!connected) {
        await _sleep(Duration(seconds: backoff));
        backoff = (backoff * 2).clamp(2, 15);
      }
    }
    _loopRunning = false;
  }

  /// Authenticated LAN discovery: only the paired computer can answer.
  Future<List<(String, int)>> discover(
    Peer pc, {
    Duration wait = const Duration(milliseconds: 1200),
  }) async {
    if (pc.disc == null) return [];
    final key = base64.decode(pc.disc!);
    final nonce = unhex(randomHex(16));
    final mac = await hmacSha256(key, [...ascii.encode('probe'), ...nonce]);
    final found = <(String, int)>[];
    RawDatagramSocket? sock;
    try {
      sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      sock.broadcastEnabled = true;
      final targets = <InternetAddress>{InternetAddress('255.255.255.255')};
      for (final i in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      )) {
        for (final a in i.addresses) {
          if (a.isLoopback) continue;
          final p = a.rawAddress;
          targets.add(
            InternetAddress.fromRawAddress(
              Uint8List.fromList([p[0], p[1], p[2], 255]),
            ),
          );
        }
      }
      final pkt = [...ascii.encode('MDDP'), ...nonce, ...mac];
      for (final t in targets) {
        try {
          sock.send(pkt, t, discoveryPort);
        } catch (_) {}
      }
      final done = Completer<void>();
      final timer = Timer(wait, () {
        if (!done.isCompleted) done.complete();
      });
      sock.listen((_) async {
        final d = sock?.receive();
        if (d == null || d.data.length != 54) return;
        final b = d.data;
        if (ascii.decode(b.sublist(0, 4), allowInvalid: true) != 'MDDR') return;
        if (!constantTimeEquals(b.sublist(4, 20), nonce)) return;
        final portB = b.sublist(20, 22);
        final want = await hmacSha256(key, [
          ...ascii.encode('reply'),
          ...nonce,
          ...portB,
        ]);
        if (!constantTimeEquals(want, b.sublist(22, 54))) return;
        found.add((d.address.address, (portB[0] << 8) | portB[1]));
        if (!done.isCompleted) done.complete();
      });
      await done.future;
      timer.cancel();
    } catch (_) {
    } finally {
      sock?.close();
    }
    return found;
  }

  /// Pairs using the code from the computer's QR. Throws on failure.
  Future<String> pair(String code) async {
    if (!code.startsWith('midad:1:'))
      throw FormatError('Not a Midad pairing code');
    final j = jsonDecode(utf8.decode(base64Url.decode(code.substring(8))));
    if (j is! Map) throw FormatError('pairing code');
    final pub = unhex(j['k'] as String);
    final psk = Uint8List.fromList(base64Url.decode(j['s'] as String));
    final port = j['p'] as int;
    final hosts = (j['h'] as List).whereType<String>().toList();
    if (pub.length != 32 || psk.length != 32) throw FormatError('pairing code');
    Object? lastError;
    for (final h in hosts) {
      SecureChannel? ch;
      try {
        ch = await SecureChannel.connect(
          h,
          port,
          identity: identity.keys,
          serverStatic: pub,
          psk: psk,
        );
        final reply = ch.messages.first.timeout(const Duration(seconds: 10));
        await ch.sendJson({'t': 'pair', 'name': deviceName});
        final m = await reply;
        if (m is! JsonMessage || m.body['t'] != 'paired')
          throw FormatError('pairing');
        final name = (m.body['name'] as String?) ?? 'Computer';
        await peers.save();
        peers.items.clear();
        await peers.upsert(
          Peer(
            pub: hexOf(pub),
            name: name,
            pairedAt: DateTime.now().millisecondsSinceEpoch,
            disc: m.body['disc'] as String,
            host: h,
            port: port,
          ),
        );
        ch.close();
        _refreshStatus();
        poke();
        return name;
      } catch (e) {
        lastError = e;
        ch?.close();
      }
    }
    throw lastError ?? FormatError('Computer not reachable');
  }

  Future<void> unpair() async {
    peers.items.clear();
    await peers.save();
    for (final l in links.toList()) {
      l.ch.close();
    }
    _refreshStatus();
  }
}
