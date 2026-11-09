import 'dart:convert';

import 'package:http/http.dart' as http;

/// Which kind of API the writing assistant talks to.
enum AiProvider { claude, openai, gemini }

/// Ready-made endpoints for the OpenAI-compatible provider.
const aiPresets = <String, (String, String)>{
  // name: (base URL, suggested model)
  'OpenAI': ('https://api.openai.com/v1', 'gpt-4o-mini'),
  'OpenRouter': ('https://openrouter.ai/api/v1', 'openai/gpt-4o-mini'),
  'Groq': ('https://api.groq.com/openai/v1', 'llama-3.3-70b-versatile'),
  'DeepSeek': ('https://api.deepseek.com/v1', 'deepseek-chat'),
  'Mistral': ('https://api.mistral.ai/v1', 'mistral-small-latest'),
  'Ollama (this computer)': ('http://localhost:11434/v1', 'llama3.1'),
};

String defaultModel(AiProvider p) => switch (p) {
      AiProvider.claude => 'claude-opus-5-5',
      AiProvider.openai => 'gpt-4o-mini',
      AiProvider.gemini => 'gemini-2.0-flash',
    };

class AiConfig {
  final AiProvider provider;
  final String model;
  final String key;
  final String baseUrl; // OpenAI-compatible only
  const AiConfig({required this.provider, required this.model, required this.key, this.baseUrl = ''});

  bool get ready =>
      model.trim().isNotEmpty &&
      (key.trim().isNotEmpty || (provider == AiProvider.openai && _isLocal(baseUrl)));

  String get label => '${switch (provider) {
        AiProvider.claude => 'Claude',
        AiProvider.gemini => 'Gemini',
        AiProvider.openai => _hostName(baseUrl),
      }} · $model';

  Map<String, String> toJson() =>
      {'p': provider.name, 'm': model, 'k': key, if (baseUrl.isNotEmpty) 'b': baseUrl};

  /// Strict parser: also used for configs received from the linked device.
  static AiConfig? fromJson(Object? j) {
    if (j is! Map) return null;
    final p = AiProvider.values.where((e) => e.name == j['p']).firstOrNull;
    final m = j['m'], k = j['k'], b = j['b'] ?? '';
    if (p == null || m is! String || k is! String || b is! String) return null;
    if (m.isEmpty || m.length > 120 || k.length > 400 || b.length > 300) return null;
    if (b.isNotEmpty) {
      final u = Uri.tryParse(b);
      if (u == null || !(u.isScheme('https') || (u.isScheme('http') && _isLocal(b)))) return null;
    }
    return AiConfig(provider: p, model: m, key: k, baseUrl: b);
  }
}

bool _isLocal(String url) {
  final h = Uri.tryParse(url)?.host ?? '';
  return h == 'localhost' || h == '127.0.0.1' || h.startsWith('192.168.') || h.startsWith('10.');
}

String _hostName(String url) {
  final h = Uri.tryParse(url)?.host ?? 'API';
  for (final e in aiPresets.entries) {
    if (url.startsWith(e.value.$1)) return e.key.split(' ').first;
  }
  return h;
}

class AssistError implements Exception {
  final String message;
  AssistError(this.message);
  @override
  String toString() => message;
}

/// One-click actions shown in the floating window.
class AssistAction {
  final String label;
  final String instruction;
  final bool insert; // result is added below instead of replacing
  const AssistAction(this.label, this.instruction, {this.insert = false});
}

const assistActions = [
  AssistAction('Improve', 'Improve the writing: clearer, more vivid and better structured, same meaning and length.'),
  AssistAction('Fix grammar', 'Fix spelling, grammar and punctuation only. Change nothing else.'),
  AssistAction('Shorter', 'Make it about half as long, keeping every key point.'),
  AssistAction('Longer', 'Expand it with useful detail and examples, in the same voice.'),
  AssistAction('Formal', 'Rewrite in a professional, formal tone.'),
  AssistAction('Simpler', 'Rewrite in plain, simple words anyone can understand.'),
  AssistAction('Continue', 'Continue writing from where the text ends, in the same voice. Return only the new part.',
      insert: true),
  AssistAction('Summarize', 'Summarize it in 3–5 short bullet points.', insert: true),
  AssistAction('Ideas', 'Give 5 concrete, practical suggestions to improve or develop this idea, as a short numbered list.',
      insert: true),
  AssistAction('Translate', 'Translate it: Arabic to English, or English to Arabic. Professional quality.'),
];

const _system = '''
You are a writing assistant inside a personal notebook app.
You receive the user's text and an instruction. Follow the instruction exactly.
Rules:
- Reply with the resulting text only — no preamble, no explanation, no quotation marks, no code fences.
- Keep the language of the original text (Arabic stays Arabic, English stays English) unless the instruction asks for a translation.
- Preserve paragraphs, line breaks and lists unless the instruction requires otherwise.
- Never invent facts about the user.''';

