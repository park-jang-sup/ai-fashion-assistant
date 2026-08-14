import 'package:flutter/foundation.dart';
import '../models/wardrobe_item.dart';
import 'gemini_service.dart';
import 'outfit_matcher.dart';

// 자기 평가 루프의 결과 한 건 — 채택된 조합과 그 근거(점수/평가 서사).
class SelfEvalOutcome {
  final OutfitMatch bestMatch;
  final String bestText; // [총점] 등 메타 줄 포함 원문
  final String summaryText; // 메타 줄 제거한 본문
  final int? bestScore;
  final int evaluatedCount; // 실제로 Gemini 평가에 성공한 횟수(수리 재평가 포함)
  final List<int> candidateScores; // 평가 순서대로(탈락/수리 포함, 파싱 실패는 0)
  // docs/task_selfeval_validity_v1.md §4 작업1 — 총점과 나란히, 후보별로
  // 남긴다(승자만 남기면 총점-축 관계를 볼 표본이 이벤트당 1개로 준다).
  // candidateScores와 길이·순서가 항상 같다. 파싱 실패 규약은 총점과
  // 동일(0, §4 작업2).
  final List<int> candidateFormalityScores;
  final List<int> candidateColorHarmonyScores;
  final List<int> candidateStyleScores;
  // 어느 모델이 이 후보를 평가했는지(§4 작업3) — withTextModelFallback이
  // 타임아웃/재시도 가능 오류 시 조용히 대체 모델로 넘어가므로, 저장해
  // 두지 않으면 반복 측정이 서로 다른 모델의 분산을 섞게 된다.
  final List<String> candidateModels;
  // 진단-수리 루프가 실제로 한 번이라도 교체를 시도했는지, 무엇을 바꿨는지.
  final bool repairAttempted;
  final String? repairNote;
  // bestMatch가 신뢰 후보(judgeCandidate 기준) 없이, 판정 유보된 후보 중
  // 최댓값을 임시로 채택한 것인지(docs/task_selfeval_bestmatch_v1.md §0
  // 승인된 설계 — "할인이 아니라 제외", 신뢰 후보가 하나도 없을 때만 예외).
  // true면 호출부가 활동 로그·화면에 이 사실을 남길 수 있어야 한다.
  final bool bestMatchUntrusted;

  const SelfEvalOutcome({
    required this.bestMatch,
    required this.bestText,
    required this.summaryText,
    required this.bestScore,
    required this.evaluatedCount,
    required this.candidateScores,
    this.candidateFormalityScores = const [],
    this.candidateColorHarmonyScores = const [],
    this.candidateStyleScores = const [],
    this.candidateModels = const [],
    this.repairAttempted = false,
    this.repairNote,
    this.bestMatchUntrusted = false,
  });
}

// 한 후보를 평가한 직후 호출부에 알려주는 콜백(agent_logs 기록용).
// score가 null이면 점수 파싱 실패, wasError면 Gemini 호출 자체가 실패해 건너뛴 것.
// verdictWithheld가 true면 점수(score)는 있어도 판정(passed)에 반영되지
// 않은 상태다 — 폴백(주 모델이 아닌) 모델이 응답해 신뢰하지 않기로 한
// 경우(docs/task_selfeval_followup_v1.md 2단계). 이때 passed는 항상
// false이지만, 이 값이 "실제로 미달"이 아니라 "판정을 유보했다"는 뜻임을
// 호출부가 구분할 수 있어야 한다 — 그래서 별도 필드로 둔다.
typedef SelfEvalStep = void Function({
  required int index,
  required int total,
  int? score,
  required bool passed,
  required bool wasError,
  required bool verdictWithheld,
});

// 다축 평가 결과 — [격식적합]/[색상조화]/[스타일통일] 세 축. 셋 다 파싱된
// 경우에만 만들어지며(하나라도 실패하면 진단-수리를 시도하지 않는다),
// 가장 낮은 축을 "원인"으로 지목한다.
class _AxisScores {
  final int formality;
  final int color;
  final int style;

  const _AxisScores(this.formality, this.color, this.style);

