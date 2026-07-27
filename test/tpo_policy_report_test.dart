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
        policy: TpoMatchPolicy.proposed,
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
        'proposed: $proposedFallbackCount/${TpoTags.all.length}');

    // proposed 정책에서 어떤 태그든 candidates가 완전히 비면(=조합 자체 불가)
    // 그건 과도한 필터링이므로 즉시 눈에 띄어야 한다.
    final emptyTags = proposedResults.entries
        .where((e) => e.value.candidates.isEmpty)
        .map((e) => e.key)
        .toList();
    expect(emptyTags, isEmpty, reason: 'proposed 정책에서 조합 불가 태그: $emptyTags');
  });
}