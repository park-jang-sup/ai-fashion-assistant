import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../constants/tpo_tags.dart';
import '../models/agent_log_entry.dart';
import '../models/clothing_attributes.dart';
import '../models/outfit_calendar_entry.dart';
import '../models/recommendation_entry.dart';
import '../models/wardrobe_item.dart';
import 'agent_activity.dart';
import 'agent_stats.dart';
import 'firestore_service.dart';
import 'gemini_service.dart';
import 'outfit_matcher.dart';
import 'outfit_self_evaluator.dart';
import 'weather_service.dart';

// 주간 플랜 한 날의 결과 — Gemini가 배정한 조합을 UI 카드로 보여주기 위한 것.
// Firestore에 바로 저장하지 않고, 사용자가 "이 코디로 확정"을 누른 날만 저장된다.
class WeeklyPlanDay {
  final DateTime date;
  final String tpoTag;
  final List<WardrobeItem> items;
  final String reason;

  const WeeklyPlanDay({
    required this.date,
    required this.tpoTag,
    required this.items,
    required this.reason,
  });
}

// 캘린더를 "관찰 대상"으로 삼는 에이전트 로직.
//  · 레벨 1(선제 추천): 다가오는 예정 태그를 감지해 미리 추천을 준비한다.
//  · 레벨 2(주간 계획): 일주일 일정을 제약과 함께 한 번에 계획한다.
class AgentPlanner {
  static const _proactiveHorizonDays = 3; // 오늘~+3일 예정을 선제 추천 대상으로
  static const _weeklyHorizonDays = 7;
  // 일정이 여러 건이면 각 건의 자기 평가 루프가 연달아 Gemini를 부르게 되므로,
  // 앱 실행 직후 호출이 한꺼번에 몰리지 않도록 건 사이에 텀을 둔다
  // (AgentSweeper의 태스크 간 딜레이와 동일한 취지).
  static const _planStepDelay = Duration(seconds: 3);

  static DateTime _todayMidnight() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  // ── 레벨 1: 선제 추천 트리거 (홈 진입 시 1회 / 백그라운드 주기 실행) ──
  // 오늘~+3일의 'planned' 예정 중 아직 추천이 없는 날에 대해, TPO 격식에 맞는
  // 조합을 자기 평가 루프로 골라 미리 추천으로 저장한다. 부가 기능이라 어느
  // 단계에서 실패하든 조용히 무시한다.
  //
  // 반환값(C단계 — 백그라운드 알림 문구용): created는 이번 실행에서 새로
  // 저장된 추천 건수, firstLabel은 그중 첫 번째 추천의 표시용 라벨(예:
  // "내일 [결혼식]")이다. 실패/스킵 시 (created: 0, firstLabel: null).
  // 앱 내 기존 호출부(main.dart)는 이 반환값을 쓰지 않으므로 영향이 없다.
  //
  // maxPlans는 백그라운드 실행 시간 상한(WorkManager ~10분) 때문에 도입한
  // 처리량 제한이다. null이면 현행과 동일하게 제한이 없다 — 앱 내 호출은
  // 인자를 넘기지 않으므로 동작이 바뀌지 않는다. planned는 이미 date
  // 오름차순으로 조회되므로(calendarEntriesForRange의 orderBy('date')),
  // take(maxPlans)는 자연히 "가장 가까운 일정부터" N건을 고른다.
  static Future<({int created, String? firstLabel})> runProactiveCheck(
    String uid, {
    int? maxPlans,
  }) async {
    var created = 0;
    String? firstLabel;
    try {
      final today = _todayMidnight();
      final horizon = today.add(const Duration(days: _proactiveHorizonDays));
      final entries = await FirestoreService.calendarEntriesForRange(uid, today, horizon);
      // isPlanned==false(이미 착장을 기록/확정한 날)는 여기서 이미 제외되므로
      // "기록된 날은 재계획하지 않는다"는 별도 체크가 필요 없다.
      var planned = entries.where((e) => e.isPlanned).toList();
      if (maxPlans != null) {
        planned = planned.take(maxPlans).toList();
      }
      if (planned.isEmpty) return (created: 0, firstLabel: null);
      debugPrint('[PLAN] 선제 추천 체크: 다가오는 예정 ${planned.length}건');

      final wardrobe = await FirestoreService.wardrobeStream(uid).first;
      final usable = wardrobe.where((i) => i.attributes != null).toList();
      if (usable.length < 2) return (created: 0, firstLabel: null);

      final weather = await WeatherService.fetch();

      for (var i = 0; i < planned.length; i++) {
        final plan = planned[i];
        var replanCount = 0;
        var previousItemIds = const <String>[];

        // 이미 이 날짜용 추천이 있으면, 예보가 유의미하게 바뀌었을 때만
        // 무효화(dismiss)해서 재계획 게이트를 통과시킨다 — 그 외엔 기존과
        // 동일하게 스킵(중복 방지). 새 파이프라인이 아니라 이 게이트 하나만
        // 갈아끼워 아래 _prepareRecommendationFor(자기 평가 루프·3회 캡·
        // fallbackNote 배지)를 그대로 재사용한다.
        final existing = await FirestoreService.recommendationForDateSilently(uid, plan.date);
        if (existing != null) {
          // userChoice가 이미 붙은 추천은 재계획 대상에서 제외한다. 이
          // 날짜 자체가 기록된 경우는 isPlanned가 꺼져 위에서 이미
          // 걸러지지만, detectFeedbackForCalendarEntry는 ±3일 범위에서
          // "가장 가까운" 추천에 userChoice를 붙이므로 아직 planned인
          // 다른 날짜의 추천에도 반응이 먼저 기록될 수 있다 — 이미
          // 사용자가 반응한 신호를 예보 변화로 지워버리면 안 된다.
          if (existing.userChoice != null) {
            debugPrint('[PLAN] ${_dateLabel(plan.date)} 추천에 이미 사용자 반응'
                '(${existing.userChoice})이 있어 재계획 대상에서 제외 — 스킵');
            continue;
          }
          final decision = shouldReplanForWeather(
            snapshotPrecipProbability: existing.forecastPrecipProbability,
            snapshotMaxTempC: existing.forecastMaxTempC,
            currentForecast: weather?.forDate(plan.date),
          );
          if (!decision.replan) {
            debugPrint('[PLAN] ${_dateLabel(plan.date)} 추천 이미 존재 — 스킵');
            continue;
          }
          if (existing.replanCount >= _maxReplanPerDate) {
            debugPrint('[PLAN] ${_dateLabel(plan.date)} 예보 변화 감지(${decision.reason})했지만 '
                '재계획 상한($_maxReplanPerDate회) 도달 — 스킵');
            continue;
          }
          await FirestoreService.dismissRecommendation(uid, existing.id);
          replanCount = existing.replanCount + 1;
          previousItemIds = existing.itemIds;
          unawaited(FirestoreService.addAgentLogSilently(
            uid,
            AgentLogEntry(
              id: '',
              eventType: AgentLogEntry.typeWeatherChecked,
              message: '${_relativeLabel(plan.date)} [${plan.tpoTag}] ${decision.reason} — '
                  '코디를 다시 준비합니다',
              relatedDocId: plan.id,
            ),
          ));
        }

        final madeRecommendation = await _prepareRecommendationFor(
            uid, plan, usable,
            replanCount: replanCount, previousItemIds: previousItemIds);
        if (madeRecommendation) {
          created++;
          firstLabel ??= '${_relativeLabel(plan.date)} [${plan.tpoTag}]';
        }
        if (i < planned.length - 1) {
          await Future.delayed(_planStepDelay);
        }
      }
      return (created: created, firstLabel: firstLabel);
    } catch (e) {
      debugPrint('[PLAN] 선제 추천 체크 예외로 중단: $e');
      return (created: 0, firstLabel: null);
    }
  }

