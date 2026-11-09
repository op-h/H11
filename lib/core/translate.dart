import 'dart:convert';

import 'package:http/http.dart' as http;

import 'identity.dart';
import 'noise.dart';

const translationModel = 'claude-opus-5-5';

final _arabic = RegExp(r'[؀-ۿݐ-ݿࢠ-ࣿﭐ-﷿ﹰ-﻿]');
final _latin = RegExp(r'[A-Za-z]');

bool isMostlyArabic(String s) {
  final a = _arabic.allMatches(s).length;
  final l = _latin.allMatches(s).length;
  return a > 0 && a >= l;
}

/// 'ar' when the text is English (or anything non-Arabic), else 'en'.
String targetFor(String s) => isMostlyArabic(s) ? 'en' : 'ar';

Future<String> sourceHash(String s) async =>
    hexOf(await sha256Of(utf8.encode(s))).substring(0, 16);

class TranslateError implements Exception {
  final String message;
  TranslateError(this.message);
  @override
  String toString() => message;
}

/// Which engine the user prefers. `auto` = best available for free:
/// DeepL if a free key is saved, otherwise Google; MyMemory as backup.
enum EngineChoice { auto, google, deepl, claude }

abstract class TranslateEngine {
  String get name;
  Future<String> translate(String text, String to);
}

/// Splits on paragraph boundaries so formatting survives and no request
/// exceeds a service's size limit.
List<String> splitText(String text, int max) {
  if (text.length <= max) return [text];
  final out = <String>[];
  var cur = StringBuffer();
  void flush() {
    if (cur.isNotEmpty) out.add(cur.toString());
    cur = StringBuffer();
  }

  for (final para in text.split('\n')) {
    final p = '$para\n';
    if (p.length > max) {
      flush();
      // Very long paragraph: cut at sentence ends, then hard-cut.
      final sentences = RegExp(
        r'[^.!?؟。]+[.!?؟。]*\s*',
      ).allMatches(p).map((m) => m[0]!);
      for (final s in sentences) {
        if (cur.length + s.length > max) flush();
        if (s.length > max) {
          for (var i = 0; i < s.length; i += max) {
            out.add(s.substring(i, (i + max).clamp(0, s.length)));
          }
        } else {
          cur.write(s);
        }
      }
      continue;
    }
    if (cur.length + p.length > max) flush();
    cur.write(p);
  }
  flush();
  // Drop the trailing newline we added to the very last paragraph.
  if (out.isNotEmpty && !text.endsWith('\n')) {
    out[out.length - 1] = out.last.substring(0, out.last.length - 1);
  }
  return out;
}

Future<http.Response> _send(Future<http.Response> f) async {
  try {
    return await f.timeout(const Duration(seconds: 60));
  } catch (_) {
    throw TranslateError(
      'No internet connection — translation needs to go online.',
    );
  }
}

/// Google Translate's public web endpoint. Free, no key, no signup.
/// Unofficial: Google may rate-limit heavy use, so MyMemory backs it up.
class GoogleFree implements TranslateEngine {
  final http.Client _c;
  GoogleFree([http.Client? c]) : _c = c ?? http.Client();
  @override
  String get name => 'Google';

  @override
  Future<String> translate(String text, String to) async {
    final out = StringBuffer();
    for (final part in splitText(text, 4500)) {
      if (part.trim().isEmpty) {
        out.write(part);
        continue;
      }
      final r = await _send(
        _c.post(
          Uri.parse(
            'https://translate.googleapis.com/translate_a/single'
            '?client=gtx&sl=auto&tl=$to&dt=t',
          ),
          headers: {
            'content-type': 'application/x-www-form-urlencoded;charset=utf-8',
          },
          body: 'q=${Uri.encodeQueryComponent(part)}',
        ),
      );
      if (r.statusCode != 200)
        throw TranslateError(
          'Google translation unavailable (${r.statusCode})',
        );
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is! List || j.isEmpty || j[0] is! List)
        throw TranslateError('Unexpected reply from Google');
      for (final seg in j[0] as List) {
        if (seg is List && seg.isNotEmpty && seg[0] is String)
          out.write(seg[0]);
      }
    }
    return out.toString().trim();
  }
}

/// DeepL API Free: the best free quality. Needs a free key from
/// deepl.com/pro-api (500,000 characters a month at no cost).
class DeepL implements TranslateEngine {
  final String key;
  final http.Client _c;
  DeepL(this.key, [http.Client? c]) : _c = c ?? http.Client();
  @override
  String get name => 'DeepL';

  @override
  Future<String> translate(String text, String to) async {
    final host = key.endsWith(':fx') ? 'api-free.deepl.com' : 'api.deepl.com';
    final parts = splitText(text, 30000);
    final r = await _send(
      _c.post(
        Uri.https(host, '/v2/translate'),
        headers: {
          'Authorization': 'DeepL-Auth-Key $key',
          'content-type': 'application/json',
        },
        body: jsonEncode({
          'text': parts,
          'target_lang': to == 'ar' ? 'AR' : 'EN-US',
          'preserve_formatting': true,
        }),
      ),
    );
    if (r.statusCode != 200) {
      throw TranslateError(switch (r.statusCode) {
        403 => 'The DeepL key was not accepted.',
        456 => 'DeepL free monthly limit reached.',
        429 => 'DeepL is busy. Try again shortly.',
        _ => 'DeepL translation failed (${r.statusCode})',
      });
    }
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    return (j['translations'] as List)
        .map((t) => t['text'] as String)
        .join()
        .trim();
  }
}

