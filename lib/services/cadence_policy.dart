// 발화 정책 자기 조정(docs/task_agent_cadence_v1.md §4~§5)의 판정부 —
// "반응이 이랬으니 간격을 이렇게 바꾼다"만 순수 함수로 결정한다. 입력은
// response_signal.dart의 산출값(ResponseSignal)만 받고 RecommendationEntry나
// Firestore를 전혀 모른다 — 산출부(입력)가 나중에 (a)의 발송-탭 매칭
// 데이터로 교체돼도 이 판정 규칙과 아래 단위 테스트는 그대로 쓴다는 것이
// 이 분리의 목적이다(TpoMatchPolicy가 정책을 재료와 분리한 것과 같은 발상,
// lib/services/outfit_matcher.dart:56 참고).

class CadenceDecision {
  final int recommendedIntervalHours;
  final bool changed; // recommendedIntervalHours != currentIntervalHours
  // 진단·활동 로그에 그대로 쓸 근거 문장. "판정을 왜 이렇게 했는가"만
  // 담는다 - "간격을 N에서 M으로 조정합니다"는 호출부가 currentIntervalHours와
  // 비교해 스스로 만든다(agent_meta 배선 단계, docs §6-1).
  final String signalReason;

  const CadenceDecision({
    required this.recommendedIntervalHours,
    required this.changed,
    required this.signalReason,
  });
}

// TpoMatchPolicy(outfit_matcher.dart:56)와 같은 발상 — 판정 규칙의 값을
// 재료(ResponseSignal)와 분리된 정책 객체로 빼서, 기본값이 "지금 배포된
// 동작"을 정확히 재현하도록 만든다. `enabled: false`가 그 재현체다 —
// 이 값을 쓰면 sampleSize·noResponseCount·acceptedCount가 무엇이든
// 항상 "유지"만 반환하므로, 이 기능이 아예 없던 이전 상태(agent_meta에
// adjustedIntervalHours가 결코 쓰이지 않는 상태)와 산출물이 diff 0이다.
// 배포 시 기본값은 `enabled: true`(아래 CadenceDecision을 실제로 쓴다) —
// off 상태는 "혹시 되돌려야 할 때"를 위한 스위치로 존재하는 것이지,
// 배포 기본값이 꺼진 채로 나가지 않는다.
class CadencePolicyConfig {
  final bool enabled;
  final int windowSize;
  final int thresholdCount; // windowSize건 중 몇 건이면 발동하는지
  final int minIntervalHours; // 하한 - 지금보다 더 자주는 안 간다(보수적 시작점)
  final int maxIntervalHours; // 상한 - 클라이언트 _minInterval(10h)보다 약간 커, 최소 하루 한 번은 확인 기회가 남는다

  const CadencePolicyConfig({
    this.enabled = true,
    this.windowSize = 5,
    this.thresholdCount = 3,
    this.minIntervalHours = 3,
    this.maxIntervalHours = 12,
  });
}

// sampleSize < windowSize면 판정하지 않고 현재 간격을 유지한다
// (docs/task_agent_cadence_v1.md §4-3) - 반응할 시간도 없었는데 성급히
// 조정하는 비용이, 판정을 미뤄 기본값을 유지하는 비용보다 크다는 판단.
CadenceDecision judgeCadence({
  required int currentIntervalHours,
  required int sampleSize,
  required int respondedCount,
  required int noResponseCount,
  required int acceptedCount,
  CadencePolicyConfig config = const CadencePolicyConfig(),
}) {
  if (!config.enabled) {
    return CadenceDecision(
      recommendedIntervalHours: currentIntervalHours,
      changed: false,
      signalReason: '발화 정책 자기 조정이 꺼져 있어 현재 간격을 유지합니다',
    );
  }

  if (sampleSize < config.windowSize) {
    return CadenceDecision(
      recommendedIntervalHours: currentIntervalHours,
      changed: false,
      signalReason:
          '최근 추천이 ${config.windowSize}건 미만이라(표본 $sampleSize건) 판정을 보류합니다',
    );
  }

  if (noResponseCount >= config.thresholdCount) {
    final recommended =
        (currentIntervalHours * 2).clamp(config.minIntervalHours, config.maxIntervalHours);
    return CadenceDecision(
      recommendedIntervalHours: recommended,
      changed: recommended != currentIntervalHours,
      signalReason: '최근 추천 $sampleSize건 중 $noResponseCount건이 반응 없음을 감지했습니다',
    );
  }

  if (acceptedCount >= config.thresholdCount) {
    final recommended =
        (currentIntervalHours ~/ 2).clamp(config.minIntervalHours, config.maxIntervalHours);
    return CadenceDecision(
      recommendedIntervalHours: recommended,
      changed: recommended != currentIntervalHours,
      signalReason: '최근 추천 $sampleSize건 중 $acceptedCount건이 채택됨을 감지했습니다',
    );
  }

  return CadenceDecision(
    recommendedIntervalHours: currentIntervalHours,
    changed: false,
    signalReason: '최근 추천 $sampleSize건의 반응이 뚜렷한 경향을 보이지 않아 간격을 유지합니다',
  );
}