  // Gemini 색상 점수가 이 값 미만이면 "격식은 됐어도 조합 자체가 약한" 것으로
  // 보고 차선(fallback) 문구를 쓴다(레벨 4의 "전부 낮은 점수" 케이스).
  // OutfitSelfEvaluator.threshold(자기 평가 채택 기준)를 그대로 참조한다 —
  // 실측(Firestore candidateScores)상 관측 최저값이 65였는데 예전 값(60)은
  // 도달 불가능한 기준이라 isFallback이 이 경로로는 한 번도 켜지지 않았다.
  // 별도 숫자로 하드코딩하면 threshold가 바뀔 때 이 기준만 조용히 벌어질
  // 수 있어, 값 자체를 공유한다.
  static const _lowScoreFloor = OutfitSelfEvaluator.threshold;

  // 조합 선정 정책. 기본값은 현행(current)이며, 표8~표14 리포트를 근거로
  // 프리셋을 바꾸는 것이 곧 배포 결정이다 — 여기 한 줄만 고치면 된다.
  static const _matchPolicy = TpoMatchPolicy.current;

  // 최근 감점 대상으로 볼 기간. 짧으면 회전이 안 돌고, 길면 옷장 대부분이
  // 감점 대상이 되어 감점이 다시 상수가 된다(색상 축이 무효였던 것과 같은
  // 실패 방식). 옷장 규모에 맞춰 조정할 손잡이다.
  static const _recencyWindow = Duration(days: 14);

  // isFallback 원인(카테고리 부족 vs 궁합 점수 낮음)에 따라 다른 문구를
  // 고른다. 순수 함수라 Firestore/Gemini 없이 단위 테스트 가능하다.
  // mismatchedCategories가 비어 있으면(드문 경우 — findForTpo의 hasCore
  // 제약상 이론상 거의 없음) 억지 문구 대신 null을 반환해 배지 자체를
  // 띄우지 않는다.
  // tpoTag가 null이면(새 옷 등록 경로 — findCandidateMatches는 TPO 개념이
  // 없어 항상 null로 넘어온다) "[태그]" 구간을 붙이지 않는다. 이 경로에서는
  // dateLabel도 상대 날짜가 아니라 트리거 아이템 설명("블랙 상의")으로
  // 채워져 문구가 자연스럽게 이어진다.
  static String? buildFallbackNote({
    required bool matchIsFallback,
    required List<String> mismatchedCategories,
    required int? bestScore,
    required String dateLabel,
    required String? tpoTag,
  }) {
    final tagSuffix = tpoTag != null ? ' [$tpoTag]' : '';
    if (matchIsFallback) {
      if (mismatchedCategories.isEmpty) return null;
      final categories = _withSubjectParticle(mismatchedCategories.join('·'));
      final scoreText = bestScore != null ? '$bestScore점' : '차선';
      return '$dateLabel$tagSuffix에 맞는 $categories 부족해 $scoreText 조합으로 준비했어요';
    }
    if (bestScore != null && bestScore < _lowScoreFloor) {
      return '$dateLabel$tagSuffix 조합 궁합 점수가 낮아($bestScore점) 차선으로 준비했어요';
    }
    return null;
  }

  // 한글 명사 뒤 주격 조사(이/가) 선택 — 마지막 음절에 받침이 있으면 "이".
  // outfit_self_evaluator.dart의 _withObjectParticle(을/를)과 같은 방식이며,
  // "신발"처럼 받침 있는 카테고리명 뒤에 "가"를 잘못 붙이지 않기 위해 둔다.
  // buildFallbackNote/buildOptionalNote 둘 다 카테고리 목록을 문구에 넣을 때
  // 이 헬퍼를 거친다 — 전엔 buildFallbackNote가 "가"를 고정 하드코딩해서
  // "신발가"처럼 틀린 문구가 나올 수 있었다(예: mismatchedCategories가
  // ['신발']뿐인 경우).
  static String _withSubjectParticle(String word) {
    if (word.isEmpty) return word;
    final code = word.codeUnitAt(word.length - 1);
    const hangulBase = 0xAC00; // '가'
    const hangulLast = 0xD7A3; // '힣'
    if (code < hangulBase || code > hangulLast) return '$word가'; // 한글 완성형이 아니면 안전하게 "가"
    final hasBatchim = (code - hangulBase) % 28 != 0;
    return hasBatchim ? '$word이' : '$word가';
  }