/// MyMemory: free, keyless backup (about 5,000 characters a day).
class MyMemory implements TranslateEngine {
  final http.Client _c;
  MyMemory([http.Client? c]) : _c = c ?? http.Client();
  @override
  String get name => 'MyMemory';

  @override
  Future<String> translate(String text, String to) async {
    final from = to == 'ar' ? 'en' : 'ar';
    final out = StringBuffer();
    for (final part in splitText(text, 450)) {
      if (part.trim().isEmpty) {
        out.write(part);
        continue;
      }
      final r = await _send(
        _c.get(
          Uri.https('api.mymemory.translated.net', '/get', {
            'q': part,
            'langpair': '$from|$to',
          }),
        ),
      );
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (r.statusCode != 200 || j is! Map || j['responseStatus'] != 200) {
        throw TranslateError('MyMemory translation unavailable');
      }
      out.write(j['responseData']['translatedText']);
      if (part.endsWith('\n')) out.write('\n');
    }
    return out.toString().trim();
  }
}

const _claudeSystem = '''
You are a senior professional translator working between Arabic and English.
Translate the user's text into the requested language.
- Use natural, polished, publication-quality language — Modern Standard Arabic for Arabic, clear contemporary English for English. Never translate word for word.
- Keep the author's meaning, tone and register exactly; do not add, explain or omit anything.
- Preserve paragraphs, line breaks, lists, headings and any Markdown.
- Keep names, numbers, URLs, code and file names unchanged unless they have an established translation.
- Output only the translation, with no preamble, notes or quotation marks.''';

/// Claude: optional, uses your own Anthropic key (paid per use).
class Claude implements TranslateEngine {
  final String apiKey;
  final http.Client _c;
  Claude(this.apiKey, [http.Client? c]) : _c = c ?? http.Client();
  @override
  String get name => 'Claude';

  @override
  Future<String> translate(String text, String to) async {
    final out = <String>[];
    for (final p in splitText(text, 12000)) {
      out.add(p.trim().isEmpty ? p : await _one(p, to));
    }
    return out.join('\n').trim();
  }

  Future<String> _one(String text, String to) async {
    final lang = to == 'ar' ? 'Arabic' : 'English';
    final r = await _send(
      _c.post(
        Uri.parse('https://api.anthropic.com/v1/messages'),
        headers: {
          'x-api-key': apiKey,
          'anthropic-version': '2023-06-01',
          'anthropic-beta': 'server-side-fallback-2026-07-01',
          'content-type': 'application/json',
        },
        body: jsonEncode({
          'model': translationModel,
          'max_tokens': 16000,
          'system': _claudeSystem,
          'output_config': {'effort': 'medium'},
          'fallbacks': 'default',
          'messages': [
            {
              'role': 'user',
              'content': 'Translate into $lang:\n\n<text>\n$text\n</text>',
            },
          ],
        }),
      ),
    );
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (r.statusCode != 200) {
      throw TranslateError(switch (r.statusCode) {
        401 => 'The Claude key was not accepted.',
        429 => 'Claude is rate-limited right now.',
        _ => 'Claude translation failed (${r.statusCode})',
      });
    }
    if (j['stop_reason'] == 'refusal')
      throw TranslateError('Claude declined this text.');
    final buf = StringBuffer();
    for (final b in (j['content'] as List)) {
      if (b is Map && b['type'] == 'text') buf.write(b['text']);
    }
    final t = buf.toString().trim().replaceAll(
      RegExp(r'^<text>\s*|\s*</text>$'),
      '',
    );
    if (t.isEmpty) throw TranslateError('Empty translation returned.');
    return t;
  }
}

/// Picks the engine and falls back automatically, so translating always
/// works as long as there is internet.
class TranslationService {
  final EngineChoice choice;
  final String? deeplKey;
  final String? claudeKey;
  final http.Client? client;
  TranslationService({
    required this.choice,
    this.deeplKey,
    this.claudeKey,
    this.client,
  });

  List<TranslateEngine> get chain {
    final deepl = (deeplKey ?? '').isNotEmpty ? DeepL(deeplKey!, client) : null;
    final claude =
        (claudeKey ?? '').isNotEmpty ? Claude(claudeKey!, client) : null;
    final google = GoogleFree(client);
    final first = switch (choice) {
      EngineChoice.deepl => deepl,
      EngineChoice.claude => claude,
      EngineChoice.google => google,
      EngineChoice.auto => deepl ?? google,
    };
    final list = <TranslateEngine>[
      if (first != null) first,
      google,
      MyMemory(client),
    ];
    final seen = <String>{};
    return list.where((e) => seen.add(e.name)).toList();
  }

  /// Returns the translation and the name of the engine that produced it.
  Future<(String, String)> translate(String text, String to) async {
    TranslateError? last;
    for (final e in chain) {
      try {
        return (await e.translate(text, to), e.name);
      } on TranslateError catch (err) {
        last = err;
      } catch (err) {
        last = TranslateError('${e.name}: $err');
      }
    }
    throw last ?? TranslateError('Translation failed');
  }
}
