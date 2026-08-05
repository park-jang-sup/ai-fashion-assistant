import 'package:flutter/foundation.dart';
import '../models/clothing_attributes.dart';
import '../models/wardrobe_item.dart';
import 'color_taxonomy.dart';
import 'embedding_service.dart';

// 새로 등록된 옷과 기존 옷장만으로 어울리는 조합 후보들을 고른다.
// FitPredictor와 동일하게 Gemini 호출 없이 순수 로컬 계산만 수행한다.
class OutfitMatch {
  final List<WardrobeItem> items; // 새 옷 포함
  final double localScore; // 로컬 궁합 점수 합 — 자기 평가 루프의 후보 순서 결정용

  const OutfitMatch(this.items, {this.localScore = 0});
}

// TPO 매칭 결과 — 조합 후보와 함께 "격식이 안 맞아 차선으로 채웠는지(isFallback)",
// "조합 자체가 불가한 경우 무엇이 부족한지(shortfall)"를 함께 전달한다(레벨 4).
class TpoMatchResult {
  final List<OutfitMatch> candidates;
  final bool isFallback;
  final String? shortfall; // candidates가 비었을 때만 채워짐
  // isFallback=true일 때만 채워짐 — 격식에 맞는 아이템이 없어(scored 제외)
  // 차선(relaxed)으로 채운 카테고리 목록. 홈 화면 배지가 "어떤 카테고리가
  // 부족했는지" 구체적으로 안내할 때 쓴다.
  final List<String> mismatchedCategories;
  // policy.optionalCategories(기본 아우터·신발) 중, 후보 조합에는 포함됐지만
  // 그 카테고리에 격식이 진짜로 맞는 아이템이 하나도 없어(순도 0 — 표5
  // 참고) 무채색 보너스로만 살아남은 아이템으로 채운 카테고리. 상의·하의만
  // 맞으면 isFallback=false여도 채워질 수 있다 — mismatchedCategories(필수
  // 부족, isFallback=true에서만 채워짐)와 달리 isFallback과 무관하다.
  final List<String> optionalMissing;

  const TpoMatchResult({
    required this.candidates,
    this.isFallback = false,
    this.shortfall,
    this.mismatchedCategories = const [],
    this.optionalMissing = const [],
  });
}

// findForTpo의 격식 판정 파라미터. gateNeutralBonus/requiredCategories/
// optionalCategories의 기본값은 원래 동작과 동일하다(neutralGating은 논문
// 5.8.3/5.8.4의 수정안이며, 실측 옷장 리포트로 영향을 확인하기 전까지
// 프로덕션 기본값이 되어서는 안 된다). maxSkeletonCategories만 실측
// A/B 리포트(tpo_policy_report_test.dart 표6·표7 — 아우터 6/9, 신발 3/9로
// 매번 정확히 하나가 조용히 탈락)를 근거로 2026-07에 3→4로 올렸다.
// skeleton3은 이전 기본값과의 비교용으로 남겨둔다.
class TpoMatchPolicy {
  // true면 무채색 보너스를 "이미 격식을 충족한 후보"에게만 적용한다(동점 처리용).
  final bool gateNeutralBonus;
  // 이 카테고리가 전부 scored에 있어야 격식 적합으로 본다.
  final Set<String> requiredCategories;
  // 없어도 조합은 성립하지만 부재를 안내해야 하는 카테고리.
  final Set<String> optionalCategories;
  // 조합의 뼈대(skeleton)에 들어갈 수 있는 카테고리 최대 개수. 4개 카테고리
  // (상의·하의·아우터·신발) 중 우선순위+점수 기준 상위 N개만 스켈레톤에
  // 들어가고 나머지는 조합에서 조용히 빠진다. 기본 4 — 표6/표7 실측으로
  // 3에서 올려, 아우터·신발 중 하나가 매번 조용히 탈락하던 문제를 없앴다.
  final int maxSkeletonCategories;
  // 카테고리별로 조합 재료로 남길 후보 벌 수(findForTpo의 topTwo 캡).
  // 기본 2 = 현행. 격식 적합도 점수가 취할 수 있는 값이 {0.5,1,2,3,4} 다섯
  // 개뿐이라 실측 옷장에서 동점이 대량 발생하는데, 2벌만 남기면 그 동점
  // 집합에서 어느 2벌이 뽑히는지가 사실상 wardrobe 순회 순서로 결정된다
  // (동점 타이브레이커 문제 — 표6 초안에서 카테고리 레벨로 한 번 겪었다).
  // 늘려도 조합 채점은 순수 로컬 산술이라 API 비용은 0이다.
  // 1~6으로 클램프한다(6^4=1296 조합 상한).
  final int candidatesPerCategory;
  // 조합 점수에 아이템 쌍 사이의 색상 궁합(_colorScore: 톤온톤/톤인톤/
  // 색상군 매트릭스/깔맞춤 감점)과 팔레트 규칙(_paletteAdjustment)을
  // 반영할지. 기본 false = 현행.
  //
  // 현행 findForTpo의 조합 점수는 "아이템별 격식 적합도의 단순 합"이라
  // 상의와 하의가 서로 어울리는지를 로컬 단계에서 한 번도 계산하지 않는다.
  // color_taxonomy.dart의 3축 정규화와 색채 이론 규칙 전체가 이 경로에서는
  // "무채색인가?" 이진값(+1)으로만 소비되고 있다 — 규칙 엔진이 실제로
  // 도는 곳은 findCandidateMatches(새 옷 등록) 하나뿐이다.
  final bool usePairwiseColorScore;
  // 폭·색상이 기본값이어도 전수 조합 생성기를 쓰게 하는 측정 전용 스위치.
  //
  // 이게 없으면 A/B에 축이 하나 숨는다 — 폭이나 색상 중 하나만 켜도 생성기가
  // 통째로 바뀌기 때문이다. 기존 생성기는 "카테고리별 최고점 고정 + 한 칸씩
  // 차순위 교체"라 후보 3개가 서로 다른 카테고리를 건드리도록 구조적으로
  // 보장되는 반면, 전수 조합은 점수순 그리디라 상위 3개가 한 벌씩만 다른
  // 이웃 조합이 되기 쉽다. 같은 풀(2벌)을 줘도 후보 구성이 달라진다.
  //
  // 따라서 forceEnumerated만 켠 enumeratedOnly를 기준선으로 두고
  // current↔enumeratedOnly(생성기) / enumeratedOnly↔wide(폭) /
  // enumeratedOnly↔color(색상)로 비교해야 귀속이 성립한다.
  final bool forceEnumerated;
  // 최근 추천/착용된 아이템에 매길 감점. 기본 0.4 — 표14 실측 근거로
  // 2026-07에 0.0에서 올렸다(커버리지 12.6%→33.3%, isFallback 0/9 유지).
  //
  // 이 값이 조합 점수가 아니라 **아이템 점수**에 들어간다는 게 핵심이다.
  // 표9에서 후보 풀을 72→144로 두 배 늘려도 실제 등장 아이템이 54로
  // 그대로였던 이유가, 조합 단계에 도달하기 전 topPerCategory의 상위 N
  // 컷에서 이미 잘려 있었기 때문이다. 조합 점수에 감점을 넣으면 같은 이유로
  // 아무것도 바뀌지 않는다.
  //
  // 격식 적합도 점수가 취하는 값은 {0, 0.5, 1, 1.5, 2, 3, 4}이고 인접 값
  // 간격의 최솟값은 0.5다. 기본값 0.4는 그 간격보다 작아 동점 집합 안에서만
  // 순서를 바꾸고(=순회 순서 타이브레이커를 "최근에 안 입은 순"으로 교체)
  // 격식 등급은 절대 못 넘는다. 그 이상(표14의 1.0/2.0)은 무채색 보너스나
  // 격식 등급까지 넘어설 수 있어 실측 없이는 기본값으로 쓰지 않는다.
  final double recencyPenalty;

