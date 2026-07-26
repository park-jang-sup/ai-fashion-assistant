// OutfitMatcher.findCandidateMatches의 순수 로직 단위 테스트.
// Firebase/네트워크 없이 결정적으로 검증되는 부분(자기 평가 루프의 재료인
// 후보 조합 생성)만 다룬다.
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_fashion_assistant/constants/tpo_tags.dart';
import 'package:ai_fashion_assistant/models/clothing_attributes.dart';
import 'package:ai_fashion_assistant/models/wardrobe_item.dart';
import 'package:ai_fashion_assistant/services/outfit_matcher.dart';

ClothingAttributes _attrs(String color, String formality) => ClothingAttributes(
      color: color,
      style: '기본',
      pattern: '무지',
      formality: formality,
      fit: '레귤러',
      tags: const [],
    );

WardrobeItem _item(String id, String category, String color, String formality) =>
    WardrobeItem(
      id: id,
      imageUrl: 'https://example.com/$id.png',
      category: category,
      createdAt: DateTime(2026, 1, 1),
      attributes: _attrs(color, formality),
    );

// 조합 안에 같은 카테고리가 두 벌 들어가지 않는다는 불변식.
Set<String> _categories(OutfitMatch m) => m.items.map((i) => i.category).toSet();

void main() {
  // 새 옷: 화이트(뉴트럴) 상의, 캐주얼.
  final newItem = _item('new-top', '상의', '화이트', '캐주얼');

  // 하의는 최고점(A)/차순위(B)가 갈리도록, 아우터·신발은 각 1벌씩.
  final bottomA = _item('bottom-a', '하의', '네이비', '캐주얼'); // 격식차0(+2)+뉴트럴(+2)=4
  final bottomB = _item('bottom-b', '하의', '블랙', '세미포멀'); // 격식차1(+1)+뉴트럴(+2)=3
  final outerA = _item('outer-a', '아우터', '베이지', '캐주얼'); // 4
  final shoesA = _item('shoes-a', '신발', '그레이', '캐주얼'); // 4
  final existing = [bottomA, bottomB, outerA, shoesA];

  group('findCandidateMatches', () {
    test('서로 다른 후보를 최대 3개까지 생성한다', () {
      final candidates = OutfitMatcher.findCandidateMatches(
        newItem: newItem,
        existingItems: existing,
      );
      expect(candidates.length, 3);

      // 후보들은 아이템 구성이 서로 달라야 한다(중복 제거).
      final signatures = candidates
          .map((c) => (c.items.map((i) => i.id).toList()..sort()).join(','))
          .toSet();
      expect(signatures.length, candidates.length);

      // 모든 후보는 새 옷을 포함하고, 카테고리가 겹치지 않는다.
      for (final c in candidates) {
        expect(c.items.any((i) => i.id == newItem.id), isTrue);
        expect(_categories(c).length, c.items.length);
      }
    });

    test('1번 후보는 카테고리별 최고점 풀 조합(localScore 최대)이다', () {
      final candidates = OutfitMatcher.findCandidateMatches(
        newItem: newItem,
        existingItems: existing,
      );
      final first = candidates.first;
      // 새 옷 + 하의A + 아우터A + 신발A = 4벌, localScore 4+4+4=12.
      expect(first.items.length, 4);
      expect(first.localScore, 12);
      expect(first.items.map((i) => i.id), containsAll(['bottom-a', 'outer-a', 'shoes-a']));
      // 차순위 하의B는 1번 조합에 들어가지 않는다.
      expect(first.items.map((i) => i.id), isNot(contains('bottom-b')));
    });

    test('변형 후보에는 차순위 교체 조합이 포함된다', () {
      final candidates = OutfitMatcher.findCandidateMatches(
        newItem: newItem,
        existingItems: existing,
      );
      // 하의를 차순위(B)로 바꾼 조합이 후보 어딘가에 있어야 한다.
      final hasSwap = candidates.any((c) => c.items.any((i) => i.id == 'bottom-b'));
      expect(hasSwap, isTrue);
    });

    test('findBestMatch는 1번 후보와 동일하다', () {
      final best = OutfitMatcher.findBestMatch(newItem: newItem, existingItems: existing);
      final candidates = OutfitMatcher.findCandidateMatches(
        newItem: newItem,
        existingItems: existing,
      );
      expect(best, isNotNull);
      expect(best!.localScore, candidates.first.localScore);
      expect(
        (best.items.map((i) => i.id).toList()..sort()),
        (candidates.first.items.map((i) => i.id).toList()..sort()),
      );
    });

    test('maxCandidates 상한을 지킨다', () {
      final candidates = OutfitMatcher.findCandidateMatches(
        newItem: newItem,
        existingItems: existing,
        maxCandidates: 1,
      );
      expect(candidates.length, 1);
    });

    test('새 옷에 attributes가 없으면 빈 리스트', () {
      final noAttrs = WardrobeItem(
        id: 'x',
        imageUrl: '',
        category: '상의',
        createdAt: DateTime(2026, 1, 1),
      );
      expect(
        OutfitMatcher.findCandidateMatches(newItem: noAttrs, existingItems: existing),
        isEmpty,
      );
    });

    test('매칭 대상이 아닌 카테고리(액세서리)면 빈 리스트', () {
      final accessory = _item('acc', '액세서리', '블랙', '캐주얼');
      expect(
        OutfitMatcher.findCandidateMatches(newItem: accessory, existingItems: existing),
        isEmpty,
      );
    });

    test('궁합 후보가 없으면 빈 리스트', () {
      expect(
        OutfitMatcher.findCandidateMatches(newItem: newItem, existingItems: const []),
        isEmpty,
      );
    });
  });

  group('findForTpo — mismatchedCategories', () {
    test('상의·아우터가 격식에 안 맞으면 차선(fallback)이고 둘 다 부족 카테고리로 잡힌다', () {
      // 상의/아우터: 캐주얼+유채색 → 포멀 타깃 기준 diff=2, 무채색 보너스도
      // 없어 score=0(scored 제외, relaxed엔 남음).
      final top = _item('top-1', '상의', '레드', '캐주얼');
      final outer = _item('outer-1', '아우터', '레드', '캐주얼');
      // 하의: 포멀+무채색이라 score>0으로 scored에 남는다(hasCore를 상의만
      // 걸리게 하기 위해 하의는 정상으로 둠).
      final bottom = _item('bottom-1', '하의', '네이비', '포멀');

      final result = OutfitMatcher.findForTpo(
        wardrobe: [top, outer, bottom],
        formalityHint: '포멀',
      );

      expect(result.isFallback, isTrue);
      expect(result.mismatchedCategories, ['상의', '아우터']);
      expect(result.candidates, isNotEmpty);
    });

    test('전 카테고리가 격식에 맞으면 fallback이 아니고 mismatchedCategories가 비어 있다', () {
      final top = _item('top-2', '상의', '화이트', '포멀');
      final bottom = _item('bottom-2', '하의', '블랙', '포멀');

      final result = OutfitMatcher.findForTpo(
        wardrobe: [top, bottom],
        formalityHint: '포멀',
      );

      expect(result.isFallback, isFalse);
      expect(result.mismatchedCategories, isEmpty);
    });

    test('실사용 TPO 태그("결혼식")로도 포멀 등급에 실제 도달해 mismatchedCategories가 채워진다', () {
      // TpoTags에 포멀 태그가 추가되기 전에는 formalityHint: '포멀' 호출이
      // 이 테스트 파일 안에서만 가능한 합성 시나리오였다 — 실제 TPO 선택
      // UI에서는 절대 나올 수 없는 문자열이라 이 fallback 분기가 죽은
      // 코드나 마찬가지였다. 이제 TpoTags.byLabel('결혼식')에서 나온 값을
      // 그대로 findForTpo에 넘겨, 실사용 경로에서도 진짜로 도달 가능함을
      // 못박는다.
      final formalityHint = TpoTags.byLabel('결혼식').formalityHint;
      expect(formalityHint, '포멀');

      final top = _item('top-3', '상의', '레드', '캐주얼');
      final outer = _item('outer-3', '아우터', '레드', '캐주얼');
      final bottom = _item('bottom-3', '하의', '네이비', '포멀');

      final result = OutfitMatcher.findForTpo(
        wardrobe: [top, outer, bottom],
        formalityHint: formalityHint,
      );

      expect(result.isFallback, isTrue);
      expect(result.mismatchedCategories, ['상의', '아우터']);
    });
  });
}
