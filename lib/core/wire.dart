import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'noise.dart';

const modeSync = 0x01;
const modePair = 0x02;
const maxFrame = 65535;
const maxPlain = maxFrame - 16;
const maxJson = 16 * 1024 * 1024;
const handshakeTimeout = Duration(seconds: 6);

const _kJson = 0x01, _kJsonMore = 0x02, _kChunk = 0x03;

List<int> prologueFor(int mode) => [...utf8.encode('midad/1'), mode];

class WireError implements Exception {
  final String message;
  WireError(this.message);
  @override
  String toString() => 'WireError: $message';
}

/// Buffered exact-length reader on top of a socket.
class _Reader {
  final _buf = BytesBuilder(copy: false);
  Uint8List _pending = Uint8List(0);
  int _off = 0;
  bool _closed = false;
  Object? _error;
  Completer<void>? _wait;
  late final StreamSubscription<Uint8List> _sub;

  _Reader(Stream<Uint8List> s) {
    _sub = s.listen(
      (d) {
        _buf.add(d);
        // Back-pressure: stop reading while a lot is buffered.
        if (_buf.length > 4 * 1024 * 1024) _sub.pause();
        _wake();
      },
      onError: (e) {
        _error = e;
        _closed = true;
        _wake();
      },
      onDone: () {
        _closed = true;
        _wake();
      },
      cancelOnError: true,
    );
  }

  void _wake() {
    final w = _wait;
    _wait = null;
    w?.complete();
  }

  int get _avail => _pending.length - _off + _buf.length;

  /// True when a whole frame is already buffered (read won't wait).
  bool hasFrame() {
    final a = _avail;
    if (a < 2) return false;
    final inPending = _pending.length - _off;
    if (inPending < 2) return a >= 2 + maxFrame; // header straddles buffers
    final len = (_pending[_off] << 8) | _pending[_off + 1];
    return a >= 2 + len;
  }

  Future<Uint8List> read(int n) async {
    while (_avail < n) {
      if (_closed)
        throw WireError(_error != null ? 'socket error' : 'connection closed');
      if (_sub.isPaused) _sub.resume();
      _wait = Completer<void>();
      await _wait!.future;
    }
    if (_pending.length - _off < n) {
      final bb =
          BytesBuilder(copy: false)
            ..add(Uint8List.sublistView(_pending, _off))
            ..add(_buf.takeBytes());
      _pending = bb.takeBytes();
      _off = 0;
    }
    final out = Uint8List.sublistView(_pending, _off, _off + n);
    _off += n;
    if (_buf.length < 1024 * 1024 && _sub.isPaused) _sub.resume();
    return out;
  }

  Future<void> cancel() => _sub.cancel();
}

Uint8List _frame(List<int> data) {
  if (data.length > maxFrame) throw WireError('frame too large');
  final out = Uint8List(2 + data.length);
  out[0] = data.length >> 8;
  out[1] = data.length & 0xff;
  out.setRange(2, out.length, data);
  return out;
}

Future<Uint8List> _readFrame(_Reader r) async {
  final h = await r.read(2);
  final len = (h[0] << 8) | h[1];
  return Uint8List.fromList(await r.read(len));
}

sealed class WireMessage {}

class JsonMessage extends WireMessage {
  final Map<String, dynamic> body;
  JsonMessage(this.body);
}

class ChunkMessage extends WireMessage {
  final String sha;
  final Uint8List data;
  ChunkMessage(this.sha, this.data);
}

/// An authenticated, encrypted, replay-protected channel.
class SecureChannel {
  final Socket _socket;
  final _Reader _reader;
  final NoiseSession _noise;
  final int mode;
  Future<void> _sendChain = Future.value();
  final _incoming = StreamController<WireMessage>();
  bool _closed = false;

  Uint8List get remoteStatic => _noise.remoteStatic;
  String get remoteAddress => _socket.remoteAddress.address;
  Stream<WireMessage> get messages => _incoming.stream;
  bool get isClosed => _closed;

  SecureChannel._(this._socket, this._reader, this._noise, this.mode) {
    _readLoop();
  }

