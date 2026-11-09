import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:midad/core/assistant.dart';

AiConfig deepseek([String model = 'deepseek-chat']) => AiConfig(
    provider: AiProvider.openai, model: model, key: 'sk-test', baseUrl: aiPresets['DeepSeek']!.$1);

http.Response j(Object body, [int code = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(body)), code, headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  test('DeepSeek: correct request, Arabic reply parsed', () async {
    late http.Request seen;
    final c = MockClient((r) async {
      seen = r;
      return j({
        'choices': [
          {'message': {'role': 'assistant', 'content': 'نص محسّن'}}
        ]
      });
    });
    final out = await AssistantClient(deepseek(), c).run('Improve', 'نص');
    expect(out, 'نص محسّن');
    expect(seen.url.toString(), 'https://api.deepseek.com/v1/chat/completions');
    expect(seen.headers['Authorization'], 'Bearer sk-test');
    final body = jsonDecode(seen.body) as Map;
    expect(body['model'], 'deepseek-chat');
    expect((body['messages'] as List).first['role'], 'system');
    expect((body['messages'] as List).last['content'], contains('<text>\nنص\n</text>'));
  });

  test('deepseek-reasoner: only the final answer is used, never the reasoning', () async {
    final c = MockClient((_) async => j({
          'choices': [
            {
              'message': {'content': 'Final answer', 'reasoning_content': 'long private reasoning…'}
            }
          ]
        }));
    expect(await AssistantClient(deepseek('deepseek-reasoner'), c).run('x', 'y'), 'Final answer');
  });

  test('trailing slash in the address, and <text> wrappers stripped', () async {
    final c = MockClient((r) async {
      expect(r.url.path, '/v1/chat/completions');
      return j({
        'choices': [
          {'message': {'content': '<text>\nclean\n</text>'}}
        ]
      });
    });
    final cfg = AiConfig(provider: AiProvider.openai, model: 'm', key: 'k', baseUrl: 'https://api.deepseek.com/v1///');
    expect(await AssistantClient(cfg, c).run('x', 'y'), 'clean');
  });

  test('Claude: text blocks joined, thinking skipped, refusal reported', () async {
    final cfg = AiConfig(provider: AiProvider.claude, model: 'claude-opus-5-5', key: 'sk-ant-x');
    final ok = MockClient((r) async {
      expect(r.headers['x-api-key'], 'sk-ant-x');
      return j({
        'stop_reason': 'end_turn',
        'content': [
          {'type': 'thinking', 'thinking': ''},
          {'type': 'text', 'text': 'Hello '},
          {'type': 'text', 'text': 'world'},
        ]
      });
    });
    expect(await AssistantClient(cfg, ok).run('x', 'y'), 'Hello world');
    final refuse = MockClient((_) async => j({'stop_reason': 'refusal', 'content': []}));
    expect(() => AssistantClient(cfg, refuse).run('x', 'y'),
        throwsA(isA<AssistError>().having((e) => e.message, 'msg', contains('declined'))));
  });

  test('Gemini: parts joined; blocked prompt reported', () async {
    final cfg = AiConfig(provider: AiProvider.gemini, model: 'gemini-2.0-flash', key: 'g');
    final ok = MockClient((r) async {
      expect(r.url.path, '/v1beta/models/gemini-2.0-flash:generateContent');
      expect(r.headers['x-goog-api-key'], 'g');
      return j({
        'candidates': [
          {
            'content': {
              'parts': [
                {'text': 'A'},
                {'text': 'B'}
              ]
            }
          }
        ]
      });
    });
    expect(await AssistantClient(cfg, ok).run('x', 'y'), 'AB');
    final blocked = MockClient((_) async => j({'promptFeedback': {'blockReason': 'SAFETY'}}));
    expect(() => AssistantClient(cfg, blocked).run('x', 'y'), throwsA(isA<AssistError>()));
  });

  for (final (code, words) in [
    (401, 'not accepted'),
    (403, 'not accepted'),
    (404, 'not found'),
    (429, 'Rate limit'),
    (500, 'failed (500)'),
    (402, 'failed (402)'), // DeepSeek: insufficient balance
  ]) {
    test('HTTP $code gives a clear message', () async {
      final c = MockClient((_) async => j({'error': {'message': 'server says no'}}, code));
      expect(() => AssistantClient(deepseek(), c).run('x', 'y'),
          throwsA(isA<AssistError>().having((e) => e.message, 'msg', contains(words))));
    });
  }

  test('garbage, empty and network failures', () async {
    final html = MockClient((_) async => http.Response('<html>oops</html>', 502));
    expect(() => AssistantClient(deepseek(), html).run('x', 'y'), throwsA(isA<AssistError>()));
    final empty = MockClient((_) async => j({
          'choices': [
            {'message': {'content': '   '}}
          ]
        }));
    expect(() => AssistantClient(deepseek(), empty).run('x', 'y'),
        throwsA(isA<AssistError>().having((e) => e.message, 'msg', contains('nothing'))));
    final noChoices = MockClient((_) async => j({'choices': []}));
    expect(() => AssistantClient(deepseek(), noChoices).run('x', 'y'), throwsA(isA<AssistError>()));
    final offline = MockClient((_) async => throw http.ClientException('no route'));
    expect(() => AssistantClient(deepseek(), offline).run('x', 'y'),
        throwsA(isA<AssistError>().having((e) => e.message, 'msg', contains('Could not reach'))));
  });

  test('not set up: friendly error, no request made', () async {
    var called = false;
    final c = MockClient((_) async {
      called = true;
      return j({});
    });
    final cfg = AiConfig(provider: AiProvider.openai, model: 'deepseek-chat', key: '', baseUrl: aiPresets['DeepSeek']!.$1);
    expect(() => AssistantClient(cfg, c).run('x', 'y'), throwsA(isA<AssistError>()));
    expect(called, isFalse);
  });

  test('Ollama on this computer needs no key', () {
    final cfg = AiConfig(provider: AiProvider.openai, model: 'llama3.1', key: '', baseUrl: 'http://localhost:11434/v1');
    expect(cfg.ready, isTrue);
  });

  test('config validation (also guards configs sent from the other device)', () {
    expect(AiConfig.fromJson(deepseek().toJson()), isNotNull);
    expect(AiConfig.fromJson({'p': 'openai', 'm': 'x', 'k': 'k', 'b': 'http://evil.example.com/v1'}), isNull,
        reason: 'plain http to the internet would leak the key');
    expect(AiConfig.fromJson({'p': 'openai', 'm': 'x', 'k': '', 'b': 'http://localhost:11434/v1'}), isNotNull);
    expect(AiConfig.fromJson({'p': 'openai', 'm': 'x', 'k': 'k', 'b': 'javascript:alert(1)'}), isNull);
    expect(AiConfig.fromJson({'p': 'nope', 'm': 'x', 'k': 'k'}), isNull);
    expect(AiConfig.fromJson({'p': 'claude', 'm': 'x' * 200, 'k': 'k'}), isNull);
    expect(AiConfig.fromJson({'p': 'claude', 'm': '', 'k': 'k'}), isNull);
    expect(AiConfig.fromJson('not a map'), isNull);
    expect(AiConfig.fromJson({'p': 'claude', 'm': 'x', 'k': 5}), isNull);
  });

  test('labels', () {
    expect(deepseek().label, 'DeepSeek · deepseek-chat');
    expect(AiConfig(provider: AiProvider.claude, model: 'claude-opus-5-5', key: 'k').label,
        'Claude · claude-opus-5-5');
  });
}