  // 동점 집합 안에서 임베딩 코사인으로 순서를 회수할지. 기본 false —
  // 켜기 전 산출물이 현행과 완전히 동일해야 한다(933f322·35820db와 같은 패턴).
  //
  // 점수 가중치(double)가 아니라 **2차 정렬 키**인 이유:
  //  (1) 동점 집합 안에서는 기본 점수가 모두 같아, w×코사인을 더해도 w의 크기와
  //      무관하게 순서가 동일하다. w가 결과를 바꾸는 유일한 경우는 동점 경계를
  //      넘을 때이고 그건 금지 대상이다 — 강도를 실측할 자리가 애초에 없다.
  //  (2) recencyPenalty(0.4)가 이미 격식 간격 0.5를 0.1까지 좁혀놓았다. 여기에
  //      w≥0.1이 붙으면 격식 등급이 다른 아이템의 순서가 뒤집힌다. 99-103행의
  //      논증은 감점 축이 하나일 때만 성립하므로, 축을 더하면 깨진다.
  //
  // 이름에 'tiebreak'를 쓰지 않은 이유: 논문 5.14.4가 근거를 "무작위의 대체"에서
  // "정보의 회수"로 재정식화했다. 이름이 옛 근거를 붙들면 다음 사람이 그 근거로
  // 읽는다.
  final bool useEmbeddingRecovery;

  // 카테고리 단위 보충 채움(docs/task_matching_redesign_v1.md §3). true면
  // hasCore(필수 상의·하의 격식 적합)가 성립하는 조합에서, optionalCategories
  // 중 scored에 없는 카테고리를 relaxed 후보로 채운다 — required는 대상이
  // 아니다(§3-2 "required 카테고리는 보충하지 않는다"). 기본 false — 켜기 전
  // 산출물이 현행과 완전히 동일해야 한다(useEmbeddingRecovery와 같은 패턴).
  //
  // gateNeutralBonus와 세트로만 의미가 있다(게이팅이 꺼져 있으면 scored에서
  // 빠지는 optionalCategories가 애초에 거의 없다) — 그래도 귀속을 분리해
  // 보려면 이 축만 단독으로 켠 프리셋(fillOnly)이 필요하다(§3-1).
  final bool fillOptionalFromRelaxed;

  const TpoMatchPolicy({
    this.gateNeutralBonus = false,
    this.requiredCategories = const {'상의', '하의'},
    this.optionalCategories = const {'아우터', '신발'},
    this.maxSkeletonCategories = 4,
    this.candidatesPerCategory = 2,
    this.usePairwiseColorScore = false,
    this.forceEnumerated = false,
    this.recencyPenalty = 0.4,
    this.useEmbeddingRecovery = false,
    this.fillOptionalFromRelaxed = false,
  });

  // 후보 폭을 넓히거나 조합 단위 채점을 켜면 기존 "기본+한 칸 교체+미니"
  // 생성기로는 표현이 안 되므로(ranked[1] 하드코딩) 전수 조합 경로를 쓴다.
  // 셋 다 기본값이면 이 값이 false라 기존 생성기가 그대로 실행된다 —
  // current 정책의 산출물이 한 비트도 바뀌지 않는다는 뜻이다.
  bool get useEnumeratedCombos =>
      forceEnumerated || usePairwiseColorScore || candidatesPerCategory > 2;

  // 실제로 적용되는 카테고리당 후보 수. num.clamp는 num을 반환해 sublist에
  // 그대로 못 쓰므로 직접 제한하고, 계산 자체를 게터로 노출해 단위 테스트가
  // 옷장 데이터 없이 경계값을 직접 단언할 수 있게 한다(6^4=1296 조합 상한).
  int get effectiveCandidatesPerCategory => candidatesPerCategory < 1
      ? 1
      : (candidatesPerCategory > 6 ? 6 : candidatesPerCategory);

  static const current = TpoMatchPolicy();
  // 무채색 보너스를 격식 충족 후보에만 적용하는 A/B 프리셋.
  // 이전 이름은 `proposed`였으나, 문서에서 "제안 정책"이 임베딩 정보 회수를
  // 가리키게 되면서 코드와 문서가 같은 말로 다른 축을 가리키는 상태가 됐다.
  // 축이 무엇인지를 이름에 담아 충돌을 없앤다.
  static const neutralGating = TpoMatchPolicy(gateNeutralBonus: true);
  static const skeleton4 = TpoMatchPolicy(maxSkeletonCategories: 4);
  static const skeleton3 = TpoMatchPolicy(maxSkeletonCategories: 3);

  // ── 조합 품질 A/B용 프리셋 ──
  // 두 축을 따로 켤 수 있게 나눠 둔다 — 개선(또는 악화)이 폭 때문인지
  // 색상 때문인지 리포트에서 분리해서 봐야 하기 때문이다.
  // 생성기 효과만 분리하는 기준선 — 폭·색상은 current와 동일하게 두고
  // 전수 조합 경로만 켠다.
  static const enumeratedOnly = TpoMatchPolicy(forceEnumerated: true);
  static const wideCandidates = TpoMatchPolicy(candidatesPerCategory: 4);
  static const pairwiseColor = TpoMatchPolicy(usePairwiseColorScore: true);
  static const qualityV2 =
      TpoMatchPolicy(candidatesPerCategory: 4, usePairwiseColorScore: true);

  // ── 다양성(옷장 회전) A/B용 프리셋 ──
  // 폭·색상·생성기는 전부 현행 그대로 두고 감점만 켠다 — 표8~표12에서 그
  // 세 축이 이 옷장에서 무효로 판정됐으므로 섞을 이유가 없다.
  // off(0.0):     감점 없음 — recencyPenalty가 current의 기본값이 되기
  //                전(current) 리포트 비교 기준선을 계속 쓸 수 있게 남겨둔다.
  // tieBreak(0.4): 동점 집합 안에서만 재정렬. 격식 등급을 절대 넘지 않는다.
  //                current의 기본값과 동일하다(둘 다 표14 채택값 0.4).
  // moderate(1.0): 무채색 보너스(+1)와 같은 크기 — 최근 입은 무채색보다
  //                안 입은 유채색이 앞선다.
  // strong(2.0):   격식 인접 등급(3↔1)까지 넘어설 수 있다. 회전은 최대지만
  //                TPO 정확도를 해칠 수 있어 실측 없이는 쓰지 않는다.
  static const diversityOff = TpoMatchPolicy(recencyPenalty: 0.0);
  static const diversityTieBreak = TpoMatchPolicy(recencyPenalty: 0.4);
  static const diversityModerate = TpoMatchPolicy(recencyPenalty: 1.0);
  static const diversityStrong = TpoMatchPolicy(recencyPenalty: 2.0);