  // buildFallbackNote와 별개 함수 — 성격이 다르다. fallbackNote는 "조합
  // 전체가 격식에 안 맞거나 점수가 낮아 차선으로 내려갔다"는 판단이고,
  // 이건 "조합 자체는 성립했지만 그중 특정(선택) 카테고리 하나만 격식에
  // 맞는 게 없어 차선 아이템으로 채웠다"는 판단이다(OutfitMatcher.
  // optionalMissing — isFallback과 무관하게 채워질 수 있음). 순수 함수라
  // Firestore/Gemini 없이 단위 테스트 가능하다.
  // tpoTag가 null이면(새 옷 등록 경로는 이 함수를 호출하지 않지만, 함수
  // 자체는 buildFallbackNote와 동일하게 nullable을 지원해둔다) "~에 어울리는"
  // 대신 "어울리는"으로 문구를 이어붙인다.
  static String? buildOptionalNote({
    required List<String> optionalMissing,
    required String? tpoTag,
  }) {
    if (optionalMissing.isEmpty) return null;
    final categories = _withSubjectParticle(optionalMissing.join('·'));
    final tagPrefix = tpoTag != null ? '$tpoTag에 어울리는 ' : '어울리는 ';
    return '$tagPrefix$categories 옷장에 없어 가장 가까운 것으로 맞췄어요';
  }

  // 같은 날짜가 예보 변화로 재계획되는 최대 횟수. 초과하면 예보가 계속
  // 바뀌어도 더 이상 재계획하지 않고 마지막 추천을 유지한다(무한 재계획/
  // 무한 Gemini 호출 방지).
  static const _maxReplanPerDate = 2;

  // 저장된 예보 스냅샷과 현재 예보를 비교해 재계획이 필요한지 판단하는
  // 순수 함수(Firestore/Gemini 호출 없음, 단위 테스트 대상).
  //  · 강수확률이 50%(WeatherService.rainProbabilityThreshold) 경계를
  //    넘나들 때(비 예보가 새로 생기거나 사라짐)
  //  · 최고기온이 5도 이상 달라졌을 때
  // 그 미만의 변화는 예보의 정상적인 미세 흔들림으로 보고 무시한다 — 매
  // 앱 실행마다 재계획(=Gemini 재호출)이 일어나면 안 되기 때문이다.
  // 스냅샷이 없거나(과거 데이터) 현재 예보 조회에 실패했으면 비교 불가로
  // 안전하게 false.
  static const _tempDiffThreshold = 5.0;

  static ({bool replan, String? reason}) shouldReplanForWeather({
    required int? snapshotPrecipProbability,
    required double? snapshotMaxTempC,
    required DailyWeather? currentForecast,
  }) {
    if (snapshotPrecipProbability == null ||
        snapshotMaxTempC == null ||
        currentForecast == null) {
      return (replan: false, reason: null);
    }
    final wasRainy = snapshotPrecipProbability >= WeatherService.rainProbabilityThreshold;
    final isRainyNow =
        currentForecast.precipitationProbability >= WeatherService.rainProbabilityThreshold;
    if (wasRainy != isRainyNow) {
      return (replan: true, reason: isRainyNow ? '비 예보가 새로 생겼어요' : '비 예보가 사라졌어요');
    }
    final tempDiff = currentForecast.maxTempC - snapshotMaxTempC;
    if (tempDiff.abs() >= _tempDiffThreshold) {
      return (
        replan: true,
        reason: tempDiff > 0 ? '예상보다 기온이 많이 올랐어요' : '예상보다 기온이 많이 내려갔어요',
      );
    }
    return (replan: false, reason: null);
  }

  // 최근 추천에 쓰인 아이템 id 집합 — findForTpo의 동점 타이브레이커를
  // "wardrobe 순회 순서"에서 "최근에 안 입은 순"으로 바꾸는 재료다.
  // Firestore 조회 결과를 인자로 받는 순수 함수라 단위 테스트가 가능하다.
  //
  // userChoice로 거르지 않는다. 여기서 세는 건 "실제로 입었는가"가 아니라
  // "최근에 제시됐는가"이기 때문이다 — 해결하려는 문제가 옷장의 12.6%만
  // 반복해서 노출되는 것이므로, 사용자가 거절한 조합도 이미 한 번 노출된
  // 이상 다시 1순위로 올릴 이유가 없다. accepted는 실제 착용이라 당연히
  // 포함되고, rejected_with_alternative는 "그 상황에 안 맞다고 판단된"
  // 조합이라 역시 뒤로 미는 게 맞다.
  @visibleForTesting
  static Set<String> recentItemIdsFrom(
    List<RecommendationEntry> recent,
    DateTime now, {
    Duration window = _recencyWindow,
  }) {
    final cutoff = now.subtract(window);
    final out = <String>{};
    for (final entry in recent) {
      if (entry.createdAt.isBefore(cutoff)) continue;
      out.addAll(entry.itemIds);
    }
    return out;
  }

