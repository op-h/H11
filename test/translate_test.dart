// Live tests: these call the real free services over the internet.
import 'package:flutter_test/flutter_test.dart';
import 'package:midad/core/translate.dart';

void main() {
  test('splitText keeps every character and respects the limit', () {
    final text = List.generate(300, (i) => 'Paragraph $i has a few words in it.').join('\n');
    final parts = splitText(text, 500);
    expect(parts.every((p) => p.length <= 500), isTrue);
    expect(parts.join(), text);
  });

  test('direction detection', () {
    expect(targetFor('Hello there'), 'ar');
    expect(targetFor('مرحبا بك'), 'en');
  });

  test('Google free: English → Arabic, keeps paragraphs', () async {
    final out = await GoogleFree().translate('Good morning.\n\nThe meeting is at three.', 'ar');
    expect(isMostlyArabic(out), isTrue);
    expect(out.contains('\n'), isTrue);
  });

  test('Google free: Arabic → English', () async {
    final out = await GoogleFree().translate('مكان هادئ في الحي ورفوف خشبية', 'en');
    expect(isMostlyArabic(out), isFalse);
    expect(out.toLowerCase(), contains('quiet'));
  });

  test('Google free: a long text (≈12,000 chars) in several requests', () async {
    final text = List.generate(240, (i) => 'Line $i: the studio has north light.').join('\n');
    final out = await GoogleFree().translate(text, 'ar');
    expect(isMostlyArabic(out), isTrue);
    expect('\n'.allMatches(out).length, greaterThan(200));
  });

  test('MyMemory backup works', () async {
    final out = await MyMemory().translate('Quiet place in the neighborhood', 'ar');
    expect(isMostlyArabic(out), isTrue);
  });

  test('bad DeepL key falls back to Google automatically', () async {
    final svc = TranslationService(choice: EngineChoice.auto, deeplKey: 'not-a-real-key-000000:fx');
    final (out, by) = await svc.translate('Thank you for your help.', 'ar');
    expect(by, 'Google');
    expect(isMostlyArabic(out), isTrue);
  });
}
