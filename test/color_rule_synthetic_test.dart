// 색상 궁합 규칙(family 매트릭스/톤온톤/톤인톤/팔레트)이 유채색이 늘어난
// 옷장에서 실제로 작동하는지 통제된 합성 데이터로 검증한다. 실데이터
// 의존 없음(임베딩/Firestore 무관 — 순수 OutfitMatcher 로직 검증).
// ignore_for_file: avoid_print — 시나리오별 기대값/실제값을 눈으로 보려는 목적.
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_fashion_assistant/models/clothing_attributes.dart';
import 'package:ai_fashion_assistant/models/wardrobe_item.dart';
import 'package:ai_fashion_assistant/services/outfit_matcher.dart';

import 'support/legacy_matcher.dart';

ClothingAttributes _attrs(String color, {String formality = '캐주얼', String pattern = '무지'}) =>
    ClothingAttributes(
      color: color,
      style: '기본',
      pattern: pattern,
      formality: formality,
      fit: '레귤러',
      tags: const [],
    );

WardrobeItem _item(String id, String category, String color,
        {String formality = '캐주얼', String pattern = '무지'}) =>
    WardrobeItem(
      id: id,
      imageUrl: 'https://example.com/$id.png',
      category: category,
      createdAt: DateTime(2026, 1, 1),
      attributes: _attrs(color, formality: formality, pattern: pattern),
    );

void _expectScore(String label, double actual, double expected) {
  print('[색상규칙] $label → 기대 $expected, 실제 $actual');
  expect(actual, expected, reason: label);
}

void main() {
  group('1. 톤온톤 보너스(같은 family, 밝기 다름)', () {
    test('브라운(어두움) + 카멜(중간) → +1', () {
      final score = OutfitMatcher.colorScoreOnly(_attrs('브라운'), _attrs('카멜'));
      _expectScore('브라운+카멜', score, 1);
    });
  });

  group('2. 깔맞춤 감점(같은 family, 같은 밝기, 같은 패턴)', () {
    test('올리브(무지) + 올리브(무지) → -1', () {
      final score =
          OutfitMatcher.colorScoreOnly(_attrs('올리브', pattern: '무지'), _attrs('올리브', pattern: '무지'));
      _expectScore('올리브+올리브(패턴 동일)', score, -1);
    });
  });

  group('3. 패턴 완화(같은 family, 같은 밝기, 다른 패턴)', () {
    test('올리브(무지) + 올리브(스트라이프) → 0(감점 면제)', () {
      final score = OutfitMatcher.colorScoreOnly(
          _attrs('올리브', pattern: '무지'), _attrs('올리브', pattern: '스트라이프'));
      _expectScore('올리브+올리브(패턴 다름)', score, 0);
    });
  });

  group('4. 톤인톤 보너스(다른 family, 같은 밝기)', () {
    test('올리브(어두움) + 와인(어두움) → +1', () {
      final score = OutfitMatcher.colorScoreOnly(_attrs('올리브'), _attrs('와인'));
      _expectScore('올리브+와인', score, 1);
    });
  });

  group('5. 매트릭스(다른 family, 다른 밝기)', () {
    test('와인(어두움) + 그린(중간) → -1(크리스마스 배색)', () {
      final score = OutfitMatcher.colorScoreOnly(_attrs('와인'), _attrs('그린'));
      _expectScore('와인+그린', score, -1);
    });
    test('브라운(어두움) + 옐로우(중간) → +1(브라운 우대)', () {
      final score = OutfitMatcher.colorScoreOnly(_attrs('브라운'), _attrs('옐로우'));
      _expectScore('브라운+옐로우', score, 1);
    });
  });

  group('6. 팔레트 규칙(유채색 4벌 조합 감점)', () {
    test('무채색 0벌 + 유채색 4벌 조합 → paletteAdjustment -1 적용', () {
      final newItem = _item('top-red', '상의', '레드');
      final bottom = _item('bottom-blue', '하의', '블루');
      final outer = _item('outer-orange', '아우터', '오렌지');
      final shoes = _item('shoes-yellow', '신발', '옐로우');
      final existing = [bottom, outer, shoes];

      final combos =
          OutfitMatcher.findCandidateMatches(newItem: newItem, existingItems: existing);
      expect(combos, isNotEmpty);
      final top = combos.first;

      expect(top.items.map((i) => i.id).toSet(),
          {'top-red', 'bottom-blue', 'outer-orange', 'shoes-yellow'});

      // 팔레트 조정 없이 순수 pairwise 합만 따로 계산해 -1 차이인지 확인.
      final rawSum = [bottom, outer, shoes]
          .map((i) => OutfitMatcher.compatibilityScore(newItem.attributes!, i.attributes!))
          .fold(0.0, (sum, s) => sum + s);

      print('[색상규칙] 팔레트: rawSum=$rawSum, localScore=${top.localScore}');
      expect(top.localScore, rawSum - 1,
          reason: '유채색 4벌(무채색 0벌) 조합은 팔레트 조정 -1이 걸려야 함');
    });
  });

  group('7. 통합 확인 — 규칙 없을 때 vs 있을 때 1번 후보 변화', () {
    test('톤온톤 보너스가 exact-color 매치를 역전시키는지', () {
      final newItem = _item('top-brown', '상의', '브라운');
      // 하의A: newItem과 완전히 같은 색(브라운, exact match) — 구 로직에서 유리.
      final bottomExact = _item('bottom-brown', '하의', '브라운');
      // 하의B: 다른 밝기의 같은 family(카멜) — 신규 로직의 톤온톤 보너스 대상.
      final bottomToneOnTone = _item('bottom-camel', '하의', '카멜');
      // 아우터/신발은 무채색으로 채워 두 로직 사이에서 순위가 안 갈리게(스켈레톤만 채움).
      final outer = _item('outer-black', '아우터', '블랙');
      final shoes = _item('shoes-black', '신발', '블랙');
      final existing = [bottomExact, bottomToneOnTone, outer, shoes];

      final without = legacyFindCandidateMatches(
        newItem: newItem,
        existingItems: existing,
        scoreFn: (a, b) => legacyCompatibilityScore(a, b, legacyNeutralColorsBugfixOnly),
      );
      final withRules =
          OutfitMatcher.findCandidateMatches(newItem: newItem, existingItems: existing);

      String bottomPickOf(List items) =>
          (items.first.items as List<WardrobeItem>).firstWhere((i) => i.category == '하의').id;

      final beforePick = bottomPickOf(without);
      final afterPick = bottomPickOf(withRules);

      print('[색상규칙] 통합: 규칙 전 1번 후보 하의=$beforePick, 규칙 후 1번 후보 하의=$afterPick');

      expect(beforePick, 'bottom-brown', reason: '규칙 전엔 exact-color 매치(브라운)가 이겨야 함');
      expect(afterPick, 'bottom-camel', reason: '규칙 후엔 톤온톤 보너스(카멜)가 이겨야 함');
      expect(beforePick, isNot(afterPick), reason: '유채색이 늘어난 옷장에서는 규칙이 실제로 1번 후보를 바꿔야 함');
    });
  });
}