  // 반환값: 추천을 실제로 저장했으면 true (runProactiveCheck의 created 집계용).
  static Future<bool> _prepareRecommendationFor(
    String uid,
    OutfitCalendarEntry plan,
    List<WardrobeItem> wardrobe, {
    int replanCount = 0,
    List<String> previousItemIds = const [],
  }) async {
    final tag = TpoTags.byLabel(plan.tpoTag);
    final wardrobeById = {for (final i in wardrobe) i.id: i};
    unawaited(FirestoreService.addAgentLogSilently(
      uid,
      AgentLogEntry(
        id: '',
        eventType: AgentLogEntry.typeScheduleDetected,
        message: '${_relativeLabel(plan.date)} [${plan.tpoTag}] 일정을 감지했습니다',
        relatedDocId: plan.id,
      ),
    ));

    // 날씨를 관찰 도구로 사용 — 이 일정 날짜의 예보가 특이하면(비/극한 기온)
    // 카드 문구에 반영할 근거로 남긴다. 조회 실패(null)면 조용히 건너뛴다.
    final dayWeather = (await WeatherService.fetch())?.forDate(plan.date);
    String? weatherNote;
    if (dayWeather != null) {
      if (dayWeather.precipitationProbability >= WeatherService.rainProbabilityThreshold) {
        weatherNote = '비 예보가 있어 어두운 톤으로 준비했어요';
      } else if (dayWeather.maxTempC >= 28) {
        weatherNote = '더운 날씨 예보라 가볍게 준비했어요';
      } else if (dayWeather.minTempC <= 5) {
        weatherNote = '쌀쌀한 날씨 예보라 보온에 신경 썼어요';
      }
      if (weatherNote != null) {
        unawaited(FirestoreService.addAgentLogSilently(
          uid,
          AgentLogEntry(
            id: '',
            eventType: AgentLogEntry.typeWeatherChecked,
            message: '${_relativeLabel(plan.date)} 예보를 확인했습니다 — '
                '강수확률 ${dayWeather.precipitationProbability}%, '
                '최고 ${dayWeather.maxTempC.round()}°C/최저 ${dayWeather.minTempC.round()}°C',
            relatedDocId: plan.id,
          ),
        ));
      }
    }

    // 최근 추천 이력을 조회해 동점 타이브레이커 재료로 넘긴다. 조회가
    // 실패하면 빈 집합이 되고, 그러면 findForTpo는 현행과 동일하게 동작한다
    // (폴백 방향은 언제나 보수적으로).
    final recentItemIds = recentItemIdsFrom(
      await FirestoreService.recentRecommendationsSilently(uid),
      DateTime.now(),
    );
    final match = OutfitMatcher.findForTpo(
      wardrobe: wardrobe,
      formalityHint: tag.formalityHint,
      policy: _matchPolicy,
      recentItemIds: recentItemIds,
    );
    // 레벨 4: 조합 자체가 불가 — 조용히 넘기지 않고 무엇이 부족한지 로그로 남긴다.
    if (match.candidates.isEmpty) {
      unawaited(FirestoreService.addAgentLogSilently(
        uid,
        AgentLogEntry(
          id: '',
          eventType: AgentLogEntry.typeScheduleDetected,
          message: '[${plan.tpoTag}] 일정용 조합을 찾지 못했습니다 — ${match.shortfall ?? '옷장이 부족해요'}',
          relatedDocId: plan.id,
        ),
      ));
      return false;
    }
    unawaited(FirestoreService.addAgentLogSilently(
      uid,
      AgentLogEntry(
        id: '',
        eventType: AgentLogEntry.typeCandidatesGenerated,
        message: match.isFallback
            ? '[${plan.tpoTag}] 격식에 딱 맞는 조합이 없어 가장 가까운 후보 ${match.candidates.length}개를 검토합니다'
            : '옷장에서 ${tag.formalityHint} 조합 ${match.candidates.length}개를 검토했습니다',
        relatedDocId: plan.id,
      ),
    ));

    // 레벨 3: 관련도 기반 과거 추천 이력을 프롬프트에 주입(있을 때만).
    // recency가 아니라 relevance로 뽑는다 — 태그 일치 +3, 후보 아이템과
    // 겹치는 아이템 1개당 +2, 과거 점수 80점 이상이면 +1. 태그가 실제로
    // 일치한 경우에만 reflectedFeedback=true로 남겨 카드에 "반영했어요"를
    // 표시한다.
    final candidateItemIds =
        match.candidates.expand((c) => c.items.map((i) => i.id)).toSet().toList();
    final history = await FirestoreService.getRelevantHistorySilently(
      uid,
      tpoTag: plan.tpoTag,
      candidateItemIds: candidateItemIds,
      wardrobeById: wardrobeById,
    );
    final feedbackText = history.lines.isEmpty ? null : history.lines.join('\n');
    if (history.tagMatchCount > 0) {
      unawaited(FirestoreService.addAgentLogSilently(
        uid,
        AgentLogEntry(
          id: '',
          eventType: AgentLogEntry.typeCandidatesGenerated,
          message: '과거 [${plan.tpoTag}] 착장 ${history.tagMatchCount}건을 참고했습니다',
          relatedDocId: plan.id,
        ),
      ));
    }

    final outcome = await OutfitSelfEvaluator.run(
      match.candidates,
      recentHistoryText: feedbackText,
      isRelevanceRanked: !history.isFallback,
      onStep: ({required index, required total, score, required passed, required wasError}) {
        final String message;
        if (wasError) {
          message = '후보 ${index + 1} 평가: Gemini 호출 실패로 건너뛰고 다음 후보 검토';
        } else {
          final scoreText = score != null ? '$score점' : '점수 파싱 실패';
          final verdict = passed
              ? '기준(${OutfitSelfEvaluator.threshold}점) 통과, 채택'
              : (index < total - 1 ? '기준 미달로 다음 후보 검토' : '기준 미달');
          message = '후보 ${index + 1} 평가: $scoreText — $verdict';
        }
        unawaited(FirestoreService.addAgentLogSilently(
          uid,
          AgentLogEntry(
            id: '',
            eventType: AgentLogEntry.typeCandidateEvaluated,
            message: message,
            relatedDocId: plan.id,
          ),
        ));
      },
    );
    if (outcome == null) return false;

    // 매처가 차선을 줬거나(격식 부적합) Gemini 점수도 낮으면 fallback으로 표기.
    final isFallback =
        match.isFallback || (outcome.bestScore != null && outcome.bestScore! < _lowScoreFloor);
    final fallbackNote = buildFallbackNote(
      matchIsFallback: match.isFallback,
      mismatchedCategories: match.mismatchedCategories,
      bestScore: outcome.bestScore,
      dateLabel: _relativeLabel(plan.date),
      tpoTag: plan.tpoTag,
    );
    // fallbackNote와 별개 — 조합 자체는 성립해도(isFallback=false) 아우터/
    // 신발 같은 선택 카테고리 하나만 격식 미달로 채워졌을 수 있다.
    final optionalNote = buildOptionalNote(
      optionalMissing: match.optionalMissing,
      tpoTag: plan.tpoTag,
    );

    // ── 채택률 지표: 자기 성능 인지 문구 ── 이 태그에서 과거 채택률이
    // 뚜렷하게 낮거나(아직 배우는 중) 높으면(자신 있음) 카드에 솔직하게
    // 밝힌다. 표본이 애매하면(중간 채택률이거나 건수 부족) 아무 말도
    // 덧붙이지 않는다 — 근거 없는 자신감/과한 겸손 둘 다 피한다.
    final stats = await AgentStats.compute(uid);
    final tagStat = stats.forTag(plan.tpoTag);
    String? confidenceNote;
    if (tagStat != null && tagStat.total >= 2 && tagStat.rate < 0.5) {
      confidenceNote = '[${plan.tpoTag}] 코디 취향은 아직 배우는 중이에요 — '
          '피드백이 쌓일수록 정확해집니다';
    } else if (tagStat != null && tagStat.total >= 3 && tagStat.rate >= 0.8) {
      final percent = (tagStat.rate * 100).round();
      confidenceNote = '[${plan.tpoTag}] 코디는 자신 있어요 (최근 채택률 $percent%)';
    }

    final entry = RecommendationEntry(
      id: '',
      itemIds: outcome.bestMatch.items.map((i) => i.id).toList(),
      itemSummaries: outcome.bestMatch.items
          .map((i) => '${i.category}: ${i.attributes!.toPromptLine()}')
          .toList(),
      colorScore: outcome.bestScore,
      summaryText: outcome.summaryText,
      triggerItemId: '', // 새 옷이 아니라 일정이 트리거
      createdAt: DateTime.now(),
      evaluatedCount: outcome.evaluatedCount,
      candidateScores: outcome.candidateScores,
      targetDate: plan.date,
      targetTpoTag: plan.tpoTag,
      reflectedFeedback: history.tagMatchCount > 0,
      isFallback: isFallback,
      fallbackNote: fallbackNote,
      optionalNote: optionalNote,
      forecastPrecipProbability: dayWeather?.precipitationProbability,
      forecastMaxTempC: dayWeather?.maxTempC,
      replanCount: replanCount,
      confidenceNote: confidenceNote,
      weatherNote: weatherNote,
    );
    final recId = await FirestoreService.addRecommendationSilently(uid, entry);
    if (recId == null) return false;

    final scorePhrase = outcome.bestScore != null ? '${outcome.bestScore}점 조합을' : '조합을';
    unawaited(FirestoreService.addAgentLogSilently(
      uid,
      AgentLogEntry(
        id: '',
        eventType: AgentLogEntry.typeRecommendationRegistered,
        message: isFallback
            ? '[${plan.tpoTag}] 조건에 맞는 조합이 부족합니다 — 차선책 $scorePhrase 제안합니다'
            : '${_relativeLabel(plan.date)} [${plan.tpoTag}] 일정을 위해 $scorePhrase 준비했습니다',
        relatedDocId: plan.id,
      ),
    ));

    // 예보 재계획으로 새로 만든 추천이면, 이전 조합에서 빠진 아이템을
    // 한 줄로 남긴다(있을 때만 — 계산 실패/변경 없음이면 조용히 생략).
    if (previousItemIds.isNotEmpty) {
      final removed = previousItemIds.toSet().difference(entry.itemIds.toSet());
      final removedLabel = removed
          .map((id) => wardrobeById[id])
          .whereType<WardrobeItem>()
          .map(_agentItemLabel)
          .join('·');
      if (removedLabel.isNotEmpty) {
        unawaited(FirestoreService.addAgentLogSilently(
          uid,
          AgentLogEntry(
            id: '',
            eventType: AgentLogEntry.typeRecommendationRegistered,
            message: '이전 조합에서 $removedLabel 아이템을 뺐어요',
            relatedDocId: plan.id,
          ),
        ));
      }
    }
    return true;
  }