  String get weakest {
    if (formality <= color && formality <= style) return 'formality';
    if (color <= style) return 'color';
    return 'style';
  }

  int valueOf(String axis) {
    switch (axis) {
      case 'formality':
        return formality;
      case 'color':
        return color;
      default:
        return style;
    }
  }
}

// 능동 추천(새 옷)과 선제 추천/주간 플랜(TPO)이 공유하는 "자기 평가 루프".
// 후보를 하나씩 Gemini로 평가하고, 기준점 이상이면 즉시 채택(조기 종료),
// 미달이면 다음 후보로, 전부 미달이면 최고점 조합을 채택한다. 호출 실패한
// 후보는 건너뛰고 다음 후보에게 기회를 준다.
//
// 진단-수리(enableRepair): 백그라운드 능동 추천 파이프라인에서만 켠다.
// 사용자가 버튼을 눌러 기다리는 동기 흐름(AI 코디 분석하기/주간 플랜)은
// 이 옵션을 켜지 않아 기존과 동일하게 1회 평가로 동작한다.
class OutfitSelfEvaluator {
  // 채택 기준점. 이 점수 이상이면 남은 후보를 평가하지 않고 바로 채택한다.
  // AgentPlanner._lowScoreFloor가 이 상수를 그대로 참조한다 — "궁합이 약해
  // 차선으로 내려간다"는 판단이 이 채택 기준과 다른 값으로 따로 놀면 안
  // 되기 때문에 별도로 하드코딩하지 않는다.
  static const threshold = 70;

  // Gemini 평가 호출 총 횟수 상한(수리 재평가 포함) — 실패한 호출도 소비한다.
  // 과부하 상황에서 재시도가 무한정 늘어나지 않게 막는 안전장치이기도 하다.
  static const _maxEvalCount = 3;

  // (passed, verdictWithheld) 판정을 함께 결정하는 순수 함수. Firestore·
  // Gemini 없이 단위 테스트가 직접 검증한다(이 저장소는 위젯·통합 테스트가
  // 0이라 판정 분기를 순수 함수로 뽑지 않으면 검증 수단이 없다).
  //
  // **화이트리스트로 판정한다** — 응답 모델이 주 모델
  // (GeminiService.primaryTextModel)과 같을 때만 점수를 신뢰하고 판정에
  // 쓴다. 폴백 모델(GeminiService.textModelFallback)과 같은지 비교하는
  // 블랙리스트 방식은 쓰지 않는다 — 나중에 세 번째 모델이 추가되거나
  // 폴백 상수가 바뀌면 그 응답이 조용히 "주 모델"로 취급되어 이 판정이
  // 조용히 무너진다. 모르는 모델의 점수는 신뢰하지 않는 쪽(fail-closed)이
  // 안전한 방향이다(docs/task_selfeval_followup_v1.md 2단계 조건 1).
  //
  // 보정 오프셋(폴백 응답의 점수에 상수를 더하거나 빼는 방식)은 쓰지
  // 않는다 — 조합 하나에서 관측된 평균차를 전역 상수로 박는 것은
  // task_selfeval_validity_v1이 내내 경계한 일반화이기 때문이다. 이
  // 함수는 점수를 보정하지 않고 그 점수를 판정에 쓸지 말지만 결정한다.
  //
  // score가 null(파싱 실패)인 경우는 이 화이트리스트와 무관하게 기존
  // 그대로 "판정 없음"으로 떨어진다(verdictWithheld는 false로 둔다 —
  // 이건 모델을 못 믿어서가 아니라 응답을 못 읽어서이므로 서로 다른
  // 원인을 같은 라벨로 뭉개지 않는다. 호출부는 score==null을 기존
  // 방식대로 "점수 파싱 실패"로 구분해 표시한다).
  // 공개(밑줄 없음) — 단위 테스트가 다른 파일(test/)에서 직접 호출해야
  // 하는데 Dart의 비공개는 파일 단위라 밑줄이 붙으면 테스트가 접근할
  // 수 없다.
  static ({bool passed, bool verdictWithheld}) judgeCandidate({
    required int? score,
    required String? respondingModel,
  }) {
    if (respondingModel != GeminiService.primaryTextModel) {
      return (passed: false, verdictWithheld: true);
    }
    return (passed: score != null && score >= threshold, verdictWithheld: false);
  }

