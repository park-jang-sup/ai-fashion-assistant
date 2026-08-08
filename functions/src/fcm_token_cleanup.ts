// FCM 무효 토큰 정리 판정 — 순수 함수로 분리해 단위 테스트한다
// (rate_limit.ts/payload_limit.ts와 같은 검증 원칙,
// docs/handoff_2026-08-07.md §6 "FCM 무효 토큰이 정리되지 않는다").
//
// 근거는 firebase-admin(이 저장소에 설치된 v14.2.0)
// node_modules/firebase-admin/lib/messaging/error.js의 각 에러 코드
// 설명 문구를 실제로 읽고 판단했다 — 추정이 아니라 실측.
//
// 판정 원칙: "토큰을 제거하라"는 지시가 SDK 에러 메시지에 명시된
// 코드만 삭제한다. 그 외 전부 유지 — 모르는 코드를 지우면 일시
// 오류(할당량/네트워크/서버 내부 오류 등)로 살아있는 토큰을 날릴 수
// 있고, 그러면 그 기기는 다음 앱 실행까지 푸시를 영영 못 받는다.
// 되돌리기 어려운 실수라 "모르면 유지"가 이 프로젝트의 폴백
// 방향(실패해도 아무것도 안 함)과 맞다.

export type TokenErrorAction = "delete" | "diagnostic" | "keep";

// 삭제 대상 — SDK 에러 메시지에 "Remove this ... and stop using it to
// send messages"가 명시된 코드만.
const DELETE_ON_CODES: ReadonlySet<string> = new Set([
  // "A previously valid registration token can be unregistered for a
  // variety of reasons... Remove this registration token and stop
  // using it to send messages." — 가장 흔한 죽은 토큰 신호(레거시
  // GCM/FCM 문서에서도 NotRegistered로 취급).
  "messaging/registration-token-not-registered",

  // "A previously valid installation ID... Remove this installation ID
  // and stop using it to send messages." — SDK 메시지가 명시적으로
  // 삭제를 지시하지만, **이 코드는 이 저장소에서 도달 불가능한
  // 경로다.** fcm_service.dart는 FirebaseMessaging.instance.getToken()
  // (등록 토큰)만 쓰고 Firebase Installations ID(FID)는 어디서도
  // 발급·저장하지 않는다 — sendEachForMulticast({tokens: [...]})에
  // 등록 토큰만 넘기므로 이 코드가 실제로 반환될 상황이 없다.
  // 그래도 지우지 않고 남겨두는 이유는 "완전성"이 아니라, 이 저장소가
  // shortfall 분기·_linkGoogleAccount처럼 도달 불가능한 경로를 지우지
  // 않고 그 사실을 코드에 남겨 나중에 이 프로젝트가 Installation ID를
  // 쓰게 되면(현재 계획 없음) 이 판정이 그대로 맞물리게 하는 것 —
  // 기존 관행을 그대로 따른 것이다.
  "messaging/installation-id-not-registered",
]);

// 삭제하지 않고 별도로 눈에 띄게 로깅만 하는 코드 — "안전" 때문이
// 아니라 "진단 가능성" 때문이다. 이 코드는 토큰 문자열 자체가
// 잘못됐다는 뜻인데, 원인이 (a) 기기에서 실제로 폐기된 토큰이거나
// (b) 클라이언트가 토큰을 저장하는 과정의 버그(예: 잘림)일 수 있다.
// 삭제해버리면 (b) 케이스에서 "삭제 → 다음 실행에 재등록 → 다시 잘려
// 저장 → 다음 발송에 다시 삭제"가 반복되며 churn만 남고 원인 신호가
// 사라진다 — 이 저장소가 겪은 "lastError가 도달 불가능해 원인을 잡을
// 수 없었던" 문제(FCM-DIAG 로그가 fcm_service.dart에 남아있는 이유와
// 같은 계열)와 같은 성격이다. 유지하면 같은 토큰이 계속 실패로 뜨고
// 로그에 남아 나중에 원인을 추적할 수 있다.
export const DIAGNOSTIC_ONLY_CODE = "messaging/invalid-registration-token";

export function classifyTokenError(errorCode: string | undefined): TokenErrorAction {
  if (!errorCode) return "keep";
  if (DELETE_ON_CODES.has(errorCode)) return "delete";
  if (errorCode === DIAGNOSTIC_ONLY_CODE) return "diagnostic";
  return "keep";
}

// tokens[i]와 responses[i]가 어긋나면 살아있는 토큰을 지우고 죽은
// 토큰을 남기는 사고가 난다 — 증상이 "가끔 푸시가 안 온다"라 원인
// 추적이 매우 어렵다. 이 함수는 그 매핑이 이미 올바르게 정렬돼
// 들어온다고 가정하지 않고, 인덱스가 아니라 토큰 문자열 자체로
// 결과를 반환해 호출부가 어떤 토큰에 어떤 조치가 필요한지 헷갈릴
// 여지를 없앤다.
export interface TokenSendResult {
  token: string;
  success: boolean;
  errorCode?: string;
}

export interface TokenCleanupPlan {
  token: string;
  action: "delete" | "diagnostic";
  errorCode: string;
}

// 순수 함수 — Firestore 접근 없음, 실제로 지울 대상과 진단 로그만
// 낼 대상을 계산만 한다. 실행(삭제·로깅)은 호출부 책임.
export function planTokenCleanup(results: TokenSendResult[]): TokenCleanupPlan[] {
  const plan: TokenCleanupPlan[] = [];
  for (const r of results) {
    if (r.success) continue;
    const action = classifyTokenError(r.errorCode);
    if (action === "keep") continue;
    plan.push({token: r.token, action, errorCode: r.errorCode ?? "(코드 없음)"});
  }
  return plan;
}
