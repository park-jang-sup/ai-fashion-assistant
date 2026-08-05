// TpoMatchPolicy.useEmbeddingRecovery(임베딩 회수 축)의 순수 로직 단위 테스트.
// 벡터는 손으로 만든다 — items.json/embeddings.json에 의존하지 않는다(CI에는
// 두 파일이 없다). 참조 벡터를 항상 R=[1,0,0]으로 고정해두면 dot(v, R) = v[0]
// 이라 코사인 값을 암산으로 검증할 수 있다(cosineSimilarity는 정규화를
// 가정하지 않는 순수 내적이라 이렇게 둬도 대소 비교에는 문제가 없다).
import 'package:flutter_test/flutter_test.dart';
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

WardrobeItem _item(
  String id,
  String category,
  String color,
  String formality, {
  List<double>? embedding,
}) =>
    WardrobeItem(
      id: id,
      imageUrl: 'https://example.com/$id.png',
      category: category,
      createdAt: DateTime(2026, 1, 1),
      attributes: _attrs(color, formality),
      embedding: embedding,
    );

// 참조 전용 아이템 — recentItemIds에만 등장하고 조합 후보에는 절대 안 들어간다.
// '전신'은 _outfitCategories 밖이라 allPerCategory 필터(outfit_matcher.dart:414)
// 에서 항상 걸러지므로 attributes 없이도 무해하다.
WardrobeItem _ref(String id, List<double> embedding) => WardrobeItem(
      id: id,
      imageUrl: 'https://example.com/$id.png',
      category: '전신',
      createdAt: DateTime(2026, 1, 1),
      embedding: embedding,
    );

String _sig(TpoMatchResult res) => res.candidates
    .map((c) => (c.items.map((i) => i.id).toList()..sort()).join(','))
    .join('|');

