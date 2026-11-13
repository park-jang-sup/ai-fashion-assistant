// 속성 값 한국어 검증 — docs/task_text_model_v1.md §4-0-b.
// 일본어(가나)·한자가 섞인 속성은 저장하지 않고 FormatException으로 폴백한다
// (2026-11-13 "레ギュラー" 24건 정정의 재발 방지).
import 'package:ai_fashion_assistant/models/clothing_attributes.dart';
import 'package:ai_fashion_assistant/services/gemini_service.dart';
import 'package:flutter_test/flutter_test.dart';

ClothingAttributes _attrs({String fit = '레귤러', List<String> tags = const ['코튼']}) => ClothingAttributes(
      color: '블랙',
      style: '캐주얼',
      pattern: '무지',
      formality: '캐주얼',
      fit: fit,
      tags: tags,
    );

void main() {
  test('실제로 저장됐던 값 "레ギュラー"(한글+가타카나)를 잡는다', () {
    expect(GeminiService.containsJapaneseOrHanja('레ギュラー'), isTrue);
    expect(GeminiService.attributesContainJapanese(_attrs(fit: '레ギュラー')), isTrue);
  });

  test('히라가나·반각 가타카나·한자도 잡는다', () {
    expect(GeminiService.containsJapaneseOrHanja('くろ'), isTrue);
    expect(GeminiService.containsJapaneseOrHanja('ﾌﾞﾗｯｸ'), isTrue);
    expect(GeminiService.containsJapaneseOrHanja('黑色'), isTrue);
  });

  test('한국어·라틴 문자·숫자·기호는 허용한다(V넥, A라인)', () {
    for (final v in ['레귤러', 'V넥', 'A라인', '7부', '봄/가을', 'Y2K', '데님 & 코튼']) {
      expect(GeminiService.containsJapaneseOrHanja(v), isFalse, reason: v);
    }
    expect(GeminiService.attributesContainJapanese(_attrs(tags: ['V넥', 'A라인'])), isFalse);
  });

  test('tags 안의 값도 검사한다', () {
    expect(GeminiService.attributesContainJapanese(_attrs(tags: ['코튼', 'ニット'])), isTrue);
  });

  test('클라이언트 별칭 — 실제 모델명이 아니라 서버 경로 표의 별칭을 보낸다', () {
    expect(GeminiService.primaryTextModel, 'text-primary');
    expect(GeminiService.textModelFallback, 'text-fallback');
  });
}