  // 캘린더 기록과 대조할 추천을 찾을 때 허용하는 날짜 오차. 정확히 같은
  // 날짜만 대상으로 하면 "일정 등록"(레벨 1) 없이 쌓이는 일반 추천은
  // 거의 매칭되지 않으므로, 등록일 전후 며칠까지 넓혀서 잡는다.
  static const _feedbackMatchWindowDays = 3;

  // 추천-기록 간 자카드 유사도가 이 값 이상이면 accepted, 미만이면
  // rejected_with_alternative. 60% ≈ 4벌 중 3벌 이상 겹침.
  static const _acceptSimilarityThreshold = 0.6;

  // ── 레벨 3: 피드백 감지 (캘린더 착장 기록 시 호출) ──────────
  // targetDate ± _feedbackMatchWindowDays 범위의 추천 중, 태그가 같은 것이
  // 있으면 그것만, 없으면(일반 추천 등 태그 없는 것 포함) 범위 전체를
  // 후보로 삼아 날짜가 가장 가까운 하나를 고른다. 사용자가 저장한 조합이
  // 그 추천과 같으면 accepted, 다르면 rejected_with_alternative로 기록한다.
  // 이 불일치가 다음 추천 프롬프트에 취향 피드백으로 주입된다.
  static Future<void> detectFeedbackForCalendarEntry(
      String uid, OutfitCalendarEntry entry) async {
    try {
      if (entry.isPlanned || entry.itemIds.isEmpty) return; // 예정/빈 기록은 대상 아님
      final recs = await FirestoreService.recommendationsInDateRangeSilently(
          uid, entry.date, _feedbackMatchWindowDays);
      final unresponded =
          recs.where((r) => r.userChoice == null && r.targetDate != null).toList();
      if (unresponded.isEmpty) return;

      final tagMatches = unresponded.where((r) => r.targetTpoTag == entry.tpoTag).toList();
      final pool = tagMatches.isNotEmpty ? tagMatches : unresponded;
      pool.sort((a, b) => a.targetDate!
          .difference(entry.date)
          .abs()
          .compareTo(b.targetDate!.difference(entry.date).abs()));
      final rec = pool.first;

      // 완전 일치를 요구하면 3~4벌 조합을 하나라도 다르게 고른 순간 전부
      // rejected가 되어 채택률이 비현실적으로 낮아진다. 자카드 유사도
      // (교집합/합집합)로 "참고해서 비슷하게 입었는지"를 판정한다.
      final recSet = rec.itemIds.toSet();
      final chosenSet = entry.itemIds.toSet();
      final intersection = recSet.intersection(chosenSet);
      final union = recSet.union(chosenSet);
      final similarity = union.isEmpty ? 0.0 : intersection.length / union.length;
      final accepted = similarity >= _acceptSimilarityThreshold;
      debugPrint('[FEEDBACK] rec=${rec.id} recItems=$recSet chosenItems=$chosenSet '
          '교집합=${intersection.length} 합집합=${union.length} '
          '유사도=${similarity.toStringAsFixed(2)} 임계값=$_acceptSimilarityThreshold '
          '→ ${accepted ? "accepted" : "rejected"}');
      if (accepted) {
        await FirestoreService.updateRecommendationFeedbackSilently(uid, rec.id,
            userChoice: RecommendationEntry.choiceAccepted);
        unawaited(FirestoreService.addAgentLogSilently(
          uid,
          AgentLogEntry(
            id: '',
            eventType: AgentLogEntry.typeCalendarLogged,
            message: '추천 코디가 채택되었습니다 ([${entry.tpoTag}])',
            relatedDocId: rec.id,
          ),
        ));
      } else {
        await FirestoreService.updateRecommendationFeedbackSilently(uid, rec.id,
            userChoice: RecommendationEntry.choiceRejectedWithAlternative,
            userChosenItemIds: entry.itemIds);
        unawaited(FirestoreService.addAgentLogSilently(
          uid,
          AgentLogEntry(
            id: '',
            eventType: AgentLogEntry.typeCalendarLogged,
            message: '추천 대신 다른 조합을 선택하셨네요 ([${entry.tpoTag}]) — 다음 추천에 반영하겠습니다',
            relatedDocId: rec.id,
          ),
        ));
      }
    } catch (e) {
      debugPrint('[FEEDBACK] 감지 실패: $e');
    }
  }

