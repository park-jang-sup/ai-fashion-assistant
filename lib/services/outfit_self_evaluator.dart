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
  // 진단-수리 루프가 실제로 한 번이라도 교체를 시도했는지, 무엇을 바꿨는지.
  final bool repairAttempted;
  final String? repairNote;

  const SelfEvalOutcome({
    required this.bestMatch,
    required this.bestText,
    required this.summaryText,
    required this.bestScore,
    required this.evaluatedCount,
    required this.candidateScores,
    this.repairAttempted = false,
    this.repairNote,
  });
}

// 한 후보를 평가한 직후 호출부에 알려주는 콜백(agent_logs 기록용).
// score가 null이면 점수 파싱 실패, wasError면 Gemini 호출 자체가 실패해 건너뛴 것.
typedef SelfEvalStep = void Function({
  required int index,
  required int total,
  int? score,
  required bool passed,
  required bool wasError,
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
    var evaluated = 0;
    final candidateScores = <int>[];
    var evalCount = 0;
    var repairAttempted = false;
    String? repairNote;

    Future<String?> evalOne(OutfitMatch combo) async {
      if (evalCount >= _maxEvalCount) return null;
      try {
        final text = await GeminiService.withTextModelFallback(
          (model) => GeminiService.analyzeOutfitFromAttributes(
            items: combo.items
                .map((it) => (category: it.category, attributes: it.attributes!))
                .toList(),
            recentHistoryText: recentHistoryText,
            isRelevanceRanked: isRelevanceRanked,
            model: model,
          ),
        );
        evalCount++;
        return text;
      } catch (e) {
        evalCount++; // 실패도 호출 자체는 소비했으므로 상한에 포함시킨다.
        debugPrint('[SELF-EVAL] Gemini 호출 실패: $e');
        return null;
      }
    }

    for (var i = 0; i < candidates.length; i++) {
      if (evalCount >= _maxEvalCount) break;
      final candidate = candidates[i];

      debugPrint('[SELF-EVAL] 후보 ${i + 1}/${candidates.length} 평가 중...');
      onNarrative?.call('후보 ${i + 1} 평가 중...');

      final analysisText = await evalOne(candidate);
      if (analysisText == null) {
        onStep?.call(index: i, total: candidates.length, score: null, passed: false, wasError: true);
        continue;
      }
      evaluated++;
      final score = parseScore(analysisText);
      candidateScores.add(score ?? 0);

      if (bestMatch == null || (score ?? -1) > (bestScore ?? -1)) {
        bestMatch = candidate;
        bestText = analysisText;
        bestScore = score;
      }
      final passed = score != null && score >= threshold;
      onStep?.call(
          index: i, total: candidates.length, score: score, passed: passed, wasError: false);

      if (passed) {
        debugPrint('[SELF-EVAL] 후보 ${i + 1}/${candidates.length} → 점수 $score (기준 통과, 채택)');
        break;
      }
      debugPrint('[SELF-EVAL] 후보 ${i + 1}/${candidates.length} → 점수 ${score ?? '(파싱 실패)'} '
          '(기준 미달${i < candidates.length - 1 ? ', 다음 후보로' : ''})');

      // ── 진단-수리 ── 총점이 기준 미달일 때, 다음 후보로 통째로 넘어가는
      // 대신 무엇이 문제인지 진단해 그 부분만 교체하고 한 번 더 평가한다.
      if (enableRepair && anchorItem != null && wardrobe != null && evalCount < _maxEvalCount) {
        final axes = _parseAxes(analysisText);
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
            final repairedText = await evalOne(repairedCombo);
            repairAttempted = true;

            if (repairedText == null) {
              onNarrative?.call('수리 재평가가 실패해 다음 후보로 넘어갑니다');
            } else {
              evaluated++;
              final repairedScore = parseScore(repairedText);
              candidateScores.add(repairedScore ?? 0);
              final repairedPassed = repairedScore != null && repairedScore >= threshold;

              onNarrative?.call(repairedPassed
                  ? '수리 후 $repairedScore점 — 이 조합을 추천으로 등록합니다'
                  : '수리 후에도 ${repairedScore ?? '점수 파싱 실패'}점으로 기준 미달입니다');
              debugPrint('[SELF-EVAL] 후보 ${i + 1} 수리 재평가 → '
                  '${repairedScore ?? '(파싱 실패)'} (${repairedPassed ? '기준 통과' : '기준 미달'})');

              repairNote = '${blamed.category} 교체(${_axisLabel(weakAxis)} 개선)';
              // 이 시점엔 bestMatch가 이미 원본 후보 평가에서 채워져 있다
              // (위에서 무조건 한 번 대입됨).
              if ((repairedScore ?? -1) > (bestScore ?? -1)) {
                bestMatch = repairedCombo;
                bestText = repairedText;
                bestScore = repairedScore;
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
      repairAttempted: repairAttempted,
      repairNote: repairNote,
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

  static String stripScoreLine(String analysisText) {
    var text = analysisText;
    for (final label in ['총점', '점수', '격식적합', '색상조화', '스타일통일', '개선점']) {
      text = text.replaceFirst(RegExp('\\[$label\\][^\\n]*\\n?'), '');
    }
    return text.trim();
  }
}
