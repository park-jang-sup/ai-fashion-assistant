// AgentPlanner.shouldReplanForWeather의 순수 로직 단위 테스트.
// 저장된 예보 스냅샷과 현재 예보를 비교해 재계획 여부를 정하는 임계값
// 판단만 다룬다(Firestore/Gemini 호출 없음).
import 'package:flutter_test/flutter_test.dart';
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
}