  // bestMatch 갱신 판정 — "할인이 아니라 제외"(docs/task_selfeval_bestmatch_v1.md
  // §0, 사용자 승인 설계). 신뢰 후보(judgeCandidate 기준)가 있으면 신뢰
  // 후보끼리만 최댓값을 겨루고, 신뢰 후보가 하나도 없을 때만(현재 최선도
  // 미신뢰) 판정 불가 후보 중 최댓값을 임시로 채택한다. judgeCandidate와
  // 같은 이유로 순수 함수로 뽑는다 — 이 저장소는 위젯·통합 테스트가 0이라
  // run() 자체(Gemini 호출)는 직접 단위 테스트할 수 없다.
  static bool shouldReplaceBest({
    required bool hasCurrentBest,
    required bool currentBestTrusted,
    required int currentBestScore,
    required bool candidateTrusted,
    required int candidateScore,
  }) {
    if (!hasCurrentBest) return true;
    if (candidateTrusted && !currentBestTrusted) return true;
    if (candidateTrusted != currentBestTrusted) return false;
    return candidateScore > currentBestScore;
  }

  static Future<SelfEvalOutcome?> run(
    List<OutfitMatch> candidates, {
    SelfEvalStep? onStep,
    String? recentHistoryText, // 취향/피드백 컨텍스트(RAG) — 있으면 평가 프롬프트에 주입
    // recentHistoryText가 relevance 기반으로 뽑힌 것인지(vs 관련 신호 없어
    // 최신순 폴백) — 프롬프트 헤더 문구 선택에 그대로 전달된다.
    bool isRelevanceRanked = false,
    bool enableRepair = false,
    // enableRepair일 때만 사용 — 교체 대상에서 제외할 기준 아이템(새 옷)과
    // 교체 후보를 찾을 전체 옷장.
    WardrobeItem? anchorItem,
    List<WardrobeItem>? wardrobe,
    // enableRepair일 때만 호출되는 실시간 서사 콜백("후보 1 평가 중...",
    // 진단/수리 결과 등). onStep과 달리 자유 문장이며, 호출부가 활동
    // 로그(agent_logs) 기록과 홈 화면 인디케이터 갱신에 그대로 쓴다.
    void Function(String message)? onNarrative,
  }) async {
    OutfitMatch? bestMatch;
    String? bestText;
    int? bestScore;
    // bestMatch가 신뢰 후보(judgeCandidate 기준)로 채워졌는지 —
    // shouldReplaceBest가 이 값으로 "신뢰 후보 우선" 규칙을 적용한다.
    var bestIsTrusted = false;
    var evaluated = 0;
    final candidateScores = <int>[];
    // docs/task_selfeval_validity_v1.md §4 작업1 — candidateScores와 항상
    // 같은 길이·순서로 나란히 쌓는다. 파싱 실패 규약(0)도 공유한다(작업2).
    final candidateFormalityScores = <int>[];
    final candidateColorHarmonyScores = <int>[];
    final candidateStyleScores = <int>[];
    final candidateModels = <String>[];
    var evalCount = 0;
    var repairAttempted = false;
    String? repairNote;

    // §4 작업2: 파싱 실패는 인메모리 최선-후보 비교와 Firestore 저장
    // 양쪽 다 0으로 통일한다(예전엔 비교가 -1, 저장이 0으로 서로 달랐다).
    // 안전한 이유: parseScore가 실제 파싱값을 [1,100]으로 clamp하므로
    // 진짜 점수는 절대 0이 될 수 없다 — 0은 "파싱 실패"만을 가리키는
    // 값으로 항상 구분된다. 비교 결과도 동일하다(-1이든 0이든 진짜
    // 점수 최솟값 1보다 항상 작으므로 실패 후보가 채택을 뒤집는 일은
    // 없다) — 기존 저장 데이터에 0이 한 번도 없었음이 1단계 실측으로
    // 확인되었으므로(docs/task_selfeval_validity_v1.md §3), 이 통일이
    // 과거 데이터의 해석을 바꾸지 않는다.
    Future<({String? text, String? model})> evalOne(OutfitMatch combo) async {
      if (evalCount >= _maxEvalCount) return (text: null, model: null);
      String? usedModel;
      try {
        final text = await GeminiService.withTextModelFallback(
          (model) {
            usedModel = model;
            return GeminiService.analyzeOutfitFromAttributes(
              items: combo.items
                  .map((it) => (category: it.category, attributes: it.attributes!))
                  .toList(),
              recentHistoryText: recentHistoryText,
              isRelevanceRanked: isRelevanceRanked,
              model: model,
            );
          },
        );
        evalCount++;
        return (text: text, model: usedModel);
      } catch (e) {
        evalCount++; // 실패도 호출 자체는 소비했으므로 상한에 포함시킨다.
        debugPrint('[SELF-EVAL] Gemini 호출 실패: $e');
        return (text: null, model: usedModel);
      }
    }

    for (var i = 0; i < candidates.length; i++) {
      if (evalCount >= _maxEvalCount) break;
      final candidate = candidates[i];

      debugPrint('[SELF-EVAL] 후보 ${i + 1}/${candidates.length} 평가 중...');
      onNarrative?.call('후보 ${i + 1} 평가 중...');

      final evalResult = await evalOne(candidate);
      final analysisText = evalResult.text;
      if (analysisText == null) {
        onStep?.call(
            index: i,
            total: candidates.length,
            score: null,
            passed: false,
            wasError: true,
            verdictWithheld: false);
        continue;
      }
      evaluated++;
      final score = parseScore(analysisText);
      // 자기 평가 프롬프트(_buildAttributeAnalysisPrompt)는 항상 다축
      // 형식이므로 총점과 함께 매 후보마다 파싱한다 — 수리 분기 전용이
      // 아니다(승자만 남기면 총점-축 관계를 볼 표본이 이벤트당 1개로
      // 준다, §4 작업1).
      final axes = _parseAxes(analysisText);
      candidateScores.add(score ?? 0);
      candidateFormalityScores.add(axes?.formality ?? 0);
      candidateColorHarmonyScores.add(axes?.color ?? 0);
      candidateStyleScores.add(axes?.style ?? 0);
      candidateModels.add(evalResult.model ?? 'unknown');

      // judgeCandidate를 bestMatch 갱신보다 먼저 계산해 재사용한다 — 이
      // 시점에 이미 score·evalResult.model이 확정돼 있어(순수 함수라)
      // 호출 시점을 옮겨도 아래 passed/verdictWithheld 쓰임에는 영향이
      // 없다(docs/task_selfeval_bestmatch_v1.md 1단계(a)(b)).
      final judgment = judgeCandidate(score: score, respondingModel: evalResult.model);
      final candidateTrusted = !judgment.verdictWithheld;
      if (shouldReplaceBest(
        hasCurrentBest: bestMatch != null,
        currentBestTrusted: bestIsTrusted,
        currentBestScore: bestScore ?? 0,
        candidateTrusted: candidateTrusted,
        candidateScore: score ?? 0,
      )) {
        bestMatch = candidate;
        bestText = analysisText;
        bestScore = score;
        bestIsTrusted = candidateTrusted;
      }
      // 홈 카드 fallbackNote·colorScore 등 사용자에게 보이는 숫자는 위
      // bestScore 그대로 흘려보낸다(승인된 (i)안 — 점수는 감추지 않는다).
      // 여기서 갈리는 것은 "이 숫자를 자기 수리 발동·활동 로그 판정 라벨에
      // 쓸지"뿐이다.
      final passed = judgment.passed;
      onStep?.call(
          index: i,
          total: candidates.length,
          score: score,
          passed: passed,
          wasError: false,
          verdictWithheld: judgment.verdictWithheld);

      if (passed) {
        debugPrint('[SELF-EVAL] 후보 ${i + 1}/${candidates.length} → 점수 $score (기준 통과, 채택)');
        break;
      }
      if (judgment.verdictWithheld) {
        debugPrint('[SELF-EVAL] 후보 ${i + 1}/${candidates.length} → 점수 ${score ?? '(파싱 실패)'} '
            '(응답 모델 ${evalResult.model} — 주 모델이 아니라 판정 유보, 수리 미발동)');
      } else {
        debugPrint('[SELF-EVAL] 후보 ${i + 1}/${candidates.length} → 점수 ${score ?? '(파싱 실패)'} '
            '(기준 미달${i < candidates.length - 1 ? ', 다음 후보로' : ''})');
      }

      // ── 진단-수리 ── 총점이 기준 미달일 때, 다음 후보로 통째로 넘어가는
      // 대신 무엇이 문제인지 진단해 그 부분만 교체하고 한 번 더 평가한다.
      // verdictWithheld(폴백 응답)면 애초에 "미달"이 아니라 "판정 불가"이므로
      // 수리를 시도하지 않는다 — 부풀려졌을 수도, 낮게 나왔을 수도 있는
      // 신뢰 못 할 점수를 근거로 진단-교체를 도는 것 자체가 의미가 없다.
      if (!judgment.verdictWithheld &&
          enableRepair &&
          anchorItem != null &&
          wardrobe != null &&
          evalCount < _maxEvalCount) {
        if (axes == null) {
          debugPrint('[SELF-EVAL] 축 파싱 실패 — 수리 없이 다음 후보로(하위호환)');
        } else {
          final weakAxis = axes.weakest;
          final others = candidate.items.where((it) => it.id != anchorItem.id).toList();
          final blamed = _diagnoseBlame(weakAxis: weakAxis, anchorItem: anchorItem, others: others);
          final replacement = blamed == null
              ? null
              : OutfitMatcher.findReplacementFor(
                  category: blamed.category,
                  wardrobe: wardrobe,
                  referenceAttrs: anchorItem.attributes!,
                  excludeIds: candidate.items.map((it) => it.id).toSet(),
                );
          if (blamed == null || replacement == null) {
            debugPrint('[SELF-EVAL] 진단은 됐지만 교체할 차순위 후보가 없음 — 다음 후보로');
          } else {
            onNarrative?.call(
                '후보 ${i + 1}: 총점 $score — ${_axisLabel(weakAxis)} 점수 ${axes.valueOf(weakAxis)}가 원인으로 진단됐습니다');
            onNarrative?.call('${_withObjectParticle(blamed.category)} 교체해 다시 평가합니다');

            final repairedItems =
                candidate.items.map((it) => it.id == blamed.id ? replacement : it).toList();
            final repairedCombo = OutfitMatch(repairedItems, localScore: candidate.localScore);
            final repairResult = await evalOne(repairedCombo);
            final repairedText = repairResult.text;
            repairAttempted = true;

            if (repairedText == null) {
              onNarrative?.call('수리 재평가가 실패해 다음 후보로 넘어갑니다');
            } else {
              evaluated++;
              final repairedScore = parseScore(repairedText);
              final repairedAxes = _parseAxes(repairedText);
              candidateScores.add(repairedScore ?? 0);
              candidateFormalityScores.add(repairedAxes?.formality ?? 0);
              candidateColorHarmonyScores.add(repairedAxes?.color ?? 0);
              candidateStyleScores.add(repairedAxes?.style ?? 0);
              candidateModels.add(repairResult.model ?? 'unknown');
              // [발견, 2026-08-13, task_selfeval_followup_v1 2단계] 원래
              // 후보가 신뢰 모델·미달이라 수리가 시작됐더라도, 수리
              // 재평가 자체는 새 Gemini 호출이라 이번에도 폴백이 걸릴 수
              // 있다 — 지시서는 "수리가 안 걸리므로 이 경로는 안 나온다"고
              // 전제했지만 그건 수리 "시작" 게이팅에만 해당한다. 수리
              // "재평가 결과"에도 같은 화이트리스트를 적용하지 않으면
              // 원래 문제(신뢰 못 할 모델의 점수로 판정)가 형태만 바뀌어
              // 재발한다 — 그래서 여기도 judgeCandidate를 그대로 적용한다.
              final repairedJudgment =
                  judgeCandidate(score: repairedScore, respondingModel: repairResult.model);
              final repairedPassed = repairedJudgment.passed;
              final repairedTrusted = !repairedJudgment.verdictWithheld;

              if (repairedJudgment.verdictWithheld) {
                onNarrative?.call(
                    '수리 후 ${repairedScore ?? '점수 파싱 실패'}점 — 대체 모델이 응답해 판정을 보류합니다');
                debugPrint('[SELF-EVAL] 후보 ${i + 1} 수리 재평가 → '
                    '${repairedScore ?? '(파싱 실패)'} (응답 모델 ${repairResult.model} — 판정 유보)');
              } else {
                onNarrative?.call(repairedPassed
                    ? '수리 후 $repairedScore점 — 이 조합을 추천으로 등록합니다'
                    : '수리 후에도 ${repairedScore ?? '점수 파싱 실패'}점으로 기준 미달입니다');
                debugPrint('[SELF-EVAL] 후보 ${i + 1} 수리 재평가 → '
                    '${repairedScore ?? '(파싱 실패)'} (${repairedPassed ? '기준 통과' : '기준 미달'})');
              }

              // [주의, docs/task_selfeval_bestmatch_v1.md 2단계(d)] repairNote는
              // 신뢰 여부와 무관하게 여기서 그대로 설정된다 — 판정 유보된
              // 수리 결과에도 확정적 문구가 붙는 문제는 별도 결함으로
              // 등록만 하고 이번엔 손대지 않는다(사용자 지시, 범위 밖).
              repairNote = '${blamed.category} 교체(${_axisLabel(weakAxis)} 개선)';
              // 이 시점엔 bestMatch가 이미 원본 후보 평가에서 채워져 있다
              // (위에서 무조건 한 번 대입됨) — bestIsTrusted도 그때 함께
              // 갱신됐으므로 여기서도 같은 shouldReplaceBest 규칙을 적용한다.
              if (shouldReplaceBest(
                hasCurrentBest: bestMatch != null,
                currentBestTrusted: bestIsTrusted,
                currentBestScore: bestScore ?? 0,
                candidateTrusted: repairedTrusted,
                candidateScore: repairedScore ?? 0,
              )) {
                bestMatch = repairedCombo;
                bestText = repairedText;
                bestScore = repairedScore;
                bestIsTrusted = repairedTrusted;
              }
              if (repairedPassed) break;
            }
          }
        }
      }
    }

    if (bestMatch == null || bestText == null) return null;
    debugPrint('[SELF-EVAL] 완료: $evaluated개 평가(점수 ${candidateScores.join(', ')}), '
        '최고 ${bestScore ?? '(점수 없음)'} 채택${repairAttempted ? ' (수리 시도됨)' : ''}');
    return SelfEvalOutcome(
      bestMatch: bestMatch,
      bestText: bestText,
      summaryText: stripScoreLine(bestText),
      bestScore: bestScore,
      evaluatedCount: evaluated,
      candidateScores: candidateScores,
      candidateFormalityScores: candidateFormalityScores,
      candidateColorHarmonyScores: candidateColorHarmonyScores,
      candidateStyleScores: candidateStyleScores,
      candidateModels: candidateModels,
      repairAttempted: repairAttempted,
      repairNote: repairNote,
      bestMatchUntrusted: !bestIsTrusted,
    );
  }

