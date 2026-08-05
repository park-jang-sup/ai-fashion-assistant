// 층별 discordant 모수 상한 리포트 — useEmbeddingRecovery를 켰을 때 current와
// 1번 후보가 갈리는 조합(discordant)이 몇 쌍까지 나올 수 있는지 실측한다.
// 7-b의 유의 수준과 검정 방식이 이 숫자 위에서 정해지므로, 이 리포트는
// **판정을 하지 않는다. 세기만 한다.** (a)/(b) 유형 분류 임계값은 코드에
// 박지 않는다 — Δ(그룹 내부 코사인 − 랜덤 베이스라인) 분포를 출력할 뿐이고,
// 분류 기준은 사람이 그 분포를 보고 정한다.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_fashion_assistant/constants/tpo_tags.dart';
import 'package:ai_fashion_assistant/models/recommendation_entry.dart';
import 'package:ai_fashion_assistant/models/wardrobe_item.dart';
import 'package:ai_fashion_assistant/services/agent_planner.dart';
import 'package:ai_fashion_assistant/services/embedding_service.dart';
import 'package:ai_fashion_assistant/services/outfit_matcher.dart';

import 'support/wardrobe_fixture.dart';

const _historyPath = 'tools/export_for_kaggle/output/history.json';
const _outfitCategories = ['상의', '하의', '아우터', '신발'];
const _randomSeed = 20260805;
const _baselineTrials = 100;

// findForTpo가 카테고리별 항목에 매기는 점수(outfit_matcher.dart:415-419)를
// 그대로 재현한다. gateNeutralBonus는 current/embeddingRecovery 둘 다 false라
// 여기서 고정한다 — 두 정책은 점수식이 아니라 정렬 키만 다르므로 "동점 그룹"
// 자체는 두 정책에 공통이다(작업 A에서 점수를 안 건드린다고 못박은 것과 같은
// 전제).
const _formalityRank = {'캐주얼': 0, '세미포멀': 1, '포멀': 2};
double _formalityFitScore(int targetRank, int itemRank) {
  final diff = (targetRank - itemRank).abs();
  return diff == 0 ? 3 : (diff == 1 ? 1 : 0);
}

double _itemScore(WardrobeItem item, int targetRank) {
  final attrs = item.attributes!;
  final rank = _formalityRank[attrs.formality];
  var score = rank == null ? 0.5 : _formalityFitScore(targetRank, rank);
  if (OutfitMatcher.isNeutralColor(attrs.color)) score += 1;
  return score;
}

double? _pairwiseAvgCosine(List<WardrobeItem> items) {
  final vectors = items.map((i) => i.embedding).whereType<List<double>>().toList();
  if (vectors.length < 2) return null;
  var sum = 0.0;
  var count = 0;
  for (var i = 0; i < vectors.length; i++) {
    for (var j = i + 1; j < vectors.length; j++) {
      final sim = EmbeddingService.cosineSimilarity(vectors[i], vectors[j]);
      if (sim != null) {
        sum += sim;
        count++;
      }
    }
  }
  return count == 0 ? null : sum / count;
}

// 같은 카테고리에서 같은 크기의 부분집합을 100회 무작위 추출해 pairwise 평균
// 코사인을 다시 평균한다. 시드를 고정하지 않으면 리포트가 실행마다 달라져
// 7-a의 수치(+0.13~+0.19 / -0.001)와 대조할 수 없다(사용자 지시).
double? _randomBaseline(List<WardrobeItem> population, int size, Random random) {
  if (size < 2 || population.length < size) return null;
  var total = 0.0;
  var validTrials = 0;
  for (var t = 0; t < _baselineTrials; t++) {
    final shuffled = [...population]..shuffle(random);
    final avg = _pairwiseAvgCosine(shuffled.sublist(0, size));
    if (avg != null) {
      total += avg;
      validTrials++;
    }
  }
  return validTrials == 0 ? null : total / validTrials;
}