  // ── 임베딩 회수(7-c) A/B용 프리셋 ──
  static const embeddingRecovery = TpoMatchPolicy(useEmbeddingRecovery: true);

  // ── 매칭 재설계(로드맵 2번) A/B용 프리셋 ──
  // perCategoryFill: 게이팅 + 보충 채움을 함께 켠 결합 정책 — 실제로 켜질
  // 후보안은 이 조합이다(§3-1). gateNeutralBonus 없이 보충만 켜면 채울
  // 카테고리가 애초에 거의 안 생긴다.
  static const perCategoryFill =
      TpoMatchPolicy(gateNeutralBonus: true, fillOptionalFromRelaxed: true);
  // fillOnly: 보충 채움 축만 단독으로 켠 귀속 분리용 프리셋(forceEnumerated/
  // enumeratedOnly와 같은 취지) — 게이팅 없이 이 축만으로 무엇이 달라지는지 본다.
  static const fillOnly = TpoMatchPolicy(fillOptionalFromRelaxed: true);
}

class OutfitMatcher {
  // 코디 조합의 뼈대가 되는 카테고리만 매칭 대상으로 삼는다.
  // 액세서리/전신은 의류 조합 판단과 무관해 제외.
  static const _outfitCategories = {'상의', '하의', '아우터', '신발'};

  static const _formalityRank = {'캐주얼': 0, '세미포멀': 1, '포멀': 2};

  // 무채색 판정 — color_taxonomy.dart의 정규화 테이블 기준(회색/차콜 포함).
  // findForTpo의 무채색 보너스와 추천 이유 템플릿(outfit_reason.dart)이
  // "뉴트럴끼리인지/포인트 컬러인지" 판단할 때 공유하는 공개 창구.
  static bool isNeutralColor(String color) => ColorTaxonomy.resolve(color).isNeutral;

  // 기존 단일 조합 API — 후보 목록의 1순위(카테고리별 최고점 조합)를 그대로
  // 돌려준다. 자기 평가 루프를 쓰지 않는 호출부를 위해 유지한다.
  static OutfitMatch? findBestMatch({
    required WardrobeItem newItem,
    required List<WardrobeItem> existingItems,
  }) {
    final candidates =
        findCandidateMatches(newItem: newItem, existingItems: existingItems, maxCandidates: 1);
    return candidates.isEmpty ? null : candidates.first;
  }

  // 새 옷(newItem)과 카테고리가 다르고 attributes가 이미 채워진 기존 아이템
  // 중 격식·색상 궁합이 좋은 후보를 카테고리별로 뽑아, 서로 다른 조합 후보를
  // 최대 maxCandidates개 만든다 — 자기 평가 루프(Gemini 재평가)가 순회할 재료.
  //  · 1번: 카테고리별 최고점 풀 조합 (findBestMatch와 동일)
  //  · 교체 변형: 한 카테고리를 차순위 아이템으로 바꾼 조합
  //  · 크기 변형: 핵심 카테고리(상의·하의)만 남긴 미니 조합
  // 1번 뒤로는 로컬 점수 내림차순이며, 아이템 구성이 같은 중복은 제거한다.
  // 매칭 불가면 빈 리스트.
  static List<OutfitMatch> findCandidateMatches({
    required WardrobeItem newItem,
    required List<WardrobeItem> existingItems,
    int maxCandidates = 3,
  }) {
    final newAttrs = newItem.attributes;
    if (newAttrs == null) {
      debugPrint('[RECOMMEND] 매칭 실패 — 이유: 새 옷에 attributes가 없음');
      return const [];
    }
    if (!_outfitCategories.contains(newItem.category)) {
      debugPrint('[RECOMMEND] 매칭 실패 — 이유: 매칭 대상 카테고리가 아님(${newItem.category})');
      return const [];
    }

    final pool = existingItems
        .where((i) =>
            i.id != newItem.id &&
            i.category != newItem.category &&
            _outfitCategories.contains(i.category) &&
            i.attributes != null)
        .toList();
    debugPrint('[RECOMMEND] 후보 풀 크기: ${pool.length}개');

    // 같은 카테고리 두 벌이 한 조합에 들어가지 않도록 카테고리별로 점수
    // 내림차순 상위 2개까지만 남긴다(2번째는 변형 조합의 교체 재료).
    final rankedPerCategory = <String, List<({WardrobeItem item, double score})>>{};
    for (final candidate in pool) {
      final score = _compatibilityScore(newAttrs, candidate.attributes!);
      if (score <= 0) continue;
      rankedPerCategory.putIfAbsent(candidate.category, () => []).add((item: candidate, score: score));
    }
    for (final list in rankedPerCategory.values) {
      list.sort((a, b) => b.score.compareTo(a.score));
      if (list.length > 2) list.removeRange(2, list.length);
    }

    if (rankedPerCategory.isEmpty) {
      final reason = pool.isEmpty
          ? '후보 풀이 비어 있음(카테고리가 다르고 attributes가 채워진 기존 옷이 없음)'
          : '후보는 ${pool.length}개 있었지만 전부 궁합 점수 0점 이하';
      debugPrint('[RECOMMEND] 매칭 실패 — 이유: $reason');
      return const [];
    }

    // 조합의 뼈대: 카테고리별 최고점 기준 상위 3개 카테고리.
    final baseCategories = rankedPerCategory.entries
        .map((e) => (category: e.key, ranked: e.value))
        .toList()
      ..sort((a, b) => b.ranked.first.score.compareTo(a.ranked.first.score));
    final skeleton = baseCategories.take(3).toList();

    // replaceCategory 카테고리만 차선 아이템으로 바꾼 조합을 만든다(null이면 전부 최고점).
    // localScore에 팔레트 조정(유채색 3개 초과 감점)을 더한다 — findForTpo
    // 경로(_buildCombosFromRanked)는 스케일이 달라 이번엔 적용하지 않는다.
    OutfitMatch buildCombo(String? replaceCategory) {
      final picked = skeleton
          .map((c) => c.category == replaceCategory ? c.ranked[1] : c.ranked.first)
          .toList();
      final items = [newItem, ...picked.map((p) => p.item)];
      return OutfitMatch(
        items,
        localScore: picked.fold(0.0, (sum, p) => sum + p.score) + _paletteAdjustment(items),
      );
    }

    // 교체 변형: 한 카테고리씩 차순위 아이템으로 바꾼 조합.
    final variants = skeleton
        .where((c) => c.ranked.length >= 2)
        .map((c) => buildCombo(c.category))
        .toList();

    // 크기 변형: 아우터/신발을 뺀 핵심(상의·하의) 미니 조합 — 단출한 조합이
    // 오히려 점수가 잘 나오는 경우를 잡는다. 새 옷이 코어 카테고리가 아니면
    // 코어 최고점들과만 묶는다.
    const coreCategories = {'상의', '하의'};
    final corePicks = skeleton.where((c) => coreCategories.contains(c.category)).toList();
    if (corePicks.isNotEmpty && corePicks.length < skeleton.length) {
      final picked = corePicks.map((c) => c.ranked.first).toList();
      variants.add(OutfitMatch(
        [newItem, ...picked.map((p) => p.item)],
        localScore: picked.fold(0.0, (sum, p) => sum + p.score),
      ));
    }

    // 1번(기본 조합)을 맨 앞에 두고, 변형들은 로컬 점수 내림차순으로 뒤에.
    // 아이템 구성이 같은 조합은 하나만 남긴다.
    variants.sort((a, b) => b.localScore.compareTo(a.localScore));
    final seen = <String>{};
    final combos = <OutfitMatch>[];
    for (final combo in [buildCombo(null), ...variants]) {
      final signature = (combo.items.map((i) => i.id).toList()..sort()).join(',');
      if (!seen.add(signature)) continue;
      combos.add(combo);
      if (combos.length >= maxCandidates) break;
    }

    debugPrint('[RECOMMEND] 매칭 성공: 후보 조합 ${combos.length}개 생성 — '
        '${combos.map((m) => '${m.items.map((i) => '${i.category}(${i.id})').join('+')}(로컬 ${m.localScore})').join(' / ')}');
    return combos;
  }

