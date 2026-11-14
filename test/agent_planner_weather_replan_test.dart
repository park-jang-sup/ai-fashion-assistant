// AgentPlanner.shouldReplanForWeather의 순수 로직 단위 테스트.
// 저장된 예보 스냅샷과 현재 예보를 비교해 재계획 여부를 정하는 임계값
// 판단만 다룬다(Firestore/Gemini 호출 없음).
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_fashion_assistant/models/recommendation_entry.dart';
import 'package:ai_fashion_assistant/services/agent_planner.dart';
import 'package:ai_fashion_assistant/services/weather_service.dart';

DailyWeather _forecast({required double maxTempC, required int precip}) => DailyWeather(
      date: DateTime(2026, 7, 27),
      maxTempC: maxTempC,
      minTempC: maxTempC - 10,
      precipitationProbability: precip,
    );

void main() {
  group('shouldReplanForWeather', () {
    test('강수확률 20%→80%: 50% 경계를 통과하면 재계획', () {
      final result = AgentPlanner.shouldReplanForWeather(
        snapshotPrecipProbability: 20,
        snapshotMaxTempC: 22,
        currentForecast: _forecast(maxTempC: 22, precip: 80),
      );
      expect(result.replan, isTrue);
      expect(result.reason, isNotNull);
    });

    test('강수확률 20%→40%: 50% 경계를 넘지 않으면 재계획 안 함', () {
      final result = AgentPlanner.shouldReplanForWeather(
        snapshotPrecipProbability: 20,
        snapshotMaxTempC: 22,
        currentForecast: _forecast(maxTempC: 22, precip: 40),
      );
      expect(result.replan, isFalse);
      expect(result.reason, isNull);
    });

    test('최고기온 22도→28도(6도차): 5도 이상 차이면 재계획', () {
      final result = AgentPlanner.shouldReplanForWeather(
        snapshotPrecipProbability: 20,
        snapshotMaxTempC: 22,
        currentForecast: _forecast(maxTempC: 28, precip: 20),
      );
      expect(result.replan, isTrue);
      expect(result.reason, isNotNull);
    });

    test('최고기온 22도→24도(2도차): 5도 미만이면 재계획 안 함', () {
      final result = AgentPlanner.shouldReplanForWeather(
        snapshotPrecipProbability: 20,
        snapshotMaxTempC: 22,
        currentForecast: _forecast(maxTempC: 24, precip: 20),
      );
      expect(result.replan, isFalse);
      expect(result.reason, isNull);
    });

    test('스냅샷 없음(기존 데이터)이면 크래시 없이 재계획 안 함', () {
      final result = AgentPlanner.shouldReplanForWeather(
        snapshotPrecipProbability: null,
        snapshotMaxTempC: null,
        currentForecast: _forecast(maxTempC: 30, precip: 90),
      );
      expect(result.replan, isFalse);
      expect(result.reason, isNull);
    });

    // §9 (1) — 만들 때 예보 조회에 실패한(forecastMissing) 추천은 예보를 얻으면 다시 계획.
    test('만들 때 예보 조회 실패로 스냅샷이 없으면, 예보를 얻은 뒤 다시 계획한다', () {
      final result = AgentPlanner.shouldReplanForWeather(
        snapshotPrecipProbability: null,
        snapshotMaxTempC: null,
        currentForecast: _forecast(maxTempC: 31, precip: 10),
        snapshotMissingAtCreation: true,
      );
      expect(result.replan, isTrue);
      expect(result.reason, '예보를 새로 확인했어요');
    });

    test('만들 때 예보 조회 실패 + 지금도 실패면 다시 계획 안 함(되풀이 없음)', () {
      final result = AgentPlanner.shouldReplanForWeather(
        snapshotPrecipProbability: null,
        snapshotMaxTempC: null,
        currentForecast: null,
        snapshotMissingAtCreation: true,
      );
      expect(result.replan, isFalse);
    });

    test('표시가 있어도 스냅샷이 있으면(다시 만든 추천) 기존 비교 규칙 그대로', () {
      final result = AgentPlanner.shouldReplanForWeather(
        snapshotPrecipProbability: 20,
        snapshotMaxTempC: 22,
        currentForecast: _forecast(maxTempC: 24, precip: 20),
        snapshotMissingAtCreation: true,
      );
      expect(result.replan, isFalse);
    });

    test('현재 예보 조회 실패(null)면 비교 불가로 재계획 안 함', () {
      final result = AgentPlanner.shouldReplanForWeather(
        snapshotPrecipProbability: 20,
        snapshotMaxTempC: 22,
        currentForecast: null,
      );
      expect(result.replan, isFalse);
      expect(result.reason, isNull);
    });
  });

  // §9-1 — 예보 없이 만든 추천의 자동 재시도 대상(추천 하나당 최대 1회, 대상이 있을 때만).
  group('forecastRetryTargets', () {
    final now = DateTime(2026, 11, 14, 16);
    RecommendationEntry rec(String id,
            {bool missing = true, bool retried = false, bool dismissed = false, String? choice, DateTime? target}) =>
        RecommendationEntry(
          id: id,
          itemIds: const ['a'],
          itemSummaries: const [],
          summaryText: '',
          triggerItemId: '',
          createdAt: now,
          dismissed: dismissed,
          userChoice: choice,
          targetDate: target ?? DateTime(2026, 11, 15),
          forecastMissing: missing,
          forecastRetried: retried,
        );
    List<String> ids(List<RecommendationEntry> r) => AgentPlanner.forecastRetryTargets(r, now).map((e) => e.id).toList();

    test('예보 없이 만든 다가오는 추천만 대상', () {
      expect(ids([rec('a'), rec('ok', missing: false)]), ['a']);
    });
    test('대상이 없으면 빈 목록(선제 추천을 돌리지 않는다)', () {
      expect(ids([rec('ok', missing: false)]), isEmpty);
      expect(ids(const []), isEmpty);
    });
    test('한 번 재시도한 추천은 다시 대상이 아니다(반복 없음)', () {
      expect(ids([rec('a', retried: true)]), isEmpty);
    });
    test('다시 만든 추천은 예보 스냅샷이 있어 대상이 아니다', () {
      // 재시도 직전 조회가 캐시(30분)에 있어 _prepareRecommendationFor가 같은 예보를 쓴다.
      expect(ids([rec('old', retried: true, dismissed: true), rec('new', missing: false)]), isEmpty);
    });
    test('정리된·사용자가 반응한·지난·범위 밖 추천은 대상이 아니다', () {
      expect(ids([
        rec('d', dismissed: true),
        rec('c', choice: 'accepted'),
        rec('past', target: DateTime(2026, 11, 13)),
        rec('far', target: DateTime(2026, 11, 18)),
      ]), isEmpty);
      expect(ids([rec('today', target: DateTime(2026, 11, 14)), rec('h', target: DateTime(2026, 11, 17))]), ['today', 'h']);
    });
    test('표시는 켰을 때만 저장한다', () {
      expect(rec('a').toFirestore().containsKey('forecastRetried'), isFalse);
      expect(rec('a', retried: true).toFirestore()['forecastRetried'], isTrue);
    });
  });
}
