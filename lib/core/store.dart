import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'model.dart';

/// On-disk store. Layout under [root]:
///   sessions/<id>.json   one file per session (written atomically)
///   blobs/<sha>/<name>   attachments, byte-for-byte originals
///   tmp/                 partial downloads
///   tombstones.json      sessions deleted on THIS device (never re-imported)
class Store {
  final Directory root;
  final String deviceId;
  final Map<String, Session> _sessions = {};
  final Set<String> _tombstones = {};
  final Set<String> _purged = {}; // deleted on every device
  final _purges = StreamController<List<String>>.broadcast();
  final _changes = StreamController<Session?>.broadcast();
  final _local = StreamController<Session>.broadcast();

  Store(this.root, this.deviceId);

  /// Emits the changed session, or null when the list changed (e.g. delete).
  Stream<Session?> get changes => _changes.stream;

  /// Only edits made on this device (what the sync engine sends out).
  Stream<Session> get localChanges => _local.stream;
  Iterable<Session> get sessions => _sessions.values;
  Set<String> get tombstones => Set.unmodifiable(_tombstones);
  Set<String> get purged => Set.unmodifiable(_purged);

  /// Newly purged page ids, to pass on to the other device(s).
  Stream<List<String>> get purges => _purges.stream;

  Directory get _sDir => Directory('${root.path}/sessions');
  Directory get _bDir => Directory('${root.path}/blobs');
  Directory get tmpDir => Directory('${root.path}/tmp');
  File get _tombFile => File('${root.path}/tombstones.json');
  File get _purgeFile => File('${root.path}/purged.json');

