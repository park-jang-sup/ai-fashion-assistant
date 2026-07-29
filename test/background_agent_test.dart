// BackgroundAgent.shouldRunNow의 순수 로직 단위 테스트. 이 작업 대부분은
// 플랫폼 통합(WorkManager/Firebase 아이솔레이트)이라 테스트로 분리할 수
// 있는 부분이 적고, 이 판정 함수 하나만 분리해 검증한다.
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_fashion_assistant/services/background_agent.dart';

void main() {
  group('BackgroundAgent.shouldRunNow', () {
    final now = DateTime(2026, 7, 29, 12, 0);

    test('최초 실행(lastRunAt == null)이면 실행', () {
      final result = BackgroundAgent.shouldRunNow(
        lastRunAt: null,
        now: now,
        force: false,
      );
      expect(result, isTrue);
    });

    test('최소 간격 미달이면 미실행', () {
      final result = BackgroundAgent.shouldRunNow(
        lastRunAt: now.subtract(const Duration(hours: 5)),
        now: now,
        force: false,
      );
      expect(result, isFalse);
    });

    test('최소 간격 충족이면 실행', () {
      final result = BackgroundAgent.shouldRunNow(
        lastRunAt: now.subtract(const Duration(hours: 11)),
        now: now,
        force: false,
      );
      expect(result, isTrue);
    });

    test('force == true면 간격 미달이어도 실행', () {
      final result = BackgroundAgent.shouldRunNow(
        lastRunAt: now.subtract(const Duration(minutes: 1)),
        now: now,
        force: true,
      );
      expect(result, isTrue);
    });

    test('lastRunAt이 미래(기기 시각 변경 등)면 실행 쪽으로 폴백', () {
      final result = BackgroundAgent.shouldRunNow(
        lastRunAt: now.add(const Duration(days: 1)),
        now: now,
        force: false,
      );
      expect(result, isTrue);
    });
  });
}
