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
    print('| 태그 | 카테고리 | 0점 아이템 수 | 무채색 구제 수 | rank=null 통과 수 |');
    print('|---|---|---|---|---|');
    for (final tag in TpoTags.all) {
      final targetRank = legacyFormalityRank[tag.formalityHint] ?? 0;
      for (final category in categories) {
        final items = wardrobe.where((i) => i.category == category && i.attributes != null);
        var zeroScoreCount = 0;
        var rescuedByNeutral = 0;
        var nullRankPassed = 0;
        for (final item in items) {
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
        print('| ${tag.label}(${tag.formalityHint}) | $category | $zeroScoreCount | '
            '$rescuedByNeutral | $nullRankPassed |');
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