  Future<void> open() async {
    for (final d in [_sDir, _bDir, tmpDir]) {
      await d.create(recursive: true);
    }
    // Keep recent partial downloads (*.part) so big files can resume;
    // clear everything else and anything older than a week.
    final week = DateTime.now().subtract(const Duration(days: 7));
    await for (final f in tmpDir.list()) {
      try {
        final old = (await f.stat()).modified.isBefore(week);
        if (!f.path.endsWith('.part') || old) await f.delete(recursive: true);
      } catch (_) {}
    }
    if (await _tombFile.exists()) {
      try {
        final l = jsonDecode(await _tombFile.readAsString());
        if (l is List) _tombstones.addAll(l.whereType<String>());
      } catch (_) {}
    }
    if (await _purgeFile.exists()) {
      try {
        final l = jsonDecode(await _purgeFile.readAsString());
        if (l is List) _purged.addAll(l.whereType<String>());
      } catch (_) {}
    }
    await for (final f in _sDir.list()) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      try {
        final s = Session.fromJson(jsonDecode(await f.readAsString()));
        _sessions[s.id] = s;
      } catch (_) {
        // A corrupt file must never stop the app from opening.
      }
    }
  }

  Session? get(String id) => _sessions[id];

  List<Session> sorted() =>
      _sessions.values.toList()..sort((a, b) => b.rev.u.compareTo(a.rev.u));

  Future<void> _write(File f, String data) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(data, flush: true);
    await tmp.rename(f.path);
  }

  /// Local edit: bumps the revision.
  Future<void> saveLocal(Session s) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    s.rev = Rev(now > s.rev.u ? now : s.rev.u + 1, deviceId);
    await _persist(s);
    _local.add(s);
  }

  Future<void> _persist(Session s) async {
    _sessions[s.id] = s;
    await _write(File('${_sDir.path}/${s.id}.json'), jsonEncode(s.toJson()));
    _changes.add(s);
  }

  /// Incoming from the other device. Returns true if it was applied.
  Future<bool> applyRemote(Session s) async {
    if (_tombstones.contains(s.id)) return false;
    final mine = _sessions[s.id];
    if (mine != null && !(s.rev > mine.rev)) return false;
    await _persist(s);
    return true;
  }

  /// Deletes on this device only. The other device keeps its copy, and this
  /// device will not take it back during later syncs.
  Future<void> deleteLocal(String id) async {
    final s = _sessions.remove(id);
    _tombstones.add(id);
    await _write(_tombFile, jsonEncode(_tombstones.toList()));
    final f = File('${_sDir.path}/$id.json');
    if (await f.exists()) await f.delete();
    if (s != null) {
      for (final a in s.attachments) {
        if (!_sessions.values.any(
          (o) => o.attachments.any((x) => x.sha == a.sha),
        )) {
          final d = Directory('${_bDir.path}/${a.sha}');
          if (await d.exists()) await d.delete(recursive: true);
        }
      }
    }
    _changes.add(null);
  }

  /// Deletes the page here AND on the other device(s), now or the next
  /// time they connect.
  Future<void> purgeEverywhere(String id) => applyPurge([id]);

  /// Applies purges (local or received). Returns the ids that were new.
  Future<List<String>> applyPurge(Iterable<String> ids) async {
    final fresh = <String>[];
    for (final id in ids) {
      if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(id) || _purged.contains(id)) continue;
      _purged.add(id);
      fresh.add(id);
      if (_sessions.containsKey(id) || !_tombstones.contains(id)) await deleteLocal(id);
    }
    if (fresh.isNotEmpty) {
      await _write(_purgeFile, jsonEncode(_purged.toList()));
      _purges.add(fresh);
    }
    return fresh;
  }

  // ---- blobs ---------------------------------------------------------------

  File blobFile(Attachment a) => File('${_bDir.path}/${a.sha}/${a.name}');

  Future<File?> findBlob(String sha) async {
    final d = Directory('${_bDir.path}/$sha');
    if (!await d.exists()) return null;
    await for (final f in d.list()) {
      if (f is File) return f;
    }
    return null;
  }

  Future<bool> hasBlob(String sha) async => (await findBlob(sha)) != null;

  /// Brings a user-picked file in. Runs on a background isolate so the UI
  /// never freezes, even for multi-GB videos. With [move] (a temporary copy
  /// the picker made), the file is moved instead of copied a second time.
  Future<Attachment> importFile(
    File src, {
    String? name,
    bool move = false,
  }) async {
    final tmp = File('${tmpDir.path}/${randomHex(8)}');
    final srcPath = src.path, tmpPath = tmp.path;
    final (sha, size) = await Isolate.run(
      () => _bringIn(srcPath, tmpPath, move),
    );
    final a = Attachment(
      sha: sha,
      name: sanitizeFileName(name ?? src.uri.pathSegments.last),
      size: size,
      added: DateTime.now().millisecondsSinceEpoch,
    );
    await _placeBlob(tmp, a);
    return a;
  }

  Future<void> _placeBlob(File tmp, Attachment a) async {
    final dir = Directory('${_bDir.path}/${a.sha}');
    if (await findBlob(a.sha) != null) {
      await tmp.delete();
      return;
    }
    await dir.create(recursive: true);
    await tmp.rename('${dir.path}/${a.name}');
  }

  /// Called by the sync engine once a received file is complete.
  /// Verifies length and hash before accepting it.
  Future<bool> acceptReceivedBlob(File tmp, Attachment a, List<int> sha) async {
    final ok = _hex(sha) == a.sha && await tmp.length() == a.size;
    if (!ok) {
      await tmp.delete();
      return false;
    }
    await _placeBlob(tmp, a);
    for (final s in _sessions.values) {
      if (s.attachments.any((x) => x.sha == a.sha)) _changes.add(s);
    }
    return true;
  }

  File partFile(String sha) => File('${tmpDir.path}/$sha.part');

  Future<void> close() async {
    await _changes.close();
    await _purges.close();
    await _local.close();
  }
}

Future<(String, int)> _bringIn(String src, String dst, bool move) async {
  if (move) {
    try {
      await File(src).rename(dst);
      return (_hex(await hashFile(dst)), await File(dst).length());
    } catch (_) {
      // Different volume: fall back to copying.
    }
  }
  final sink = Sha256().newHashSink();
  final out = File(dst).openWrite();
  var size = 0;
  await for (final chunk in File(src).openRead()) {
    sink.add(chunk);
    out.add(chunk);
    size += chunk.length;
  }
  await out.close();
  sink.close();
  return (_hex((await sink.hash()).bytes), size);
}

/// SHA-256 of a file, streamed. Call it through Isolate.run for big files.
Future<Uint8List> hashFile(String path) async {
  final sink = Sha256().newHashSink();
  await for (final c in File(path).openRead()) {
    sink.add(c);
  }
  sink.close();
  return Uint8List.fromList((await sink.hash()).bytes);
}

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