  /// Phone side. [psk] set only while pairing.
  static Future<SecureChannel> connect(
    String host,
    int port, {
    required KeyPair25519 identity,
    required Uint8List serverStatic,
    Uint8List? psk,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    final reader = _Reader(socket);
    try {
      final mode = psk == null ? modeSync : modePair;
      final hs = IKHandshake.initiator(
        s: identity,
        responderStatic: serverStatic,
        psk: psk,
        prologue: prologueFor(mode),
      );
      final m1 = await hs.writeMessage1();
      socket.add([mode, ..._frame(m1)]);
      await socket.flush();
      final m2 = await _readFrame(reader).timeout(handshakeTimeout);
      final (_, session) = await hs.readMessage2(m2);
      return SecureChannel._(socket, reader, session, mode);
    } catch (e) {
      await reader.cancel();
      socket.destroy();
      rethrow;
    }
  }

  /// Computer side. [allow] decides whether an authenticated static key is
  /// a paired device. [pairingPsk] is non-null only while the QR is shown.
  static Future<SecureChannel> accept(
    Socket socket, {
    required KeyPair25519 identity,
    required bool Function(Uint8List remoteStatic) allow,
    required Uint8List? Function() pairingPsk,
  }) async {
    final reader = _Reader(socket);
    try {
      return await () async {
        final mode = (await reader.read(1))[0];
        Uint8List? psk;
        if (mode == modePair) {
          psk = pairingPsk();
          if (psk == null) throw WireError('not in pairing mode');
        } else if (mode != modeSync) {
          throw WireError('unknown mode');
        }
        final hs = IKHandshake.responder(
          s: identity,
          psk: psk,
          prologue: prologueFor(mode),
        );
        final m1 = await _readFrame(reader);
        await hs.readMessage1(m1);
        // In pairing mode the PSK already proved the QR was scanned.
        if (mode == modeSync && !allow(hs.rs!))
          throw WireError('unknown device');
        final (m2, session) = await hs.writeMessage2();
        socket.add(_frame(m2));
        await socket.flush();
        socket.setOption(SocketOption.tcpNoDelay, true);
        return SecureChannel._(socket, reader, session, mode);
      }().timeout(handshakeTimeout);
    } catch (e) {
      await reader.cancel();
      socket.destroy();
      rethrow;
    }
  }

  Future<void> _readLoop() async {
    final jsonBuf = BytesBuilder(copy: false);
    try {
      while (true) {
        final first = await _readFrame(_reader);
        // During a file transfer many frames are already waiting: decrypt
        // them together off the UI thread.
        final batch = <Uint8List>[first];
        var bytes = first.length;
        while (batch.length < 32 && _reader.hasFrame()) {
          final f = await _readFrame(_reader);
          batch.add(f);
          bytes += f.length;
        }
        final List<Uint8List> plains;
        if (bytes > 128 * 1024) {
          plains = await _noise.recv.decryptMany(batch);
        } else {
          plains = [];
          for (final ct in batch) {
            plains.add(await _noise.recv.decrypt(const [], ct));
          }
        }
        for (final pt in plains) {
          if (pt.isEmpty) throw WireError('empty message');
          final kind = pt[0];
          if (kind == _kJson || kind == _kJsonMore) {
            jsonBuf.add(Uint8List.sublistView(pt, 1));
            if (jsonBuf.length > maxJson) throw WireError('message too large');
            if (kind == _kJson) {
              final obj = jsonDecode(utf8.decode(jsonBuf.takeBytes()));
              if (obj is! Map<String, dynamic>) throw WireError('bad message');
              _incoming.add(JsonMessage(obj));
            }
          } else if (kind == _kChunk) {
            if (pt.length < 33) throw WireError('bad chunk');
            final sha =
                pt
                    .sublist(1, 33)
                    .map((b) => b.toRadixString(16).padLeft(2, '0'))
                    .join();
            _incoming.add(ChunkMessage(sha, Uint8List.sublistView(pt, 33)));
          } else {
            throw WireError('unknown message kind');
          }
        }
      }
    } catch (e) {
      // Any decryption failure, malformed frame or socket error kills the
      // channel. There is no partial trust.
      final cleanClose = e is WireError && e.message == 'connection closed';
      if (!_incoming.isClosed && !cleanClose) _incoming.addError(e);
    } finally {
      close();
    }
  }

  Future<void> _sendPlain(List<int> pt) {
    final f = _sendChain.then((_) async {
      if (_closed) throw WireError('closed');
      final ct = await _noise.send.encrypt(const [], pt);
      _socket.add(_frame(ct));
    });
    _sendChain = f.catchError((_) {});
    return f;
  }

  Future<void> sendJson(Map<String, Object?> m) async {
    final data = utf8.encode(jsonEncode(m));
    if (data.length > maxJson) throw WireError('message too large');
    const step = maxPlain - 1;
    for (var i = 0; i < data.length || i == 0; i += step) {
      final end = (i + step < data.length) ? i + step : data.length;
      final last = end == data.length;
      await _sendPlain([last ? _kJson : _kJsonMore, ...data.sublist(i, end)]);
      if (last) break;
    }
    await flush();
  }

  static const chunkSize = maxPlain - 33;

  Future<void> sendChunk(List<int> shaRaw, List<int> data) {
    if (data.length > chunkSize || shaRaw.length != 32)
      throw WireError('bad chunk');
    final b = Uint8List(33 + data.length);
    b[0] = _kChunk;
    b.setRange(1, 33, shaRaw);
    b.setRange(33, b.length, data);
    return _sendPlain(b);
  }

  /// Sends a run of file chunks, encrypted together on a background isolate.
  Future<void> sendChunks(List<int> shaRaw, List<Uint8List> datas) {
    if (shaRaw.length != 32) throw WireError('bad chunk');
    final pts = <Uint8List>[];
    for (final d in datas) {
      if (d.length > chunkSize) throw WireError('bad chunk');
      final b = Uint8List(33 + d.length);
      b[0] = _kChunk;
      b.setRange(1, 33, shaRaw);
      b.setRange(33, b.length, d);
      pts.add(b);
    }
    final f = _sendChain.then((_) async {
      if (_closed) throw WireError('closed');
      final cts = await _noise.send.encryptMany(pts);
      for (final ct in cts) {
        _socket.add(_frame(ct));
      }
      await _socket.flush();
    });
    _sendChain = f.catchError((_) {});
    return f;
  }

  Future<void> flush() => _sendChain.then((_) => _socket.flush());

  void close() {
    if (_closed) return;
    _closed = true;
    _reader.cancel();
    _socket.destroy();
    if (!_incoming.isClosed) _incoming.close();
  }
}