  // 진단-수리 루프(OutfitSelfEvaluator)가 "어떤 아이템이 문제인지" 판단할 때
  // 재사용하는 공개 래퍼들.
  static double compatibilityScore(ClothingAttributes a, ClothingAttributes b) =>
      _compatibilityScore(a, b);

  // 검증/진단 전용 — 색상 축만 분리해서 보고 싶을 때(예: 감점 비율 통계).
  static double colorScoreOnly(ClothingAttributes a, ClothingAttributes b) =>
      _colorScore(a, b);

  static int formalityRankOf(String formality) => _formalityRank[formality] ?? 0;

  // 진단-수리 루프 전용 — 특정 카테고리의 아이템을 다른 후보로 교체할 때 쓴다.
  // referenceAttrs(새 옷의 attributes)와 궁합이 가장 좋은, excludeIds에 없는
  // wardrobe 아이템을 그 카테고리에서 하나 고른다. 없으면 null.
  static WardrobeItem? findReplacementFor({
    required String category,
    required List<WardrobeItem> wardrobe,
    required ClothingAttributes referenceAttrs,
    required Set<String> excludeIds,
  }) {
    final pool = wardrobe
        .where((i) =>
            i.category == category && i.attributes != null && !excludeIds.contains(i.id))
        .toList();
    if (pool.isEmpty) return null;
    pool.sort((a, b) => _compatibilityScore(referenceAttrs, b.attributes!)
        .compareTo(_compatibilityScore(referenceAttrs, a.attributes!)));
    return pool.first;
  }

  static double _compatibilityScore(ClothingAttributes a, ClothingAttributes b) {
    double score = 0;

    final rankA = _formalityRank[a.formality];
    final rankB = _formalityRank[b.formality];
    if (rankA != null && rankB != null) {
      final diff = (rankA - rankB).abs();
      score += diff == 0 ? 2 : (diff == 1 ? 1 : -1);
    }

    score += _colorScore(a, b);

    return score;
  }

  // 색상 궁합 — 정규화 테이블(color_taxonomy.dart) 기반. 무채색 와일드카드는
  // isNeutralColor()와 동일한 판정을 pairwise로 확장한 것. family/매트릭스/
  // 톤온톤 같은 나머지 로직은 findCandidateMatches 전용(findForTpo와는
  // 스케일이 달라 섞지 않음).
  static double _colorScore(ClothingAttributes a, ClothingAttributes b) {
    final colorA = ColorTaxonomy.resolve(a.color);
    final colorB = ColorTaxonomy.resolve(b.color);

    if (colorA.isNeutral || colorB.isNeutral) return 2;

    if (colorA.family == null || colorB.family == null) {
      // 라벨 매핑 실패 — family 기반 규칙을 적용할 수 없어 기존 방식대로
      // 원본 문자열이 완전히 같을 때만 동색 보너스.
      return (a.color == b.color && a.color.isNotEmpty) ? 1 : 0;
    }

    if (colorA.family == colorB.family) {
      if (colorA.brightness != colorB.brightness) return 1; // 톤온톤
      // 같은 계열 + 같은 밝기 — 애매한 깔맞춤. 패턴이 서로 다르면(예: 무지 vs
      // 스트라이프) 의도된 매치로 보고 감점을 면제한다(둘 다 패턴 확인된
      // 경우에만 — 미확인이면 보수적으로 감점 유지).
      final patternDiffers =
          a.pattern.isNotEmpty && b.pattern.isNotEmpty && a.pattern != b.pattern;
      return patternDiffers ? 0 : -1;
    }

    // 다른 계열
    if (colorA.brightness == colorB.brightness) return 1; // 톤인톤
    return ColorTaxonomy.matrixScore(colorA.family!, colorB.family!).toDouble();
  }

  // 유채색(무채색 아님) 아이템이 3벌을 초과하는 조합에 감점. findCandidateMatches
  // 전용(§검증계획) — combo 전체를 봐야 하는 유일한 규칙이라 buildCombo 직후
  // 후처리로 적용한다.
  static double _paletteAdjustment(List<WardrobeItem> items) {
    final chromaticCount = items.where((i) {
      final attrs = i.attributes;
      return attrs != null && !ColorTaxonomy.resolve(attrs.color).isNeutral;
    }).length;
    return chromaticCount > 3 ? -1 : 0;
  }