  // 축 진단 → 교체할 아이템을 고른다. anchorItem(새 옷)은 교체 대상에서 제외.
  // 교체할 근거가 마땅치 않으면(다른 아이템이 없거나, 스타일 축인데 전부
  // anchorItem과 같은 스타일이면) null.
  static WardrobeItem? _diagnoseBlame({
    required String weakAxis,
    required WardrobeItem anchorItem,
    required List<WardrobeItem> others,
  }) {
    if (others.isEmpty) return null;
    switch (weakAxis) {
      case 'formality':
        final anchorRank = OutfitMatcher.formalityRankOf(anchorItem.attributes!.formality);
        final sorted = List<WardrobeItem>.from(others)
          ..sort((a, b) {
            final da = (OutfitMatcher.formalityRankOf(a.attributes!.formality) - anchorRank).abs();
            final db = (OutfitMatcher.formalityRankOf(b.attributes!.formality) - anchorRank).abs();
            return db.compareTo(da);
          });
        return sorted.first;
      case 'color':
        final sorted = List<WardrobeItem>.from(others)
          ..sort((a, b) =>
              OutfitMatcher.compatibilityScore(anchorItem.attributes!, a.attributes!)
                  .compareTo(OutfitMatcher.compatibilityScore(anchorItem.attributes!, b.attributes!)));
        return sorted.first;
      case 'style':
        final diffStyle =
            others.where((o) => o.attributes!.style != anchorItem.attributes!.style);
        return diffStyle.isNotEmpty ? diffStyle.first : null;
      default:
        return null;
    }
  }

