// TPO 격식 판정 정책(TpoMatchPolicy) A/B 실측 리포트.
// docs/task_formality_policy_ab.md §3 — 결함 A(무채색 보너스가 격식 필터를
// 무력화)/결함 B(hasCore가 상의·하의만 검사)를 정책 하나로 스위치했을 때
// 실측 옷장(tools/export_for_kaggle/output/items.json)에서 어느 쪽으로
// 기우는지 측정한다. 이 파일의 목적은 진단이지 회귀 방지가 아니다 — 정책
// 기본값을 바꾸는 판단은 사람이 한다(§4).
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_fashion_assistant/constants/tpo_tags.dart';
import 'package:ai_fashion_assistant/models/wardrobe_item.dart';
import 'package:ai_fashion_assistant/services/outfit_matcher.dart';

import 'support/legacy_matcher.dart' show legacyFormalityRank, legacyFormalityFitScore;
import 'support/wardrobe_fixture.dart';

String _sig(List<WardrobeItem> items) => (items.map((i) => i.id).toList()..sort()).join(',');

// findForTpo 내부의 scored 계산(score 공식 + topTwo 캡)을 그대로 재현한다.
// genuine=true는 rank!=null && 격식 거리 0~1(=_formalityFitScore>0)인
// "진짜" 적합 아이템 — 무채색 보너스나 rank=null 통과와 무관하게 격식만으로
// 필터를 통과했을 아이템이다. gateNeutralBonus로 current/proposed 공식을
// 그대로 스위치해서 표5(필터 순도)와 카테고리 소멸 여부 확인에 함께 쓴다.
List<({WardrobeItem item, bool genuine})> _scoredTopTwo({
  required Iterable<WardrobeItem> categoryItems,
  required int targetRank,
  required bool gateNeutralBonus,
}) {
  final scored = <({WardrobeItem item, double score, bool genuine})>[];
  for (final item in categoryItems) {
    final attrs = item.attributes!;
    final rank = legacyFormalityRank[attrs.formality];
    var score = rank == null ? 0.5 : legacyFormalityFitScore(targetRank, rank);
    final genuine = rank != null && score > 0;
    if (OutfitMatcher.isNeutralColor(attrs.color) && (!gateNeutralBonus || score > 0)) {
      score += 1;
    }
    if (score > 0) scored.add((item: item, score: score, genuine: genuine));
  }
  scored.sort((a, b) => b.score.compareTo(a.score));
  final top = scored.length > 2 ? scored.sublist(0, 2) : scored;
  return top.map((e) => (item: e.item, genuine: e.genuine)).toList();
}

// 카테고리별 최고 점수(current=ungated 공식, score>0만) — _buildCombosFromRanked의
// skeleton 우선순위+점수 정렬을 표6에서 그대로 재현하기 위한 재료.
// 반환 맵의 키 순서(=카테고리 최초 등장 순서)가 중요하다 — 실제 코드의
// allPerCategory/scored도 wardrobe 순회 중 카테고리가 처음 등장한 순서로
// 채워지는 LinkedHashMap이고, _buildCombosFromRanked의 정렬은 리스트 크기가
// 작아(≤4) 삽입정렬(안정 정렬)이 적용돼 동점일 때 그 최초 등장 순서가
// 그대로 타이브레이커가 된다. 고정된 카테고리 리스트 순서로 맵을 채우면
// 이 타이브레이크가 실제 코드와 어긋난다(동점 시 신발/아우터 우열이 뒤집힘).
Map<String, double> _topScorePerCategory({
  required List<WardrobeItem> wardrobe,
  required Set<String> categories,
  required int targetRank,
}) {
  final maxScore = <String, double>{};
  final firstSeenOrder = <String>[];
  for (final item in wardrobe) {
    final attrs = item.attributes;
    if (attrs == null || !categories.contains(item.category)) continue;
    if (!firstSeenOrder.contains(item.category)) firstSeenOrder.add(item.category);
    final rank = legacyFormalityRank[attrs.formality];
    var score = rank == null ? 0.5 : legacyFormalityFitScore(targetRank, rank);
    if (OutfitMatcher.isNeutralColor(attrs.color)) score += 1;
    if (score <= 0) continue;
    final prev = maxScore[item.category];
    if (prev == null || score > prev) maxScore[item.category] = score;
  }
  final result = <String, double>{};
  for (final c in firstSeenOrder) {
    if (maxScore.containsKey(c)) result[c] = maxScore[c]!;
  }
  return result;
}

// findForTpo의 카테고리별 후보 선정(topPerCategory)을 정책 그대로 재현해
// "후보 풀 크기"를 센다. 표9에서 두 가지를 분리하기 위한 재료다 —
// (a) 폭 확대가 실제로 풀을 넓혔는가, (b) 넓어진 풀이 최종 후보에 반영됐는가.
// 구분하지 않으면 "폭 확대는 이 옷장에서 효과 없음"과 "그리디 선택이 넓어진
// 풀을 못 쓴다"가 똑같은 숫자로 보인다(7/26 무채색 게이팅이 "판단 불가"로
// 끝났던 것과 같은 함정).
// 전제: maxSkeletonCategories(4) >= 실제 카테고리 수(4)라 스켈레톤 컷은
// 여기서 고려하지 않는다. 그 전제가 깨지면 이 함수도 같이 고쳐야 한다.
int _candidatePoolSize({
  required List<WardrobeItem> wardrobe,
  required Set<String> categories,
  required int targetRank,
  required TpoMatchPolicy policy,
  required bool relaxed,
}) {
  final perCategory = policy.effectiveCandidatesPerCategory;
  final counts = <String, int>{};
  for (final item in wardrobe) {
    final attrs = item.attributes;
    if (attrs == null || !categories.contains(item.category)) continue;
    final rank = legacyFormalityRank[attrs.formality];
    var score = rank == null ? 0.5 : legacyFormalityFitScore(targetRank, rank);
    if (OutfitMatcher.isNeutralColor(attrs.color) &&
        (!policy.gateNeutralBonus || score > 0)) {
      score += 1;
    }
    if (!relaxed && score <= 0) continue;
    counts[item.category] = (counts[item.category] ?? 0) + 1;
  }
  var total = 0;
  for (final n in counts.values) {
    total += n > perCategory ? perCategory : n;
  }
  return total;
}

