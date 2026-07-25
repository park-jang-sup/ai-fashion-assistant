import 'package:ai_fashion_assistant/models/clothing_attributes.dart';
import 'package:ai_fashion_assistant/models/wardrobe_item.dart';

// 궁합 규칙 보강(2026-07) 이전 findCandidateMatches/findForTpo를
// matcher_spec.md 기준으로 그대로 재구현한 것. 검증 전용 — lib/에는
// 존재하지 않는다. 색상 점수 함수/neutralColors 세트만 바꿔 끼워서
// "OLD"(원래 8개 무채색 세트)와 "BUGFIX-ONLY"(회색·차콜 추가, family/
// 매트릭스/톤온톤 없음) 변형을 만드는 데 쓴다.
const legacyOutfitCategories = {'상의', '하의', '아우터', '신발'};
const legacyFormalityRank = {'캐주얼': 0, '세미포멀': 1, '포멀': 2};

const legacyNeutralColorsOld = {
  '화이트', '블랙', '네이비', '그레이', '베이지', '아이보리', '카키', '그레이지',
};
const legacyNeutralColorsBugfixOnly = {
  '화이트', '블랙', '네이비', '그레이', '베이지', '아이보리', '카키', '그레이지', '회색', '차콜',
};

double legacyCompatibilityScore(ClothingAttributes a, ClothingAttributes b, Set<String> neutralColors) {
  double score = 0;
  final rankA = legacyFormalityRank[a.formality];
  final rankB = legacyFormalityRank[b.formality];
  if (rankA != null && rankB != null) {
    final diff = (rankA - rankB).abs();
    score += diff == 0 ? 2 : (diff == 1 ? 1 : -1);
  }
  if (neutralColors.contains(a.color) || neutralColors.contains(b.color)) {
    score += 2;
  } else if (a.color == b.color && a.color.isNotEmpty) {
    score += 1;
  }
  return score;
}

class LegacyMatch {
  final List<WardrobeItem> items;
  final double localScore;
  const LegacyMatch(this.items, this.localScore);
}

typedef PairScoreFn = double Function(ClothingAttributes a, ClothingAttributes b);

List<LegacyMatch> legacyFindCandidateMatches({
  required WardrobeItem newItem,
  required List<WardrobeItem> existingItems,
  required PairScoreFn scoreFn,
  int maxCandidates = 3,
}) {
  final newAttrs = newItem.attributes;
  if (newAttrs == null || !legacyOutfitCategories.contains(newItem.category)) return const [];

  final pool = existingItems
      .where((i) =>
          i.id != newItem.id &&
          i.category != newItem.category &&
          legacyOutfitCategories.contains(i.category) &&
          i.attributes != null)
      .toList();

  final rankedPerCategory = <String, List<({WardrobeItem item, double score})>>{};
  for (final candidate in pool) {
    final score = scoreFn(newAttrs, candidate.attributes!);
    if (score <= 0) continue;
    rankedPerCategory.putIfAbsent(candidate.category, () => []).add((item: candidate, score: score));
  }
  for (final list in rankedPerCategory.values) {
    list.sort((a, b) => b.score.compareTo(a.score));
    if (list.length > 2) list.removeRange(2, list.length);
  }
  if (rankedPerCategory.isEmpty) return const [];

  final baseCategories = rankedPerCategory.entries
      .map((e) => (category: e.key, ranked: e.value))
      .toList()
    ..sort((a, b) => b.ranked.first.score.compareTo(a.ranked.first.score));
  final skeleton = baseCategories.take(3).toList();

  LegacyMatch buildCombo(String? replaceCategory) {
    final picked = skeleton
        .map((c) => c.category == replaceCategory ? c.ranked[1] : c.ranked.first)
        .toList();
    return LegacyMatch(
      [newItem, ...picked.map((p) => p.item)],
      picked.fold(0.0, (sum, p) => sum + p.score),
    );
  }

  final variants = skeleton
      .where((c) => c.ranked.length >= 2)
      .map((c) => buildCombo(c.category))
      .toList();

  const coreCategories = {'상의', '하의'};
  final corePicks = skeleton.where((c) => coreCategories.contains(c.category)).toList();
  if (corePicks.isNotEmpty && corePicks.length < skeleton.length) {
    final picked = corePicks.map((c) => c.ranked.first).toList();
    variants.add(LegacyMatch(
      [newItem, ...picked.map((p) => p.item)],
      picked.fold(0.0, (sum, p) => sum + p.score),
    ));
  }

  variants.sort((a, b) => b.localScore.compareTo(a.localScore));
  final seen = <String>{};
  final combos = <LegacyMatch>[];
  for (final combo in [buildCombo(null), ...variants]) {
    final signature = (combo.items.map((i) => i.id).toList()..sort()).join(',');
    if (!seen.add(signature)) continue;
    combos.add(combo);
    if (combos.length >= maxCandidates) break;
  }
  return combos;
}

