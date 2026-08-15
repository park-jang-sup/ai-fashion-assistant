// cadence_policy.dart의 순수 함수 단위 테스트. response_signal.dart와
// 완전히 무관하게(ResponseSignal 인스턴스를 만들지 않고 필드값만 직접
// 넘겨) 판정 규칙만 검증한다.
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_fashion_assistant/services/cadence_policy.dart';

void main() {
  group('judgeCadence — 표본 부족 경계(windowSize=5)', () {
    test('sampleSize=4면 판정 보류, 현재 간격 유지', () {
      final d = judgeCadence(
        currentIntervalHours: 3,
        sampleSize: 4,
        respondedCount: 1,
        noResponseCount: 3,
        acceptedCount: 0,
      );
      expect(d.changed, isFalse);
      expect(d.recommendedIntervalHours, 3);
    });

    test('sampleSize=5면 판정 진행(표본 부족 아님)', () {
      final d = judgeCadence(
        currentIntervalHours: 3,
        sampleSize: 5,
        respondedCount: 2,
        noResponseCount: 3,
        acceptedCount: 0,
      );
      expect(d.changed, isTrue); // 무반응 3건 규칙이 발동해 간격이 바뀐다
    });
  });

  group('judgeCadence — 무반응 임계값 경계(3건)', () {
    test('무반응 2건이면 발동 안 함(유지)', () {
      final d = judgeCadence(
        currentIntervalHours: 3,
        sampleSize: 5,
        respondedCount: 3,
        noResponseCount: 2,
        acceptedCount: 0,
      );
      expect(d.changed, isFalse);
      expect(d.recommendedIntervalHours, 3);
    });

    test('무반응 3건이면 간격이 2배가 된다', () {
      final d = judgeCadence(
        currentIntervalHours: 3,
        sampleSize: 5,
        respondedCount: 2,
        noResponseCount: 3,
        acceptedCount: 0,
      );
      expect(d.recommendedIntervalHours, 6);
      expect(d.changed, isTrue);
    });
  });

  group('judgeCadence — 채택 임계값 경계(3건)', () {
    test('채택 2건이면 발동 안 함(유지)', () {
      final d = judgeCadence(
        currentIntervalHours: 6,
        sampleSize: 5,
        respondedCount: 5,
        noResponseCount: 0,
        acceptedCount: 2,
      );
      expect(d.changed, isFalse);
      expect(d.recommendedIntervalHours, 6);
    });

    test('채택 3건이면 간격이 절반이 된다', () {
      final d = judgeCadence(
        currentIntervalHours: 6,
        sampleSize: 5,
        respondedCount: 5,
        noResponseCount: 0,
        acceptedCount: 3,
      );
      expect(d.recommendedIntervalHours, 3);
      expect(d.changed, isTrue);
    });
  });

  group('judgeCadence — 상한·하한 클램프', () {
    test('12시간에서 무반응 3건이면 24시간이 아니라 상한 12시간에 머문다(변경 없음)', () {
      final d = judgeCadence(
        currentIntervalHours: 12,
        sampleSize: 5,
        respondedCount: 2,
        noResponseCount: 3,
        acceptedCount: 0,
      );
      expect(d.recommendedIntervalHours, 12);
      expect(d.changed, isFalse); // 상한에 이미 있어 값 자체는 안 바뀐다
    });

    test('8시간에서 무반응 3건이면 상한(12)을 넘지 않고 16이 아니라 12로 클램프', () {
      final d = judgeCadence(
        currentIntervalHours: 8,
        sampleSize: 5,
        respondedCount: 2,
        noResponseCount: 3,
        acceptedCount: 0,
      );
      expect(d.recommendedIntervalHours, 12);
      expect(d.changed, isTrue);
    });

    test('3시간(하한)에서 채택 3건이면 1시간이 아니라 하한 3시간에 머문다(변경 없음)', () {
      final d = judgeCadence(
        currentIntervalHours: 3,
        sampleSize: 5,
        respondedCount: 5,
        noResponseCount: 0,
        acceptedCount: 3,
      );
      expect(d.recommendedIntervalHours, 3);
      expect(d.changed, isFalse);
    });

    test('4시간에서 채택 3건이면 2시간이 아니라 하한 3시간으로 클램프', () {
      final d = judgeCadence(
        currentIntervalHours: 4,
        sampleSize: 5,
        respondedCount: 5,
        noResponseCount: 0,
        acceptedCount: 3,
      );
      expect(d.recommendedIntervalHours, 3);
      expect(d.changed, isTrue);
    });
  });

  group('judgeCadence — 두 조건의 상호 배타성(windowSize=5 표본에서는 구조적으로 동시 성립 불가)', () {
    test('무반응 3건 이상이면 acceptedCount가 아무리 커도(≤2) 채택 규칙 쪽으로는 안 간다', () {
      // sampleSize<=5, noResponseCount=3이면 respondedCount<=2이므로
      // acceptedCount<=2 — 이 조합 자체가 accept 임계값(3)에 못 미친다.
      // 이 제약이 실제로 지켜지는지(=우선순위 코드가 없어도 도달 못 함)를
      // 대표 조합으로 확인한다.
      final d = judgeCadence(
        currentIntervalHours: 3,
        sampleSize: 5,
        respondedCount: 2,
        noResponseCount: 3,
        acceptedCount: 2, // 이론상 최댓값
      );
      expect(d.recommendedIntervalHours, 6); // 2배 규칙(무반응)이 적용됨
    });

    test('채택 3건 이상이면 noResponseCount는 최대 2 — 무반응 규칙 쪽으로는 안 간다', () {
      final d = judgeCadence(
        currentIntervalHours: 6,
        sampleSize: 5,
        respondedCount: 3,
        noResponseCount: 2, // 이론상 최댓값
        acceptedCount: 3,
      );
      expect(d.recommendedIntervalHours, 3); // 절반 규칙(채택)이 적용됨
    });
  });

  group('judgeCadence — 유지 사유 문구', () {
    test('무반응·채택 둘 다 임계값 미달이면 유지 사유 문구를 남긴다', () {
      final d = judgeCadence(
        currentIntervalHours: 3,
        sampleSize: 5,
        respondedCount: 3,
        noResponseCount: 2,
        acceptedCount: 1,
      );
      expect(d.changed, isFalse);
      expect(d.signalReason, contains('유지'));
    });
  });

  group('CadencePolicyConfig(enabled: false) — diff 0 재현 (docs §9-1)', () {
    const disabled = CadencePolicyConfig(enabled: false);

    test('무반응 3건이어도(원래는 2배) 꺼져 있으면 그대로 유지 — 이 기능이 없던 상태와 산출물이 같다', () {
      final d = judgeCadence(
        currentIntervalHours: 3,
        sampleSize: 5,
        respondedCount: 2,
        noResponseCount: 3,
        acceptedCount: 0,
        config: disabled,
      );
      expect(d.changed, isFalse);
      expect(d.recommendedIntervalHours, 3);
    });

    test('채택 3건이어도(원래는 절반) 꺼져 있으면 그대로 유지', () {
      final d = judgeCadence(
        currentIntervalHours: 6,
        sampleSize: 5,
        respondedCount: 5,
        noResponseCount: 0,
        acceptedCount: 3,
        config: disabled,
      );
      expect(d.changed, isFalse);
      expect(d.recommendedIntervalHours, 6);
    });

    test('표본 부족이어도 꺼져 있으면 결과가 같다(둘 다 유지) — 이 경로는 원래도 유지라 구분이 안 되므로 changed만 확인', () {
      final d = judgeCadence(
        currentIntervalHours: 3,
        sampleSize: 2,
        respondedCount: 1,
        noResponseCount: 1,
        acceptedCount: 0,
        config: disabled,
      );
      expect(d.changed, isFalse);
      expect(d.recommendedIntervalHours, 3);
    });
  });

  group('CadencePolicyConfig 기본값 — 명시적으로 안 넘겨도 enabled 정책과 동일', () {
    test('config를 안 넘긴 호출과 CadencePolicyConfig()를 명시한 호출이 같은 결과를 낸다', () {
      final withoutConfig = judgeCadence(
        currentIntervalHours: 3,
        sampleSize: 5,
        respondedCount: 2,
        noResponseCount: 3,
        acceptedCount: 0,
      );
      final withDefaultConfig = judgeCadence(
        currentIntervalHours: 3,
        sampleSize: 5,
        respondedCount: 2,
        noResponseCount: 3,
        acceptedCount: 0,
        config: const CadencePolicyConfig(),
      );
      expect(withoutConfig.recommendedIntervalHours, withDefaultConfig.recommendedIntervalHours);
      expect(withoutConfig.changed, withDefaultConfig.changed);
    });
  });
}