  // ── TPO(일정) 기반 조합 후보 생성 ────────────────────────
  // findCandidateMatches가 "새 옷"을 축으로 삼는 것과 달리, 이건 특정 TPO의
  // 요구 격식(formalityHint)을 축으로 옷장에서 조합을 만든다. 선제 추천/주간
  // 플랜이 "이 일정에 뭘 입힐까"를 계산할 때 쓰며, 결과는 동일한 자기 평가
  // 루프(OutfitSelfEvaluator)에 그대로 넘어간다.
  //
  // 레벨 4(실패 대응): 격식에 딱 맞는 후보가 없어도 조용히 포기하지 않는다.
  //  · 격식 적합 후보로 조합 가능 → isFallback=false
  //  · 격식은 안 맞아도 상의·하의가 있으면 → 가장 가까운 차선 조합, isFallback=true
  //  · 상의/하의 자체가 없으면 → candidates 비고 shortfall에 부족 카테고리 안내
  static TpoMatchResult findForTpo({
    required List<WardrobeItem> wardrobe,
    required String formalityHint,
    int maxCandidates = 3,
    TpoMatchPolicy policy = TpoMatchPolicy.current,
    // 최근에 추천/착용된 아이템 id. policy.recencyPenalty와 함께 동작하며,
    // 둘 중 하나라도 비어 있으면(기본값) 정렬 결과가 현행과 완전히 같다.
    Set<String> recentItemIds = const {},
  }) {
    final targetRank = _formalityRank[formalityHint] ?? 0;

    // 카테고리별 전체 후보(격식 적합도 점수 포함, 차이 0→3 / 1→1 / 그외→0,
    // 무채색 +1). scored는 그중 유효점(>0)만, all은 존재하는 것 전부(차선용).
    final allPerCategory = <String, List<({WardrobeItem item, double score})>>{};
    for (final item in wardrobe) {
      final attrs = item.attributes;
      if (attrs == null || !_outfitCategories.contains(item.category)) continue;
      final rank = _formalityRank[attrs.formality];
      double score = rank == null ? 0.5 : _formalityFitScore(targetRank, rank);
      if (isNeutralColor(attrs.color) && (!policy.gateNeutralBonus || score > 0)) {
        score += 1;
      }
      allPerCategory.putIfAbsent(item.category, () => []).add((item: item, score: score));
    }
    // 카테고리별로 상위 N벌만 남긴다(N = policy.candidatesPerCategory, 기본 2).
    // 이름은 topTwo 그대로 두지 않고 topPerCategory로 바꿨다 — 2가 더 이상
    // 고정값이 아니기 때문이다.
    final perCategory = policy.effectiveCandidatesPerCategory;

    // 최근 감점은 "정렬"에만 쓰고 "통과 여부(keep)"에는 쓰지 않는다.
    // keep은 score>0으로 격식 적합 여부를 가르고 그 결과가 hasCore →
    // isFallback → mismatchedCategories까지 이어지는데, 감점 때문에 0 밑으로
    // 내려간 아이템이 탈락하면 최근에 뭘 입었느냐가 폴백 판정을 바꿔버린다.
    // 자격은 격식이, 순서는 최근도가 정한다.
    final applyRecency = policy.recencyPenalty > 0 && recentItemIds.isNotEmpty;
    double rankScore(({WardrobeItem item, double score}) c) =>
        applyRecency && recentItemIds.contains(c.item.id)
            ? c.score - policy.recencyPenalty
            : c.score;

    // 회수 축(§3-1) — recentItemIds 각각의 WardrobeItem을 조회할 인덱스.
    // wardrobe를 id마다 O(n) 스캔하지 않도록 한 번만 만든다. 축이 꺼져 있거나
    // recentItemIds가 비면 이 블록 자체를 건너뛰어 기존 호출부에는 비용이
    // 전혀 늘지 않는다.
    final wardrobeById = policy.useEmbeddingRecovery && recentItemIds.isNotEmpty
        ? {for (final w in wardrobe) w.id: w}
        : const <String, WardrobeItem>{};
    // embedding이 없는 최근 아이템은 코사인을 낼 수 없으니 참조 집합에서 제외.
    final referenceIds =
        recentItemIds.where((id) => wardrobeById[id]?.embedding != null).toList();

    // 회수 축(§3-1-b) — "아이템별 최근 노출분과의 최대 코사인"을 정렬 전에
    // 한 번 계산해 맵에 담는다. 비교자 안에서 계산하지 않는 이유: sort는
    // 비교자를 O(n log n)번 부르므로 안에 계산이 있으면 같은 아이템의 유사도를
    // 수십 번 다시 구하게 되고(참조 집합 크기까지 곱해져 더 늘어난다), 비교자
    // 안에서 던져진 예외는 스택이 정렬 내부라 원인 추적이 어렵다 — 계산을 밖으로
    // 빼면 실패가 정렬 이전에, 진단 가능한 위치에서 난다.
    final recoverySimilarity = <String, double>{};
    if (referenceIds.isNotEmpty) {
      for (final item in wardrobe) {
        final vec = item.embedding;
        if (vec == null) continue;
        double? best;
        for (final refId in referenceIds) {
          // 자기 자신이 최근 노출 목록에 있어도 그 코사인(1.0)을 자기 순위에
          // 반영하지 않는다 — 반영하면 recencyPenalty를 한 번 더 적용하는
          // 꼴이 되어, 이 축의 목적(id로는 안 잡히는 "닮은 다른 옷"의 회수)과
          // 어긋난다.
          if (refId == item.id) continue;
          final sim = EmbeddingService.cosineSimilarity(vec, wardrobeById[refId]!.embedding);
          if (sim != null && (best == null || sim > best)) best = sim;
        }
        if (best != null) recoverySimilarity[item.id] = best;
      }
    }

    // 정렬 키: [rankScore 내림차순] → [3블록: 벡터+유사도 / 벡터만 / 벡터 없음]
    // → [블록 0 안에서만: 최근 노출 유사도 오름차순] → [id 오름차순]. 뒤 세
    // 단계는 rankScore가 동점일 때만 보고, recoverySimilarity가 비어 있으면
    // (축 off 또는 참조 벡터 없음) 전부 건너뛰어 현행 비교자와 완전히 동일하게
    // 동작한다.
    //
    // 블록을 둘이 아니라 셋으로 나누는 이유(2026-08-05, 78abe0f 직후 발견) —
    // "벡터는 있으나 유사도 값이 없는" 아이템이 있을 수 있다. 참조 집합이
    // 자기 자신뿐이라 자기 제외 후 비었거나(1), 모든 참조 쌍에서 코사인이
    // null이었을 때(2)다. 이 아이템을 "벡터 보유"와 같은 블록에 두고 유사도
    // 비교만 건너뛰면(둘 다 값 있을 때만 비교) 전이성이 깨진다: 참조 집합이
    // {B}뿐이고 map[A]=0.8, map[C]=0.2, map[B]=없음, id A<B<C인 반례에서
    // A vs C는 유사도로 C<A, A vs B/B vs C는 유사도 비교를 건너뛰어 id로
    // A<B<C가 나온다 — A<B이고 B<C인데 C<A가 되어 순환이 생긴다. 없는 값을
    // 센티널(1.0/−1.0/negativeInfinity 등)로 지어내는 대안도 있지만, 어떤
    // 값을 넣든 그 방향이 근거 없는 편향이 되고 "왜 이 아이템이 앞에 왔는가"에
    // 답할 근거가 없다. 그래서 값을 만드는 대신 블록을 하나 더 둬 유사도
    // 비교 단계 자체에 도달하지 못하게 막는다 — 블록 키가 유사도 비교보다
    // 먼저 갈리므로 서로 다른 블록의 두 아이템은 3단계에 도달하지 않는다.
    //
    // 블록 1(벡터는 있으나 유사도 없음)을 0과 2 사이에 두는 이유: 벡터를 가진
    // 아이템이 벡터 없는 아이템보다 뒤로 밀리면, 정보를 더 가진 쪽이 불리해
    // 지는 역전이 생긴다.
    //
    // **기본값(recencyPenalty=0.4)에서 이 반례가 안전한 것은 우연이다.**
    // 이 상황이 성립하려면 recentItemIds에 든 아이템이 감점을 받고도 다른
    // 아이템과 동점이어야 하는데(base_B − recencyPenalty = base_A), 점수
    // 집합 {0,0.5,1,1.5,2,3,4}의 차이가 전부 0.5의 배수라 0.4에서는 만들어
    // 지지 않는다. 그러나 표14가 실측한 값(0.0/1.0/2.0)은 전부 도달 가능하다
    // — recencyPenalty를 스윕하는 하네스라면 걸린다.
    int compareCandidates(
        ({WardrobeItem item, double score}) a, ({WardrobeItem item, double score}) b) {
      final byRank = rankScore(b).compareTo(rankScore(a));
      if (byRank != 0 || recoverySimilarity.isEmpty) return byRank;

      // 블록 0=벡터+유사도 있음, 1=벡터만 있음(유사도 없음), 2=벡터 없음.
      // embedding==null을 가장 뒤 블록에 두는 이유: 전이성을 지키려면
      // 총순서가 필요하고 그 안에서는 어떤 순서를 택해도 한쪽이 앞서는데,
      // 벡터가 없는 아이템은 회수 판단에 참여할 수 없어 "회전에 더 나은
      // 선택"임을 보일 수단이 없으므로 뒤로 보낸다.
      //
      // 영향 범위: 현재 백필 이후 등록된 아이템(2026-08 기준 119벌 중 20벌)이
      // 동점에서 뒤로 밀린다. 7-b 하네스는 items.json 87벌 커버리지 100%라
      // 측정에는 영향이 없고, 논문 7.2-5(신규 아이템 실시간 임베딩)가
      // 해결되면 이 블록 자체가 사라진다. 과도기 한정 편향으로 기록한다.
      int blockOf(({WardrobeItem item, double score}) c) {
        if (c.item.embedding == null) return 2;
        return recoverySimilarity.containsKey(c.item.id) ? 0 : 1;
      }

      final blockA = blockOf(a);
      final byBlock = blockA.compareTo(blockOf(b));
      if (byBlock != 0) return byBlock;

      if (blockA == 0) {
        final bySimilarity =
            recoverySimilarity[a.item.id]!.compareTo(recoverySimilarity[b.item.id]!);
        if (bySimilarity != 0) return bySimilarity; // 오름차순: 덜 닮은 쪽이 앞
      }
      return a.item.id.compareTo(b.item.id);
    }

    Map<String, List<({WardrobeItem item, double score})>> topPerCategory(
        bool Function(double) keep) {
      final out = <String, List<({WardrobeItem item, double score})>>{};
      for (final e in allPerCategory.entries) {
        final list = e.value.where((c) => keep(c.score)).toList()
          ..sort(compareCandidates);
        if (list.isEmpty) continue;
        out[e.key] =
            list.length > perCategory ? list.sublist(0, perCategory) : list;
      }
      return out;
    }

    // 정책에 따라 조합 생성기를 고른다. 기본값(2벌·색상 미반영)이면 기존
    // 생성기가 그대로 호출된다.
    List<OutfitMatch> buildCombos(
        Map<String, List<({WardrobeItem item, double score})>> ranked) {
      return policy.useEnumeratedCombos
          ? _buildCombosByEnumeration(ranked, maxCandidates,
              policy.maxSkeletonCategories, policy.usePairwiseColorScore)
          : _buildCombosFromRanked(
              ranked, maxCandidates, policy.maxSkeletonCategories);
    }

    // 무채색 보너스를 뺀 "진짜" 격식 적합 여부 — rank가 있고 diff가 0~1
    // (_formalityFitScore>0)인 아이템만 true. 표5(필터 순도)의 "진짜 적합"과
    // 동일한 정의다.
    bool isGenuineFit(WardrobeItem item) {
      final rank = _formalityRank[item.attributes!.formality];
      return rank != null && _formalityFitScore(targetRank, rank) > 0;
    }

    // rankedMap(scored 또는 relaxed) 안에서 policy.optionalCategories 중
    // 순도(진짜 적합 아이템 비율)가 0인 카테고리 — 아이템은 있지만 전부
    // 무채색 보너스로만 살아남았다는 뜻. 표시 순서는 mismatchedCategories와
    // 동일하게 _outfitCategories(LinkedHashSet) 삽입 순서를 쓴다.
    List<String> optionalMissingFrom(
        Map<String, List<({WardrobeItem item, double score})>> rankedMap) {
      return _outfitCategories.where((c) {
        if (!policy.optionalCategories.contains(c)) return false;
        final items = rankedMap[c];
        if (items == null || items.isEmpty) return false;
        return items.every((e) => !isGenuineFit(e.item));
      }).toList();
    }

    final scored = topPerCategory((s) => s > 0);
    final hasCore = policy.requiredCategories.every(scored.containsKey);
    if (hasCore) {
      // 카테고리 단위 보충 채움(§3-2) — hasCore는 이미 성립했으므로(필수는
      // 진짜 적합) required는 건드리지 않고, optionalCategories 중 scored에
      // 없는 카테고리만 relaxed로 채운다. 플래그 off 또는 채울 카테고리가
      // 없으면 이 블록은 아무 것도 만들지 않고 combosSource는 scored 그대로
      // — off 경로 비용 0(useEmbeddingRecovery의 wardrobeById 지연 생성과
      // 같은 패턴).
      var combosSource = scored;
      if (policy.fillOptionalFromRelaxed) {
        final missingOptional = policy.optionalCategories
            .where((c) => !scored.containsKey(c) && allPerCategory.containsKey(c));
        for (final category in missingOptional) {
          // 보충분 내부 순서는 게이팅 안 한(ungated) 점수로 매긴다(§3-2 핵심
          // 한 줄) — allPerCategory의 점수는 이미 policy.gateNeutralBonus가
          // 반영돼 있으므로, 이 카테고리만 무채색 보너스를 무조건 더하는
          // ungated 공식으로 재채점한다.
          final rescored = <({WardrobeItem item, double score})>[];
          for (final c in allPerCategory[category]!) {
            final attrs = c.item.attributes!;
            final rank = _formalityRank[attrs.formality];
            var ungatedScore = rank == null ? 0.5 : _formalityFitScore(targetRank, rank);
            if (isNeutralColor(attrs.color)) ungatedScore += 1;
            rescored.add((item: c.item, score: ungatedScore));
          }
          final passing = rescored.where((c) => c.score > 0).toList()
            ..sort(compareCandidates);
          if (passing.isEmpty) continue;
          combosSource = combosSource == scored ? Map.of(scored) : combosSource;
          combosSource[category] =
              passing.length > perCategory ? passing.sublist(0, perCategory) : passing;
        }
      }
      final combos = buildCombos(combosSource);
      // optionalMissingFrom은 보충 카테고리를 자연히 잡는다 — 채워 넣은
      // 아이템은 전원 격식 미달(그래서 애초에 scored에 없었다)이므로
      // every !isGenuineFit이 성립해, 기존 의미(순도 0)와 신규 의미(보충)가
      // 같은 필드로 합쳐진다(§3-2, 부록).
      final optionalMissing = optionalMissingFrom(combosSource);
      debugPrint('[PLAN] TPO($formalityHint) 매칭 성공: 후보 ${combos.length}개 (격식 적합)'
          '${optionalMissing.isEmpty ? '' : ', 선택 카테고리 순도 0=$optionalMissing'}');
      return TpoMatchResult(
          candidates: combos, isFallback: false, optionalMissing: optionalMissing);
    }

    // 차선: 격식 무시하고 필수 카테고리가 존재하면 가장 가까운 조합.
    final relaxed = topPerCategory((_) => true);
    if (policy.requiredCategories.every(relaxed.containsKey)) {
      final combos = buildCombos(relaxed);
      // 표시 순서는 _outfitCategories(Set 리터럴 → LinkedHashSet)의 삽입
      // 순서를 그대로 쓴다 — 별도 순서 리스트를 두지 않아 카테고리 변경 시
      // 자동으로 동기화된다. 대상은 정책이 다루는 범위(필수+선택)로 한정.
      final consideredCategories = {...policy.requiredCategories, ...policy.optionalCategories};
      final mismatched = _outfitCategories
          .where((c) =>
              consideredCategories.contains(c) &&
              relaxed.containsKey(c) &&
              !scored.containsKey(c))
          .toList();
      final optionalMissing = optionalMissingFrom(relaxed);
      debugPrint('[PLAN] TPO($formalityHint) 차선 조합 ${combos.length}개 '
          '(격식 부적합, fallback, 부족 카테고리=$mismatched)');
      return TpoMatchResult(
          candidates: combos,
          isFallback: true,
          mismatchedCategories: mismatched,
          optionalMissing: optionalMissing);
    }

    // 조합 불가 — 부족한 핵심 카테고리를 안내한다.
    final missing = <String>[];
    if (!relaxed.containsKey('상의')) missing.add('상의');
    if (!relaxed.containsKey('하의')) missing.add('하의');
    final shortfall = '$formalityHint 조합에 필요한 ${missing.join('·')}가 옷장에 없어요';
    debugPrint('[PLAN] TPO($formalityHint) 매칭 실패 — $shortfall');
    return TpoMatchResult(candidates: const [], isFallback: false, shortfall: shortfall);
  }