// findForTpo(TPO 경로) 이전 버전을 그대로 재구현. isNeutralColor 소스만
// 바꾼 이번 수정 검증 전용 — neutralColors 세트만 바꿔 끼우면 "OLD"(고치기
// 전) 결과를 만들 수 있다.
double legacyFormalityFitScore(int targetRank, int itemRank) {
  final diff = (targetRank - itemRank).abs();
  return diff == 0 ? 3 : (diff == 1 ? 1 : 0);
}

class LegacyTpoResult {
  final List<LegacyMatch> candidates;
  final bool isFallback;
  final String? shortfall;
  const LegacyTpoResult({required this.candidates, required this.isFallback, this.shortfall});
}

List<LegacyMatch> _legacyBuildCombosFromRanked(
  Map<String, List<({WardrobeItem item, double score})>> rankedPerCategory,
  int maxCandidates,
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
  final skeleton = ordered.take(3).toList();

  LegacyMatch buildCombo(String? replaceCategory) {
    final picked = skeleton
        .map((c) => c.category == replaceCategory ? c.ranked[1] : c.ranked.first)
        .toList();
    return LegacyMatch(
      picked.map((p) => p.item).toList(),
      picked.fold(0.0, (sum, p) => sum + p.score),
    );
  }

  final variants = skeleton
      .where((c) => c.ranked.length >= 2)
      .map((c) => buildCombo(c.category))
      .toList();
  final core = skeleton.where((c) => c.category == '상의' || c.category == '하의').toList();
  if (core.length == 2 && skeleton.length > 2) {
    final picked = core.map((c) => c.ranked.first).toList();
    variants.add(LegacyMatch(
      picked.map((p) => p.item).toList(),
      picked.fold(0.0, (sum, p) => sum + p.score),
    ));
  }

  variants.sort((a, b) => b.localScore.compareTo(a.localScore));
  final seen = <String>{};
  final combos = <LegacyMatch>[];
  for (final combo in [buildCombo(null), ...variants]) {
    final signature = (combo.items.map((i) => i.id).toList()..sort()).join(',');
    if (!seen.add(signature)) continue;
    combos.add(combo);
    if (combos.length >= maxCandidates) break;
  }
  return combos;
}

LegacyTpoResult legacyFindForTpo({
  required List<WardrobeItem> wardrobe,
  required String formalityHint,
  required Set<String> neutralColors,
  int maxCandidates = 3,
}) {
  final targetRank = legacyFormalityRank[formalityHint] ?? 0;

  final allPerCategory = <String, List<({WardrobeItem item, double score})>>{};
  for (final item in wardrobe) {
    final attrs = item.attributes;
    if (attrs == null || !legacyOutfitCategories.contains(item.category)) continue;
    final rank = legacyFormalityRank[attrs.formality];
    double score = rank == null ? 0.5 : legacyFormalityFitScore(targetRank, rank);
    if (neutralColors.contains(attrs.color)) score += 1;
    allPerCategory.putIfAbsent(item.category, () => []).add((item: item, score: score));
  }

  Map<String, List<({WardrobeItem item, double score})>> topTwo(bool Function(double) keep) {
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
  final hasCore = scored.containsKey('상의') && scored.containsKey('하의');
  if (hasCore) {
    return LegacyTpoResult(
      candidates: _legacyBuildCombosFromRanked(scored, maxCandidates),
      isFallback: false,
    );
  }

  final relaxed = topTwo((_) => true);
  if (relaxed.containsKey('상의') && relaxed.containsKey('하의')) {
    return LegacyTpoResult(
      candidates: _legacyBuildCombosFromRanked(relaxed, maxCandidates),
      isFallback: true,
    );
  }

  final missing = <String>[];
  if (!relaxed.containsKey('상의')) missing.add('상의');
  if (!relaxed.containsKey('하의')) missing.add('하의');
  return LegacyTpoResult(
    candidates: const [],
    isFallback: false,
    shortfall: '$formalityHint 조합에 필요한 ${missing.join('·')}가 옷장에 없어요',
  );
}
