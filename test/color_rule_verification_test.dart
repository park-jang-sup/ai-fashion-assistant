// 궁합 규칙 보강 전/후 검증 리포트.
// 항목 1(정규화 테이블)은 color_taxonomy_test.dart가 별도로 담당한다.
// 여기서는:
//   - 항목 4: findForTpo가 전/후 완전히 동일한지(회귀 안전성)
//   - 항목 2: 1번 후보 변화를 (a)버그수정만 / (b)새 규칙 으로 구분
//   - 항목 3: 색상 축 감점(-1) 비율, 팔레트(유채색3+) 감점 비율
// ignore_for_file: avoid_print — 진단 리포트가 목적이라 print가 곧 출력.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_fashion_assistant/models/wardrobe_item.dart';
import 'package:ai_fashion_assistant/services/color_taxonomy.dart';
import 'package:ai_fashion_assistant/services/outfit_matcher.dart';

import 'support/legacy_matcher.dart';
import 'support/wardrobe_fixture.dart';

String _sig(List<WardrobeItem> items) => (items.map((i) => i.id).toList()..sort()).join(',');

String _label(WardrobeItem i) => '${i.category}/${i.attributes?.color ?? '?'}(${i.id})';

void main() {
  // items.json은 tools/export_for_kaggle/output/ 산출물(.gitignore 대상, 실제
  // 사용자 옷장 데이터라 저장소에 커밋 안 됨) — 로컬에 없으면 이 파일 전체를
  // 스킵한다(CI/새 클론에서 실패하지 않도록).
  final itemsFile = File('tools/export_for_kaggle/output/items.json');
  if (!itemsFile.existsSync()) {
    test('궁합 규칙 검증(로컬 데이터 없음 — 스킵)', () {}, skip: 'tools/export_for_kaggle/output/items.json 없음');
    return;
  }

  final wardrobe = loadWardrobeFixture();
  final triggers = wardrobe
      .where((i) => i.attributes != null && legacyOutfitCategories.contains(i.category))
      .toList();

  test('항목4 — findForTpo 회귀 안전성(전/후 완전 동일)', () {
    final baselineFile = File('test/fixtures/tpo_baseline.json');
    if (!baselineFile.existsSync()) {
      markTestSkipped('베이스라인 fixture 없음(로컬 전용, 궁합 규칙 보강 작업 시 1회 캡처됨)');
      return;
    }
    final baseline = jsonDecode(baselineFile.readAsStringSync()) as Map;
    var identical = true;
    for (final tag in ['캐주얼', '세미포멀', '포멀']) {
      final r = OutfitMatcher.findForTpo(wardrobe: wardrobe, formalityHint: tag);
      final actual = {
        'isFallback': r.isFallback,
        'shortfall': r.shortfall,
        'candidates': r.candidates
            .map((c) => {
                  'ids': (c.items.map((i) => i.id).toList()..sort()),
                  'localScore': c.localScore,
                })
            .toList(),
      };
      final expected = baseline[tag];
      final same = const DeepCollectionEquality().equals(actual, expected);
      print('[항목4] TPO($tag) 전/후 동일: $same');
      if (!same) {
        identical = false;
        print('  BEFORE: ${jsonEncode(expected)}');
        print('  AFTER : ${jsonEncode(actual)}');
      }
    }
    expect(identical, true, reason: 'findForTpo 결과가 바뀌면 안 됨(이번엔 손대지 않은 경로)');
  });

  test('항목2 — 1번 후보 변화: 버그수정 효과 vs 새 규칙 효과 분리', () {
    var bugfixOnlyFlips = 0;
    var newRuleFlips = 0;
    var totalWithCandidates = 0;
    final bugfixFlipDetails = <String>[];
    final newRuleFlipDetails = <String>[];

    for (final trigger in triggers) {
      final oldCombos = legacyFindCandidateMatches(
        newItem: trigger,
        existingItems: wardrobe,
        scoreFn: (a, b) => legacyCompatibilityScore(a, b, legacyNeutralColorsOld),
      );
      final bugfixCombos = legacyFindCandidateMatches(
        newItem: trigger,
        existingItems: wardrobe,
        scoreFn: (a, b) => legacyCompatibilityScore(a, b, legacyNeutralColorsBugfixOnly),
      );
      final newCombos = OutfitMatcher.findCandidateMatches(
        newItem: trigger,
        existingItems: wardrobe,
      );

      if (oldCombos.isEmpty && bugfixCombos.isEmpty && newCombos.isEmpty) continue;
      totalWithCandidates++;

      final oldTop = oldCombos.isEmpty ? null : _sig(oldCombos.first.items);
      final bugfixTop = bugfixCombos.isEmpty ? null : _sig(bugfixCombos.first.items);
      final newTop = newCombos.isEmpty ? null : _sig(newCombos.first.items);

      if (oldTop != bugfixTop) {
        bugfixOnlyFlips++;
        bugfixFlipDetails.add(
          '  트리거 ${_label(trigger)}: OLD[${oldCombos.isEmpty ? '-' : oldCombos.first.items.map(_label).join('+')}] '
          '→ BUGFIX[${bugfixCombos.isEmpty ? '-' : bugfixCombos.first.items.map(_label).join('+')}]',
        );
      }
      if (bugfixTop != newTop) {
        newRuleFlips++;
        newRuleFlipDetails.add(
          '  트리거 ${_label(trigger)}: BUGFIX[${bugfixCombos.isEmpty ? '-' : bugfixCombos.first.items.map(_label).join('+')}] '
          '(${bugfixCombos.isEmpty ? '-' : bugfixCombos.first.localScore}) '
          '→ NEW[${newCombos.isEmpty ? '-' : newCombos.first.items.map(_label).join('+')}] '
          '(${newCombos.isEmpty ? '-' : newCombos.first.localScore})',
        );
      }
    }

    print('[항목2] 후보가 존재한 트리거 아이템: $totalWithCandidates / ${triggers.length}');
    print('[항목2-a] 버그수정(회색/차콜)만으로 1번 후보가 바뀐 건수: $bugfixOnlyFlips');
    for (final d in bugfixFlipDetails) {
      print(d);
    }
    print('[항목2-b] 새 색상 규칙(매트릭스/톤온톤/패턴완화/팔레트)으로 1번 후보가 바뀐 건수: $newRuleFlips');
    for (final d in newRuleFlipDetails) {
      print(d);
    }

    expect(totalWithCandidates, greaterThan(0));
  });

  test('항목3 — 색상 축 감점(-1) 비율 / 팔레트 감점 비율', () {
    var chromaticPairs = 0;
    var chromaticPenalized = 0;
    final scoreHistogram = <double, int>{};

    for (var i = 0; i < wardrobe.length; i++) {
      final a = wardrobe[i];
      if (a.attributes == null || !legacyOutfitCategories.contains(a.category)) continue;
      for (var j = i + 1; j < wardrobe.length; j++) {
        final b = wardrobe[j];
        if (b.attributes == null || !legacyOutfitCategories.contains(b.category)) continue;
        if (a.category == b.category) continue;

        final colorScore = OutfitMatcher.colorScoreOnly(a.attributes!, b.attributes!);
        scoreHistogram[colorScore] = (scoreHistogram[colorScore] ?? 0) + 1;

        final resolvedA = ColorTaxonomy.resolve(a.attributes!.color);
        final resolvedB = ColorTaxonomy.resolve(b.attributes!.color);
        if (!resolvedA.isNeutral && !resolvedB.isNeutral) {
          chromaticPairs++;
          if (colorScore == -1) chromaticPenalized++;
        }
      }
    }

    print('[항목3] 색상 점수 분포(전체 이종카테고리 쌍): $scoreHistogram');
    final pct = chromaticPairs == 0 ? 0.0 : chromaticPenalized / chromaticPairs * 100;
    print('[항목3] 유채색-유채색 쌍 중 감점(-1) 비율: '
        '$chromaticPenalized / $chromaticPairs (${pct.toStringAsFixed(1)}%)');
    if (pct >= 30) {
      print('[항목3][경고] 감점 비율이 30%를 넘음 — 규칙이 과할 수 있음, 매트릭스/깔맞춤 감점 완화 검토 필요');
    }

    // 팔레트(유채색 3개 초과) 감점이 실제로 얼마나 걸리는지.
    var comboCount = 0;
    var paletteHit = 0;
    for (final trigger in triggers) {
      final combos = OutfitMatcher.findCandidateMatches(newItem: trigger, existingItems: wardrobe);
      for (final combo in combos) {
        comboCount++;
        final chromaticCount = combo.items.where((it) {
          final attrs = it.attributes;
          return attrs != null && !ColorTaxonomy.resolve(attrs.color).isNeutral;
        }).length;
        if (chromaticCount > 3) paletteHit++;
      }
    }
    final palettePct = comboCount == 0 ? 0.0 : paletteHit / comboCount * 100;
    print('[항목3] 팔레트(유채색 3개 초과) 감점이 걸린 조합: '
        '$paletteHit / $comboCount (${palettePct.toStringAsFixed(1)}%)');

    expect(chromaticPairs, greaterThan(0));
  });
}

// package:collection 없이 얕은 재귀 비교(Map/List/기본형만 다루면 충분).
class DeepCollectionEquality {
  const DeepCollectionEquality();
  bool equals(dynamic a, dynamic b) {
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final k in a.keys) {
        if (!b.containsKey(k) || !equals(a[k], b[k])) return false;
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!equals(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }
}