  // 한글 명사 뒤 목적격 조사(을/를) 선택 — 마지막 음절에 받침이 있으면 "을".
  // "하의를"/"신발을"처럼 카테고리명이 상황마다 달라지는 로그 문장에 쓴다.
  static String _withObjectParticle(String word) {
    if (word.isEmpty) return word;
    final code = word.codeUnitAt(word.length - 1);
    const hangulBase = 0xAC00; // '가'
    const hangulLast = 0xD7A3; // '힣'
    if (code < hangulBase || code > hangulLast) return '$word을'; // 한글 완성형이 아니면 안전하게 "을"
    final hasBatchim = (code - hangulBase) % 28 != 0;
    return hasBatchim ? '$word을' : '$word를';
  }

  static String _axisLabel(String axis) {
    switch (axis) {
      case 'formality':
        return '격식';
      case 'color':
        return '색상';
      default:
        return '스타일';
    }
  }

  // 총점 파싱 — [총점] 우선, 없으면 하위호환으로 [점수].
  static int? parseScore(String analysisText) {
    final match = RegExp(r'\[총점\]\s*(\d+)').firstMatch(analysisText) ??
        RegExp(r'\[점수\]\s*(\d+)').firstMatch(analysisText);
    if (match == null) return null;
    final score = int.tryParse(match.group(1) ?? '');
    return score?.clamp(1, 100);
  }

