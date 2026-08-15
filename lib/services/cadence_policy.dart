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

const int _minIntervalHours = 3; // 하한 - 지금보다 더 자주는 안 간다(보수적 시작점)
const int _maxIntervalHours = 12; // 상한 - 클라이언트 _minInterval(10h)보다 약간 커, 최소 하루 한 번은 확인 기회가 남는다
const int _windowSize = 5;
const int _thresholdCount = 3; // windowSize 5건 중 3건 이상

// sampleSize < windowSize면 판정하지 않고 현재 간격을 유지한다
// (docs/task_agent_cadence_v1.md §4-3) - 반응할 시간도 없었는데 성급히
// 조정하는 비용이, 판정을 미뤄 기본값을 유지하는 비용보다 크다는 판단.
CadenceDecision judgeCadence({
  required int currentIntervalHours,
  required int sampleSize,
  required int respondedCount,
  required int noResponseCount,
  required int acceptedCount,
}) {
  if (sampleSize < _windowSize) {
    return CadenceDecision(
      recommendedIntervalHours: currentIntervalHours,
      changed: false,
      signalReason: '최근 추천이 $_windowSize건 미만이라(표본 $sampleSize건) 판정을 보류합니다',
    );
  }

  if (noResponseCount >= _thresholdCount) {
    final recommended = (currentIntervalHours * 2).clamp(_minIntervalHours, _maxIntervalHours);
    return CadenceDecision(
      recommendedIntervalHours: recommended,
      changed: recommended != currentIntervalHours,
      signalReason: '최근 추천 $sampleSize건 중 $noResponseCount건이 반응 없음을 감지했습니다',
    );
  }

  if (acceptedCount >= _thresholdCount) {
    final recommended = (currentIntervalHours ~/ 2).clamp(_minIntervalHours, _maxIntervalHours);
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