  // ── 레벨 2: 주간 코디 플랜 (버튼 트리거) ──────────────────
  // 오늘부터 7일의 일정(예정 태그 없으면 '일상')과 옷장 전체를 Gemini에 단
  // 1회 호출해 제약(중복 회피·격식 배분)을 고려한 날짜별 조합을 받는다.
  // 결과는 UI 카드로 반환하고, 저장은 사용자가 날짜별로 확정할 때 이뤄진다.
  // 진행 불가/실패는 조용히 넘기지 않고 StateError로 사유를 던져 UI가 안내한다.
  static Future<List<WeeklyPlanDay>> generateWeeklyPlan(String uid) async {
    final wardrobe = await FirestoreService.wardrobeStream(uid).first;
    final usable = wardrobe.where((i) => i.attributes != null).toList();
    if (usable.length < 2) {
      throw StateError('플랜을 세우려면 속성이 분석된 옷이 2벌 이상 필요해요.');
    }
    final byId = {for (final i in usable) i.id: i};

    final today = _todayMidnight();
    final horizon = today.add(const Duration(days: _weeklyHorizonDays - 1));
    final calendar = await FirestoreService.calendarEntriesForRange(uid, today, horizon);
    // 날짜별 예정 태그 맵(있으면 그 태그, 없으면 '일상').
    final plannedByDate = <String, String>{};
    for (final e in calendar) {
      if (e.isPlanned) plannedByDate[_dateKey(e.date)] = e.tpoTag;
    }

    // 날씨를 관찰 도구로 사용 — 7일 예보를 날짜별 제약으로 스케줄 줄에
    // 덧붙인다. 조회 실패(null)면 조용히 날씨 제약 없이 진행한다.
    final weather = await WeatherService.fetch();
    if (weather != null) {
      final rainyDayLabels = <String>[];
      for (final d in weather.daily) {
        final w = weather.forDate(d.date);
        if (w != null && w.precipitationProbability >= WeatherService.rainProbabilityThreshold) {
          rainyDayLabels.add(_weekdayKo(d.date));
        }
      }
      unawaited(FirestoreService.addAgentLogSilently(
        uid,
        AgentLogEntry(
          id: '',
          eventType: AgentLogEntry.typeWeatherChecked,
          message: rainyDayLabels.isEmpty
              ? '주간 예보를 확인했습니다 — 특별한 날씨 변수는 없었습니다'
              : '주간 예보를 확인했습니다 — ${rainyDayLabels.join('・')}요일 비 예보를 플랜에 반영합니다',
        ),
      ));
    }

    // 7일 스케줄 구성.
    final days = List.generate(
        _weeklyHorizonDays, (i) => today.add(Duration(days: i)));
    final scheduleLines = <String>[];
    final tpoByDate = <String, String>{};
    for (var i = 0; i < days.length; i++) {
      final d = days[i];
      final key = _dateKey(d);
      final tpo = plannedByDate[key] ?? '일상';
      tpoByDate[key] = tpo;
      final formality = TpoTags.byLabel(tpo).formalityHint;
      final weatherNote = weather == null ? '' : _weatherConstraintNote(weather.forDate(d));
      scheduleLines
          .add('${i + 1}. $key (${_weekdayKo(d)}) — $tpo — 요구 격식: $formality$weatherNote');
    }

    final catalog = usable
        .map((i) => '- id=${i.id} | ${i.category} | ${i.attributes!.toPromptLine()}')
        .join('\n');

    // 레벨 3: 관련도 기반 과거 추천 이력을 주간 플랜 프롬프트에도 주입한다.
    // 하루짜리 후보 조합이 없어 tpoTag/candidateItemIds 없이 호출 — 이 경우
    // colorScore>=80 축만 유효해 "잘 됐던 과거 추천 위주"로 걸러진다.
    final history = await FirestoreService.getRelevantHistorySilently(
      uid,
      wardrobeById: byId,
    );
    final feedbackText = history.lines.isEmpty ? null : history.lines.join('\n');

    debugPrint('[PLAN] 주간 플랜 요청: ${days.length}일, 옷장 ${usable.length}벌'
        '${feedbackText != null ? ' (이력 ${history.lines.length}건 반영)' : ''}');
    String raw;
    try {
      raw = await GeminiService.withTextModelFallback(
        (model) => GeminiService.planWeeklyOutfits(
          scheduleLines: scheduleLines.join('\n'),
          wardrobeCatalog: catalog,
          recentFeedbackText: feedbackText,
          model: model,
        ),
      );
    } catch (e) {
      debugPrint('[PLAN] 주간 플랜 Gemini 실패: $e');
      throw StateError('플랜 생성에 실패했어요. 잠시 후 다시 시도해주세요.');
    }

    final parsed = _parsePlanArray(raw);
    final result = <WeeklyPlanDay>[];
    for (final row in parsed) {
      final dateStr = row['date'] as String?;
      final rawIds = (row['itemIds'] as List?)?.map((e) => e.toString()) ?? const [];
      // 옷장에 실제로 있는 id만 남긴다(모델이 지어낸 id 방어).
      final items = rawIds.map((id) => byId[id]).whereType<WardrobeItem>().toList();
      if (dateStr == null || items.isEmpty) continue;
      final date = DateTime.tryParse(dateStr);
      if (date == null) continue;
      final key = _dateKey(date);
      result.add(WeeklyPlanDay(
        date: DateTime(date.year, date.month, date.day),
        tpoTag: tpoByDate[key] ?? '일상',
        items: items,
        reason: (row['reason'] as String?)?.trim() ?? '',
      ));
    }
    if (result.isEmpty) {
      throw StateError('플랜 응답을 해석하지 못했어요. 잠시 후 다시 시도해주세요.');
    }

    unawaited(FirestoreService.addAgentLogSilently(
      uid,
      AgentLogEntry(
        id: '',
        eventType: AgentLogEntry.typeWeeklyPlanned,
        message: '주간 플랜을 수립했습니다 — ${result.length}일 일정에 대해 중복 없이 조합을 배분했습니다',
      ),
    ));
    return result;
  }

