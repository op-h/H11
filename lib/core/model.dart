import 'dart:math';

final _rand = Random.secure();

String randomHex(int bytes) =>
    List.generate(
      bytes,
      (_) => _rand.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();

final _idRe = RegExp(r'^[0-9a-f]{32}$');
final _shaRe = RegExp(r'^[0-9a-f]{64}$');
final _deviceRe = RegExp(r'^[0-9a-f]{16,64}$');

const maxTitle = 500;
const maxBody = 2000000;
const maxAttachments = 500;
const maxBlobSize = 8 * 1024 * 1024 * 1024; // 8 GB per file

class FormatError implements Exception {
  final String message;
  FormatError(this.message);
  @override
  String toString() => 'FormatError: $message';
}

T _req<T>(Map m, String k) {
  final v = m[k];
  if (v is! T) throw FormatError('field "$k" missing or wrong type');
  return v;
}

/// Makes a filename safe to place on disk on Windows and Android:
/// no paths, no control or reserved characters, no reserved device names.
String sanitizeFileName(String raw) {
  var s = raw.split(RegExp(r'[\\/]')).last;
  s = s.replaceAll(RegExp(r'[\x00-\x1f\x7f<>:"|?*]'), '_');
  s = s.replaceAll(RegExp(r'^[\s.]+'), '').replaceAll(RegExp(r'[\s.]+$'), '');
  final base = s.split('.').first.toUpperCase();
  const reserved = {
    'CON',
    'PRN',
    'AUX',
    'NUL',
    'COM1',
    'COM2',
    'COM3',
    'COM4',
    'COM5',
    'COM6',
    'COM7',
    'COM8',
    'COM9',
    'LPT1',
    'LPT2',
    'LPT3',
    'LPT4',
    'LPT5',
    'LPT6',
    'LPT7',
    'LPT8',
    'LPT9',
  };
  if (reserved.contains(base)) s = '_$s';
  if (s.isEmpty) s = 'file';
  if (s.length > 120) {
    final dot = s.lastIndexOf('.');
    final ext = (dot > 0 && s.length - dot <= 12) ? s.substring(dot) : '';
    s = s.substring(0, 120 - ext.length) + ext;
  }
  return s;
}

/// Revision used for last-writer-wins: (time, device) ordered.
class Rev implements Comparable<Rev> {
  final int u;
  final String d;
  const Rev(this.u, this.d);
  @override
  int compareTo(Rev o) => u != o.u ? u.compareTo(o.u) : d.compareTo(o.d);
  bool operator >(Rev o) => compareTo(o) > 0;
  Map<String, Object> toJson() => {'u': u, 'd': d};
  static Rev fromJson(Object? j) {
    if (j is! Map) throw FormatError('rev');
    final u = _req<int>(j, 'u');
    final d = _req<String>(j, 'd');
    if (!_deviceRe.hasMatch(d) || u < 0) throw FormatError('rev values');
    return Rev(u, d);
  }
}

class Attachment {
  final String sha; // sha256 of content; also the blob id
  final String name;
  final int size;
  final int added;
  const Attachment({
    required this.sha,
    required this.name,
    required this.size,
    required this.added,
  });

  String get ext {
    final i = name.lastIndexOf('.');
    return i > 0 ? name.substring(i + 1).toLowerCase() : '';
  }

  bool get isImage =>
      const {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic'}.contains(ext);

  Map<String, Object> toJson() => {
    'sha': sha,
    'name': name,
    'size': size,
    'added': added,
  };

  static Attachment fromJson(Object? j) {
    if (j is! Map) throw FormatError('attachment');
    final sha = _req<String>(j, 'sha');
    final size = _req<int>(j, 'size');
    if (!_shaRe.hasMatch(sha)) throw FormatError('attachment sha');
    if (size < 0 || size > maxBlobSize) throw FormatError('attachment size');
    final name = sanitizeFileName(_req<String>(j, 'name'));
    return Attachment(
      sha: sha,
      name: name,
      size: size,
      added: _req<int>(j, 'added'),
    );
  }
}

class Translation {
  final String text;
  final String to; // 'ar' or 'en'
  final String sourceHash; // detects when the original changed afterwards
  final int at;
  final String? by; // engine that produced it
  const Translation({
    required this.text,
    required this.to,
    required this.sourceHash,
    required this.at,
    this.by,
  });
  Map<String, Object> toJson() => {
    'text': text,
    'to': to,
    'src': sourceHash,
    'at': at,
    if (by != null) 'by': by!,
  };
  static Translation fromJson(Object? j) {
    if (j is! Map) throw FormatError('translation');
    final to = _req<String>(j, 'to');
    if (to != 'ar' && to != 'en') throw FormatError('translation lang');
    final text = _req<String>(j, 'text');
    if (text.length > maxBody * 2) throw FormatError('translation too long');
    final by = j['by'];
    return Translation(
      text: text,
      to: to,
      sourceHash: _req<String>(j, 'src'),
      at: _req<int>(j, 'at'),
      by: (by is String && by.length <= 20) ? by : null,
    );
  }
}

class Session {
  final String id;
  String title;
  String body;
  List<Attachment> attachments;
  Translation? translation;
  final int created;
  Rev rev;

  Session({
    required this.id,
    this.title = '',
    this.body = '',
    List<Attachment>? attachments,
    this.translation,
    required this.created,
    required this.rev,
  }) : attachments = attachments ?? [];

  static Session create(String deviceId) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return Session(id: randomHex(16), created: now, rev: Rev(now, deviceId));
  }

  String get displayTitle {
    if (title.trim().isNotEmpty) return title.trim();
    final first = body.trim().split('\n').first.trim();
    if (first.isNotEmpty)
      return first.length > 80 ? '${first.substring(0, 80)}…' : first;
    return attachments.isNotEmpty ? attachments.first.name : 'Untitled';
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'body': body,
    'att': attachments.map((a) => a.toJson()).toList(),
    'tr': translation?.toJson(),
    'created': created,
    'rev': rev.toJson(),
  };

  /// Strict parser: everything coming from the network goes through here.
  static Session fromJson(Object? j) {
    if (j is! Map) throw FormatError('session');
    final id = _req<String>(j, 'id');
    if (!_idRe.hasMatch(id)) throw FormatError('session id');
    final title = _req<String>(j, 'title');
    final body = _req<String>(j, 'body');
    if (title.length > maxTitle || body.length > maxBody)
      throw FormatError('too long');
    final att = _req<List>(j, 'att');
    if (att.length > maxAttachments) throw FormatError('too many attachments');
    final tr = j['tr'];
    return Session(
      id: id,
      title: title,
      body: body,
      attachments: att.map(Attachment.fromJson).toList(),
      translation: tr == null ? null : Translation.fromJson(tr),
      created: _req<int>(j, 'created'),
      rev: Rev.fromJson(j['rev']),
    );
  }
}