  static int? _parseAxisScore(String analysisText, String label) {
    final match = RegExp('\\[$label\\]\\s*(\\d+)').firstMatch(analysisText);
    if (match == null) return null;
    return int.tryParse(match.group(1) ?? '')?.clamp(1, 100);
  }

  // 셋 다 파싱돼야만 진단-수리를 시도한다(하나라도 실패하면 null — 기존
  // 방식대로 다음 후보로 넘어간다).
  static _AxisScores? _parseAxes(String analysisText) {
    final formality = _parseAxisScore(analysisText, '격식적합');
    final color = _parseAxisScore(analysisText, '색상조화');
    final style = _parseAxisScore(analysisText, '스타일통일');
    if (formality == null || color == null || style == null) return null;
    return _AxisScores(formality, color, style);
  }

  // docs/task_selfeval_validity_v1.md §4 작업4 — 그대로 둔다. 사용자에게
  // 보이는 텍스트에서 점수 메타 줄을 지우는 것은 의도된 동작이고, 축
  // 점수는 이제 이 함수가 지우기 전에 이미 구조화된 필드(candidate*
  // Scores)로 따로 남으므로 원문을 보존할 필요가 없다.
  static String stripScoreLine(String analysisText) {
    var text = analysisText;
    for (final label in ['총점', '점수', '격식적합', '색상조화', '스타일통일', '개선점']) {
      text = text.replaceFirst(RegExp('\\[$label\\][^\\n]*\\n?'), '');
    }
    return text.trim();
  }
}