  // JSON 배열 파싱 — _parseJsonObject(GeminiService)의 배열판. 코드블록 펜스를
  // 벗기고 첫 '['~마지막 ']' 구간만 안전하게 디코드한다.
  static List<Map<String, dynamic>> _parsePlanArray(String text) {
    var cleaned = text.trim();
    cleaned = cleaned
        .replaceAll(RegExp(r'```json\s*'), '')
        .replaceAll(RegExp(r'```\s*'), '');
    final start = cleaned.indexOf('[');
    final end = cleaned.lastIndexOf(']');
    if (start == -1 || end == -1 || end < start) {
      debugPrint('[PLAN] JSON 배열을 찾지 못함: $text');
      return const [];
    }
    try {
      final decoded = jsonDecode(cleaned.substring(start, end + 1)) as List;
      return decoded.whereType<Map<String, dynamic>>().toList();
    } catch (e) {
      debugPrint('[PLAN] JSON 파싱 실패: $e');
      return const [];
    }
  }

  // ── 새 옷 등록 추천 파이프라인 (wardrobe_screen.dart의 최초 트리거와
  // AgentSweeper의 재개 양쪽이 공유) ──────────────────────
  // 순수 파이프라인 함수 — 태스크 enqueue는 호출부 책임이다(최초 트리거와
  // 재개 트리거가 "새 태스크 생성"과 "기존 태스크 재스케줄"을 다르게
  // 처리해야 하므로 이 함수 안에 숨기지 않는다).

  // 타임아웃/일시적 과부하 시 같은 모델로 재시도하는 대신 대체 모델로 바꿔
  // 한 번 더 시도한다(GeminiService.withTextModelFallback 공통 정책).
  static Future<ClothingAttributes> extractAttributesWithRetry(
    String imageUrl,
    String category,
  ) {
    return GeminiService.withTextModelFallback(
      (model) => GeminiService.extractAttributes(
        imageUrl: imageUrl,
        category: category,
        model: model,
      ),
    );
  }

