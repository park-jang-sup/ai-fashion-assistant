// 서버 프록시(callGeminiText) 호출량 상한 판정 — 순수 함수로 분리해
// Firestore/시각 의존 없이 단위 테스트한다(이 저장소의 검증 원칙,
// docs/task_matching_redesign_v1.md M1~M3와 같은 결).
//
// 근거: 논문 5.13.5/7.1 "프록시의 호출량 무제한" — 인증만 통과하면
// 계정 하나로 상한 없이 호출 가능한 상태를 닫는다.

// "sign"은 getSignedImageUrls(docs/task_signed_urls_v1.md A-2) 호출 계측용
// — textCount/imageCount와 섞이지 않게 signCount를 별도 필드로 둔다
// (표본 오염 금지 원칙의 연장, §3-3).
export type RateLimitKind = "text" | "image" | "sign";

export interface RateLimitState {
  bucket: string; // UTC 시간 버킷 "yyyymmddHH"
  textCount: number;
  imageCount: number;
  signCount: number;
  rejectedCount: number;
}

export interface RateLimitConfig {
  textLimit: number;
  imageLimit: number;
  signLimit: number;
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
  return {bucket, textCount: 0, imageCount: 0, signCount: 0, rejectedCount: 0};
}

// current가 있어도 같은 버킷 안이라면 그대로 이어받는다 — 다만 카운트
// 필드는 ?? 0으로 방어한다. rate_limits 문서는 스키마가 시간이 지나며
// 늘어날 수 있고(signCount가 그 사례 — 기존 문서엔 없던 필드), 새 필드가
// undefined인 상태로 산술하면(undefined + 1) NaN이 그대로 Firestore에
// 저장돼 그 뒤로 그 버킷은 영원히 상한 판정이 깨진다.
function carryOver(current: RateLimitState, bucket: string): RateLimitState {
  return {
    bucket,
    textCount: current.textCount ?? 0,
    imageCount: current.imageCount ?? 0,
    signCount: current.signCount ?? 0,
    rejectedCount: current.rejectedCount ?? 0,
  };
}

function countField(kind: RateLimitKind): "textCount" | "imageCount" | "signCount" {
  if (kind === "text") return "textCount";
  if (kind === "image") return "imageCount";
  return "signCount";
}

function limitFor(kind: RateLimitKind, config: RateLimitConfig): number {
  if (kind === "text") return config.textLimit;
  if (kind === "image") return config.imageLimit;
  return config.signLimit;
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
  const base = current && current.bucket === bucket ? carryOver(current, bucket) : emptyState(bucket);
  const field = countField(kind);
  const limit = limitFor(kind, config);
  const count = base[field];

  if (count >= limit) {
    return {
      allowed: false,
      nextState: {...base, rejectedCount: base.rejectedCount + 1},
    };
  }

  const nextState: RateLimitState = {...base, [field]: base[field] + 1};
  return {allowed: true, nextState};
}
