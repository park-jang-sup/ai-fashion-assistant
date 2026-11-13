// 가상 피팅 요청 구성 — docs/task_fitting_quality_v2.md §4 보충 1~5.
// 앱 프롬프트는 프로브(tools/fitting_probe/probe.mjs) 변형 B가 실제로 보낸
// 문자열을 글자 그대로 옮긴 것이다(보충 2). 아래 첫 묶음은 probe.mjs 원문을
// 직접 읽어 대조한다 — 어느 한쪽만 고치면 여기서 깨진다.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai_fashion_assistant/services/gemini_service.dart';
import 'package:flutter_test/flutter_test.dart';

final _jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0, 0, 0, 0]);
final _png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0]);

String _probeLiteral(String source, RegExp pattern) {
  final m = pattern.firstMatch(source);
  if (m == null) fail('probe.mjs에서 $pattern 을 찾지 못함');
  return m.group(1)!;
}

void main() {
  group('프롬프트 문자열 = 프로브 변형 B 원문(보충 2)', () {
    // CRLF 체크아웃(Windows autocrlf)이어도 원문 비교가 깨지지 않게 줄바꿈을 맞춘다.
    final probe = File('tools/fitting_probe/probe.mjs').readAsStringSync().replaceAll('\r\n', '\n');

    test('지시 문장', () {
      final intro = _probeLiteral(probe, RegExp(r'\{text: "(You are a virtual try-on engine\.[^"]*)"\}'));
      expect(GeminiService.fittingIntroText, intro);
    });

    test('전신 라벨', () {
      final label = _probeLiteral(probe, RegExp(r'\{text: "(IMAGE 1 — the PERSON\.[^"]*)"\}'));
      expect(GeminiService.fittingPersonLabelText, label);
    });

    test('Rules(B = NEW_RULES_HEAD + LAST_RULE.b)', () {
      final head = _probeLiteral(probe, RegExp(r'const NEW_RULES_HEAD = `([^`]*)`;'));
      final lastB = _probeLiteral(probe, RegExp(r'^  b: "([^"]*)",$', multiLine: true));
      expect(GeminiService.fittingRulesText, '$head\n$lastB');
    });

    test('옷 라벨 줄 형식 — IMAGE n — ITEM (라벨): 설명', () {
      expect(probe, contains(r'`IMAGE ${i + 2} — ITEM (${SLOTS[slot].label}): ${labels[slot]}`'));
      final parts = GeminiService.buildFittingParts(
        personBytes: _jpeg,
        items: [(bytes: _jpeg, label: '상의 / top', description: '색상 블랙')],
      );
      expect(parts[3], {'text': 'IMAGE 2 — ITEM (상의 / top): 색상 블랙'});
    });

    test('괄호 라벨 — 프로브 SLOTS와 같다(팔찌는 프로브에 없던 새 값)', () {
      const cases = {
        ('상의', null): '상의 / top',
        ('하의', null): '하의 / bottom',
        ('아우터', null): '아우터 / outerwear',
        ('신발', null): '신발 / shoes',
        ('액세서리', '모자'): '모자 / hat, worn on the head',
        ('액세서리', '가방'): '가방 / bag',
        ('액세서리', '시계'): '시계 / watch, worn on the wrist',
      };
      cases.forEach((k, v) {
        expect(GeminiService.fittingItemLabel(category: k.$1, subCategory: k.$2), v);
        expect(probe, contains('label: "$v"'));
      });
      expect(GeminiService.fittingItemLabel(category: '액세서리', subCategory: '팔찌'),
          '팔찌 / bracelet, worn on the wrist');
      expect(GeminiService.fittingItemLabel(category: '액세서리'), '액세서리');
    });
  });

  group('parts 구성', () {
    test('8슬롯 전부 — parts 20 · inlineData 9(서버 request_shape 상한 20/18 안, 보충 5)', () {
      final parts = GeminiService.buildFittingParts(
        personBytes: _jpeg,
        items: List.generate(8, (i) => (bytes: _jpeg, label: 'L$i', description: 'D$i')),
      );
      expect(parts.length, 20);
      expect(parts.where((p) => p.containsKey('inlineData')).length, 9);
    });

    test('순서 — [지시, 전신 라벨, 전신, (옷 라벨, 옷)×N, 규칙]', () {
      final parts = GeminiService.buildFittingParts(
        personBytes: _jpeg,
        items: [
          (bytes: _png, label: '상의 / top', description: 'a'),
          (bytes: _jpeg, label: '하의 / bottom', description: 'b'),
        ],
      );
      expect(parts.map((p) => p.keys.single).toList(),
          ['text', 'text', 'inlineData', 'text', 'inlineData', 'text', 'inlineData', 'text']);
      expect(parts.first['text'], GeminiService.fittingIntroText);
      expect(parts.last['text'], GeminiService.fittingRulesText);
      expect((parts[4]['inlineData'] as Map)['mimeType'], 'image/png');
      expect((parts[4]['inlineData'] as Map)['data'], base64Encode(_png));
      expect((parts[6]['inlineData'] as Map)['mimeType'], 'image/jpeg');
    });
  });

  test('generationConfig — 보충 1 확정 값, aspectRatio 없음', () {
    expect(GeminiService.fittingGenerationConfig, {
      'responseModalities': ['IMAGE'],
      'thinkingConfig': {'thinkingLevel': 'minimal'},
      'imageConfig': {'imageSize': '1K'},
    });
  });

  group('설명 — 프로브 labels.json 형식(보충 4)', () {
    test('subCategory + 속성 요약', () {
      expect(
        GeminiService.fittingItemDescription(
            category: '액세서리', subCategory: '모자', attributesLine: '색상 블랙, 스타일 스트릿'),
        '모자, 색상 블랙, 스타일 스트릿',
      );
    });
    test('subCategory 없음 — 속성 요약만', () {
      expect(GeminiService.fittingItemDescription(category: '상의', attributesLine: '색상 블랙'), '색상 블랙');
    });
    test('속성도 없음 — 카테고리 이름만', () {
      expect(GeminiService.fittingItemDescription(category: '상의'), '상의');
      expect(GeminiService.fittingItemDescription(category: '액세서리', subCategory: '팔찌'), '팔찌');
    });
  });

  test('보내는 순서 — 상의→하의→아우터→신발→액세서리, 액세서리는 입력 순서(보충 3)', () {
    // 입력은 main.dart 슬롯 맵 선언 순서(아우터·상의·하의·신발·모자·가방·시계·팔찌).
    final names = ['아우터', '상의', '하의', '신발', '액세서리', '액세서리', '액세서리', '액세서리'];
    expect(GeminiService.fittingRenderOrder(names), [1, 2, 0, 3, 4, 5, 6, 7]);
  });

  test('mimeType 매직 넘버 판별', () {
    expect(GeminiService.sniffImageMimeType(_png), 'image/png');
    expect(GeminiService.sniffImageMimeType(_jpeg), 'image/jpeg');
    expect(
      GeminiService.sniffImageMimeType(Uint8List.fromList(utf8.encode('RIFF0000WEBPVP8 '))),
      'image/webp',
    );
  });
}
