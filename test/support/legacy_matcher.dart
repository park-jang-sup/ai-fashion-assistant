import 'package:ai_fashion_assistant/models/clothing_attributes.dart';
import 'package:ai_fashion_assistant/models/wardrobe_item.dart';

// 궁합 규칙 보강(2026-07) 이전 findCandidateMatches를 matcher_spec.md 기준으로
// 그대로 재구현한 것. 검증 전용 — lib/에는 존재하지 않는다. 색상 점수 함수만
// 바꿔 끼워서 "OLD"(원래 8개 무채색 세트)와 "BUGFIX-ONLY"(회색·차콜 추가,
// family/매트릭스/톤온톤 없음) 두 변형을 만드는 데 쓴다.
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