String _categoriesOf(List<WardrobeItem> items) {
  const order = ['상의', '하의', '아우터', '신발'];
  final present = items.map((i) => i.category).toSet();
  return order.where(present.contains).join('+');
}

void main() {
  // items.json은 tools/export_for_kaggle/output/ 산출물(.gitignore 대상, 실제
  // 사용자 옷장 데이터라 저장소에 커밋 안 됨) — 로컬에 없으면 이 파일 전체를
  // 스킵한다(CI/새 클론에서 실패하지 않도록).
  final itemsFile = File('tools/export_for_kaggle/output/items.json');
  if (!itemsFile.existsSync()) {
    test('TPO 정책 A/B 리포트(로컬 데이터 없음 — 스킵)', () {},
        skip: 'tools/export_for_kaggle/output/items.json 없음');
    return;
  }

  final wardrobe = loadWardrobeFixture();
  const categories = ['상의', '하의', '아우터', '신발'];

  test('TPO 9종 × {current, proposed} 정책 비교 리포트', () {
    final currentResults = <String, TpoMatchResult>{};
    final proposedResults = <String, TpoMatchResult>{};
    final skeleton4Results = <String, TpoMatchResult>{};
    for (final tag in TpoTags.all) {
      currentResults[tag.label] = OutfitMatcher.findForTpo(
        wardrobe: wardrobe,
        formalityHint: tag.formalityHint,
        policy: TpoMatchPolicy.current,
      );
      proposedResults[tag.label] = OutfitMatcher.findForTpo(
        wardrobe: wardrobe,
        formalityHint: tag.formalityHint,
        policy: TpoMatchPolicy.neutralGating,
      );
      skeleton4Results[tag.label] = OutfitMatcher.findForTpo(
        wardrobe: wardrobe,
        formalityHint: tag.formalityHint,
        policy: TpoMatchPolicy.skeleton4,
      );
    }

    // ── 표 1 — 태그별 정책 비교 ──────────────────────────────
    print('\n[표1] 태그별 정책 비교');
    print('| 태그 | 요구격식 | current isFallback | proposed isFallback | '
        'current 후보수 | proposed 후보수 | 1번후보 변화 |');
    print('|---|---|---|---|---|---|---|');
    for (final tag in TpoTags.all) {
      final cur = currentResults[tag.label]!;
      final prop = proposedResults[tag.label]!;
      final curTop = cur.candidates.isEmpty ? null : _sig(cur.candidates.first.items);
      final propTop = prop.candidates.isEmpty ? null : _sig(prop.candidates.first.items);
      final topChanged = curTop != propTop;
      print('| ${tag.label} | ${tag.formalityHint} | ${cur.isFallback} | ${prop.isFallback} | '
          '${cur.candidates.length} | ${prop.candidates.length} | ${topChanged ? '변경' : '동일'} |');
    }

    // ── 표 2 — proposed에서 새로 채워진 mismatchedCategories ──
    print('\n[표2] proposed에서 채워진 mismatchedCategories (부재 인지 배지 재료)');
    print('| 태그 | 요구격식 | mismatchedCategories |');
    print('|---|---|---|');
    for (final tag in TpoTags.all) {
      final prop = proposedResults[tag.label]!;
      print('| ${tag.label} | ${tag.formalityHint} | '
          '${prop.mismatchedCategories.isEmpty ? '-' : prop.mismatchedCategories.join('·')} |');
    }

    // ── 표 3 — 무채색 보너스 구제 현황(핵심 지표) ─────────────
    // 0점 아이템 수: rank!=null이고 _formalityFitScore(targetRank, rank)==0인 아이템.
    // 무채색 구제 수: 그중 무채색이라 +1 보너스로 score>0을 통과한 아이템(구제 경로1).
    // rank=null 통과 수: 격식 속성이 없어 0.5점으로 통과한 아이템(구제 경로2).
    print('\n[표3] 무채색 보너스 구제 현황 (핵심 지표)');
    print('| 태그 | 카테고리 | 총 아이템 수 | 0점 아이템 수 | 무채색 구제 수 | rank=null 통과 수 |');
    print('|---|---|---|---|---|---|');
    for (final tag in TpoTags.all) {
      final targetRank = legacyFormalityRank[tag.formalityHint] ?? 0;
      for (final category in categories) {
        final items = wardrobe.where((i) => i.category == category && i.attributes != null);
        var totalCount = 0;
        var zeroScoreCount = 0;
        var rescuedByNeutral = 0;
        var nullRankPassed = 0;
        for (final item in items) {
          totalCount++;
          final attrs = item.attributes!;
          final rank = legacyFormalityRank[attrs.formality];
          if (rank == null) {
            nullRankPassed++;
            continue;
          }
          final fit = legacyFormalityFitScore(targetRank, rank);
          if (fit == 0) {
            zeroScoreCount++;
            if (OutfitMatcher.isNeutralColor(attrs.color)) rescuedByNeutral++;
          }
        }
        print('| ${tag.label}(${tag.formalityHint}) | $category | $totalCount | $zeroScoreCount | '
            '$rescuedByNeutral | $nullRankPassed |');
      }
    }

    // ── 표 5 — 필터 순도(무채색 보너스의 오염도, isFallback과 무관) ──
    // scored(topTwo 캡 적용, current=ungated 공식)에 남은 최대 2개 중
    // 실제로 격식 거리 0~1인 "진짜" 적합 아이템의 비율. 1.0이면 무채색
    // 보너스가 최종 후보 선정에 전혀 관여하지 않은 것이고, 낮을수록
    // scored가 무채색으로만 구제된 아이템에 잠식된 것이다. optionalMissing
    // (§5) 착수 전 발화 범위를 가늠하려고 9태그×4카테고리 전체를 본다 —
    // 포멀만 봐서는 캐주얼/세미포멀에서도 순도 0인 카테고리가 있는지 알 수 없다.
    print('\n[표5] 필터 순도 — scored 중 격식 거리 0~1 비율 (isFallback과 무관, 9태그×4카테고리 전체)');
    print('| 태그 | 카테고리 | 순도(진짜적합/scored) |');
    print('|---|---|---|');
    final zeroPurityPairs = <({String tag, String formalityHint, String category, bool required})>[];
    for (final tag in TpoTags.all) {
      final targetRank = legacyFormalityRank[tag.formalityHint] ?? 0;
      for (final category in categories) {
        final items = wardrobe.where((i) => i.category == category && i.attributes != null);
        final top = _scoredTopTwo(categoryItems: items, targetRank: targetRank, gateNeutralBonus: false);
        final genuineCount = top.where((e) => e.genuine).length;
        final purityCell = top.isEmpty
            ? '- (0/0)'
            : '${(genuineCount / top.length).toStringAsFixed(2)} ($genuineCount/${top.length})';
        print('| ${tag.label}(${tag.formalityHint}) | $category | $purityCell |');
        if (top.isNotEmpty && genuineCount == 0) {
          zeroPurityPairs.add((
            tag: tag.label,
            formalityHint: tag.formalityHint,
            category: category,
            required: TpoMatchPolicy.current.requiredCategories.contains(category),
          ));
        }
      }
    }

    // ── 표 5 요약 — optionalMissing 발화 범위 가늠 ──
    print('\n[표5 요약] 순도 0.00인 (태그, 카테고리) 쌍');
    if (zeroPurityPairs.isEmpty) {
      print('  없음');
    } else {
      for (final p in zeroPurityPairs) {
        print('  ${p.tag}(${p.formalityHint}) × ${p.category} — ${p.required ? '필수(상의·하의)' : '선택(아우터·신발)'}');
      }
    }
    final requiredZeroTags = zeroPurityPairs.where((p) => p.required).map((p) => p.tag).toSet();
    final optionalZeroTags = zeroPurityPairs.where((p) => !p.required).map((p) => p.tag).toSet();
    final anyZeroTags = zeroPurityPairs.map((p) => p.tag).toSet();
    print('  필수 카테고리에서 발생: ${requiredZeroTags.length}/${TpoTags.all.length}개 태그'
        '${requiredZeroTags.isEmpty ? '' : ' (${requiredZeroTags.join(', ')})'}');
    print('  선택 카테고리에서 발생: ${optionalZeroTags.length}/${TpoTags.all.length}개 태그'
        '${optionalZeroTags.isEmpty ? '' : ' (${optionalZeroTags.join(', ')})'}');
    print('  둘 중 하나라도 발생: ${anyZeroTags.length}/${TpoTags.all.length}개 태그 — '
        'optionalMissing 구현 시 안내가 발생할 태그 수 추정치');

    // ── 참고 — 게이팅(gated) 적용 시 scored에서 완전히 사라지는 카테고리 ──
    // 상의·하의(필수)가 아니어도 조용히 조합에서 빠질 수 있어(§4
    // optionalMissing의 동기) 포멀 목표 기준으로 확인해 둔다.
    print('\n[참고] 게이팅 적용 시 scored 소멸 카테고리 (포멀 목표)');
    if (TpoTags.all.any((t) => t.formalityHint == '포멀')) {
      final targetRank = legacyFormalityRank['포멀']!;
      for (final category in categories) {
        final items = wardrobe.where((i) => i.category == category && i.attributes != null);
        final ungated =
            _scoredTopTwo(categoryItems: items, targetRank: targetRank, gateNeutralBonus: false);
        final gated =
            _scoredTopTwo(categoryItems: items, targetRank: targetRank, gateNeutralBonus: true);
        final vanished = ungated.isNotEmpty && gated.isEmpty;
        print('  $category: ungated=${ungated.length} gated=${gated.length}'
            '${vanished ? ' ← 게이팅 시 소멸' : ''}');
      }
    }

    // ── 표 4 — 역효과 감지 ───────────────────────────────────
    print('\n[표4] 역효과 감지 (current 적합 → proposed 조합불가/fallback)');
    final regressedTags = <String>[];
    for (final tag in TpoTags.all) {
      final cur = currentResults[tag.label]!;
      final prop = proposedResults[tag.label]!;
      if (!cur.isFallback && (prop.candidates.isEmpty || prop.isFallback)) {
        regressedTags.add(tag.label);
        print('  ${tag.label}(${tag.formalityHint}): current 적합 → '
            'proposed ${prop.candidates.isEmpty ? '조합불가(${prop.shortfall})' : 'fallback'}');
      }
    }
    if (regressedTags.isEmpty) print('  없음');

    // ── 표 6 — skeleton 경쟁: maxSkeletonCategories 3(current) vs 4(skeleton4) ──
    // 탈락 카테고리/점수차는 current(3칸) 기준 — 4개 카테고리 중 우선순위
    // (상의>하의>그외) + 점수 정렬로 상위 3개만 스켈레톤에 들어가고, 나머지
    // 1개는 조합에서 조용히 빠진다(§표3/표5/[참고]가 보여준 신발 소멸의
    // 메커니즘 그 자체). skeleton4는 4칸이라 4개 카테고리가 다 있으면
    // 전부 스켈레톤에 들어간다.
    print('\n[표6] skeleton 경쟁 — current(3칸) vs skeleton4(4칸)');
    print('| 태그 | 요구격식 | 1번후보 카테고리(current) | 1번후보 카테고리(skeleton4) | '
        '후보개수(current→skeleton4) | 탈락 카테고리(current) | 점수차 |');
    print('|---|---|---|---|---|---|---|');
    for (final tag in TpoTags.all) {
      final targetRank = legacyFormalityRank[tag.formalityHint] ?? 0;
      final cur = currentResults[tag.label]!;
      final sk4 = skeleton4Results[tag.label]!;

      final topScores = _topScorePerCategory(
          wardrobe: wardrobe, categories: categories.toSet(), targetRank: targetRank);
      int pri(String c) => c == '상의' ? 0 : (c == '하의' ? 1 : 2);
      final ordered = topScores.entries.toList()
        ..sort((a, b) {
          final byPriority = pri(a.key).compareTo(pri(b.key));
          if (byPriority != 0) return byPriority;
          return b.value.compareTo(a.value);
        });
      final skeleton3 = ordered.take(3).toList();
      final excluded = ordered.length > 3 ? ordered.sublist(3) : const <MapEntry<String, double>>[];
      final droppedLabel = excluded.isEmpty
          ? '-'
          : excluded.map((e) => e.key).join(',');
      final scoreGap = excluded.isEmpty
          ? '-'
          : (skeleton3.last.value - excluded.first.value).toStringAsFixed(2);

      final curCats = cur.candidates.isEmpty ? '-' : _categoriesOf(cur.candidates.first.items);
      final sk4Cats = sk4.candidates.isEmpty ? '-' : _categoriesOf(sk4.candidates.first.items);

      print('| ${tag.label} | ${tag.formalityHint} | $curCats | $sk4Cats | '
          '${cur.candidates.length}→${sk4.candidates.length} | $droppedLabel | $scoreGap |');
    }

    // ── 표 7 — current 정책에서 1번 후보에 아우터/신발이 포함된 횟수 ──
    print('\n[표7] current 1번 후보에 아우터/신발이 포함된 횟수 (9개 태그 중)');
    var outerCount = 0;
    var shoesCount = 0;
    for (final tag in TpoTags.all) {
      final cur = currentResults[tag.label]!;
      if (cur.candidates.isEmpty) continue;
      final cats = cur.candidates.first.items.map((i) => i.category).toSet();
      if (cats.contains('아우터')) outerCount++;
      if (cats.contains('신발')) shoesCount++;
    }
    print('  아우터 포함: $outerCount / ${TpoTags.all.length}');
    print('  신발 포함: $shoesCount / ${TpoTags.all.length}');

    // ── 요약 한 줄 ───────────────────────────────────────────
    final currentFallbackCount = currentResults.values.where((r) => r.isFallback).length;
    final proposedFallbackCount = proposedResults.values.where((r) => r.isFallback).length;
    print('\ncurrent fallback 발화율: $currentFallbackCount/${TpoTags.all.length}  →  '
        'neutralGating: $proposedFallbackCount/${TpoTags.all.length}');

    // proposed 정책에서 어떤 태그든 candidates가 완전히 비면(=조합 자체 불가)
    // 그건 과도한 필터링이므로 즉시 눈에 띄어야 한다.
    final emptyTags = proposedResults.entries
        .where((e) => e.value.candidates.isEmpty)
        .map((e) => e.key)
        .toList();
    expect(emptyTags, isEmpty, reason: 'proposed 정책에서 조합 불가 태그: $emptyTags');
  });

  // ── 조합 품질 A/B (candidatesPerCategory × usePairwiseColorScore) ──────
  // 위 리포트가 "격식 필터가 무엇을 통과시키는가"를 봤다면, 이쪽은 "통과한
  // 것들로 무슨 조합을 만드는가"를 본다. 현행 findForTpo의 조합 점수는
  // 아이템별 격식 적합도의 단순 합이라 아이템 간 궁합이 개입할 자리가 없고,
  // 격식 점수의 값 종류가 다섯 개뿐이라 카테고리당 2벌 캡에서 동점이 대량
  // 발생한다. 두 축을 따로/같이 켜서 실측 옷장에서 무엇이 달라지는지 잰다.
  test('조합 품질 정책 A/B 리포트 (후보 폭 × 조합 단위 색상 채점)', () {
    // enum(=enumeratedOnly)이 기준선이다. current와의 차이는 순수하게
    // 생성기 교체 효과이고, wide/color는 enum과 비교해야 각 축의 효과가
    // 분리된다. current와 직접 비교하면 생성기 효과가 모든 셀에 섞인다.
    const policies = <String, TpoMatchPolicy>{
      'current': TpoMatchPolicy.current,
      'enum': TpoMatchPolicy.enumeratedOnly,
      'wide': TpoMatchPolicy.wideCandidates,
      'color': TpoMatchPolicy.pairwiseColor,
      'v2': TpoMatchPolicy.qualityV2,
    };

    final results = <String, Map<String, TpoMatchResult>>{};
    for (final entry in policies.entries) {
      final byTag = <String, TpoMatchResult>{};
      for (final tag in TpoTags.all) {
        byTag[tag.label] = OutfitMatcher.findForTpo(
          wardrobe: wardrobe,
          formalityHint: tag.formalityHint,
          policy: entry.value,
        );
      }
      results[entry.key] = byTag;
    }

    // 조합 하나의 색상 축 통계 — 쌍 평균 점수와, _colorScore가 음수를 준
    // 쌍(같은 색상군 + 같은 밝기 + 패턴도 같은 "깔맞춤")의 개수.
    // 후자가 이 변경이 실제로 무엇을 걸러내는지 보여주는 지표다.
    ({double avg, int clashes}) colorStats(List<WardrobeItem> items) {
      var sum = 0.0;
      var count = 0;
      var clashes = 0;
      for (var i = 0; i < items.length; i++) {
        for (var j = i + 1; j < items.length; j++) {
          final a = items[i].attributes, b = items[j].attributes;
          if (a == null || b == null) continue;
          final s = OutfitMatcher.colorScoreOnly(a, b);
          sum += s;
          count++;
          if (s < 0) clashes++;
        }
      }
      return (avg: count == 0 ? 0.0 : sum / count, clashes: clashes);
    }

    // ── 표 8 — 1번 후보 변화의 축별 귀속 ────────────────────
    // 각 열은 딱 한 축만 다른 비교다.
    //   생성기 = current vs enum   (폭·색상 동일, 생성기만 교체)
    //   폭     = enum    vs wide   (생성기·색상 동일, 폭만 2→4)
    //   색상   = enum    vs color  (생성기·폭 동일, 색상만 on)
    //   합산   = current vs v2     (셋 다)
    print('\n[표8] 1번 후보 변화의 축별 귀속');
    print('| 태그 | 요구격식 | current | enum | wide | color | v2 | '
        '생성기 | 폭 | 색상 | 합산 |');
    print('|---|---|---|---|---|---|---|---|---|---|---|');
    var genChanged = 0, widthChanged = 0, colorChanged = 0, totalChanged = 0;
    for (final tag in TpoTags.all) {
      String cell(String key) {
        final r = results[key]![tag.label]!;
        return r.candidates.isEmpty ? '-' : _categoriesOf(r.candidates.first.items);
      }
      String sigOf(String key) {
        final r = results[key]![tag.label]!;
        return r.candidates.isEmpty ? '' : _sig(r.candidates.first.items);
      }
      String mark(String a, String b) => sigOf(a) != sigOf(b) ? 'O' : '-';

      if (sigOf('current') != sigOf('enum')) genChanged++;
      if (sigOf('enum') != sigOf('wide')) widthChanged++;
      if (sigOf('enum') != sigOf('color')) colorChanged++;
      if (sigOf('current') != sigOf('v2')) totalChanged++;

      print('| ${tag.label} | ${tag.formalityHint} | ${cell('current')} | ${cell('enum')} | '
          '${cell('wide')} | ${cell('color')} | ${cell('v2')} | '
          '${mark('current', 'enum')} | ${mark('enum', 'wide')} | '
          '${mark('enum', 'color')} | ${mark('current', 'v2')} |');
    }
    final n = TpoTags.all.length;
    print('  1번 후보가 바뀐 태그 수 — 생성기 $genChanged/$n · 폭 $widthChanged/$n · '
        '색상 $colorChanged/$n · 합산 $totalChanged/$n');
    print('  (생성기 열이 크면 아래 표들의 current 대비 수치는 색상/폭의 효과가 아니다)');

    // ── 표 9 — 옷장 커버리지 ─────────────────────────────────
    // 9개 태그의 후보 전체(1~3번)에 실제로 등장한 고유 아이템 수. 낮을수록
    // "같은 옷만 반복 추천"이다 — 이 앱이 해결하겠다고 내건 문제 그 자체라
    // 정책 판단의 1차 지표로 둔다.
    final poolSize = wardrobe
        .where((i) => i.attributes != null && categories.contains(i.category))
        .length;
    print('\n[표9] 옷장 커버리지 (모집단 $poolSize벌)');
    print('| 정책 | 후보 풀 합계 | 후보 등장 합계 | 풀 활용률 | 고유 아이템 | 커버리지 |');
    print('|---|---|---|---|---|---|');
    for (final key in policies.keys) {
      final policy = policies[key]!;
      final all = <String>{};
      var poolTotal = 0;
      var usedTotal = 0;
      for (final tag in TpoTags.all) {
        final r = results[key]![tag.label]!;
        final targetRank = legacyFormalityRank[tag.formalityHint] ?? 0;
        poolTotal += _candidatePoolSize(
          wardrobe: wardrobe,
          categories: categories.toSet(),
          targetRank: targetRank,
          policy: policy,
          relaxed: r.isFallback,
        );
        final perTag = <String>{};
        for (final c in r.candidates) {
          for (final item in c.items) {
            perTag.add(item.id);
            all.add(item.id);
          }
        }
        usedTotal += perTag.length;
      }
      final pct = poolSize == 0 ? 0.0 : all.length / poolSize * 100;
      final util = poolTotal == 0 ? 0.0 : usedTotal / poolTotal * 100;
      print('| $key | $poolTotal | $usedTotal | ${util.toStringAsFixed(1)}% | '
          '${all.length} | ${pct.toStringAsFixed(1)}% |');
    }
    print('  읽는 법: 풀 합계가 늘었는데 등장 합계가 그대로면 병목은 폭이 아니라');
    print('  선택 단계(점수순 그리디)다 — "폭 확대는 효과 없음"으로 읽으면 오귀속.');

    // ── 표 10 — 색상 품질 ────────────────────────────────────
    // 1번 후보의 쌍 평균 색상 점수와 충돌 쌍 수를 정책별로 비교한다.
    // 충돌 쌍이 current에서 몇 건 나오는지가 "색상 엔진이 안 돌고 있다"는
    // 진단의 실측 근거이고, v2에서 그게 줄어드는지가 개선의 증거다.
    print('\n[표10] 1번 후보의 색상 품질 (쌍 평균 / 충돌 쌍 수)');
    print('| 태그 | current 평균 | current 충돌 | v2 평균 | v2 충돌 |');
    print('|---|---|---|---|---|');
    var curClashTotal = 0;
    var v2ClashTotal = 0;
    var curAvgSum = 0.0;
    var v2AvgSum = 0.0;
    var counted = 0;
    for (final tag in TpoTags.all) {
      final cur = results['current']![tag.label]!;
      final v2 = results['v2']![tag.label]!;
      if (cur.candidates.isEmpty || v2.candidates.isEmpty) {
        print('| ${tag.label} | - | - | - | - |');
        continue;
      }
      final cs = colorStats(cur.candidates.first.items);
      final vs = colorStats(v2.candidates.first.items);
      curClashTotal += cs.clashes;
      v2ClashTotal += vs.clashes;
      curAvgSum += cs.avg;
      v2AvgSum += vs.avg;
      counted++;
      print('| ${tag.label} | ${cs.avg.toStringAsFixed(2)} | ${cs.clashes} | '
          '${vs.avg.toStringAsFixed(2)} | ${vs.clashes} |');
    }
    if (counted > 0) {
      print('  전체 평균: current ${(curAvgSum / counted).toStringAsFixed(2)} → '
          'v2 ${(v2AvgSum / counted).toStringAsFixed(2)}');
      print('  충돌 쌍 합계: current $curClashTotal → v2 $v2ClashTotal');
    }

    // ── 표 11 — 후보 간 다양성 ───────────────────────────────
    // 반환된 후보 3개가 서로 몇 벌이나 다른지. 실측 candidateScores에
    // [65,65,65]처럼 동일 점수가 찍힌 적이 있는데, 후보들이 사실상 같은 옷의
    // 순열이면 Gemini 평가가 구분할 게 없다. 폭을 넓히면 이게 개선되는지,
    // 아니면 다양성 항을 따로 넣어야 하는지(=다음 단계 필요 여부)를 본다.
    print('\n[표11] 후보 간 다양성 — 1번 후보 대비 2·3번 후보의 상이 아이템 수');
    print('| 태그 | current (2번/3번) | v2 (2번/3번) |');
    print('|---|---|---|');
    for (final tag in TpoTags.all) {
      String diffCell(String key) {
        final r = results[key]![tag.label]!;
        if (r.candidates.isEmpty) return '-';
        final base = r.candidates.first.items.map((i) => i.id).toSet();
        final parts = <String>[];
        for (var c = 1; c < 3; c++) {
          if (c >= r.candidates.length) {
            parts.add('-');
            continue;
          }
          final other = r.candidates[c].items.map((i) => i.id).toSet();
          parts.add('${other.difference(base).length}');
        }
        return parts.join('/');
      }
      print('| ${tag.label} | ${diffCell('current')} | ${diffCell('v2')} |');
    }

    // ── 표 12 — 미니 조합(상의·하의만)이 후보에 든 횟수 ──────
    // 조합 점수의 격식 축이 "아이템별 점수의 합"이라 4벌 조합의 base가
    // 구조적으로 2벌 조합보다 크다(최대 16 vs 8). 색상 항은 쌍 평균 × 3이라
    // 양쪽 다 [-3,+6] 범위여서 그 격차를 뒤집기 어렵다. 즉 미니 조합은
    // 생성·채점·정렬은 되지만 후보에 못 들 가능성이 높다.
    // 기존 _buildCombosFromRanked도 같은 성질이었으므로(localScore 역시 합,
    // 게다가 base 조합이 무조건 1번 고정) 이 패치가 만든 문제는 아니지만,
    // 0/9로 확인되면 근거를 갖고 제거하거나 base를 아이템 수로 정규화하는
    // 걸 검토해야 한다. 후자는 점수 스케일 전체를 건드리는 변경이다.
    print('\n[표12] 미니 조합(2벌)이 후보에 든 태그 수');
    for (final key in policies.keys) {
      var tagsWithMini = 0;
      var miniAtTop = 0;
      for (final tag in TpoTags.all) {
        final r = results[key]![tag.label]!;
        if (r.candidates.isEmpty) continue;
        // 이 태그에서 조합 가능한 최대 카테고리 수보다 적은 조합 = 미니.
        final maxItems =
            r.candidates.map((c) => c.items.length).reduce((a, b) => a > b ? a : b);
        if (maxItems <= 2) continue; // 애초에 2벌짜리만 가능한 태그는 제외
        if (r.candidates.any((c) => c.items.length == 2)) tagsWithMini++;
        if (r.candidates.first.items.length == 2) miniAtTop++;
      }
      print('  $key: 후보에 포함 $tagsWithMini/${TpoTags.all.length} · '
          '1번 후보로 채택 $miniAtTop/${TpoTags.all.length}');
    }

    // 폭을 넓히거나 색상을 켜서 어떤 태그의 조합이 아예 사라지면 과도한
    // 변경이므로 즉시 실패시킨다(표4와 같은 취지의 안전망).
    for (final key in policies.keys) {
      final empty = results[key]!
          .entries
          .where((e) => e.value.candidates.isEmpty)
          .map((e) => e.key)
          .toList();
      expect(empty, isEmpty, reason: '$key 정책에서 조합 불가 태그: $empty');
    }
  });

  // ── 다양성(옷장 회전) A/B ────────────────────────────────────────────
  // 표8~표12에서 생성기·폭·색상 세 축이 모두 0/9로 나왔고, 표9에서 후보 풀을
  // 두 배로 넓혀도 실제 등장 아이템은 그대로였다(활용률 75%→37.5%). 병목이
  // 조합 단계가 아니라 그 앞의 topPerCategory 상위 N 컷이라는 뜻이다.
  // 격식 점수가 취하는 값이 몇 개뿐이라 동점이 대량 발생하고, 동점은 정렬
  // 안정성에 기대 wardrobe 순회 순서로 갈린다 — 그래서 9개 태그가 모두 같은
  // 옷 11벌을 돌려 쓴다(커버리지 12.6%).
  // 여기서는 (a) 그 동점 집합이 실제로 얼마나 큰지(=회전 가능 여지)와
  // (b) 아이템 점수에 최근 감점을 넣으면 회전이 실제로 도는지를 잰다.
  test('다양성 정책 A/B 리포트 (동점 규모 × 최근 감점)', () {
    // ── 표 13 — 카테고리별 최고점 동점 규모 ─────────────────
    // "채택"은 policy.candidatesPerCategory(기본 2)이고 "동점"은 그 최고점을
    // 공유하는 전체 벌 수다. 동점이 2 이하면 감점을 넣어도 돌릴 여지가 없고,
    // 크면 클수록 커버리지 상한이 높다.
    print('\n[표13] 카테고리별 최고점 동점 규모 (채택 ${TpoMatchPolicy.current.effectiveCandidatesPerCategory}벌)');
    print('| 태그 | 요구격식 | 상의 | 하의 | 아우터 | 신발 |');
    print('|---|---|---|---|---|---|');
    var tiedTotal = 0;
    var takenTotal = 0;
    for (final tag in TpoTags.all) {
      final targetRank = legacyFormalityRank[tag.formalityHint] ?? 0;
      final scores = <String, List<double>>{};
      for (final item in wardrobe) {
        final attrs = item.attributes;
        if (attrs == null || !categories.contains(item.category)) continue;
        final rank = legacyFormalityRank[attrs.formality];
        var score = rank == null ? 0.5 : legacyFormalityFitScore(targetRank, rank);
        if (OutfitMatcher.isNeutralColor(attrs.color)) score += 1;
        if (score <= 0) continue; // scored 경로 기준
        scores.putIfAbsent(item.category, () => []).add(score);
      }
      final cells = <String>[];
      for (final c in categories) {
        final list = scores[c];
        if (list == null || list.isEmpty) {
          cells.add('-');
          continue;
        }
        final top = list.reduce((a, b) => a > b ? a : b);
        final tied = list.where((v) => v == top).length;
        final taken = TpoMatchPolicy.current.effectiveCandidatesPerCategory;
        tiedTotal += tied;
        takenTotal += tied < taken ? tied : taken;
        cells.add('${top.toStringAsFixed(1)}점 $tied벌');
      }
      print('| ${tag.label} | ${tag.formalityHint} | ${cells.join(' | ')} |');
    }
    print('  최고점 동점 합계 $tiedTotal벌 중 $takenTotal벌만 채택 — '
        '나머지 ${tiedTotal - takenTotal}벌이 순회 순서로 탈락한다');

    // ── 표 14 — 최근 감점 강도별 순차 시뮬레이션 ──────────────
    // 9개 태그를 순서대로 처리하며 앞선 태그의 1번 후보를 recent에 누적한다.
    // 하루 한 건씩 추천이 쌓이는 실제 운용과 같은 구조라, 감점이 옷장 회전을
    // 실제로 만들어내는지 그대로 재현된다. recent를 누적하지 않는(=현행)
    // 경우가 penalty 0.0 행이다.
    const diversityPolicies = <String, TpoMatchPolicy>{
      '0.0 (현행)': TpoMatchPolicy.diversityOff,
      '0.4 (동점만)': TpoMatchPolicy.diversityTieBreak,
      '1.0 (무채색급)': TpoMatchPolicy.diversityModerate,
      '2.0 (격식급)': TpoMatchPolicy.diversityStrong,
    };
    final poolSize = wardrobe
        .where((i) => i.attributes != null && categories.contains(i.category))
        .length;

    print('\n[표14] 최근 감점 강도별 순차 시뮬레이션 (모집단 $poolSize벌)');
    print('| 감점 | 고유 아이템 | 커버리지 | 1번 후보 고유 | isFallback 태그 수 |');
    print('|---|---|---|---|---|');
    final firstPickByPolicy = <String, List<String>>{};
    for (final entry in diversityPolicies.entries) {
      final recent = <String>{};
      final all = <String>{};
      final firstPicks = <String>{};
      final picks = <String>[];
      var fallbackCount = 0;
      for (final tag in TpoTags.all) {
        final r = OutfitMatcher.findForTpo(
          wardrobe: wardrobe,
          formalityHint: tag.formalityHint,
          policy: entry.value,
          recentItemIds: recent,
        );
        if (r.isFallback) fallbackCount++;
        for (final c in r.candidates) {
          for (final i in c.items) {
            all.add(i.id);
          }
        }
        if (r.candidates.isNotEmpty) {
          final top = r.candidates.first.items.map((i) => i.id).toList();
          firstPicks.addAll(top);
          picks.add(_sig(r.candidates.first.items));
          // 실제로 사용자에게 제시되는 건 1번 후보이므로 그것만 누적한다.
          recent.addAll(top);
        }
      }
      firstPickByPolicy[entry.key] = picks;
      final pct = poolSize == 0 ? 0.0 : all.length / poolSize * 100;
      print('| ${entry.key} | ${all.length} | ${pct.toStringAsFixed(1)}% | '
          '${firstPicks.length} | $fallbackCount |');
    }

    // ── 표 15 — 감점이 TPO 정확도를 해치지 않았는지 ────────────
    // 회전이 늘어도 격식이 무너지면 의미가 없다. 감점 강도를 올렸을 때
    // isFallback 태그가 늘거나 1번 후보 구성이 무너지는지 확인한다.
    print('\n[표15] 감점 강도별 1번 후보 변화 (현행 대비)');
    print('| 태그 | 0.4 | 1.0 | 2.0 |');
    print('|---|---|---|---|');
    final base = firstPickByPolicy['0.0 (현행)']!;
    for (var i = 0; i < TpoTags.all.length; i++) {
      String mark(String key) {
        final list = firstPickByPolicy[key]!;
        if (i >= list.length || i >= base.length) return '-';
        return list[i] != base[i] ? 'O' : '-';
      }
      print('| ${TpoTags.all[i].label} | ${mark('0.4 (동점만)')} | '
          '${mark('1.0 (무채색급)')} | ${mark('2.0 (격식급)')} |');
    }

    // 감점을 켜서 조합 자체가 사라지는 태그가 생기면 과도한 변경이다.
    for (final entry in diversityPolicies.entries) {
      final recent = <String>{};
      for (final tag in TpoTags.all) {
        final r = OutfitMatcher.findForTpo(
          wardrobe: wardrobe,
          formalityHint: tag.formalityHint,
          policy: entry.value,
          recentItemIds: recent,
        );
        expect(r.candidates, isNotEmpty,
            reason: '${entry.key} 정책 · ${tag.label}에서 조합 불가');
        recent.addAll(r.candidates.first.items.map((i) => i.id));
      }
    }
  });

  // ── 매칭 재설계 v1 (docs/task_matching_redesign_v1.md) — 표16~19 골격 ──
  // M1: 신규 정책 코드(fillOptionalFromRelaxed) 없이, 기존 프리셋(current,
  // neutralGating)만으로 표 구조를 먼저 세운다. perCategoryFill 관련 열/표는
  // M2에서 프리셋이 추가된 뒤 채운다 — 지금은 자리만 잡아둔다.
  test('매칭 재설계 A/B 골격 (표16~19, M1 — 신규 정책 없이 기존 프리셋)', () {
    final currentResults = <String, TpoMatchResult>{};
    final neutralGatingResults = <String, TpoMatchResult>{};
    for (final tag in TpoTags.all) {
      currentResults[tag.label] = OutfitMatcher.findForTpo(
        wardrobe: wardrobe,
        formalityHint: tag.formalityHint,
        policy: TpoMatchPolicy.current,
      );
      neutralGatingResults[tag.label] = OutfitMatcher.findForTpo(
        wardrobe: wardrobe,
        formalityHint: tag.formalityHint,
        policy: TpoMatchPolicy.neutralGating,
      );
    }

    bool hasCategory(TpoMatchResult r, String category) =>
        r.candidates.isNotEmpty &&
        r.candidates.first.items.any((i) => i.category == category);

    // 1번 후보 아이템 중 "진짜" 격식 적합(rank!=null && ungated fit>0) 비율.
    // §3-2가 말하는 "조합 순도" — 무채색 보너스만으로 살아남은 아이템은
    // 분자에서 빠진다.
    double purity(TpoMatchResult r, int targetRank) {
      if (r.candidates.isEmpty) return double.nan;
      final items = r.candidates.first.items;
      final genuine = items.where((i) {
        final rank = legacyFormalityRank[i.attributes?.formality];
        return rank != null && legacyFormalityFitScore(targetRank, rank) > 0;
      }).length;
      return genuine / items.length;
    }

    String fmtBool(bool b) => b ? 'O' : '-';
    String fmtPurity(double p) => p.isNaN ? '-' : p.toStringAsFixed(2);

    // ── 표 16 — 재설계 A/B 골격 ──────────────────────────────
    print('\n[표16] 재설계 A/B 골격 — 1번 후보 신발/아우터, isFallback, '
        'optionalMissing, 조합 순도 (perCategoryFill 열은 M2 이후 채움)');
    print('| 태그 | 요구격식 | 신발(current) | 신발(neutralGating) | '
        '신발(perCategoryFill) | 아우터(current) | 아우터(neutralGating) | '
        '아우터(perCategoryFill) | isFallback(cur/nG/pF) | '
        'optionalMissing 건수(cur/nG/pF) | 조합순도(cur/nG/pF) |');
    print('|---|---|---|---|---|---|---|---|---|---|---|');
    var shoesVanishedCount = 0;
    for (final tag in TpoTags.all) {
      final targetRank = legacyFormalityRank[tag.formalityHint] ?? 0;
      final cur = currentResults[tag.label]!;
      final ng = neutralGatingResults[tag.label]!;
      final curShoes = hasCategory(cur, '신발');
      final ngShoes = hasCategory(ng, '신발');
      if (curShoes && !ngShoes) shoesVanishedCount++;
      final curOuter = hasCategory(cur, '아우터');
      final ngOuter = hasCategory(ng, '아우터');
      final curPurity = purity(cur, targetRank);
      final ngPurity = purity(ng, targetRank);
      print('| ${tag.label} | ${tag.formalityHint} | ${fmtBool(curShoes)} | '
          '${fmtBool(ngShoes)} | (M2) | ${fmtBool(curOuter)} | '
          '${fmtBool(ngOuter)} | (M2) | ${cur.isFallback}/${ng.isFallback}/(M2) | '
          '${cur.optionalMissing.length}/${ng.optionalMissing.length}/(M2) | '
          '${fmtPurity(curPurity)}/${fmtPurity(ngPurity)}/(M2) |');
    }
    print('\n[표16 핵심대조] neutralGating 단독에서 1번 후보 신발이 사라지는 '
        '태그 수(현행엔 있었는데 neutralGating엔 없음): '
        '$shoesVanishedCount/${TpoTags.all.length}');
    print('  perCategoryFill에서 0이 되는지는 M2 이후(프리셋 추가 후) 이 표를 다시 채워 확인한다.');

    // ── 표 17 — 색상 변별력 회복 (골격만, M2 이후 측정) ────────
    print('\n[표17] 색상 변별력 회복 (perCategoryFill+pairwiseColor, 표8 대조) '
        '— 골격만, M2 이후 측정');
    print('| 태그 | 표8 current 1번후보 | 표8 v2 1번후보 | '
        'perCategoryFill+pairwiseColor 1번후보 |');
    print('|---|---|---|---|');
    print('  perCategoryFill 프리셋 미도입 — M2에서 프리셋 추가 후 채운다.');

    // ── 표 18 — 커버리지 영향 (current/neutralGating만 실측) ───
    final poolSize = wardrobe
        .where((i) => i.attributes != null && categories.contains(i.category))
        .length;
    print('\n[표18] 커버리지 영향 (모집단 $poolSize벌) — perCategoryFill 열은 M2 이후');
    print('| 정책 | 고유 아이템 | 커버리지 |');
    print('|---|---|---|');
    for (final entry in {
      'current': currentResults,
      'neutralGating': neutralGatingResults,
    }.entries) {
      final all = <String>{};
      for (final r in entry.value.values) {
        for (final c in r.candidates) {
          for (final item in c.items) {
            all.add(item.id);
          }
        }
      }
      final pct = poolSize == 0 ? 0.0 : all.length / poolSize * 100;
      print('| ${entry.key} | ${all.length} | ${pct.toStringAsFixed(1)}% |');
    }
    print('| perCategoryFill | (M2) | (M2) |');
    print('  보충 채움이 relaxed에서 끌어오는 아이템이 기존 미노출군인지 분리 집계하는 것도 M2 이후.');

    // ── 표 19 — recency 상호작용 (골격만, M2 이후 측정) ────────
    print('\n[표19] recency 상호작용 (perCategoryFill × {0.0, 0.4}) '
        '— 골격만, M2 이후 측정');
    print('| 태그 | isFallback(pF, recency 0.0) | isFallback(pF, recency 0.4) | '
        '1번후보 변화 |');
    print('|---|---|---|---|');
    print('  perCategoryFill 프리셋 미도입 — M2에서 프리셋 추가 후 채운다.');
  });
}
