// 발화 정책 자기 조정 - 서버 측 게이트(docs/task_agent_cadence_v1.md §8)의
// 판정만 순수 함수로 분리한다. Firestore 읽기는 index.ts의
// isCadenceGateBlocking(얇은 래퍼)이 맡는다 - rate_limit.ts의
// evaluateRateLimit과 같은 결(Firestore/시각 의존 없이 단위 테스트).
//
// adjustedIntervalHours(클라이언트 judgeCadence가 낸 값)와
// serverLastSentAt(마지막으로 실제 발송을 시도한 시각 - "체크인
// 시각"(serverLastRunAt)과 다르다, index.ts의 recordServerInvocation
// 주석 참고) 둘 다 있을 때만 게이트가 작동한다. 하나라도 없으면(아직
// 한 번도 조정 안 됨, 또는 한 번도 발송 안 함) 항상 false(막지 않음) -
// 이 기능 도입 이전 동작(findNextUntriggeredDate만으로 판정)과 diff 0.
export function evaluateCadenceGate(params: {
  nowMs: number;
  adjustedIntervalHours: number | undefined;
  serverLastSentAtMs: number | undefined;
}): boolean {
  const {nowMs, adjustedIntervalHours, serverLastSentAtMs} = params;
  if (adjustedIntervalHours == null || serverLastSentAtMs == null) {
    return false;
  }
  const elapsedMs = nowMs - serverLastSentAtMs;
  const requiredMs = adjustedIntervalHours * 60 * 60 * 1000;
  return elapsedMs < requiredMs;
}