  // 자기 평가 루프를 쓰지 않는 호출부용 — 후보 리스트만 반환(하위호환).
  static List<OutfitMatch> findCandidatesForTpo({
    required List<WardrobeItem> wardrobe,
    required String formalityHint,
    int maxCandidates = 3,
  }) =>
      findForTpo(
        wardrobe: wardrobe,
        formalityHint: formalityHint,
        maxCandidates: maxCandidates,
      ).candidates;

  // 카테고리별 상위 후보 맵에서 조합들을 만든다(기본 + 교체 변형 + 미니 변형,
  // 아이템 구성 중복 제거). 상의·하의가 반드시 있다고 가정한다.
  static List<OutfitMatch> _buildCombosFromRanked(
    Map<String, List<({WardrobeItem item, double score})>> rankedPerCategory,
    int maxCandidates,
    int maxSkeletonCategories,
  ) {
    final ordered = rankedPerCategory.entries
        .map((e) => (category: e.key, ranked: e.value))
        .toList()
      ..sort((a, b) {
        int pri(String c) => c == '상의' ? 0 : (c == '하의' ? 1 : 2);
        final byPriority = pri(a.category).compareTo(pri(b.category));
        if (byPriority != 0) return byPriority;
        return b.ranked.first.score.compareTo(a.ranked.first.score);
      });
    final skeleton = ordered.take(maxSkeletonCategories).toList();

    OutfitMatch buildCombo(String? replaceCategory) {
      final picked = skeleton
          .map((c) => c.category == replaceCategory ? c.ranked[1] : c.ranked.first)
          .toList();
      return OutfitMatch(
        picked.map((p) => p.item).toList(),
        localScore: picked.fold(0.0, (sum, p) => sum + p.score),
      );
    }

    final variants = skeleton
        .where((c) => c.ranked.length >= 2)
        .map((c) => buildCombo(c.category))
        .toList();
    final core = skeleton.where((c) => c.category == '상의' || c.category == '하의').toList();
    if (core.length == 2 && skeleton.length > 2) {
      final picked = core.map((c) => c.ranked.first).toList();
      variants.add(OutfitMatch(
        picked.map((p) => p.item).toList(),
        localScore: picked.fold(0.0, (sum, p) => sum + p.score),
      ));
    }

    variants.sort((a, b) => b.localScore.compareTo(a.localScore));
    final seen = <String>{};
    final combos = <OutfitMatch>[];
    for (final combo in [buildCombo(null), ...variants]) {
      final signature = (combo.items.map((i) => i.id).toList()..sort()).join(',');
      if (!seen.add(signature)) continue;
      combos.add(combo);
      if (combos.length >= maxCandidates) break;
    }
    return combos;
  }