void main() {
  // items.json/embeddings.json이 로컬에 없으면 스킵한다(CI에는 두 파일이
  // 없다) — tpo_policy_report_test.dart/embedding_service_test.dart와 같은
  // 패턴.
  final itemsFile = File(kFixtureItemsPath);
  final embeddingsFile = File(kFixtureEmbeddingsPath);
  if (!itemsFile.existsSync() || !embeddingsFile.existsSync()) {
    test('층별 discordant 모수 상한 리포트(로컬 데이터 없음 — 스킵)', () {},
        skip: 'items.json 또는 embeddings.json 없음');
    return;
  }

  test('층별 discordant 모수 상한 리포트', () {
    final loaded = loadWardrobeFixtureWithEmbeddings();
    final wardrobe = loaded.items;
    print(loaded.report.describe());
    print('');

    // ── C-2: recentItemIds 구성 ──────────────────────────────
    final wardrobeIds = {for (final w in wardrobe) w.id};

    final historyFile = File(_historyPath);
    List<Map<String, dynamic>> historyRaw = const [];
    if (historyFile.existsSync()) {
      historyRaw = (jsonDecode(historyFile.readAsStringSync()) as List)
          .cast<Map<String, dynamic>>();
    } else {
      print('[모수] $_historyPath 없음 — recentItemIds를 못 만든다. '
          '회수 축은 recentItemIds가 비면 작동하지 않으므로 discordant는 항상 0으로 나온다.');
    }

    // 계정 필터 — user 값을 추측해 고르지 않고, itemIds가 items.json id로
    // 하나 이상 해소되는지로 자기검증한다(사용자 지시). 다른 계정 레코드가
    // 섞이면 해소되지 않는 itemId가 recentItemIds를 조용히 부풀린다.
    final userCounts = <String, int>{};
    for (final r in historyRaw) {
      final u = r['user']?.toString() ?? '(없음)';
      userCounts[u] = (userCounts[u] ?? 0) + 1;
    }
    print('[모수] history.json user 필드 분포(${historyRaw.length}건):');
    for (final e in userCounts.entries) {
      print('  ${e.key}: ${e.value}건');
    }

    final qualifying = <Map<String, dynamic>>[];
    var excludedCount = 0;
    for (final r in historyRaw) {
      final ids = (r['itemIds'] as List).map((e) => e.toString());
      final resolvedCount = ids.where(wardrobeIds.contains).length;
      if (resolvedCount > 0) {
        qualifying.add(r);
      } else {
        excludedCount++;
      }
    }
    print('[모수] itemIds가 items.json id로 하나 이상 해소되는 레코드: '
        '${qualifying.length}/${historyRaw.length} (제외 $excludedCount건)');
    if (historyRaw.isNotEmpty) {
      print(excludedCount == 0
          ? '  → 제외 0건. user 필드값이 여럿이어도(${userCounts.keys.join(', ')}) '
              '표본 전체가 동일 계정(items.json 옷장)으로 보인다.'
          : '  → $excludedCount건이 다른 계정 것으로 보여 제외했다.');
    }
    print('');

    // RecommendationEntry로 변환해 AgentPlanner.recentItemIdsFrom(프로덕션
    // 로직, 14일 창 — agent_planner.dart의 _recencyWindow와 동일한 기본값)을
    // 그대로 재사용한다. 새로 구현하면 동형성이 깨질 수 있다(사용자 지시).
    final entries = qualifying.map((r) {
      return RecommendationEntry(
        id: r['recommendationId']?.toString() ?? '',
        itemIds: (r['itemIds'] as List).map((e) => e.toString()).toList(),
        itemSummaries:
            (r['itemSummaries'] as List? ?? const []).map((e) => e.toString()).toList(),
        summaryText: r['summaryText']?.toString() ?? '',
        triggerItemId: r['triggerItemId']?.toString() ?? '',
        createdAt: DateTime.parse(r['createdAt'] as String),
      );
    }).toList();

    Set<String> recentItemIds = const {};
    if (entries.isNotEmpty) {
      // 기준 시각 — DateTime.now()가 아니라 이력의 최신 레코드 시각으로
      // 고정한다. 안 그러면 리포트가 실행일마다 달라진다(사용자 지시).
      final referenceTime =
          entries.map((e) => e.createdAt).reduce((a, b) => a.isAfter(b) ? a : b);

      // 프로덕션 경로(firestore_service.dart:recentRecommendationsSilently)는
      // Firestore에서 createdAt 내림차순 상위 30건만 가져온 뒤
      // recentItemIdsFrom이 그 안에서 14일 창을 적용한다. 순서를 맞춘다.
      final sorted = [...entries]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final top30 = sorted.length > 30 ? sorted.sublist(0, 30) : sorted;

      recentItemIds = AgentPlanner.recentItemIdsFrom(top30, referenceTime);

      final within14Days = top30
          .where((e) => !e.createdAt
              .isBefore(referenceTime.subtract(const Duration(days: 14))))
          .length;

      print('[모수] 기준 시각(이력 최신 레코드): $referenceTime');
      print('[모수] 상위 30건 규칙: 전체 ${entries.length}건 중 ${top30.length}건 사용'
          '${entries.length <= 30 ? ' — 30건 미만이라 아무것도 안 잘림' : ''}');
      print('[모수] 14일 창: 위 ${top30.length}건 중 $within14Days건이 창 안'
          '${within14Days == top30.length ? ' — 이번 표본에서는 창이 아무것도 걸러내지 않는다' : ''}');
    }

    const coreCount = 87; // 상의+하의+아우터+신발(작업 A 보고 실측, items.json 기준)
    final recentInWardrobe = recentItemIds.where(wardrobeIds.contains).length;
    final ratio = recentInWardrobe / coreCount;
    print('[모수] recentItemIds 원본 크기(미해소 id 포함 가능): ${recentItemIds.length}, '
        '옷장에서 실제로 찾아지는 것: $recentInWardrobe / $coreCount '
        '(${(ratio * 100).toStringAsFixed(1)}%)');
    print('');

    // ── C-3: 동점 그룹 열거와 Δ 측정 ──────────────────────────
    final random = Random(_randomSeed);
    print('[Δ 분포] 랜덤 베이스라인 시드=$_randomSeed, 시행=$_baselineTrials회');
    print('| 태그 | 카테고리 | 그룹크기 | 벡터보유 | 그룹내평균코사인 | 랜덤베이스라인 | Δ |');
    print('|---|---|---|---|---|---|---|');

    final categoryPopulations = <String, List<WardrobeItem>>{
      for (final cat in _outfitCategories)
        cat: wardrobe.where((w) => w.category == cat && w.embedding != null).toList(),
    };

    // (tag,category) → 그룹 정보. C-5 삼분류에서 재사용한다.
    final groupInfo = <String, ({int size, int vectorCount, double? delta})>{};
    final deltas = <double>[];

    for (final tag in TpoTags.all) {
      final targetRank = _formalityRank[tag.formalityHint] ?? 0;
      for (final cat in _outfitCategories) {
        final items = wardrobe.where((w) => w.category == cat && w.attributes != null);
        final scored = items
            .map((w) => (item: w, score: _itemScore(w, targetRank)))
            .where((e) => e.score > 0)
            .toList();
        final key = '${tag.label}|$cat';
        if (scored.isEmpty) {
          groupInfo[key] = (size: 0, vectorCount: 0, delta: null);
          print('| ${tag.label} | $cat | 0 | 0 | — | — | — |');
          continue;
        }
        final maxScore = scored.map((e) => e.score).reduce(max);
        final group = scored.where((e) => e.score == maxScore).map((e) => e.item).toList();
        final vectorCount = group.where((i) => i.embedding != null).length;

        double? groupAvg;
        double? baseline;
        double? delta;
        if (group.length >= 2 && vectorCount >= 2) {
          groupAvg = _pairwiseAvgCosine(group);
          baseline = _randomBaseline(categoryPopulations[cat]!, group.length, random);
          if (groupAvg != null && baseline != null) {
            delta = groupAvg - baseline;
            deltas.add(delta);
          }
        }
        groupInfo[key] = (size: group.length, vectorCount: vectorCount, delta: delta);

        String fmt(double? v) => v == null ? '—' : v.toStringAsFixed(4);
        print('| ${tag.label} | $cat | ${group.length} | $vectorCount | '
            '${fmt(groupAvg)} | ${fmt(baseline)} | ${fmt(delta)} |');
      }
    }
    print('');

    if (deltas.isEmpty) {
      print('[Δ 분포] Δ를 계산할 수 있는 (태그,카테고리) 조합이 0개다 — '
          '이봉/단봉 판정 불가.');
    } else {
      final sortedDeltas = [...deltas]..sort();
      final meanDelta = deltas.reduce((a, b) => a + b) / deltas.length;
      print('[Δ 분포] n=${deltas.length}, 평균=${meanDelta.toStringAsFixed(4)}, '
          '정렬된 값: ${sortedDeltas.map((d) => d.toStringAsFixed(4)).join(', ')}');
      print('  → 이봉/단봉 여부는 위 정렬된 값을 사람이 직접 보고 판단한다 '
          '(임계값을 코드에 박지 않는다).');
    }
    print('');

    // ── C-4: discordant 열거 + C-5: "모수 0"의 삼분류 ──────────
    // TpoMatchPolicy.embeddingRecovery는 recencyPenalty가 기본값(0.4)이다.
    // 바꾸지 않는다 — 두 축이 recentItemIds를 공유해 함께 흔들면 교란이
    // 된다(§5 함정 26).
    // 두 리포트가 같은 findForTpo 호출 쌍(current/embeddingRecovery)을
    // 쓰므로 한 루프에서 함께 낸다 — 태그당 두 번(9태그×2=18회)이면
    // 충분한데 따로 돌리면 36회로 늘어난다.
    print('[discordant] 태그별 1번 후보 비교 (current vs embeddingRecovery)');
    print('| 태그 | discordant | 바뀐 카테고리 슬롯 |');
    print('|---|---|---|');

    String comboSig(OutfitMatch c) => (c.items.map((i) => i.id).toList()..sort()).join(',');

    var discordantCount = 0;
    // 태그×카테고리 삼분류는 discordant 루프 안에서 함께 채우고, 표는
    // discordant 표 출력 후 이어서 낸다(호출 결과를 저장해 재사용).
    final classificationRows = <(String tag, String cat, String classification)>[];
    final classificationCounts = <String, int>{
      '(1) 동점 없음': 0,
      '(2) 벡터 부족': 0,
      '(3a) 순서 불변': 0,
      '(3b) 순서 바뀜': 0,
    };

    for (final tag in TpoTags.all) {
      final resultCurrent = OutfitMatcher.findForTpo(
        wardrobe: wardrobe,
        formalityHint: tag.formalityHint,
        policy: TpoMatchPolicy.current,
        recentItemIds: recentItemIds,
      );
      final resultEmbedding = OutfitMatcher.findForTpo(
        wardrobe: wardrobe,
        formalityHint: tag.formalityHint,
        policy: TpoMatchPolicy.embeddingRecovery,
        recentItemIds: recentItemIds,
      );

      WardrobeItem? pick(TpoMatchResult r, String cat) {
        if (r.candidates.isEmpty) return null;
        final items = r.candidates.first.items.where((i) => i.category == cat);
        return items.isEmpty ? null : items.first;
      }

      // discordant 표
      if (resultCurrent.candidates.isEmpty || resultEmbedding.candidates.isEmpty) {
        print('| ${tag.label} | (후보 없음) | — |');
      } else {
        final isDiscordant =
            comboSig(resultCurrent.candidates.first) != comboSig(resultEmbedding.candidates.first);
        final changed = <String>[];
        for (final cat in _outfitCategories) {
          final curPick = pick(resultCurrent, cat);
          final embPick = pick(resultEmbedding, cat);
          if (curPick?.id != embPick?.id) {
            changed.add('$cat(${curPick?.id ?? '없음'}→${embPick?.id ?? '없음'})');
          }
        }
        if (isDiscordant) discordantCount++;
        print('| ${tag.label} | ${isDiscordant ? 'O' : '-'} | '
            '${changed.isEmpty ? '—' : changed.join(', ')} |');
      }

      // 삼분류(§C-5) — (3)은 순서 불변/바뀜 두 하위 라벨로 나눠 세지만
      // "그룹·벡터 다 있음"이라는 조건 자체는 하나다(사용자 지시 표의 셋째
      // 줄 그대로). (3a)만이 5.14.4의 "(가) 유형에서는 여전히 무의미하다"의
      // 정량 근거이고, (3b)는 그 자리에서 회수가 실제로 작동했다는 뜻이라
      // discordant 표와 대조해 읽는다.
      for (final cat in _outfitCategories) {
        final info = groupInfo['${tag.label}|$cat']!;
        String classification;
        if (info.size <= 1) {
          classification = '(1) 동점 없음';
        } else if (info.vectorCount <= 1) {
          classification = '(2) 벡터 부족';
        } else {
          final same = pick(resultCurrent, cat)?.id == pick(resultEmbedding, cat)?.id;
          classification = same ? '(3a) 순서 불변' : '(3b) 순서 바뀜';
        }
        classificationCounts[classification] = (classificationCounts[classification] ?? 0) + 1;
        classificationRows.add((tag.label, cat, classification));
      }
    }
    print('');
    print('[discordant] 총 discordant 수: $discordantCount / ${TpoTags.all.length}');
    print('');

    print('[삼분류] EmbeddingJoinReport.coverage='
        '${(loaded.report.coverage * 100).toStringAsFixed(1)}% '
        '(joined ${loaded.report.joined}/${loaded.report.itemCount})');
    print('| 태그 | 카테고리 | 분류 |');
    print('|---|---|---|');
    for (final row in classificationRows) {
      print('| ${row.$1} | ${row.$2} | ${row.$3} |');
    }
    print('');
    print('[삼분류] 요약: $classificationCounts');
    print('  → (3a)만이 5.14.4의 "(가) 유형에서는 여전히 무의미하다"의 정량 근거다.');

    expect(discordantCount, greaterThanOrEqualTo(0));
  });
}