class AssistantClient {
  final AiConfig cfg;
  final http.Client _c;
  AssistantClient(this.cfg, [http.Client? c]) : _c = c ?? http.Client();

  Future<String> run(String instruction, String text) async {
    if (!cfg.ready) throw AssistError('Set up the writing assistant in Settings first.');
    final user = 'Instruction: $instruction\n\n<text>\n$text\n</text>';
    final http.Response r;
    try {
      r = await switch (cfg.provider) {
        AiProvider.claude => _claude(user),
        AiProvider.openai => _openai(user),
        AiProvider.gemini => _gemini(user),
      }
          .timeout(const Duration(minutes: 3));
    } on AssistError {
      rethrow;
    } catch (_) {
      throw AssistError('Could not reach ${cfg.label}. Check the internet connection and the address.');
    }
    final body = utf8.decode(r.bodyBytes);
    Object? j;
    try {
      j = jsonDecode(body);
    } catch (_) {
      throw AssistError('Unexpected reply (${r.statusCode}).');
    }
    if (r.statusCode != 200) {
      final msg = _errorMessage(j);
      throw AssistError(switch (r.statusCode) {
        401 || 403 => 'The key was not accepted${msg != null ? ': $msg' : '.'}',
        404 => 'Model or address not found${msg != null ? ': $msg' : '.'}',
        429 => 'Rate limit or quota reached. Try again in a moment.',
        _ => 'Request failed (${r.statusCode})${msg != null ? ': $msg' : ''}',
      });
    }
    final out = _extract(j).trim().replaceAll(RegExp(r'^<text>\s*|\s*</text>$'), '');
    if (out.isEmpty) throw AssistError('The model returned nothing.');
    return out;
  }

  String? _errorMessage(Object? j) {
    if (j is Map) {
      final e = j['error'];
      if (e is Map && e['message'] is String) return e['message'] as String;
      if (e is String) return e;
    }
    if (j is List && j.isNotEmpty) return _errorMessage(j.first);
    return null;
  }

  Future<http.Response> _claude(String user) => _c.post(
        Uri.parse('https://api.anthropic.com/v1/messages'),
        headers: {
          'x-api-key': cfg.key,
          'anthropic-version': '2023-06-01',
          'anthropic-beta': 'server-side-fallback-2026-07-01',
          'content-type': 'application/json',
        },
        body: jsonEncode({
          'model': cfg.model,
          'max_tokens': 16000,
          'system': _system,
          'output_config': {'effort': 'medium'},
          'fallbacks': 'default',
          'messages': [
            {'role': 'user', 'content': user}
          ],
        }),
      );

  Future<http.Response> _openai(String user) {
    final base = cfg.baseUrl.replaceAll(RegExp(r'/+$'), '');
    return _c.post(
      Uri.parse('$base/chat/completions'),
      headers: {
        if (cfg.key.isNotEmpty) 'Authorization': 'Bearer ${cfg.key}',
        'content-type': 'application/json',
      },
      body: jsonEncode({
        'model': cfg.model,
        'messages': [
          {'role': 'system', 'content': _system},
          {'role': 'user', 'content': user},
        ],
      }),
    );
  }

  Future<http.Response> _gemini(String user) => _c.post(
        Uri.https('generativelanguage.googleapis.com', '/v1beta/models/${cfg.model}:generateContent'),
        headers: {'x-goog-api-key': cfg.key, 'content-type': 'application/json'},
        body: jsonEncode({
          'systemInstruction': {
            'parts': [
              {'text': _system}
            ]
          },
          'contents': [
            {
              'role': 'user',
              'parts': [
                {'text': user}
              ]
            }
          ],
        }),
      );

  String _extract(Object? j) {
    if (j is! Map) return '';
    switch (cfg.provider) {
      case AiProvider.claude:
        if (j['stop_reason'] == 'refusal') throw AssistError('Claude declined this request.');
        return [
          for (final b in (j['content'] as List? ?? const []))
            if (b is Map && b['type'] == 'text') b['text'] as String
        ].join();
      case AiProvider.openai:
        final ch = j['choices'];
        if (ch is List && ch.isNotEmpty) {
          final m = ch.first['message'];
          if (m is Map && m['content'] is String) return m['content'] as String;
        }
        return '';
      case AiProvider.gemini:
        final c = j['candidates'];
        if (c is List && c.isNotEmpty) {
          final parts = c.first['content']?['parts'];
          if (parts is List) {
            return [for (final p in parts) if (p is Map && p['text'] is String) p['text'] as String].join();
          }
        }
        if (j['promptFeedback']?['blockReason'] != null) throw AssistError('Gemini blocked this request.');
        return '';
    }
  }
}