  // 조합 점수에서 색상 축이 갖는 무게. 격식 축은 아이템당 {0.5,1,2,3,4}라
  // 4벌 조합에서 2~16 범위를 갖는다. 색상 축은 쌍 평균(_colorScore ∈ [-1,2])에
  // 이 가중치를 곱해 [-3,+6] 범위로 맞춘다 — 아이템 하나의 격식 기여도와
  // 비슷한 크기다. 합이 아니라 평균을 쓰는 이유는, 합으로 두면 쌍 개수가
  // 많은(=아이템이 많은) 조합이 색상 축에서 자동으로 유리해져 미니 조합이
  // 구조적으로 밀려나기 때문이다.
  // 이 값이 이 변경의 유일한 튜닝 손잡이다 — 리포트(표8~표11)를 보고 조정한다.
  static const _colorWeight = 3.0;

  // 전수 조합 상한. maxSkeletonCategories(≤4) × candidatesPerCategory(≤6)로
  // 최대 1296이며 전부 순수 산술이라 ms 단위지만, 정책이 잘못 설정돼도
  // 폭주하지 않도록 상한을 명시해 둔다.
  static const _maxEnumeratedCombos = 2000;

  // 곱집합 크기를 상한 안에 넣는 카테고리당 후보 수(width)를 고른다.
  //
  // 핵심은 "상한을 넘으면 카테고리를 자른다"가 아니라 "폭을 좁힌다"라는
  // 점이다. 카테고리를 자르면 신발 같은 항목이 조합에서 조용히 빠지는데,
  // 그건 이 프로젝트가 이미 한 번 고친 결함이다. 폭을 좁히면 후보 수만
  // 줄고 조합의 카테고리 구성은 온전하다 — 실패 방향이 보수적이다.
  // width는 최소 1이라(조합 1개) 루프는 반드시 종료된다.
  //
  // 부수효과가 없는 정적 함수라 실제 옷장 없이 경계 조건을 단위 테스트할 수
  // 있다(실기기·실데이터로 재현하기 어려운 조건은 순수 함수로 뺀다는 원칙).
  @visibleForTesting
  static int resolveEnumerationWidth({
    required List<int> categoryCounts,
    List<int> miniCounts = const [],
    int maxCombos = _maxEnumeratedCombos,
  }) {
    if (categoryCounts.isEmpty) return 1;

    int sizeAt(int w) {
      var total = 1;
      for (final n in categoryCounts) {
        total *= n < w ? n : w;
        if (total > maxCombos) return total; // 조기 종료 — 곱이 커지는 걸 막는다
      }
      if (miniCounts.isEmpty) return total;
      // 미니 조합도 같은 후보 풀에서 나오므로 상한 계산에 포함한다.
      var mini = 1;
      for (final n in miniCounts) {
        mini *= n < w ? n : w;
      }
      return total + mini;
    }

    var width = categoryCounts.reduce((a, b) => a > b ? a : b);
    while (width > 1 && sizeAt(width) > maxCombos) {
      width--;
    }
    return width;
  }