  // 새 옷 등록(또는 재개)을 계기로 로컬 매칭(후보 최대 3개) → 자기 평가
  // 루프 → 저장까지. 반환값은 "재시도가 필요한 실패"였는지만 알려준다
  // (candidates.isEmpty처럼 옷장이 부족해 애초에 추천할 게 없는 경우는
  // 실패가 아니므로 true — 재시도해도 달라지지 않는다).
  static Future<bool> generateRecommendationForNewItem(
    String uid,
    WardrobeItem newItem,
  ) async {
    debugPrint('[RECOMMEND] 파이프라인 시작: 새 옷 id=${newItem.id}, category=${newItem.category}');
    // 홈 화면 "에이전트 작업 중" 인디케이터 — 성공/실패 상관없이 끝나면
    // 반드시 유휴로 되돌려야 하므로 finally에서 초기화한다.
    AgentActivity.current.value = '새 옷 코디를 검토 중...';
    try {
      final itemLabel = _agentItemLabel(newItem);
      unawaited(FirestoreService.addAgentLogSilently(
        uid,
        AgentLogEntry(
          id: '',
          eventType: AgentLogEntry.typeNewItemDetected,
          message: '새 옷($itemLabel) 등록을 감지했습니다',
          relatedDocId: newItem.id,
        ),
      ));

      final existingItems = await FirestoreService.wardrobeStream(uid).first;
      final candidates = OutfitMatcher.findCandidateMatches(
        newItem: newItem,
        existingItems: existingItems,
      );
      if (candidates.isEmpty) return true; // 매칭 불가 — 재시도 대상 아님

      final comparedCount = existingItems.where((i) => i.id != newItem.id).length;
      unawaited(FirestoreService.addAgentLogSilently(
        uid,
        AgentLogEntry(
          id: '',
          eventType: AgentLogEntry.typeCandidatesGenerated,
          message: '옷장 $comparedCount벌과 대조해 후보 ${candidates.length}개 조합을 생성했습니다',
          relatedDocId: newItem.id,
        ),
      ));

      final outcome = await OutfitSelfEvaluator.run(
        candidates,
        // 진단-수리 루프는 이 백그라운드 파이프라인에서만 켠다(동기 흐름인
        // AI 코디 분석하기/주간 플랜은 켜지 않아 기존과 동일하게 1회 평가).
        enableRepair: true,
        anchorItem: newItem,
        wardrobe: existingItems,
        onStep: ({required index, required total, score, required passed, required wasError}) {
          final String message;
          if (wasError) {
            message = '후보 ${index + 1} 평가: Gemini 호출 실패로 건너뛰고 다음 후보 검토';
          } else {
            final scoreText = score != null ? '$score점' : '점수 파싱 실패';
            final verdict = passed
                ? '기준(${OutfitSelfEvaluator.threshold}점) 통과, 채택'
                : (index < total - 1 ? '기준 미달로 다음 후보 검토' : '기준 미달');
            message = '후보 ${index + 1} 평가: $scoreText — $verdict';
          }
          unawaited(FirestoreService.addAgentLogSilently(
            uid,
            AgentLogEntry(
              id: '',
              eventType: AgentLogEntry.typeCandidateEvaluated,
              message: message,
              relatedDocId: newItem.id,
            ),
          ));
        },
        // 진단-수리 서사("후보 N 평가 중...", 진단, 교체, 수리 결과)는
        // 일어나는 순간마다 바로 activity 인디케이터 + 활동 로그에 반영한다.
        onNarrative: (message) {
          AgentActivity.current.value = message;
          unawaited(FirestoreService.addAgentLogSilently(
            uid,
            AgentLogEntry(
              id: '',
              eventType: AgentLogEntry.typeCandidateEvaluated,
              message: message,
              relatedDocId: newItem.id,
            ),
          ));
        },
      );
      if (outcome == null) return false; // Gemini 평가가 폴백까지 전부 실패

      // 이 경로(findCandidateMatches)는 TPO/격식 개념이 없어 match.isFallback에
      // 대응하는 값이 없다 — 점수가 낮은 경우만 차선으로 본다. 이걸 안 채우면
      // 새 옷 추천은 점수가 낮아도 사용자에게 아무 신호가 안 갔다(버그).
      final isFallback = outcome.bestScore != null && outcome.bestScore! < _lowScoreFloor;
      final fallbackNote = buildFallbackNote(
        matchIsFallback: false,
        mismatchedCategories: const [],
        bestScore: outcome.bestScore,
        dateLabel: itemLabel,
        tpoTag: null, // 일정 기반 경로와 달리 TPO 태그가 없다
      );

      final entry = RecommendationEntry(
        id: '',
        itemIds: outcome.bestMatch.items.map((i) => i.id).toList(),
        itemSummaries: outcome.bestMatch.items
            .map((i) => '${i.category}: ${i.attributes!.toPromptLine()}')
            .toList(),
        colorScore: outcome.bestScore,
        summaryText: outcome.summaryText,
        triggerItemId: newItem.id,
        createdAt: DateTime.now(),
        evaluatedCount: outcome.evaluatedCount,
        candidateScores: outcome.candidateScores,
        repairAttempted: outcome.repairAttempted,
        repairNote: outcome.repairNote,
        isFallback: isFallback,
        fallbackNote: fallbackNote,
        // 일정 기반 선제 추천이 아니라도 등록일 기준 targetDate를 채워
        // 채택률 집계(AgentStats) 대상에 포함시킨다. targetTpoTag는 비워두면
        // '일반' 태그로 잡힌다(agent_stats.dart forTag 참고).
        targetDate: DateTime.now(),
      );

      debugPrint('[RECOMMEND] Firestore 저장 시도...');
      final recId = await FirestoreService.addRecommendationSilently(uid, entry);
      if (recId == null) return false; // 저장 실패 시 "등록했습니다" 로그를 남기지 않는다.

      final scorePhrase = outcome.bestScore != null ? '${outcome.bestScore}점 조합을' : '조합을';
      unawaited(FirestoreService.addAgentLogSilently(
        uid,
        AgentLogEntry(
          id: '',
          eventType: AgentLogEntry.typeRecommendationRegistered,
          message: outcome.evaluatedCount > 1
              ? '${outcome.evaluatedCount}개 조합을 비교 평가해 $scorePhrase 추천으로 등록했습니다'
              : '옷장 분석으로 $scorePhrase 추천으로 등록했습니다',
          relatedDocId: newItem.id,
        ),
      ));
      return true;
    } catch (e) {
      debugPrint('[RECOMMEND] 파이프라인 예외로 중단: $e');
      return false;
    } finally {
      AgentActivity.current.value = null;
    }
  }

  // 활동 로그 문장용 짧은 옷 설명 — "블랙 상의"처럼 색+카테고리.
  static String _agentItemLabel(WardrobeItem item) {
    final color = item.attributes?.color;
    return (color != null && color.isNotEmpty) ? '$color ${item.category}' : item.category;
  }

  static String _dateKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static String _dateLabel(DateTime d) => '${d.month}/${d.day}';

  static const _weekdays = ['월', '화', '수', '목', '금', '토', '일'];
  static String _weekdayKo(DateTime d) => _weekdays[d.weekday - 1];

  // 하루치 예보를 스케줄 줄에 덧붙일 제약 문구로 변환. 특이사항 없으면 빈 문자열.
  static String _weatherConstraintNote(DailyWeather? w) {
    if (w == null) return '';
    final parts = <String>[];
    if (w.precipitationProbability >= WeatherService.rainProbabilityThreshold) {
      parts.add('비 예보(강수확률 ${w.precipitationProbability}%) — '
          '밝은 색/니트류 회피, 방수 소재나 어두운 톤 우선');
    }
    if (w.maxTempC >= 28) {
      parts.add('더운 날(최고 ${w.maxTempC.round()}°C) — 얇고 통풍 잘 되는 소재 우선');
    } else if (w.minTempC <= 5) {
      parts.add('추운 날(최저 ${w.minTempC.round()}°C) — 두꺼운 아우터 우선');
    }
    if (parts.isEmpty) return '';
    return ' — ${parts.join(', ')}';
  }

  // "오늘/내일/모레/N일 뒤" 상대 표기.
  static String _relativeLabel(DateTime date) {
    final today = _todayMidnight();
    final diff = DateTime(date.year, date.month, date.day).difference(today).inDays;
    if (diff <= 0) return '오늘';
    if (diff == 1) return '내일';
    if (diff == 2) return '모레';
    return '$diff일 뒤';
  }

  // 홈 추천 카드가 targetDate 문구를 만들 때 재사용하는 공개 헬퍼.
  static String relativeLabel(DateTime date) => _relativeLabel(date);
}
