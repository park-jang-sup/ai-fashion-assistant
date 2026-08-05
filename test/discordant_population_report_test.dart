// 층별 discordant 모수 상한 리포트.
//
// discordant의 단위(2026-08-05 재정의) — **(태그, 카테고리) 동점 그룹 안에서
// current와 embeddingRecovery의 top-1 아이템이 다른 경우.** 처음엔 태그
// 단위(9종)로 세서 상한이 구조적으로 9였고, 9/9 포화가 나왔다 — 이는 회수
// 축이 항상 작동한다는 뜻이 아니라 모수가 좁아 포화된 것이었다. 라벨러에게
// 물을 질문도 "[태그] 상황에 이 두 [카테고리] 중 어느 쪽을 입겠는가"가 돼야
// 조합 전체(슬롯 4개 동시 변화)보다 교란이 없다.
//
// 7-b의 유의 수준과 검정 방식이 이 숫자 위에서 정해지므로, 이 리포트는
// **판정을 하지 않는다. 세기만 한다.** (a)/(b) 유형 분류의 Δ 임계값도 코드에
// 박지 않는다 — 여러 임계값에서 층별 수가 어떻게 변하는지 민감도 표로만
// 낸다(§A-2). 분류 기준은 사람이 그 표를 보고 정한다.
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

// Δ 분류 임계값 후보 — **판정이 아니라 민감도 확인용이며, 분류 기준은 아직
// 확정되지 않았다.** 여러 값에서 층별 그룹 수·discordant 수가 어떻게
// 변하는지만 보여준다(§A-2). 숫자가 임계값에 따라 크게 흔들리면 이봉이
// 겉보기보다 깨끗하지 않다는 뜻이고, 그 자체가 보고 대상이다.
const _sensitivityThresholds = [0.02, 0.05, 0.10];

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

// top-2 밖(절단선 아래)의 순서는 candidatesPerCategory=2가 조합 조립 이전에
// 잘라내 findForTpo의 공개 출력(candidates)에 아예 나타나지 않는다 — 관측할
// 방법이 구조적으로 없다. 이 함수는 outfit_matcher.dart의 compareCandidates
// (커밋 211bb94, 3블록 분리)를 동점 그룹 원소만 놓고 그대로 재현해 그 순서를
// 대신 계산한다.
//
// **이건 검증 전용 재구현이다 — 신뢰도는 아래 두 가지로 뒷받침한다:**
//  1. rank-1(orderCurrent/orderEmbedding의 첫 원소)이 findForTpo의 실제
//     출력(candidates.first, `pick()`)과 매번 일치하는지 호출부에서 대조한다.
//  2. rank-2도 findForTpo가 실제로 만드는 "차순위 교체 변형"(_rank2Pick,
//     공개 API 경로)과 대조한다.
// 이 두 지점이 맞으면 3번째 이후 순서(공개 API로는 검증 불가능한 부분)도
// 같은 비교자를 그대로 적용한 것이므로 신뢰할 근거가 된다. 하나라도
// 어긋나면 호출부가 경고를 찍는다 — 그 경고가 뜨면 이 함수의 결과를
// 신뢰하지 말 것.
List<WardrobeItem> _sortGroupExternally({
  required List<WardrobeItem> group,
  required Map<String, WardrobeItem> wardrobeById,
  required Set<String> recentItemIds,
  required bool useEmbeddingRecovery,
  required double recencyPenalty,
}) {
  // 그룹 원소는 전부 같은 raw score(그룹 정의 자체가 최고점 동점)이므로
  // rankScore 차이는 오직 recencyPenalty 여부에서만 난다 — 절대값은
  // 필요 없고 상대 순서만 맞으면 된다.
  double rankScoreOf(WardrobeItem item) =>
      recentItemIds.contains(item.id) ? -recencyPenalty : 0.0;

  final similarity = <String, double>{};
  if (useEmbeddingRecovery) {
    final referenceIds =
        recentItemIds.where((id) => wardrobeById[id]?.embedding != null).toList();
    if (referenceIds.isNotEmpty) {
      for (final item in group) {
        final vec = item.embedding;
        if (vec == null) continue;
        double? best;
        for (final refId in referenceIds) {
          if (refId == item.id) continue; // 자기 자신 제외 — outfit_matcher.dart와 동일
          final sim = EmbeddingService.cosineSimilarity(vec, wardrobeById[refId]!.embedding);
          if (sim != null && (best == null || sim > best)) best = sim;
        }
        if (best != null) similarity[item.id] = best;
      }
    }
  }

  final sorted = [...group]
    ..sort((a, b) {
      final byRank = rankScoreOf(b).compareTo(rankScoreOf(a));
      if (byRank != 0 || similarity.isEmpty) return byRank;
      int blockOf(WardrobeItem i) {
        if (i.embedding == null) return 2;
        return similarity.containsKey(i.id) ? 0 : 1;
      }

      final blockA = blockOf(a);
      final byBlock = blockA.compareTo(blockOf(b));
      if (byBlock != 0) return byBlock;
      if (blockA == 0) {
        final bySim = similarity[a.id]!.compareTo(similarity[b.id]!);
        if (bySim != 0) return bySim;
      }
      return a.id.compareTo(b.id);
    });
  return sorted;
}

