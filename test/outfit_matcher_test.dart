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
String _sigOf(OutfitMatch m) =>
    (m.items.map((i) => i.id).toList()..sort()).join(',');

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

  // candidatesPerCategory(후보 폭)와 usePairwiseColorScore(조합 단위 색상
  // 채점). 두 축 모두 기본값이 현행이라, 먼저 "기본 정책은 아무것도 바뀌지
  // 않는다"를 못박고 그다음에 각 축의 효과를 본다.
  group('findForTpo — 조합 품질 정책', () {
    // 유채색으로 구성한 합성 옷장. 무채색이 섞이면 _colorScore가 무조건 2를
    // 반환해(와일드카드) 규칙 간 차이가 안 드러나므로 일부러 배제한다 —
    // 실측 옷장이 무채색 편중이라 A/B에서 효과가 안 보이는 것과 같은 이유다.
    final topRed = _item('t-red', '상의', '레드', '캐주얼');
    final topBlue = _item('t-blue', '상의', '블루', '캐주얼');
    final bottomRed = _item('b-red', '하의', '레드', '캐주얼'); // topRed와 깔맞춤(-1)
    final bottomYellow = _item('b-yellow', '하의', '옐로우', '캐주얼');
    final chromaticWardrobe = [topRed, topBlue, bottomRed, bottomYellow];

    // 폭(candidatesPerCategory) 축을 실제로 시험하려면 카테고리당 후보가
    // 캡보다 많아야 한다 — 2벌짜리 옷장에서는 캡이 2든 4든 6이든 결과가
    // 같아서 어떤 단언도 공허해진다. 카테고리당 8벌, 전부 캐주얼(격식
    // 점수 동점)으로 두어 실측 옷장의 조건 — 동점 대량 발생 — 을 재현한다.
    const chromaticLabels = ['레드', '블루', '옐로우', '그린', '오렌지', '핑크', '퍼플', '브라운'];
    final wideWardrobe = <WardrobeItem>[
      for (var i = 0; i < chromaticLabels.length; i++) ...[
        _item('wt-$i', '상의', chromaticLabels[i], '캐주얼'),
        _item('wb-$i', '하의', chromaticLabels[i], '캐주얼'),
      ],
    ];

    test('기본 정책은 명시적 current와 결과가 동일하다(무손상)', () {
      String sig(TpoMatchResult r) => r.candidates
          .map((c) => (c.items.map((i) => i.id).toList()..sort()).join(','))
          .join('|');

      for (final tag in TpoTags.all) {
        final implicit = OutfitMatcher.findForTpo(
          wardrobe: chromaticWardrobe,
          formalityHint: tag.formalityHint,
        );
        final explicit = OutfitMatcher.findForTpo(
          wardrobe: chromaticWardrobe,
          formalityHint: tag.formalityHint,
          policy: TpoMatchPolicy.current,
        );
        expect(sig(implicit), sig(explicit), reason: '태그: ${tag.label}');
        expect(implicit.isFallback, explicit.isFallback);
      }
    });

    test('current는 전수 조합 경로를 쓰지 않는다(플래그 확인)', () {
      expect(TpoMatchPolicy.current.useEnumeratedCombos, isFalse);
      expect(TpoMatchPolicy.wideCandidates.useEnumeratedCombos, isTrue);
      expect(TpoMatchPolicy.pairwiseColor.useEnumeratedCombos, isTrue);
      expect(TpoMatchPolicy.qualityV2.useEnumeratedCombos, isTrue);
    });

    test('색상 채점을 켜면 같은 계열·같은 밝기 깔맞춤 조합이 1번에서 밀려난다', () {
      // 격식 점수만 보면 네 아이템이 전부 동점(캐주얼 목표, 차0=3점)이라
      // current에서는 1번 후보가 순회 순서로 정해진다. 색상 축을 켜면
      // 레드 상의 + 레드 하의(같은 계열·같은 밝기·같은 패턴 = -1)가
      // 최상위에서 밀려나야 한다.
      final withColor = OutfitMatcher.findForTpo(
        wardrobe: chromaticWardrobe,
        formalityHint: '캐주얼',
        policy: TpoMatchPolicy.qualityV2,
      );

      expect(withColor.candidates, isNotEmpty);
      final topIds = withColor.candidates.first.items.map((i) => i.id).toSet();
      expect(
        topIds.containsAll({'t-red', 'b-red'}),
        isFalse,
        reason: '레드+레드 깔맞춤이 1번 후보로 남아 있음: $topIds',
      );
    });

    test('폭을 넓히면 후보 풀이 넓어진다 — 카테고리당 8벌 옷장', () {
      // 넓어진 풀이 최종 후보(상위 3개)까지 반영되는지는 별개 문제다.
      // 점수순 그리디라 상위 3개가 이웃 조합으로 몰릴 수 있어, 여기서는
      // "폭이 실제로 다른 아이템을 조합에 들여보내는가"만 확인한다.
      // maxCandidates 상한을 풀어 풀 전체를 본다 — 상위 3개만 보면 어느
      // 3개가 뽑히느냐가 동점 정렬에 의존해 단언이 불안정해진다.
      Set<String> pool(TpoMatchPolicy policy) {
        final r = OutfitMatcher.findForTpo(
          wardrobe: wideWardrobe,
          formalityHint: '캐주얼',
          maxCandidates: 999,
          policy: policy,
        );
        return {for (final c in r.candidates) ...c.items.map((i) => i.id)};
      }

      // 생성기 효과를 배제하고 폭만 비교한다(enumeratedOnly ↔ wideCandidates).
      final narrow = pool(TpoMatchPolicy.enumeratedOnly);
      final wide = pool(TpoMatchPolicy.wideCandidates);
      expect(narrow.length, 4); // 상의 2 + 하의 2
      expect(wide.length, 8); // 상의 4 + 하의 4
      expect(wide.difference(narrow), isNotEmpty,
          reason: '폭을 2→4로 넓혔는데 새로 등장한 아이템이 없음: $wide');
    });

    test('폭을 넓혀도 카테고리 중복 없이 조합이 성립한다', () {
      final r = OutfitMatcher.findForTpo(
        wardrobe: chromaticWardrobe,
        formalityHint: '캐주얼',
        policy: TpoMatchPolicy.qualityV2,
      );
      expect(r.candidates, isNotEmpty);
      for (final c in r.candidates) {
        expect(_categories(c).length, c.items.length);
      }
      // 시그니처 중복 없음.
      final signatures = r.candidates
          .map((c) => (c.items.map((i) => i.id).toList()..sort()).join(','))
          .toSet();
      expect(signatures.length, r.candidates.length);
    });

    test('effectiveCandidatesPerCategory가 1~6으로 클램프된다', () {
      // 클램프 자체를 게터로 노출해 직접 단언한다 — 옷장을 통해 간접
      // 확인하면 카테고리당 벌 수가 캡보다 적을 때 클램프를 지워도 통과하는
      // 공허한 테스트가 된다.
      expect(const TpoMatchPolicy(candidatesPerCategory: 99).effectiveCandidatesPerCategory, 6);
      expect(const TpoMatchPolicy(candidatesPerCategory: 7).effectiveCandidatesPerCategory, 6);
      expect(const TpoMatchPolicy(candidatesPerCategory: 6).effectiveCandidatesPerCategory, 6);
      expect(const TpoMatchPolicy(candidatesPerCategory: 0).effectiveCandidatesPerCategory, 1);
      expect(const TpoMatchPolicy(candidatesPerCategory: -3).effectiveCandidatesPerCategory, 1);
      expect(TpoMatchPolicy.current.effectiveCandidatesPerCategory, 2);
    });

    test('클램프가 실제 후보 풀에도 적용된다 — 카테고리당 8벌 옷장', () {
      // 캡 6 vs 무제한을 가르려면 카테고리당 벌 수(8) > 캡(6)이어야 한다.
      Set<String> coverage(int perCategory) {
        final r = OutfitMatcher.findForTpo(
          wardrobe: wideWardrobe,
          formalityHint: '캐주얼',
          maxCandidates: 99, // 후보 상한이 아니라 풀 상한을 보고 싶다
          policy: TpoMatchPolicy(candidatesPerCategory: perCategory),
        );
        return {for (final c in r.candidates) ...c.items.map((i) => i.id)};
      }

      // 8벌 전부를 요구해도 카테고리당 6벌로 잘리므로 상의·하의 합쳐 최대 12벌.
      expect(coverage(99).length, lessThanOrEqualTo(12));
      expect(coverage(99).length, coverage(6).length);
    });

    test('resolveEnumerationWidth — 상한 안이면 폭을 그대로 쓴다', () {
      // 6^4 = 1296 ≤ 2000 → 기본 상한에서는 축소가 일어나지 않는다.
      expect(
        OutfitMatcher.resolveEnumerationWidth(categoryCounts: [6, 6, 6, 6]),
        6,
      );
      // 카테고리별 실제 벌 수가 폭보다 적으면 그만큼만 곱해진다.
      expect(
        OutfitMatcher.resolveEnumerationWidth(categoryCounts: [2, 2]),
        2,
      );
    });

    test('resolveEnumerationWidth — 상한을 넘으면 카테고리가 아니라 폭을 줄인다', () {
      // 카테고리 5개 × 6벌 = 7776 > 2000. 폭을 4로 낮추면 1024로 들어온다.
      // 중요한 건 카테고리 수(5)가 그대로 유지된다는 점 — 조합에서 카테고리가
      // 빠지는 대신 후보만 좁아진다.
      expect(
        OutfitMatcher.resolveEnumerationWidth(categoryCounts: [6, 6, 6, 6, 6]),
        4,
      );
      // 폭 2면 2^3=8 ≤ 10이라 아직 2가 유지된다.
      expect(
        OutfitMatcher.resolveEnumerationWidth(
          categoryCounts: [50, 50, 50],
          maxCombos: 10,
        ),
        2,
      );
      // 상한이 더 빡빡해도 1 밑으로는 안 내려간다 — 카테고리를 버리는 대신
      // 카테고리당 1벌씩 넣은 조합 하나는 반드시 만든다(폴백은 항상 보수적).
      expect(
        OutfitMatcher.resolveEnumerationWidth(
          categoryCounts: [50, 50, 50],
          maxCombos: 7,
        ),
        1,
      );
    });

    test('resolveEnumerationWidth — 미니 조합도 상한 계산에 포함된다', () {
      // 폭 4: 4^4(=256) + 미니 4×4(=16) = 272 > 260 → 축소.
      // 폭 3: 3^4(=81) + 3×3(=9) = 90 ≤ 260 → 채택.
      expect(
        OutfitMatcher.resolveEnumerationWidth(
          categoryCounts: [4, 4, 4, 4],
          miniCounts: [4, 4],
          maxCombos: 260,
        ),
        3,
      );
      // 같은 조건에서 미니를 빼면 256 ≤ 260이라 4가 유지된다 —
      // 즉 미니 몫이 실제로 계산에 들어간다.
      expect(
        OutfitMatcher.resolveEnumerationWidth(
          categoryCounts: [4, 4, 4, 4],
          maxCombos: 260,
        ),
        4,
      );
    });

    test('전수 조합은 skeleton 카테고리를 하나도 빠뜨리지 않는다', () {
      // 상의·하의·아우터·신발이 모두 있는 옷장에서, 최고점 조합에 4개
      // 카테고리가 전부 들어가는지 확인한다(미니 조합은 2벌이므로 별도).
      final full = [
        ...wideWardrobe,
        _item('wo-0', '아우터', '카멜', '캐주얼'),
        _item('wo-1', '아우터', '올리브', '캐주얼'),
        _item('ws-0', '신발', '와인', '캐주얼'),
        _item('ws-1', '신발', '인디고', '캐주얼'),
      ];
      final r = OutfitMatcher.findForTpo(
        wardrobe: full,
        formalityHint: '캐주얼',
        maxCandidates: 999,
        policy: TpoMatchPolicy.qualityV2,
      );
      final fullCombos =
          r.candidates.where((c) => c.items.length > 2).toList();
      expect(fullCombos, isNotEmpty);
      for (final c in fullCombos) {
        expect(_categories(c), {'상의', '하의', '아우터', '신발'});
      }
    });

    // 최근 감점은 topPerCategory의 상위 N 컷 **이전**, 아이템 점수 단계에서
    // 작동해야 한다. 조합 점수에 넣으면 이미 잘린 뒤라 아무 효과가 없다
    // (표9에서 후보 풀을 두 배로 늘려도 등장 아이템이 그대로였던 것과 같은
    // 이유). 아래 테스트들이 그 위치를 못박는다.
    test('감점 0이거나 recent가 비면 현행과 완전히 동일하다', () {
      String sig(TpoMatchResult r) => r.candidates.map((c) => _sigOf(c)).join('|');
      final baseline = OutfitMatcher.findForTpo(
        wardrobe: wideWardrobe,
        formalityHint: '캐주얼',
      );
      // 감점은 있으나 recent가 빈 경우
      expect(
        sig(OutfitMatcher.findForTpo(
          wardrobe: wideWardrobe,
          formalityHint: '캐주얼',
          policy: TpoMatchPolicy.diversityStrong,
        )),
        sig(baseline),
      );
      // recent는 있으나 감점이 0인 경우 — current는 기본값이 0.4로 바뀌어
      // 더 이상 "감점 0" 정책이 아니므로, 감점 0을 보장하는 diversityOff를
      // 명시해야 이 서브케이스의 의도(감점 자체가 0이면 무손상)가 성립한다.
      expect(
        sig(OutfitMatcher.findForTpo(
          wardrobe: wideWardrobe,
          formalityHint: '캐주얼',
          policy: TpoMatchPolicy.diversityOff,
          recentItemIds: {'wt-0', 'wb-0'},
        )),
        sig(baseline),
      );
    });

    test('기본 정책(current)은 이제 감점이 켜져 있다', () {
      // 표14 근거로 2026-07에 recencyPenalty 기본값을 0.0→0.4로 올린 것이
      // 사고가 아니라 의도임을 값과 실제 동작 양쪽으로 못박는다.
      expect(TpoMatchPolicy.current.recencyPenalty, 0.4);
      expect(TpoMatchPolicy.diversityOff.recencyPenalty, 0.0);

      String sig(TpoMatchResult r) => r.candidates.map((c) => _sigOf(c)).join('|');
      const recent = {'wt-0', 'wb-0'};
      final withCurrent = OutfitMatcher.findForTpo(
        wardrobe: wideWardrobe,
        formalityHint: '캐주얼',
        recentItemIds: recent,
      );
      final withDiversityOff = OutfitMatcher.findForTpo(
        wardrobe: wideWardrobe,
        formalityHint: '캐주얼',
        policy: TpoMatchPolicy.diversityOff,
        recentItemIds: recent,
      );
      expect(
        sig(withCurrent),
        isNot(sig(withDiversityOff)),
        reason: 'current(0.4)가 recent 아이템을 실제로 밀어내지 않음: ${sig(withCurrent)}',
      );
    });

    test('최근 아이템은 동점 집합 안에서 뒤로 밀린다', () {
      // wideWardrobe는 전부 캐주얼·유채색이라 8벌 모두 3.0점 동점이다.
      // 현행에서는 순회 순서로 wt-0/wb-0이 뽑히는데, 그 둘을 recent에 넣으면
      // 다음 후보로 교체돼야 한다.
      final before = OutfitMatcher.findForTpo(
        wardrobe: wideWardrobe,
        formalityHint: '캐주얼',
      ).candidates.first.items.map((i) => i.id).toSet();

      final after = OutfitMatcher.findForTpo(
        wardrobe: wideWardrobe,
        formalityHint: '캐주얼',
        policy: TpoMatchPolicy.diversityTieBreak,
        recentItemIds: before,
      ).candidates.first.items.map((i) => i.id).toSet();

      expect(after.intersection(before), isEmpty,
          reason: '최근 아이템이 그대로 1번 후보에 남음: $after');
    });

    test('감점 0.4는 격식 등급을 넘지 못한다(자격이 아니라 순서만 바꾼다)', () {
      // 정확 일치(diff 0 → 3.0)이지만 최근에 입은 상의 vs 인접 등급
      // (diff 1 → 1.0)이고 안 입은 상의. 3.0 - 0.4 = 2.6 > 1.0이므로
      // 여전히 격식이 맞는 쪽이 이겨야 한다.
      // 캐주얼(diff 2)은 0점이라 scored 필터에서 아예 탈락해 비교가 성립하지
      // 않으므로 세미포멀을 쓴다.
      final fitRecent = _item('fit', '상의', '레드', '포멀');
      final unfitFresh = _item('unfit', '상의', '블루', '세미포멀');
      final bottom = _item('bt', '하의', '옐로우', '포멀');

      final r = OutfitMatcher.findForTpo(
        wardrobe: [fitRecent, unfitFresh, bottom],
        formalityHint: '포멀',
        policy: TpoMatchPolicy.diversityTieBreak,
        recentItemIds: {'fit'},
      );
      expect(r.candidates.first.items.map((i) => i.id), contains('fit'));
    });

    test('감점이 충분히 크면 격식 등급을 넘어선다', () {
      // 3.0 - 2.5 = 0.5 < 1.0이라 인접 등급 쪽이 앞선다. 감점 2.0이면 정확히
      // 동점(1.0)이 되어 순서가 뒤집히지 않으므로 2.5로 확실히 가른다 —
      // 이 경계가 곧 "회전을 위해 TPO 정확도를 얼마나 포기하는가"다.
      final fitRecent = _item('fit', '상의', '레드', '포멀');
      final unfitFresh = _item('unfit', '상의', '블루', '세미포멀');
      final bottom = _item('bt', '하의', '옐로우', '포멀');

      final r = OutfitMatcher.findForTpo(
        wardrobe: [fitRecent, unfitFresh, bottom],
        formalityHint: '포멀',
        policy: const TpoMatchPolicy(recencyPenalty: 2.5),
        recentItemIds: {'fit'},
      );
      expect(r.candidates.first.items.map((i) => i.id), contains('unfit'));
    });

    test('감점은 자격(keep)이 아니라 순서만 바꾼다 — isFallback 불변', () {
      // 감점이 score를 0 밑으로 내려도 scored 통과 여부는 그대로여야 한다.
      // 그렇지 않으면 "최근에 뭘 입었는가"가 폴백 판정을 바꾼다.
      final top = _item('t', '상의', '레드', '포멀');
      final bottom = _item('b', '하의', '블루', '포멀');
      final wardrobe = [top, bottom];

      final plain = OutfitMatcher.findForTpo(
        wardrobe: wardrobe,
        formalityHint: '포멀',
      );
      final penalized = OutfitMatcher.findForTpo(
        wardrobe: wardrobe,
        formalityHint: '포멀',
        policy: const TpoMatchPolicy(recencyPenalty: 10.0),
        recentItemIds: {'t', 'b'},
      );
      expect(penalized.isFallback, plain.isFallback);
      expect(penalized.mismatchedCategories, plain.mismatchedCategories);
      expect(penalized.candidates, isNotEmpty);
    });

    test('생성기 축이 폭·색상과 분리된다(enumeratedOnly)', () {
      // enumeratedOnly는 폭·색상이 current와 동일하고 생성기만 다르다.
      expect(TpoMatchPolicy.enumeratedOnly.candidatesPerCategory,
          TpoMatchPolicy.current.candidatesPerCategory);
      expect(TpoMatchPolicy.enumeratedOnly.usePairwiseColorScore,
          TpoMatchPolicy.current.usePairwiseColorScore);
      expect(TpoMatchPolicy.enumeratedOnly.useEnumeratedCombos, isTrue);
      expect(TpoMatchPolicy.current.useEnumeratedCombos, isFalse);
    });
  });
}
