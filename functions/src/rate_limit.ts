// 서버 프록시(callGeminiText) 호출량 상한 판정 — 순수 함수로 분리해
// Firestore/시각 의존 없이 단위 테스트한다(이 저장소의 검증 원칙,
// docs/task_matching_redesign_v1.md M1~M3와 같은 결).
//
// 근거: 논문 5.13.5/7.1 "프록시의 호출량 무제한" — 인증만 통과하면
// 계정 하나로 상한 없이 호출 가능한 상태를 닫는다.

export type RateLimitKind = "text" | "image";

export interface RateLimitState {
  bucket: string; // UTC 시간 버킷 "yyyymmddHH"
  textCount: number;
  imageCount: number;
  rejectedCount: number;
}

export interface RateLimitConfig {
  textLimit: number;
  imageLimit: number;
}

export interface RateLimitDecision {
  allowed: boolean;
  nextState: RateLimitState;
}

// KST 무관 — 고정 창이라 버킷 경계가 어느 타임존이든 판정 자체는 동일하다
// (kstMidnight처럼 사용자 날짜 표시에 맞출 필요가 없다). UTC를 그대로 쓴다.
export function utcHourBucket(date: Date): string {
  const y = date.getUTCFullYear();
  const m = String(date.getUTCMonth() + 1).padStart(2, "0");
  const d = String(date.getUTCDate()).padStart(2, "0");
  const h = String(date.getUTCHours()).padStart(2, "0");
  return `${y}${m}${d}${h}`;
}

function emptyState(bucket: string): RateLimitState {
  return {bucket, textCount: 0, imageCount: 0, rejectedCount: 0};
}

// current가 없거나(첫 호출) 버킷이 바뀌었으면(시간이 넘어감) 카운트를
// 전부 리셋한다. rejectedCount도 버킷 단위로 리셋한다 — "이번 시간에
// 상한이 몇 번 발화했는가"를 보는 관측치라, 누적하면 언제 발화가
// 몰렸는지 알 수 없다.
export function evaluateRateLimit(
  current: RateLimitState | undefined,
  now: Date,
  kind: RateLimitKind,
  config: RateLimitConfig
): RateLimitDecision {
  const bucket = utcHourBucket(now);
  const base = current && current.bucket === bucket ? current : emptyState(bucket);
  const limit = kind === "text" ? config.textLimit : config.imageLimit;
  const count = kind === "text" ? base.textCount : base.imageCount;

  if (count >= limit) {
    return {
      allowed: false,
      nextState: {...base, rejectedCount: base.rejectedCount + 1},
    };
  }

  const nextState: RateLimitState = kind === "text" ?
    {...base, textCount: base.textCount + 1} :
    {...base, imageCount: base.imageCount + 1};
  return {allowed: true, nextState};
}
