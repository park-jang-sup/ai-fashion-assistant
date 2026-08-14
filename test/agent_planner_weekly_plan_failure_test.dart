// AgentPlanner.classifyWeeklyPlanFailure/weeklyPlanFailureMessage의 순수
// 로직 단위 테스트. docs/task_weekly_plan_scale_v1.md 4단계 — 주간 플랜
// 실패를 "재시도 유효(일시적)"와 "재시도 무효(구조적)"로 가르고, 구조적
// 실패 중 옷장 규모가 원인인 경우만 그 사실을 밝힌다. FirebaseFunctionsException
// 생성자가 @protected라 이 타입 자체는 만들 수 없으므로, 호출부가 뽑아
// 넘기는 원시값(functionsErrorCode/violations 등)만으로 검증한다.
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_fashion_assistant/services/agent_planner.dart';

void main() {
  group('classifyWeeklyPlanFailure', () {
    test('호출량 상한(RateLimitExceededException 대응) → rateLimited', () {
      final r = AgentPlanner.classifyWeeklyPlanFailure(isRateLimited: true);
      expect(r, WeeklyPlanFailureReason.rateLimited);
    });

    test('GeminiApiException 재시도 가능(503/429) → transient', () {
      final r = AgentPlanner.classifyWeeklyPlanFailure(isGeminiRetryable: true);
      expect(r, WeeklyPlanFailureReason.transient);
    });

    test('GeminiApiException 재시도 불가(예: 400) → structuralOther', () {
      final r = AgentPlanner.classifyWeeklyPlanFailure(isGeminiRetryable: false);
      expect(r, WeeklyPlanFailureReason.structuralOther);
    });

    test('FirebaseFunctionsException(unauthenticated) → transient — '
        '재로그인하면 풀리는 실패라 "구조적"에 넣지 않는다', () {
      final r = AgentPlanner.classifyWeeklyPlanFailure(functionsErrorCode: 'unauthenticated');
      expect(r, WeeklyPlanFailureReason.transient);
    });

    test('FirebaseFunctionsException(invalid-argument) + violations에 '
        'text_too_long 포함 → wardrobeTooLarge', () {
      final r = AgentPlanner.classifyWeeklyPlanFailure(
        functionsErrorCode: 'invalid-argument',
        violations: ['text_too_long'],
      );
      expect(r, WeeklyPlanFailureReason.wardrobeTooLarge);
    });

    test('violations에 text_too_long이 다른 위반과 함께 섞여 있어도 '
        'wardrobeTooLarge로 판정한다', () {
      final r = AgentPlanner.classifyWeeklyPlanFailure(
        functionsErrorCode: 'invalid-argument',
        violations: ['parts_too_many', 'text_too_long'],
      );
      expect(r, WeeklyPlanFailureReason.wardrobeTooLarge);
    });

    test('FirebaseFunctionsException(invalid-argument) + violations에 '
        'text_too_long 없음 → structuralOther(원인 특정 안 함)', () {
      final r = AgentPlanner.classifyWeeklyPlanFailure(
        functionsErrorCode: 'invalid-argument',
        violations: ['top_level_unknown_key'],
      );
      expect(r, WeeklyPlanFailureReason.structuralOther);
    });

    test('FirebaseFunctionsException이되 violations 자체가 없음(예: '
        'payload_limit 위반) → structuralOther', () {
      final r = AgentPlanner.classifyWeeklyPlanFailure(functionsErrorCode: 'invalid-argument');
      expect(r, WeeklyPlanFailureReason.structuralOther);
    });

    test('아무 타입도 안 걸림(TimeoutException/FormatException/미분류 대응) '
        '→ transient — 모르는 실패는 재시도를 막지 않는 쪽이 안전하다', () {
      final r = AgentPlanner.classifyWeeklyPlanFailure();
      expect(r, WeeklyPlanFailureReason.transient);
    });
  });

  group('weeklyPlanFailureMessage', () {
    test('wardrobeTooLarge — 원인을 밝히고 재시도를 권하지 않는다', () {
      final m = AgentPlanner.weeklyPlanFailureMessage(WeeklyPlanFailureReason.wardrobeTooLarge);
      expect(m, contains('옷'));
      expect(m, isNot(contains('다시 시도해주세요')));
    });

    test('structuralOther — 재시도를 권하지 않는다', () {
      final m = AgentPlanner.weeklyPlanFailureMessage(WeeklyPlanFailureReason.structuralOther);
      expect(m, isNot(contains('다시 시도해주세요')));
    });

    test('transient — 기존 문구 그대로(회귀 없음)', () {
      final m = AgentPlanner.weeklyPlanFailureMessage(WeeklyPlanFailureReason.transient);
      expect(m, '플랜 생성에 실패했어요. 잠시 후 다시 시도해주세요.');
    });
  });
}