void main() {
  group('useEmbeddingRecovery — 비활성 기본값', () {
    test('정책이 false면 recentItemIds/embedding이 있어도 결과가 현행과 동일하다', () {
      final ta = _item('ta', '상의', '레드', '캐주얼', embedding: [0, 1, 0]);
      final tb = _item('tb', '상의', '블루', '캐주얼', embedding: [0.99, 0.14, 0]);
      final bottom = _item('bt', '하의', '네이비', '캐주얼');
      final r = _ref('r', [1, 0, 0]);
      final wardrobe = [ta, tb, bottom, r];

      final withoutRecencyData = OutfitMatcher.findForTpo(
        wardrobe: wardrobe,
        formalityHint: '캐주얼',
        policy: TpoMatchPolicy.current,
      );
      final withRecencyDataButAxisOff = OutfitMatcher.findForTpo(
        wardrobe: wardrobe,
        formalityHint: '캐주얼',
        policy: TpoMatchPolicy.current, // useEmbeddingRecovery 기본 false
        recentItemIds: {'r'},
      );
      expect(_sig(withRecencyDataButAxisOff), _sig(withoutRecencyData));
    });
  });

  group('useEmbeddingRecovery — 점수 순서 불가침', () {
    test('격식 등급이 다른 두 아이템은 유사도 방향과 무관하게 점수 순서가 유지된다', () {
      // fit: 포멀 정확 일치(diff0→3점), unfit: 인접 등급(diff1→1점) — 동점이
      // 아니므로 회수 축이 어떻게 설정돼도 순서를 못 바꿔야 한다. 유사도는
      // 일부러 반대 방향으로 심는다 — fit을 최근 아이템과 완전히 같게(코사인
      // 1.0, 회수 축만 있었다면 뒤로 밀릴 조건), unfit을 완전히 다르게
      // (코사인 0, 앞으로 갈 조건) 둬서 회수 축이 규칙을 어기면 unfit이
      // 앞으로 튀어나오게 만든다.
      final fit = _item('fit', '상의', '레드', '포멀', embedding: [1, 0, 0]);
      final unfit = _item('unfit', '상의', '블루', '세미포멀', embedding: [0, 1, 0]);
      final bottom = _item('bt', '하의', '네이비', '포멀');
      final r = _ref('r', [1, 0, 0]); // fit과 완전히 같은 벡터 → cosine(fit,r)=1

      final result = OutfitMatcher.findForTpo(
        wardrobe: [fit, unfit, bottom, r],
        formalityHint: '포멀',
        policy: TpoMatchPolicy.embeddingRecovery,
        recentItemIds: {'r'},
      );

      expect(result.candidates.first.items.map((i) => i.id), contains('fit'));
      expect(result.candidates.first.items.map((i) => i.id), isNot(contains('unfit')));
    });
  });

  group('useEmbeddingRecovery — 동점 집합 안에서의 회수', () {
    test('최근 노출분과 덜 닮은 아이템이 앞에 온다', () {
      // R=[1,0,0] 고정이므로 dot(v,R)=v[0]. a=0(가장 안 닮음) < c=0.7 < b=0.99
      // (가장 닮음) — 오름차순이 곧 "덜 닮은 순"이라 승자는 a여야 한다.
      final a = _item('a-top', '상의', '레드', '캐주얼', embedding: [0, 1, 0]);
      final b = _item('b-top', '상의', '블루', '캐주얼', embedding: [0.99, 0.14, 0]);
      final c = _item('c-top', '상의', '그린', '캐주얼', embedding: [0.7, 0.7, 0]);
      final bottom = _item('bt', '하의', '네이비', '캐주얼');
      final r = _ref('r', [1, 0, 0]);

      final result = OutfitMatcher.findForTpo(
        wardrobe: [a, b, c, bottom, r],
        formalityHint: '캐주얼',
        policy: TpoMatchPolicy.embeddingRecovery,
        recentItemIds: {'r'},
      );

      expect(result.candidates.first.items.map((i) => i.id), contains('a-top'));
    });
  });

  group('useEmbeddingRecovery — 벡터 보유 블록', () {
    test('embedding == null 아이템은 유사도와 무관하게 뒤로 밀린다', () {
      // 'a-no-embed'를 id 알파벳 순으로 가장 앞에 둔다 — 블록 분리 없이 id
      // 타이브레이크만 작동했다면 이 아이템이 이겼을 상황을 일부러 만든다.
      final noEmbed = _item('a-no-embed', '상의', '레드', '캐주얼'); // embedding 없음
      final dissimilar = _item('b-dissimilar', '상의', '블루', '캐주얼', embedding: [0, 1, 0]);
      final similar = _item('c-similar', '상의', '그린', '캐주얼', embedding: [0.99, 0.14, 0]);
      final bottom = _item('bt', '하의', '네이비', '캐주얼');
      final r = _ref('r', [1, 0, 0]);

      final result = OutfitMatcher.findForTpo(
        wardrobe: [noEmbed, dissimilar, similar, bottom, r],
        formalityHint: '캐주얼',
        policy: TpoMatchPolicy.embeddingRecovery,
        recentItemIds: {'r'},
      );

      final winner = result.candidates.first.items.map((i) => i.id).toSet();
      expect(winner.contains('a-no-embed'), isFalse,
          reason: 'embedding 없는 아이템이 벡터 보유 블록보다 앞섬: $winner');
      expect(winner.contains('b-dissimilar'), isTrue);
    });
  });

  group('useEmbeddingRecovery — recentItemIds가 비면 비활성', () {
    test('축은 켜져 있어도 recentItemIds가 비면 결과가 현행과 동일하다', () {
      final ta = _item('ta', '상의', '레드', '캐주얼', embedding: [0, 1, 0]);
      final tb = _item('tb', '상의', '블루', '캐주얼', embedding: [0.99, 0.14, 0]);
      final bottom = _item('bt', '하의', '네이비', '캐주얼');
      final wardrobe = [ta, tb, bottom];

      final axisOffNoData = OutfitMatcher.findForTpo(
        wardrobe: wardrobe,
        formalityHint: '캐주얼',
        policy: TpoMatchPolicy.current,
      );
      final axisOnNoRecent = OutfitMatcher.findForTpo(
        wardrobe: wardrobe,
        formalityHint: '캐주얼',
        policy: TpoMatchPolicy.embeddingRecovery,
        // recentItemIds 기본값(빈 집합) — 명시하지 않는다.
      );
      expect(_sig(axisOnNoRecent), _sig(axisOffNoData));
    });
  });

  group('useEmbeddingRecovery — 자기 자신 제외', () {
    test('recentItemIds에 자기 자신이 있어도 그 코사인(1.0)이 자기 순위에 반영되지 않는다', () {
      // a 자신이 recentItemIds에 있다. 자기 자신을 안 뺐다면 cosine(a,a)=1.0이
      // "최댓값"이 되어 a가 무조건 뒤로 밀린다(recencyPenalty를 벡터로 한 번
      // 더 먹이는 꼴). 제대로 뺐다면 a의 유사도는 r([0,1,0])과의 코사인(=0,
      // 안 닮음)만 남아, b-top(양쪽 다 0.5)보다 오히려 앞으로 와야 한다.
      //
      // 기본 프리셋(recencyPenalty 0.4)을 쓰면 자기 자신이 recentItemIds에 있다는
      // 이유로 감점까지 함께 적용돼 rankScore 자체가 갈리고, 이 테스트가 확인하려는
      // "동점 안에서의 자기 자신 제외"가 애초에 시험되지 않는다. 두 축이
      // recentItemIds를 공유하기 때문이다.
      //
      // 따라서 이 테스트는 **출시 기본값에서는 도달하지 않는 경로**를 검증한다.
      // 기본값에서는 자기 자신이 이미 감점으로 동점 집합 밖으로 밀려난다.
      // 규칙 자체는 정책 값과 무관하게 성립해야 하므로 검증은 유지한다.
      final a = _item('a', '상의', '레드', '캐주얼', embedding: [1, 0, 0]);
      final b = _item('b-top', '상의', '블루', '캐주얼', embedding: [0.5, 0.5, 0]);
      final bottom = _item('bt', '하의', '네이비', '캐주얼');
      final r = _ref('r', [0, 1, 0]);

      final result = OutfitMatcher.findForTpo(
        wardrobe: [a, b, bottom, r],
        formalityHint: '캐주얼',
        policy: const TpoMatchPolicy(useEmbeddingRecovery: true, recencyPenalty: 0.0),
        recentItemIds: {'a', 'r'}, // a 자신 + 외부 참조 r
      );

      expect(
        result.candidates.first.items.map((i) => i.id),
        contains('a'),
        reason: '자기 자신의 코사인이 반영됐다면 a가 밀려나 b-top이 이겨야 함',
      );
    });
  });

  group('useEmbeddingRecovery — 금지 사항 불변', () {
    test('회수 축을 켜도 isFallback·mismatchedCategories·keep 집합이 완전히 동일하다', () {
      // 상의 두 벌이 서로 동점(둘 다 diff2→0점, 무채색 아님)이라 relaxed에서만
      // 살아남고, 아우터 한 벌도 마찬가지로 score 0. 하의만 포멀+무채색이라
      // scored에 남아 hasCore가 false → fallback 경로. 이 스캐폴딩 자체는
      // outfit_matcher_test.dart의 mismatchedCategories 테스트와 동일하다 —
      // 여기서는 "회수 축을 켜면 순서는 바뀌어도 폴백 판정 자체는 안 바뀐다"만
      // 새로 확인한다.
      final topA = _item('topA', '상의', '레드', '캐주얼', embedding: [1, 0, 0]);
      final topB = _item('topB', '상의', '블루', '캐주얼', embedding: [0, 1, 0]);
      final outer = _item('outer-1', '아우터', '레드', '캐주얼');
      final bottom = _item('bottom-1', '하의', '네이비', '포멀');
      final r = _ref('r', [1, 0, 0]); // topA와 완전히 같은 벡터

      TpoMatchResult run(TpoMatchPolicy policy) => OutfitMatcher.findForTpo(
            wardrobe: [topA, topB, outer, bottom, r],
            formalityHint: '포멀',
            maxCandidates: 99,
            policy: policy,
            recentItemIds: {'r'},
          );

      final off = run(TpoMatchPolicy.current);
      final on = run(TpoMatchPolicy.embeddingRecovery);

      // 회수 축이 실제로 순서를 바꿨는지 먼저 확인한다 — 안 바뀌었다면 아래
      // "불변"이 성립해도 아무것도 증명하지 못하는 공허한 테스트가 된다.
      expect(
        off.candidates.first.items.map((i) => i.id).toList(),
        isNot(equals(on.candidates.first.items.map((i) => i.id).toList())),
        reason: '이 테스트의 전제(회수가 실제로 순서를 바꿈)가 깨짐',
      );

      expect(on.isFallback, off.isFallback);
      expect(on.mismatchedCategories, off.mismatchedCategories);
      expect(on.optionalMissing, off.optionalMissing);

      Set<String> itemPool(TpoMatchResult r) =>
          {for (final c in r.candidates) ...c.items.map((i) => i.id)};
      expect(
        itemPool(on),
        itemPool(off),
        reason: '회수 축이 켜졌다고 keep 집합(조합 가능한 아이템 구성) 자체가 달라짐',
      );
    });
  });

  group('useEmbeddingRecovery — 3블록: 유사도 없음 블록', () {
    test('유사도 값이 없는 아이템(참조 집합이 자기 자신뿐)이 벡터+유사도 블록과 벡터 없음 블록 사이에 온다', () {
      // 참조 집합이 x-self 하나뿐이고 x-self 자신도 그 참조 집합에 있다.
      // 자기 자신을 제외하면 x-self의 참조 집합은 비어 유사도 값이 안 생긴다
      // (블록1: 벡터는 있으나 유사도 없음). y-has-sim은 x-self를 참조해
      // 유사도 값이 생긴다(블록0). z-no-vec은 embedding 자체가 없다(블록2).
      //
      // id를 일부러 알파벳 순(x<y<z)과 기대 순서(y,x,z)가 다르게 골랐다 —
      // id 타이브레이크만 작동해도 우연히 통과하는 공허한 테스트를 피하기
      // 위해서다.
      //
      // recencyPenalty는 0으로 끈다 — x-self가 recentItemIds에 있으므로
      // 기본값(0.4)이면 rankScore 단계에서 이미 밀려나 "동점 집합 안에서의
      // 블록 분리"를 시험하지 못한다(테스트6과 같은 이유).
      final xSelf = _item('x-self', '상의', '레드', '캐주얼', embedding: [1, 0, 0]);
      final yHasSim = _item('y-has-sim', '상의', '블루', '캐주얼', embedding: [0.6, 0.8, 0]);
      final zNoVec = _item('z-no-vec', '상의', '그린', '캐주얼'); // embedding 없음
      final bottom = _item('bt', '하의', '네이비', '캐주얼');

      final result = OutfitMatcher.findForTpo(
        wardrobe: [xSelf, yHasSim, zNoVec, bottom],
        formalityHint: '캐주얼',
        policy: const TpoMatchPolicy(useEmbeddingRecovery: true, recencyPenalty: 0.0),
        recentItemIds: {'x-self'},
      );

      // candidatesPerCategory 기본 2라 상위 2개만 살아남는다. 블록 순서가
      // 맞다면 y(블록0)와 x(블록1)가 살아남고 z(블록2)는 잘려야 한다.
      final survivors = {for (final c in result.candidates) ...c.items.map((i) => i.id)};
      expect(
        survivors.contains('z-no-vec'),
        isFalse,
        reason: '벡터 없는 아이템이 블록1(벡터만 있음)보다 앞에 살아남음: $survivors',
      );
      expect(
        result.candidates.first.items.map((i) => i.id),
        contains('y-has-sim'),
        reason: '유사도 값이 있는 아이템(블록0)이 1번이 아님',
      );
    });
  });

  group('useEmbeddingRecovery — 전이성', () {
    test('반례(A·B·C, 참조 집합 {B}, map[A]=0.8, map[C]=0.2, map[B]=없음)가 순환을 만들지 않는다', () {
      // 78abe0f 직후 발견된 반례를 그대로 재현한다. B 자신이 참조 집합에
      // 있어 자기 제외 후 유사도 값이 없어진다(블록1). A·C는 B와의 유사도로
      // 블록0에서 오름차순 비교된다(C=0.2 < A=0.8 → C가 앞).
      //
      // 2블록(벡터 있음/없음)뿐이었던 이전 구현이었다면: A vs C는 유사도로
      // C<A, A vs B/B vs C는 유사도 비교를 건너뛰고 id로 A<B<C가 나와
      // A<B, B<C, C<A가 동시에 성립하는 순환이 생겼다. 3블록 분리 후에는
      // B가 블록1로 A·C(블록0)보다 항상 뒤이므로 순환 자체가 성립할 수
      // 없다 — C<A<B로 완전히 일관된 순서 하나만 나와야 한다.
      //
      // recencyPenalty는 0으로 끈다 — b-item이 recentItemIds에 있으므로
      // 기본값이면 rankScore 단계에서 이미 밀려나 반례의 전제(A·B·C가
      // 동점)가 깨진다.
      final a = _item('a-item', '상의', '레드', '캐주얼', embedding: [0.8, 0, 0]);
      final b = _item('b-item', '상의', '블루', '캐주얼', embedding: [1, 0, 0]);
      final c = _item('c-item', '상의', '그린', '캐주얼', embedding: [0.2, 0, 0]);
      final bottom = _item('bt', '하의', '네이비', '캐주얼');

      const policy = TpoMatchPolicy(useEmbeddingRecovery: true, recencyPenalty: 0.0);

      TpoMatchResult run() => OutfitMatcher.findForTpo(
            wardrobe: [a, b, c, bottom],
            formalityHint: '캐주얼',
            policy: policy,
            recentItemIds: {'b-item'},
          );

      // 결정성 — 같은 입력을 여러 번 정렬해도 결과가 매번 같아야 한다.
      // 전이성이 깨진 비교자는 정렬 결과가 정의되지 않아, 최소한 이 검사는
      // 반드시 통과해야 "정렬 결과가 안정적으로 정의됐다"고 말할 수 있다.
      final baseline = _sig(run());
      for (var i = 0; i < 4; i++) {
        expect(_sig(run()), baseline, reason: '동일 입력인데 실행마다 결과가 다름(전이성 위반 신호)');
      }

      // 세 쌍의 비교 결과가 서로 모순되지 않는지 — candidatesPerCategory
      // 기본 2라 상위 2개(C, A)만 살아남고 B(블록1)는 잘려야 한다. B가
      // 살아남으면 순환 때문에 정렬이 예측 불가능하게 동작했다는 신호다.
      final result = run();
      final survivors = {for (final combo in result.candidates) ...combo.items.map((i) => i.id)};
      expect(
        survivors.contains('b-item'),
        isFalse,
        reason: '블록1(유사도 없음) 아이템이 블록0보다 앞에 살아남음: $survivors',
      );

      // C(0.2, 덜 닮음)가 1번, A(0.8, 더 닮음)가 2번이어야 한다 — 순서까지
      // 직접 확인해 "C<A" 관계 자체를 못박는다.
      expect(result.candidates[0].items.map((i) => i.id), contains('c-item'));
      expect(result.candidates[1].items.map((i) => i.id), contains('a-item'));
    });
  });
}