  // 카테고리별 후보를 전수 조합해 "조합 단위"로 채점하는 생성기.
  // 기존 _buildCombosFromRanked가 카테고리별 최고점을 고정하고 한 칸씩만
  // 차순위로 바꾸는(ranked[1] 하드코딩) 방식이라 후보를 3벌 이상으로
  // 늘려도 쓸 수 없고, 조합 점수가 아이템 점수의 단순 합이라 아이템 간
  // 궁합이 개입할 자리가 없다. 이 경로는 둘 다 해소한다.
  //
  // 호출 조건은 policy.useEnumeratedCombos — 기본 정책에서는 호출되지 않으므로
  // 기존 산출물에 영향이 없다.
  static List<OutfitMatch> _buildCombosByEnumeration(
    Map<String, List<({WardrobeItem item, double score})>> rankedPerCategory,
    int maxCandidates,
    int maxSkeletonCategories,
    bool usePairwiseColorScore,
  ) {
    // 스켈레톤 선정은 기존 경로와 동일한 규칙(우선순위 상의>하의>그외,
    // 동순위는 카테고리 최고점 내림차순)을 그대로 쓴다.
    final ordered = rankedPerCategory.entries
        .map((e) => (category: e.key, ranked: e.value))
        .toList()
      ..sort((a, b) {
        int pri(String c) => c == '상의' ? 0 : (c == '하의' ? 1 : 2);
        final byPriority = pri(a.category).compareTo(pri(b.category));
        if (byPriority != 0) return byPriority;
        return b.ranked.first.score.compareTo(a.ranked.first.score);
      });
    final skeleton = ordered.take(maxSkeletonCategories).toList();
    if (skeleton.isEmpty) return const [];

    double comboScore(List<({WardrobeItem item, double score})> picked) {
      final base = picked.fold(0.0, (sum, p) => sum + p.score);
      if (!usePairwiseColorScore) return base;
      final items = picked.map((p) => p.item).toList();
      var pairSum = 0.0;
      var pairCount = 0;
      for (var i = 0; i < items.length; i++) {
        for (var j = i + 1; j < items.length; j++) {
          pairSum += _colorScore(items[i].attributes!, items[j].attributes!);
          pairCount++;
        }
      }
      final colorTerm = pairCount == 0 ? 0.0 : _colorWeight * (pairSum / pairCount);
      return base + colorTerm + _paletteAdjustment(items);
    }

    // 미니 조합에 쓸 상의·하의 항목. skeleton은 pri()로 상의<하의<그외 순
    // 정렬돼 있지만 여기서 그 순서에 기대지 않고 카테고리 이름으로 직접
    // 집는다 — 우선순위 함수를 손대면 상의-상의 쌍이 만들어질 수 있다.
    const coreOrder = ['상의', '하의'];
    final coreEntries = [
      for (final name in coreOrder) ...skeleton.where((c) => c.category == name),
    ];
    final hasMini = coreEntries.length == 2 && skeleton.length > 2;

    // 곱집합이 상한을 넘을 때 카테고리 루프를 끊으면, 아직 처리하지 않은
    // 카테고리(신발 등)가 조합에서 조용히 빠진 채로 최종 후보가 된다 —
    // maxSkeletonCategories를 3→4로 올려 없앤 결함과 정확히 같은 실패
    // 모드다. 그래서 카테고리를 자르지 않고 카테고리당 후보 수(width)를
    // 낮춘다. 후보가 적어질 뿐 조합의 카테고리 구성은 언제나 온전하다.
    final width = resolveEnumerationWidth(
      categoryCounts: [for (final c in skeleton) c.ranked.length],
      miniCounts: hasMini ? [for (final c in coreEntries) c.ranked.length] : const [],
    );
    List<({WardrobeItem item, double score})> trim(
            List<({WardrobeItem item, double score})> list) =>
        list.length > width ? list.sublist(0, width) : list;

    // 전수 조합 — 카테고리별 후보 리스트의 곱집합. 모든 skeleton 카테고리를
    // 빠짐없이 순회한다(중도 이탈 없음).
    var product = <List<({WardrobeItem item, double score})>>[const []];
    for (final c in skeleton) {
      product = [
        for (final partial in product)
          for (final cand in trim(c.ranked)) [...partial, cand]
      ];
    }

    // 미니 조합(상의·하의만) — 기존 경로의 "크기 변형"과 같은 취지로,
    // 아우터·신발을 뺀 단출한 조합이 더 나을 수 있는 경우를 살려둔다.
    // coreEntries의 순서는 coreOrder에서 오므로 [0]=상의, [1]=하의가 보장된다.
    if (hasMini) {
      for (final top in trim(coreEntries[0].ranked)) {
        for (final bottom in trim(coreEntries[1].ranked)) {
          product.add([top, bottom]);
        }
      }
    }

    String signatureOf(List<({WardrobeItem item, double score})> picked) =>
        (picked.map((p) => p.item.id).toList()..sort()).join(',');

    // 점수 내림차순. 동점은 시그니처로 갈라 결과가 실행마다 흔들리지 않게 한다
    // (동점 타이브레이커를 순회 순서에 맡기지 않는다 — 이 변경의 동기 자체가
    // 그 문제였다).
    final ranked = product
        .map((p) => (picked: p, score: comboScore(p), sig: signatureOf(p)))
        .toList()
      ..sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        return byScore != 0 ? byScore : a.sig.compareTo(b.sig);
      });

    final seen = <String>{};
    final combos = <OutfitMatch>[];
    for (final entry in ranked) {
      if (entry.picked.isEmpty) continue;
      if (!seen.add(entry.sig)) continue;
      combos.add(OutfitMatch(
        entry.picked.map((p) => p.item).toList(),
        localScore: entry.score,
      ));
      if (combos.length >= maxCandidates) break;
    }
    return combos;
  }

  // 요구 격식(targetRank)과 아이템 격식(itemRank)의 근접도 점수.
  static double _formalityFitScore(int targetRank, int itemRank) {
    final diff = (targetRank - itemRank).abs();
    return diff == 0 ? 3 : (diff == 1 ? 1 : 0);
  }
}