// findForTpo가 실제로 만드는 "차순위 교체 변형" 조합에서 카테고리 cat의
// rank-2 아이템을 찾는다 — 재구현이 아니라 공개 API 출력을 그대로 읽는
// 것이라 rank-1과 같은 신뢰도를 가진다. maxCandidates를 크게 줘서 호출해야
// 변형이 잘리지 않는다.
WardrobeItem? _rank2Pick(TpoMatchResult result, String cat) {
  if (result.candidates.isEmpty) return null;
  final base = result.candidates.first;
  final baseByCat = {for (final i in base.items) i.category: i.id};
  for (final combo in result.candidates.skip(1)) {
    final comboByCat = {for (final i in combo.items) i.category: i.id};
    // 카테고리 구성 자체가 다르면(미니 조합 등) "그 카테고리만 바뀐 변형"이
    // 아니다 — 카테고리 집합이 완전히 같아야 순수 교체 변형으로 본다.
    if (comboByCat.keys.toSet().length != baseByCat.keys.toSet().length) continue;
    if (!comboByCat.keys.toSet().containsAll(baseByCat.keys)) continue;
    final diffCats = comboByCat.keys.where((c) => comboByCat[c] != baseByCat[c]).toList();
    if (diffCats.length == 1 && diffCats.first == cat) {
      return combo.items.firstWhere((i) => i.category == cat);
    }
  }
  return null;
}

