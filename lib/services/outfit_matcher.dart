import 'package:flutter/foundation.dart';
import '../models/clothing_attributes.dart';
import '../models/wardrobe_item.dart';
import 'color_taxonomy.dart';

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

  const TpoMatchResult({
    required this.candidates,
    this.isFallback = false,
    this.shortfall,
    this.mismatchedCategories = const [],
  });
}

// findForTpo의 격식 판정 파라미터. 기본값(current)은 현행 동작과 완전히
// 동일하다 — 정책을 주입하지 않은 모든 호출부는 한 비트도 달라지지 않는다.
// proposed는 논문 5.8.3/5.8.4의 수정안이며, 실측 옷장 리포트로 영향을
// 확인하기 전까지 프로덕션 기본값이 되어서는 안 된다.
class TpoMatchPolicy {
  // true면 무채색 보너스를 "이미 격식을 충족한 후보"에게만 적용한다(동점 처리용).
  final bool gateNeutralBonus;
  // 이 카테고리가 전부 scored에 있어야 격식 적합으로 본다.
  final Set<String> requiredCategories;
  // 없어도 조합은 성립하지만 부재를 안내해야 하는 카테고리.
  final Set<String> optionalCategories;
  // 조합의 뼈대(skeleton)에 들어갈 수 있는 카테고리 최대 개수. 4개 카테고리
  // (상의·하의·아우터·신발) 중 우선순위+점수 기준 상위 N개만 스켈레톤에
  // 들어가고 나머지는 조합에서 조용히 빠진다 — 기본 3은 현행 동작과 동일.
  final int maxSkeletonCategories;

  const TpoMatchPolicy({
    this.gateNeutralBonus = false,
    this.requiredCategories = const {'상의', '하의'},
    this.optionalCategories = const {'아우터', '신발'},
    this.maxSkeletonCategories = 3,
  });

  static const current = TpoMatchPolicy();
  static const proposed = TpoMatchPolicy(gateNeutralBonus: true);
  static const skeleton4 = TpoMatchPolicy(maxSkeletonCategories: 4);
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
    Map<String, List<({WardrobeItem item, double score})>> topTwo(
        bool Function(double) keep) {
      final out = <String, List<({WardrobeItem item, double score})>>{};
      for (final e in allPerCategory.entries) {
        final list = e.value.where((c) => keep(c.score)).toList()
          ..sort((a, b) => b.score.compareTo(a.score));
        if (list.isEmpty) continue;
        out[e.key] = list.length > 2 ? list.sublist(0, 2) : list;
      }
      return out;
    }

    final scored = topTwo((s) => s > 0);
    final hasCore = policy.requiredCategories.every(scored.containsKey);
    if (hasCore) {
      final combos = _buildCombosFromRanked(scored, maxCandidates, policy.maxSkeletonCategories);
      debugPrint('[PLAN] TPO($formalityHint) 매칭 성공: 후보 ${combos.length}개 (격식 적합)');
      return TpoMatchResult(candidates: combos, isFallback: false);
    }

    // 차선: 격식 무시하고 필수 카테고리가 존재하면 가장 가까운 조합.
    final relaxed = topTwo((_) => true);
    if (policy.requiredCategories.every(relaxed.containsKey)) {
      final combos = _buildCombosFromRanked(relaxed, maxCandidates, policy.maxSkeletonCategories);
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
      debugPrint('[PLAN] TPO($formalityHint) 차선 조합 ${combos.length}개 '
          '(격식 부적합, fallback, 부족 카테고리=$mismatched)');
      return TpoMatchResult(
          candidates: combos, isFallback: true, mismatchedCategories: mismatched);
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

  // 요구 격식(targetRank)과 아이템 격식(itemRank)의 근접도 점수.
  static double _formalityFitScore(int targetRank, int itemRank) {
    final diff = (targetRank - itemRank).abs();
    return diff == 0 ? 3 : (diff == 1 ? 1 : 0);
  }
}