bool _idsEqual(List<WardrobeItem> a, List<WardrobeItem> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].id != b[i].id) return false;
  }
  return true;
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
    final wardrobeById = {for (final w in wardrobe) w.id: w};

    // §A-4: Δ 값은 전부 아래 한 개의 Random(seed)을 (태그 × 카테고리) 루프
    // 전체에서 순차 소비해 낸다 — 조합마다 새 Random(seed)를 만들면 같은
    // 그룹 크기(예: 신발 22)에서 난수 시퀀스가 겹쳐 실질 시행 횟수가 준다.
    // 그 대가로 **모든 Δ 값이 이 루프의 순회 순서에 의존한다.** 지금은
    // TpoTags.all × _outfitCategories 순서가 고정이라 재현되지만, 태그가
    // 하나 추가되거나 순서가 바뀌면 그 뒤에 소비되는 모든 Δ 값이 조용히
    // 달라진다 — 데이터가 바뀐 것과 구분이 안 간다. 그래서 시드값과 실제
    // 순회 순서를 리포트 머리에 못박아 둔다(아래 출력).
    print('[재현성] 랜덤 시드=$_randomSeed');
    print('[재현성] 태그 순회 순서: ${TpoTags.all.map((t) => t.label).join(' → ')}');
    print('[재현성] 카테고리 순회 순서: ${_outfitCategories.join(' → ')}');
    print('');
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
    // 이 Random 하나를 (태그 × 카테고리) 루프 전체에서 순차 소비한다 — 조합
    // 마다 새 Random(seed)를 만들면 같은 그룹 크기(예: 신발 22)에서 난수
    // 시퀀스가 겹쳐 실질 시행 횟수가 준다(100회 시행이 진짜 100개의 서로
    // 다른 표본이 아니게 된다). 대신 그 결과로 **모든 Δ 값이 아래 루프의
    // 순회 순서(TpoTags.all → _outfitCategories)에 의존한다** — 태그가
    // 추가/재배열되면 그 이후에 소비되는 모든 Δ가 조용히 달라진다. 재현성
    // 확인은 리포트 머리(§A-4)의 시드·순회 순서 출력으로 한다.
    final random = Random(_randomSeed);
    print('[Δ 분포] 랜덤 베이스라인 시드=$_randomSeed, 시행=$_baselineTrials회');
    print('| 태그 | 카테고리 | 그룹크기 | 벡터보유 | 그룹내평균코사인 | 랜덤베이스라인 | Δ |');
    print('|---|---|---|---|---|---|---|');

    final categoryPopulations = <String, List<WardrobeItem>>{
      for (final cat in _outfitCategories)
        cat: wardrobe.where((w) => w.category == cat && w.embedding != null).toList(),
    };

    // (tag,category) → 그룹 정보. C-5 삼분류/§A-1 슬롯 분류에서 재사용한다.
    // items를 함께 들고 있어야 top-1/2/3+ 비교에 다시 스캔하지 않는다.
    final groupInfo =
        <String, ({int size, int vectorCount, double? delta, List<WardrobeItem> items})>{};
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
          groupInfo[key] = (size: 0, vectorCount: 0, delta: null, items: const []);
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
        groupInfo[key] =
            (size: group.length, vectorCount: vectorCount, delta: delta, items: group);

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

    // ── §A-1: discordant 재정의 + 삼분류 세분화 ────────────────
    // TpoMatchPolicy.embeddingRecovery는 recencyPenalty가 기본값(0.4)이다.
    // 바꾸지 않는다 — 두 축이 recentItemIds를 공유해 함께 흔들면 교란이
    // 된다(§5 함정 26). 두 정책이 이 값을 공유한다는 전제 자체를 아래서
    // 확인한다.
    final recencyPenalty = TpoMatchPolicy.current.recencyPenalty;
    assert(TpoMatchPolicy.embeddingRecovery.recencyPenalty == recencyPenalty);

    // discordant의 새 정의: 같은 (태그, 카테고리) 슬롯에서 current와
    // embeddingRecovery의 top-1 아이템이 다른 경우 — 라벨러에게 물을 단위
    // 그대로다("[태그] 상황에 이 두 [카테고리] 중 어느 쪽을 입겠는가").
    // 조합 전체(comboSig) 비교는 모수가 태그 9개라 상한이 9로 포화되므로
    // 더 이상 discordant로 쓰지 않는다 — 아래 "참고" 표로만 남긴다.
    String comboSig(OutfitMatch c) => (c.items.map((i) => i.id).toList()..sort()).join(',');
    WardrobeItem? pick(TpoMatchResult r, String cat) {
      if (r.candidates.isEmpty) return null;
      final items = r.candidates.first.items.where((i) => i.category == cat);
      return items.isEmpty ? null : items.first;
    }

    final legacyRows = <(String tag, bool discordant, String changed)>[];
    final classificationRows = <(String tag, String cat, String classification)>[];
    final classificationCounts = <String, int>{
      '(1) 동점 없음': 0,
      '(2) 벡터 부족': 0,
      '(3a) 순서 불변': 0,
      '(3b-1) top-1 다름': 0,
      '(3b-2) top-2 안에서만 다름': 0,
      '(3b-3) 절단선 아래에서만 다름': 0,
    };
    // A-3 라벨링 입력 — (3b-1) 건만 모은다.
    final labelingRows =
        <(String tag, String cat, String curId, String embId, int groupSize, double? delta)>[];
    var mismatchWarnings = 0;

    for (final tag in TpoTags.all) {
      // maxCandidates를 크게 줘야 _rank2Pick이 볼 변형(카테고리별 차순위
      // 교체 조합)이 기본값(3)에 잘려나가지 않는다. candidates.first(=top-1)
      // 는 maxCandidates와 무관하게 항상 같은 조합이라 §C-4의 기존 비교와
      // 결과가 달라지지 않는다.
      final resultCurrent = OutfitMatcher.findForTpo(
        wardrobe: wardrobe,
        formalityHint: tag.formalityHint,
        policy: TpoMatchPolicy.current,
        recentItemIds: recentItemIds,
        maxCandidates: 99,
      );
      final resultEmbedding = OutfitMatcher.findForTpo(
        wardrobe: wardrobe,
        formalityHint: tag.formalityHint,
        policy: TpoMatchPolicy.embeddingRecovery,
        recentItemIds: recentItemIds,
        maxCandidates: 99,
      );

      // [참고 — 구버전 지표] 태그 단위 전체 조합(1번 후보) 비교. 모수가
      // 태그 9개라 상한이 구조적으로 9다 — discordant로 안 쓴다(§A-0).
      if (resultCurrent.candidates.isEmpty || resultEmbedding.candidates.isEmpty) {
        legacyRows.add((tag.label, false, '(후보 없음)'));
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
        legacyRows.add((tag.label, isDiscordant, changed.isEmpty ? '—' : changed.join(', ')));
      }

      for (final cat in _outfitCategories) {
        final info = groupInfo['${tag.label}|$cat']!;
        String classification;
        if (info.size <= 1) {
          classification = '(1) 동점 없음';
        } else if (info.vectorCount <= 1) {
          classification = '(2) 벡터 부족';
        } else {
          final top1Cur = pick(resultCurrent, cat);
          final top1Emb = pick(resultEmbedding, cat);
          if (top1Cur?.id != top1Emb?.id) {
            classification = '(3b-1) top-1 다름';
            labelingRows.add((
              tag.label,
              cat,
              top1Cur?.id ?? '(없음)',
              top1Emb?.id ?? '(없음)',
              info.size,
              info.delta,
            ));
          } else {
            final rank2Cur = _rank2Pick(resultCurrent, cat);
            final rank2Emb = _rank2Pick(resultEmbedding, cat);
            if (rank2Cur?.id != rank2Emb?.id) {
              classification = '(3b-2) top-2 안에서만 다름';
            } else if (info.size >= 3) {
              // top-2까지 같다고 확인됐으니, 남은 차이가 있다면 절단선
              // 아래(3위 이후)뿐이다 — candidatesPerCategory=2가 조합
              // 조립 전에 잘라내는 자리라 공개 API로는 볼 수 없다.
              // _sortGroupExternally로 재구현해 대신 본다.
              final orderCur = _sortGroupExternally(
                group: info.items,
                wardrobeById: wardrobeById,
                recentItemIds: recentItemIds,
                useEmbeddingRecovery: false,
                recencyPenalty: recencyPenalty,
              );
              final orderEmb = _sortGroupExternally(
                group: info.items,
                wardrobeById: wardrobeById,
                recentItemIds: recentItemIds,
                useEmbeddingRecovery: true,
                recencyPenalty: recencyPenalty,
              );
              // 재구현 신뢰도 검증 — rank-1/rank-2는 공개 API로 이미
              // 확보했으니 대조한다. 어긋나면 재구현이 실제 비교자와
              // 다르다는 뜻이라 그 사실을 리포트에 남긴다(추측으로 넘기지
              // 않는다).
              if (orderCur.first.id != top1Cur?.id || orderEmb.first.id != top1Emb?.id) {
                mismatchWarnings++;
                print('[검증 경고] ${tag.label}/$cat: 재구현 rank-1이 공개 API와 어긋남 '
                    '(current: ${orderCur.first.id} vs ${top1Cur?.id}, '
                    'embedding: ${orderEmb.first.id} vs ${top1Emb?.id})');
              }
              if (orderCur[1].id != rank2Cur?.id || orderEmb[1].id != rank2Emb?.id) {
                mismatchWarnings++;
                print('[검증 경고] ${tag.label}/$cat: 재구현 rank-2가 공개 API와 어긋남 '
                    '(current: ${orderCur[1].id} vs ${rank2Cur?.id}, '
                    'embedding: ${orderEmb[1].id} vs ${rank2Emb?.id})');
              }
              final orderMatches = _idsEqual(orderCur, orderEmb);
              classification =
                  orderMatches ? '(3a) 순서 불변' : '(3b-3) 절단선 아래에서만 다름';
            } else {
              // 그룹 크기 2 — top-1·top-2가 곧 그룹 전체라 절단선 아래가
              // 존재하지 않는다. 재구현 없이 바로 (3a).
              classification = '(3a) 순서 불변';
            }
          }
        }
        classificationCounts[classification] = (classificationCounts[classification] ?? 0) + 1;
        classificationRows.add((tag.label, cat, classification));
      }
    }
    print('');

    // ── §A-2: Δ 임계값 민감도 표 ────────────────────────────
    // 임계값 자체는 판정이 아니다 — 여러 값에서 층별 수가 얼마나 흔들리는지
    // 만 보여준다. groupInfo의 delta와 classificationRows의 분류를
    // (태그,카테고리) 키로 조인해서 "이 임계값이면 (가)/(나) 각각 몇 그룹,
    // 그중 discordant(=3b-1)는 몇 건"을 센다.
    print('[민감도] Δ 임계값별 층 분류 — 판정 아님, 확인용');
    print('| 임계값 | (가)유형 그룹수 | (나)유형 그룹수 | (가) discordant | (나) discordant |');
    print('|---|---|---|---|---|');
    final classByKey = {
      for (final row in classificationRows) '${row.$1}|${row.$2}': row.$3,
    };
    for (final threshold in _sensitivityThresholds) {
      var groupA = 0, groupB = 0, discordantA = 0, discordantB = 0;
      for (final tag in TpoTags.all) {
        for (final cat in _outfitCategories) {
          final info = groupInfo['${tag.label}|$cat']!;
          if (info.delta == null) continue; // Δ 없음 = (1)/(2) — 층 분류 대상 아님
          final isDiscordant = classByKey['${tag.label}|$cat'] == '(3b-1) top-1 다름';
          if (info.delta! >= threshold) {
            groupA++;
            if (isDiscordant) discordantA++;
          } else {
            groupB++;
            if (isDiscordant) discordantB++;
          }
        }
      }
      print('| $threshold | $groupA | $groupB | $discordantA | $discordantB |');
    }
    print('');

    // ── [참고 — 구버전] 태그 단위 전체 조합 비교 ────────────────
    print('[참고, 구버전 지표] 태그별 전체 조합(1번 후보) 비교 — '
        '모수가 태그 9개라 상한이 9. discordant로 쓰지 않는다(§A-0).');
    print('| 태그 | 전체조합 불일치 | 바뀐 카테고리 슬롯 |');
    print('|---|---|---|');
    var legacyDiscordant = 0;
    for (final row in legacyRows) {
      if (row.$2) legacyDiscordant++;
      print('| ${row.$1} | ${row.$2 ? 'O' : '-'} | ${row.$3} |');
    }
    print('');
    print('[참고] 태그 단위 전체조합 불일치 수: $legacyDiscordant / ${TpoTags.all.length}');
    print('');

    // ── §A-1: 새 discordant 집계 ────────────────────────────
    final newDiscordant = classificationCounts['(3b-1) top-1 다름']!;
    final group3Total = classificationCounts['(3a) 순서 불변']! +
        classificationCounts['(3b-1) top-1 다름']! +
        classificationCounts['(3b-2) top-2 안에서만 다름']! +
        classificationCounts['(3b-3) 절단선 아래에서만 다름']!;
    print('[discordant] 새 정의(동점 그룹 슬롯당 top-1 비교) 기준: '
        '$newDiscordant / $group3Total (그룹·벡터 다 있는 슬롯)');
    print('');

    print('[분류] EmbeddingJoinReport.coverage='
        '${(loaded.report.coverage * 100).toStringAsFixed(1)}% '
        '(joined ${loaded.report.joined}/${loaded.report.itemCount})');
    print('| 태그 | 카테고리 | 분류 |');
    print('|---|---|---|');
    for (final row in classificationRows) {
      print('| ${row.$1} | ${row.$2} | ${row.$3} |');
    }
    print('');
    print('[분류] 요약: $classificationCounts');
    print('  → (3a)만이 5.14.4의 "(가) 유형에서는 여전히 무의미하다"의 정량 근거다.');
    print('  → 재구현(재검증) 불일치 경고: $mismatchWarnings건 '
        '(0이어야 (3b-3) 판정을 신뢰할 수 있다)');
    print('');

    // 일관성 확인 — (3b-1)은 §C-4의 옛 (3b) 계산과 동일한 top-1 비교라
    // 정의상 같은 값이 나와야 한다(리팩터가 옛 동작을 보존했는지 확인).
    // (3b-2)+(3b-3)은 옛 (3a)=9건 안에서 새로 찾아낸 것이라 옛 (3b)=21과
    // 합산 비교 대상이 아니다 — 옛 (3a)=9와 합산해야 한다.
    final oldA = 9;
    final oldB = 21;
    final newA = classificationCounts['(3a) 순서 불변']!;
    final b1 = classificationCounts['(3b-1) top-1 다름']!;
    final b2 = classificationCounts['(3b-2) top-2 안에서만 다름']!;
    final b3 = classificationCounts['(3b-3) 절단선 아래에서만 다름']!;
    print('[일관성] (3b-1)=$b1, 기존 (3b)=$oldB → ${b1 == oldB ? "일치" : "불일치(코드 확인 필요)"}');
    print('[일관성] (3a-새)+(3b-2)+(3b-3)=${newA + b2 + b3}, 기존 (3a)=$oldA → '
        '${newA + b2 + b3 == oldA ? "일치" : "불일치"}');
    if (b2 + b3 > 0) {
      print('  → 기존 "순서 불변"(top-1만 비교) $oldA건 중 $b2+$b3=${b2 + b3}건은 '
          'top-1은 같지만 top-2 이하에서 실제로 순서가 바뀐다. '
          '이 결과들은 (3a)의 "무의미하다" 근거에서 제외해야 한다.');
    } else {
      print('  → 기존 "순서 불변" $oldA건 전부가 top-2 이하까지도 완전히 동일하다 '
          '— (3a)가 5.14.4의 근거로 그대로 유효하다.');
    }
    print('');

    // ── §A-3: 라벨링 입력 표 ────────────────────────────────
    print('[라벨링 입력] (3b-1) top-1 다름 — 다음 단계(라벨링 도구)의 입력');
    print('| 태그 | 카테고리 | current top-1 (id) | recovery top-1 (id) | 그룹 크기 | 그룹 Δ |');
    print('|---|---|---|---|---|---|');
    for (final row in labelingRows) {
      final deltaText = row.$6 == null ? '—' : row.$6!.toStringAsFixed(4);
      print('| ${row.$1} | ${row.$2} | ${row.$3} | ${row.$4} | ${row.$5} | $deltaText |');
    }
    print('');
    print('[라벨링 입력] 총 ${labelingRows.length}건 (= discordant 수와 같아야 함: '
        '${labelingRows.length == newDiscordant ? "일치" : "불일치"})');

    expect(newDiscordant, greaterThanOrEqualTo(0));
  });
}
