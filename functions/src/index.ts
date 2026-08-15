import {randomUUID} from "node:crypto";
import {onCall, HttpsError} from "firebase-functions/v2/https";
import {onSchedule} from "firebase-functions/v2/scheduler";
import {onObjectFinalized} from "firebase-functions/v2/storage";
import {defineSecret} from "firebase-functions/params";
import {initializeApp} from "firebase-admin/app";
import {getFirestore, Timestamp, FieldValue} from "firebase-admin/firestore";
import {getMessaging, SendResponse} from "firebase-admin/messaging";
import {getStorage} from "firebase-admin/storage";
import {evaluateRateLimit, RateLimitConfig, RateLimitKind, RateLimitState} from "./rate_limit";
import {evaluatePayloadLimit, kindForModel, PAYLOAD_LIMIT_CONFIG} from "./payload_limit";
import {planTokenCleanup, TokenSendResult} from "./fcm_token_cleanup";
import {
  decideSignedUrlAccess,
  validateBatch,
  MAX_BATCH_SIZE,
  DocFields,
  SignedUrlCollection,
  SignedUrlRequestItem,
} from "./signed_url_policy";
import {buildFittingCacheKey} from "./fitting_cache_key";
import {verifyFittingOwnership} from "./fitting_ownership_policy";
import {evaluateRequestShape, REQUEST_SHAPE_CONFIG, RequestShapeDecision} from "./request_shape";

// firebase-admin 14.x부터 admin.firestore()/admin.messaging() 같은
// 네임스페이스 호환 API가 최상위 export에서 빠졌다 - getFirestore()/
// getMessaging() 모듈형 API를 직접 써야 한다.
initializeApp();

const geminiApiKey = defineSecret("GEMINI_API_KEY");

// notification_service.dart(로컬 알림)와 반드시 같은 채널을 써야 한다 -
// B단계 함정 6. 다르면 사용자가 알림 설정을 두 번 관리해야 한다.
const FCM_NOTIFICATION_CHANNEL_ID = "agent_recommendation";

// 이 함수는 텍스트/이미지 양쪽 모델을 중계한다. 이름이 Text인 것은
// A-1에서 텍스트만 옮겼기 때문이고 A-2에서 이미지 모델이 추가됐다.
// 이름을 바꾸려면 클라이언트 호출명과 함께 바꾸고 재배포해야 한다.
//
// 클라이언트 GeminiService의 _textModel/textModelFallback/_imageModel과 이
// 배열은 반드시 같은 커밋에서 함께 바꾼다. 어긋나면 폴백 경로만 조용히
// invalid-argument로 죽는다 - 이 저장소는 모델을 이미 두 번 갈아탔다
// (gemini-3-flash-preview → 3.5-flash, 2.5-flash → 3.1-flash-lite).
const ALLOWED_MODELS = [
  "gemini-3.5-flash",
  "gemini-3.1-flash-lite",
  // A-2: 가상 피팅 이미지 합성(Nano Banana 2). 텍스트 계열과 요청/응답
  // 스키마가 다르지만(inlineData 여러 장, responseModalities: IMAGE),
  // 서버는 requestBody를 가공 없이 그대로 중계하므로 화이트리스트에만
  // 추가하면 된다 - 별도 처리 분기가 필요 없다.
  "gemini-3.1-flash-image",
];

const GEMINI_BASE_URL = "https://generativelanguage.googleapis.com/v1beta";

// 요청 본문 스키마 강제(S3-c, docs/task_hardening_v2.md §4) - 2026-08-11,
// §4-3의 전환 조건 4가지(5경로 실행·allowed=false 0건·evaluator_failed
// 0건·5경로 전부 로그 관측)를 확인한 뒤 true로 전환했다. 상한값
// (request_shape.ts)은 이번 전환에서 실측 최댓값이 아니라 "코드가
// 만들 수 있는 최댓값"(한 번에 방식 가상 피팅 등 미실행 경로 포함)
// 기준으로 재산정했다 - request_shape.ts 상단 주석 참고.
//
// 거부 위치는 여전히 checkAndRecordRateLimit보다 앞이다 - 형식이
// 틀린 요청 때문에 정상 사용자의 시간당 할당량이 깎이면 안 된다는
// 원칙은 바뀌지 않았다. 이 트레이드오프(값싼 거부의 반복)의 천장은
// S1의 maxInstances가 잡는다.
//
// 롤백 경로: 이 플래그는 코드 상수이므로 되돌리려면 재배포가
// 필요하다 - S2-b(App Check 강제)와 같은 제약이다. 다만 실패
// 방향은 다르다 - App Check 강제가 잘못되면 6개 onCall 전부가
// 한꺼번에 막히지만(§1 순서 근거, "앱 전면 정지"), 이 스키마
// 강제가 잘못되면 특정 요청 형태(위반으로 오판된 경로)만 막히고
// 나머지는 산다 - 장애 범위가 좁다는 뜻이지, 검증을 건너뛰어도
// 된다는 뜻은 아니다. 그래서 전환 후 검증에서 5경로를 전부 다시
// 돌아야 한다(§4-3 "전환 후 검증" 참고) - 국소 장애는 사용자가
// "그 기능만" 이상하다고 느끼는 형태라 오히려 원인 추적이 늦어질
// 수 있다.
const REQUEST_SHAPE_ENFORCE = true;

// callGeminiText/generateFittingImage 두 곳에서 동일한 형식으로 로그를
// 남긴다 - [appCheck] 계측에서 reqId 유무로 형식이 갈렸던 것과 달리
// 이번은 두 함수 모두 reqId가 있으므로 갈릴 이유가 없다. 공용 함수로
// 묶어 형식이 실수로 갈리는 것 자체를 구조적으로 막는다.
//
// metrics는 위반 여부와 무관하게 항상 남긴다 - 상한을 조이는 근거가
// 정상 요청의 분포이므로, 통과한 요청의 수치가 오히려 핵심 데이터다.
// §3-3-1에서 "증거 수집 필터가 찾으려는 상태의 이름에 의존해 다른
// 상태를 구조적으로 못 보게 만들었다"는 사건이 있었으므로, 여기서는
// 처음부터 전량 기록해 같은 사각을 만들지 않는다.
function logRequestShape(fn: string, reqId: string, uid: string, shape: RequestShapeDecision): void {
  console.log(
    `[requestShape] fn=${fn} reqId=${reqId} uid=${uid} ` +
      `allowed=${shape.allowed} violations=${shape.violations.join("|") || "-"} ` +
      `contents=${shape.metrics.contentsCount} ` +
      `maxParts=${shape.metrics.maxPartsInAnyContent} ` +
      `textChars=${shape.metrics.totalTextChars} ` +
      `inline=${shape.metrics.inlineDataCount}`
  );
}

// 업스트림이 멈추면 함수 자체 타임아웃까지 무한정 붙들리므로, 클라이언트의
// 기존 .timeout(60초)와 같은 의도로 그보다 살짝 짧게 직접 끊는다.
//
// [2026-08-08 측정용 임시 상향] 원래 값 55_000(55초) - 이미지 모델
// (gemini-3.1-flash-image) 호출이 본인·심사용 두 계정, 서로 다른 이미지
// 조합에서 반복적으로 정확히 55초 근처에서 abort되는 게 계측으로
// 확인됐다(handoff_2026-08-07.md "업스트림 이미지 생성이 55초를 넘겨
// 실패"). 55초가 실제 업스트림 소요시간인지 그보다 훨씬 긴 지연/무응답인지
// 이 값 자체가 가려서 알 수 없었다 - 그래서 300초(5분)로 늘려 실제
// 소요시간 분포를 처음 측정한다. **되돌릴 조건: 위 분포를 확보한 시점 -
// 그때 55_000(원래 값)으로 되돌리고, 필요하면 그 분포에 맞는 근거 있는
// 값으로 다시 정한다. 이 상수를 55_000이 아닌 다른 값으로 또 바꾸려면
// 반드시 그 근거(측정한 분포)를 이 주석 옆에 남길 것.**
const UPSTREAM_TIMEOUT_MS = 300_000;

function extractUpstreamErrorMessage(rawBody: string): string {
  try {
    const parsed = JSON.parse(rawBody);
    return (parsed?.error?.message as string | undefined) ?? "알 수 없는 오류";
  } catch {
    return "알 수 없는 오류";
  }
}

// docs/task_selfeval_validity_v1.md §6-가 "폴백 상태코드 규명 시도"(2026-08-12)
// - 실패 경로의 catch-all 로거가 HttpsError.details에 이미 실려 있는
// upstreamStatus를 안 읽어 503/429를 사후에 구분할 수 없었던 계측 공백을
// 메운다. 값을 새로 만드는 게 아니라 이미 던져둔 details(423-429행·
// 455-461행 등)를 읽기만 한다 - 제어 흐름은 바꾸지 않는다.
function extractUpstreamStatus(err: unknown): number | undefined {
  if (!(err instanceof HttpsError)) return undefined;
  const details = err.details;
  if (details === null || typeof details !== "object") return undefined;
  const status = (details as {upstreamStatus?: unknown}).upstreamStatus;
  return typeof status === "number" ? status : undefined;
}

// reqId/startedAt는 계측용 상관 키 - callGeminiText의 시작 로그와 같은
// 키로 묶여야 여러 요청이 겹칠 때(동시 사용자·재시도) 어느 시작에 어느
// 완료/abort가 대응하는지 알 수 있다(handoff_2026-08-08 "업스트림 이미지
// 생성이 55초를 넘겨 실패" 계측 설계).
async function fetchUpstream(
  endpoint: string,
  body: string,
  reqId: string,
  startedAt: number
): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => {
    // abort()가 실제로 발동했는지를 로그로 직접 남긴다 - 이전엔 이 시점을
    // 알 방법이 없어 "55초를 넘겼다"를 함수 로그의 침묵으로부터 추론해야
    // 했다(handoff_2026-08-07.md "업스트림 이미지 생성이 55초를 넘겨 실패").
    console.log(
      `[callGeminiText] upstream-abort reqId=${reqId} elapsedMs=${Date.now() - startedAt}`
    );
    controller.abort();
  }, UPSTREAM_TIMEOUT_MS);
  try {
    return await fetch(endpoint, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        // 원래 클라이언트에 있던 헤더를 서버로 옮길 때 누락된 것을 복원.
        // 클라이언트가 Gemini를 직접 호출하던 시절엔 gzip 응답 버퍼링을
        // 피하려고 Accept-Encoding: identity를 붙였었다. 서버 이전 시
        // 이 헤더가 함께 옮겨지지 않아 복원했으나, 짧은 응답(analyzeOutfit
        // 스트리밍, 약 100자)에서는 [TIMING] 첫 청크~전체 완료 간격이
        // 추가 전(200~230ms)과 후(243~255ms)로 사실상 동일해 효과가
        // 관측되지 않았다 - 원인이 압축이 아니라 Gemini가 짧은 응답을
        // 애초에 한 번에 방출하는 것일 가능성이 있다(handoff_2026-08-01.md
        // §2-9 참고). 유해하지는 않고 응답이 긴 경로(주간 플랜 등)에서는
        // 값을 할 수 있어 제거하지 않고 유지한다.
        "Accept-Encoding": "identity",
      },
      body,
      signal: controller.signal,
    });
  } catch (err) {
    // 이 55초 어보트는 클라이언트의 HttpsCallableOptions.timeout(60초)보다
    // 먼저 발동한다. AbortError를 여기서 deadline-exceeded로 명시하지
    // 않으면 fetch가 그냥 예외를 던지고 끝나 함수 핸들러가 처리 안 된
    // 예외로 죽고, Functions 프레임워크가 이걸 디테일 없는 internal로
    // 뭉개버린다 - 그러면 클라이언트의 _mapProxyException은
    // deadline-exceeded 매핑도, upstreamStatus 매핑도 둘 다 못 걸려
    // withTextModelFallback의 폴백이 무력화된다(실제로 릴리스 빌드에서
    // planWeeklyOutfits가 이렇게 죽는 걸 확인했다).
    if (err instanceof Error && err.name === "AbortError") {
      throw new HttpsError("deadline-exceeded", "Gemini 응답이 지연되고 있습니다.");
    }
    // AbortError가 아닌 나머지(DNS 실패·연결 끊김 등 네트워크 자체 실패)도
    // 잡지 않으면 같은 구멍으로 디테일 없는 internal에 빠진다. upstreamStatus는
    // 만들 수 없지만(Gemini가 응답 자체를 안 준 상황) 최소한 원인 메시지는
    // 실어 보내 로그·디버깅에서 "그냥 internal"보다 더 알 수 있게 한다.
    const message = err instanceof Error ? err.message : String(err);
    throw new HttpsError("internal", `업스트림 요청 실패: ${message}`);
  } finally {
    clearTimeout(timer);
  }
}

// 프록시 호출량 상한(논문 5.13.5/7.1 "프록시의 호출량 무제한") — 값은
// 사람이 정상 사용하는 패턴으로는 도달 불가능하고 스크립트 남용만
// 차단하는 수준으로 잡았다. **배포 전 실제 값은 사용자 확인이 필요하다.**
//   텍스트 60/시간: 옷 등록 시 속성 추출(옷 1벌당 1회) + 추천/분석/주간
//     플랜 등을 활발히 써도 시간당 수십 건을 넘기기 어렵다.
//   이미지 20/시간: 가상 피팅 1건이 12.7초 안팎 걸려, 사람이 시간당
//     20건을 연달아 누르는 것 자체가 비현실적이다(handoff 실측 근거).
//   서명(sign) 120/시간: 텍스트·이미지와 잣대가 다르다 — (1) 서명은
//     무료 IAM 호출이라 이 상한의 목적이 비용이 아니라 스크립트 남용
//     차단뿐이다. 정상 사용 대비 여유를 크게 둬도 목적이 훼손되지
//     않는다. (2) ImageUrlResolver의 캐시가 메모리라(A-3, Firestore
//     비영속) 콜드스타트마다 재발급된다 — 검증 세션(반복 설치 + 화면
//     순회)이 낮은 상한(30 등)에는 실제로 닿을 수 있다. (3) Phase C
//     이후에는 초과 시 레거시 URL 폴백이 없어(토큰 회수로 구 URL 자체가
//     죽음) 이미지가 시간 단위로 깨진다 — 오발 거부의 비용이 크다.
// imageLimit 20->32(docs/task_sequential_fitting_v1.md §d): 순차 합성이
// 피팅 1회당 옷 개수만큼 image 호출을 쓰므로, fittingLimit(아래)×실사용
// 벌 수 여유를 흡수할 만큼 올렸다 — 정확한 코디보드 슬롯 분포 실측은
// 아님(문서 §d에 한계로 등록), 남용 방지라는 image 상한의 원래 목적은
// fittingLimit이 "피팅 시도 자체"를 더 촘촘히 제한해 대신 지킨다.
const RATE_LIMIT_CONFIG: RateLimitConfig = {
  textLimit: 60,
  imageLimit: 32,
  signLimit: 120,
  fittingLimit: 6,
};

// rate_limits/{uid} 문서는 firestore.rules에 대응 match 블록이 없어
// 기본 거부다(의도적 — firestore.rules 주석 참고). 클라이언트가 자기
// 카운터를 읽거나 지워 상한을 우회할 수 없다.
//
// 실패 방향은 열림(fail-open) — 카운터 읽기/쓰기가 실패하면 호출을
// 허용하고 console.error만 남긴다. recordServerInvocation과 같은 결:
// 계측/제어 장치의 고장이 서비스 전체 중단으로 번지면 안 된다.
//
// 트랜잭션으로 감싸는 이유는 recordServerInvocation과 동일 — RMW
// 경합(같은 uid가 짧은 간격으로 여러 번 호출) 없이 카운트가 정확해야
// 상한이 의미가 있다.
async function checkAndRecordRateLimit(uid: string, kind: RateLimitKind): Promise<void> {
  const db = getFirestore();
  const docRef = db.collection("rate_limits").doc(uid);

  let decision;
  try {
    decision = await db.runTransaction(async (tx) => {
      const snap = await tx.get(docRef);
      const current = snap.exists ? (snap.data() as RateLimitState) : undefined;
      const result = evaluateRateLimit(current, new Date(), kind, RATE_LIMIT_CONFIG);
      tx.set(docRef, result.nextState);
      return result;
    });
  } catch (err) {
    console.error(`[rateLimit] 판정 실패, 호출 허용(fail-open) uid=${uid} kind=${kind}:`, err);
    return;
  }

  if (!decision.allowed) {
    console.log(`[rateLimit] 초과 uid=${uid} kind=${kind} bucket=${decision.nextState.bucket}`);
    throw new HttpsError(
      "resource-exhausted",
      "호출량이 많아 잠시 후 다시 시도해주세요."
    );
  }
}

// 텍스트 계열 Gemini 호출을 그대로 중계하는 단순 프록시. 클라이언트가 만든
// requestBody를 가공 없이 그대로 넘기고, 응답도 원본 JSON을 그대로 돌려준다.
// 여기서 텍스트를 뽑아버리면 클라이언트의 _extractTextFromResponse류 파싱이
// 서버·클라이언트 두 벌이 되어, withTextModelFallback을 서버로 옮기지 않기로
// 한 이유(모델 폴백 판정에 필요한 FormatException은 호출부마다 다른 JSON
// 파싱에서 나온다)가 축소판으로 재발한다. 모델 선택·재시도 판단은 전부
// 클라이언트(withTextModelFallback)의 몫으로 남긴다.
// [2026-08-08 측정용 임시 상향] 원래 값 60(60초) - UPSTREAM_TIMEOUT_MS를
// 300초로 올린 것과 같은 세트. abort(300초)보다 여유가 있어야 abort 로그
// 자체가 찍히고 함수가 깨끗하게 HttpsError를 반환한다(안 그러면 GCF
// 런타임이 이 값에서 먼저 강제 종료시켜 위 upstream-abort 로그가 찍히기
// 전에 잘린다). **되돌릴 조건: UPSTREAM_TIMEOUT_MS와 동시에 - 업스트림
// 소요시간 분포를 확보하면 60(원래 값)으로, 또는 그 분포에 맞는 값으로
// 되돌린다.**
// maxInstances(S1/3) - 이 함수를 포함해 아래 9개 서버 함수에 공통 적용되는
// 근거: 현재 사용자 규모는 n=1이고, 동시 호출이 나오는 유일한 경로(옷 N벌
// 순차 합성 = 호출 N회)도 클라이언트가 직렬로 돈다 - 즉 정상 사용에서
// 동시 인스턴스가 2를 넘을 일이 없다. 따라서 아래 값들은 "정상 사용의
// 상한"이 아니라 "비정상 사용(버그·남용)의 천장"이다. 실사용자가 붙으면
// 반드시 재산정해야 한다.
export const callGeminiText = onCall(
  {secrets: [geminiApiKey], region: "asia-northeast3", timeoutSeconds: 320, maxInstances: 10},
  async (request, response) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "로그인이 필요합니다.");
    }

    // 완료·실패 로그 부재로 5.19.2류 증상(무한 로딩 vs 정상 실패)을 구분 못
    // 했던 계측 공백을 메운다(handoff_2026-08-08). reqId는 시작 로그와
    // 완료 로그를 묶는 상관 키 - 동시 요청이 섞여도 어느 시작에 어느
    // 완료가 대응하는지 알 수 있어야 한다.
    const reqId = randomUUID().slice(0, 8);
    const startedAt = Date.now();

    // [appCheck] 계측(S2-a, docs/task_hardening_v2.md §3-2) - 강제
    // (enforceAppCheck)는 이번 커밋에서 넣지 않는다. firebase-functions v2는
    // 유효한 App Check 토큰이 검증됐을 때만 request.app을 채우고, 이는
    // enforceAppCheck가 false여도 마찬가지다 - 즉 강제 이전에도 "실제 호출이
    // 토큰을 싣고 오는가"를 관측할 수 있다. 판정 기준(축1 포그라운드
    // hasApp=true 100% / 축2 백그라운드 hasApp=false 최소 1회)은 §3-3에
    // 사전 등록되어 있다.
    // reqId 있는 자리에 로그를 둔다 - auth 검사 직후(230행)에 두면 reqId가
    // 아직 없어 위 [callGeminiText] start/done 로그와 상관시킬 수 없다.
    // generateFittingImage도 같은 이유로 같은 자리(reqId 생성 직후)에 둔다 -
    // 나머지 4개 onCall은 reqId가 없으므로 auth 검사 직후에 그대로 둔다.
    console.log(
      `[appCheck] fn=callGeminiText uid=${request.auth.uid} reqId=${reqId} ` +
        `hasApp=${request.app != null}`
    );

    const {model, requestBody} = (request.data ?? {}) as {
      model?: unknown;
      requestBody?: unknown;
    };
    if (typeof model !== "string" || !ALLOWED_MODELS.includes(model)) {
      throw new HttpsError("invalid-argument", `허용되지 않은 모델: ${String(model)}`);
    }
    if (requestBody === null || typeof requestBody !== "object") {
      throw new HttpsError("invalid-argument", "requestBody가 필요합니다.");
    }

    const requestBodyJson = JSON.stringify(requestBody);
    // A-2 이미지 경로 페이로드 실측용 - 핸드오프의 "3.5MB 안팎" 추산을
    // 실측치로 바꾸는 목적. 값 자체(옷 이미지 base64)는 로그에 남기지
    // 않고 바이트 수만 남긴다. 이 값을 아래 페이로드 크기 상한 판정이
    // 그대로 재사용한다 - 대용량 페이로드에서 JSON.stringify를 두 번
    // 하는 비용을 피한다.
    const requestBytes = Buffer.byteLength(requestBodyJson, "utf8");
    console.log(
      `[callGeminiText] start reqId=${reqId} uid=${request.auth.uid} ` +
        `model=${model} requestBytes=${requestBytes}`
    );

    // 호출량 상한과 같은 model→kind 파생을 쓴다(payload_limit.ts
    // kindForModel - 단일 출처, 이전엔 여기 인라인 삼항연산자였다).
    const kind = kindForModel(model);

    // 요청 본문 스키마 계측(S3-b) - 페이로드 크기 검사보다 앞에 둔다.
    // 형식이 틀린 요청이 아래 checkAndRecordRateLimit에 도달해 정상
    // 사용자의 할당량을 깎으면 안 된다는, 페이로드 크기 검사를 호출량
    // 상한보다 앞에 둔 기존 설계판단(아래 "설계판단(가)")과 같은
    // 근거다 - 그 트레이드오프의 천장은 S1의 maxInstances가 잡는다.
    // request_shape.ts는 총체적이라(예외를 던지지 않는다) 이 try/catch에
    // 도달하지 않아야 정상이다 - 도달했다면 그 자체가 evaluateRequestShape의
    // 결함이므로 로그로 드러내되, 서버의 fail-open 원칙(5.21.7)에 따라
    // 요청은 통과시킨다(shape를 null로 두고 아래 로그·강제 분기를 건너뛴다).
    let shape: RequestShapeDecision | null;
    try {
      shape = evaluateRequestShape(requestBody, kind, REQUEST_SHAPE_CONFIG);
    } catch (e) {
      console.log(`[requestShape] evaluator_failed reqId=${reqId} err=${String(e)}`);
      shape = null;
    }
    if (shape) {
      logRequestShape("callGeminiText", reqId, request.auth.uid, shape);
      if (!shape.allowed && REQUEST_SHAPE_ENFORCE) {
        throw new HttpsError("invalid-argument", "허용되지 않은 요청 형식입니다.", {
          violations: shape.violations,
        });
      }
    }

    // 페이로드 크기 상한(handoff_2026-08-07.md §6 (4)) - 근거·상한값
    // 도출 과정은 payload_limit.ts 상단 주석 참고.
    //
    // 설계판단(가): 이 검사를 호출량 상한(checkAndRecordRateLimit)보다
    // 앞에 둔다. 상한 초과 요청은 현실적으로 악의적 남용이 아니라
    // 클라이언트 버그 조건(예: 리사이즈 누락)에 가깝고, 그런 요청
    // 때문에 정상 사용자의 시간당 호출 할당량이 깎이면 안 된다. 대가로
    // "값싼 거부를 무제한 반복"할 수 있는 문이 열리지만 - 이 경로는
    // Gemini를 타지 않으므로 비용은 함수 호출 자체뿐이다. 그 천장은
    // maxInstances가 잡는다(S1/3 - 위 onCall 옵션에 설정 완료, 근거는
    // 옵션 바로 위 주석 참고) - 이 트레이드오프의 다른 절반을 닫았다.
    const payloadDecision = evaluatePayloadLimit(requestBytes, kind, PAYLOAD_LIMIT_CONFIG);
    if (!payloadDecision.allowed) {
      console.log(
        `[payloadLimit] 초과 uid=${request.auth.uid} kind=${kind} ` +
          `requestBytes=${requestBytes} limitBytes=${payloadDecision.limitBytes}`
      );
      // 설계판단(나): upstream 오류가 details에 upstreamStatus/
      // upstreamMessage를 싣는 것과 같은 형식으로, 로그 없이도 원인을
      // 알 수 있게 requestBytes/limitBytes/kind를 싣는다.
      console.log(
        `[callGeminiText] done reqId=${reqId} elapsedMs=${Date.now() - startedAt} ` +
          "outcome=rejected reason=payload_limit"
      );
      throw new HttpsError("invalid-argument", "요청 페이로드가 너무 큽니다.", {
        requestBytes,
        limitBytes: payloadDecision.limitBytes,
        kind,
      });
    }

    // 이 아래(호출량 상한 이후)는 outcome을 아직 모른 채로 여러 실패 지점
    // (rate limit/data-loss/internal/invalid-json/성공)으로 갈라지므로,
    // 하나의 try/catch로 감싸 완료 로그 한 줄을 반드시 남긴다 - 어느
    // 경로로 끝나든 reqId·elapsedMs가 찍힌다(계측 공백 메움,
    // handoff_2026-08-08).
    try {
      // 계수 시점은 상류 호출 전 - 실패할 요청도 셈한다(실패를 반복 때리는
      // 것도 남용이다). resource-exhausted를 던지면 여기서 함수가 끝나
      // fetchUpstream은 아예 호출되지 않는다.
      await checkAndRecordRateLimit(request.auth.uid, kind);

      const key = geminiApiKey.value();
      const endpoint = request.acceptsStreaming ?
        `${GEMINI_BASE_URL}/models/${model}:streamGenerateContent?alt=sse&key=${key}` :
        `${GEMINI_BASE_URL}/models/${model}:generateContent?key=${key}`;

      const upstream = await fetchUpstream(endpoint, requestBodyJson, reqId, startedAt);

      if (!request.acceptsStreaming) {
        let text: string;
        try {
          text = await upstream.text();
        } catch (err) {
          // 헤더는 받았지만(fetchUpstream 통과) 본문 전송 도중 연결이 끊긴
          // 경우 - AbortError도 네트워크 실패도 아니라 fetchUpstream의 catch를
          // 거치지 않고 여기서 처음 발생한다. 안 잡으면 프레임워크가 디테일
          // 없는 internal로 뭉개 클라이언트가 재시도 여부를 판단할 근거를
          // 잃는다. "응답이 끊겨 온전히 못 받음"은 어느 모델을 썼는지와
          // 무관한 순수 네트워크 문제이므로 data-loss로 명시하고, 클라이언트
          // _mapProxyException이 이를 GeminiApiException(503)으로 재구성해
          // 기존 재시도(isRetryable) 판정에 태워 대체 모델로 넘어가게 한다.
          const message = err instanceof Error ? err.message : String(err);
          throw new HttpsError(
            "data-loss",
            `업스트림 응답 본문을 읽는 중 연결이 끊겼습니다: ${message}`
          );
        }
        if (!upstream.ok) {
          const message = extractUpstreamErrorMessage(text);
          throw new HttpsError("internal", message, {
            upstreamStatus: upstream.status,
            upstreamMessage: message,
          });
        }
        try {
          const parsed = JSON.parse(text);
          console.log(
            `[callGeminiText] done reqId=${reqId} elapsedMs=${Date.now() - startedAt} ` +
              `outcome=success upstreamStatus=${upstream.status} ` +
              `responseBytes=${Buffer.byteLength(text, "utf8")}`
          );
          return parsed;
        } catch (err) {
          // 200인데 본문이 유효 JSON이 아닌 경우 - Gemini는 성공으로 응답했지만
          // 파싱 불가한 바디를 준 것이므로, 직접 호출 시절 _parseJsonObject가
          // 던지던 FormatException(1차 모델 응답이 중간에 잘림 등)과 같은
          // 성격의 실패다. reason: invalid-json으로 표시해 클라이언트가
          // FormatException으로 재구성하게 한다 - withTextModelFallback은
          // 이미 FormatException을 "대체 모델로 넘어갈 이유"로 처리한다.
          const message = err instanceof Error ? err.message : String(err);
          throw new HttpsError(
            "internal",
            `Gemini 응답이 유효한 JSON이 아닙니다: ${message}`,
            {reason: "invalid-json"}
          );
        }
      }

      // 스트리밍 경로 - SSE data: 라인을 텍스트 추출 없이 원본 JSON 그대로 중계한다.
      if (!upstream.ok || !upstream.body) {
        const text = await upstream.text();
        const message = extractUpstreamErrorMessage(text);
        throw new HttpsError("internal", message, {
          upstreamStatus: upstream.status,
          upstreamMessage: message,
        });
      }

      const reader = upstream.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";
      let streamedBytes = 0;
      for (;;) {
        let done: boolean;
        let value: Uint8Array | undefined;
        try {
          ({done, value} = await reader.read());
        } catch (err) {
          // SSE 스트리밍 도중 연결이 끊긴 경우 - 비스트리밍 경로의 upstream.text()
          // 실패와 같은 성격(본문 전송 중 단절)이라 동일하게 data-loss로 던진다.
          // 다만 이 경로의 실제 착지점은 fitting_job_controller의 catch(e) →
          // [STREAM-FALLBACK] → 비스트리밍 재시도이므로, 여기서의 코드 선택보다
          // "internal로 뭉개지 않고 원인을 남긴다"는 점이 더 중요하다.
          const message = err instanceof Error ? err.message : String(err);
          throw new HttpsError(
            "data-loss",
            `스트리밍 응답을 읽는 중 연결이 끊겼습니다: ${message}`
          );
        }
        if (done) break;
        streamedBytes += value?.byteLength ?? 0;
        buffer += decoder.decode(value, {stream: true});
        const lines = buffer.split("\n");
        buffer = lines.pop() ?? "";
        for (const line of lines) {
          if (!line.startsWith("data:")) continue;
          const jsonStr = line.slice(5).trim();
          if (!jsonStr) continue;
          let chunk: unknown;
          try {
            chunk = JSON.parse(jsonStr);
          } catch (err) {
            // SSE 한 청크가 깨진 JSON인 경우 - 비스트리밍 경로의 JSON.parse(text)
            // 실패와 같은 응답 형식 문제이므로 동일하게 invalid-json으로 표시한다.
            // 이 예외도 결국 [STREAM-FALLBACK]으로 착지하지만, 원인을 남겨야
            // 나중에 로그에서 "형식 문제였는지 연결 문제였는지" 구분할 수 있다.
            const message = err instanceof Error ? err.message : String(err);
            throw new HttpsError(
              "internal",
              `SSE 청크가 유효한 JSON이 아닙니다: ${message}`,
              {reason: "invalid-json"}
            );
          }
          response?.sendChunk(chunk);
        }
      }
      console.log(
        `[callGeminiText] done reqId=${reqId} elapsedMs=${Date.now() - startedAt} ` +
          `outcome=success upstreamStatus=${upstream.status} responseBytes=${streamedBytes}`
      );
      // 최종 반환값은 쓰지 않는다 - 클라이언트가 청크를 누적해 직접 파싱한다.
      return {};
    } catch (err) {
      // HttpsError면 code/message를 그대로, 아니면 이름만이라도 남긴다 -
      // 어느 쪽이든 "왜 끝났는지"가 이 한 줄에 남아야 한다.
      const code = err instanceof HttpsError ? err.code : "unknown";
      const message = err instanceof Error ? err.message : String(err);
      // upstreamStatus가 있으면 성공 로그와 같은 키로, 같은 위치
      // (outcome= 바로 뒤)에 싣는다 - 나중에 outcome 무관하게 같은
      // 쿼리로 집계할 수 있어야 한다(§6-가 참고, 위 extractUpstreamStatus).
      // 없는 경우(예: unauthenticated/invalid-argument처럼 업스트림까지
      // 못 간 실패)는 필드 자체를 생략한다 - 없는 값을 자리표시자로
      // 채우지 않는다.
      const upstreamStatus = extractUpstreamStatus(err);
      console.log(
        `[callGeminiText] done reqId=${reqId} elapsedMs=${Date.now() - startedAt} ` +
          "outcome=error " +
          (upstreamStatus !== undefined ? `upstreamStatus=${upstreamStatus} ` : "") +
          `code=${code} message=${message}`
      );
      throw err;
    }
  }
);

// ── 가상 피팅 전용 콜러블(docs/task_fitting_server_cache_v1.md) ─────
// callGeminiText와 분리한 이유(§0): callGeminiText는 모델 불문 중계
// 원칙을 지켜야 논문 5.16류 모델 교체 사전 검증이 서버 무변경으로
// 가능하다 - 가상 피팅 전용 로직(캐시 키·소유권 검증·Storage 쓰기)을
// 그 안에 넣으면 이 원칙이 깨진다. 가상 피팅은 이미지 개수 가변·
// 유일한 캐시 필요·유일한 100초대 응답이라는 점에서도 성격이 다르다.
//
// UPSTREAM_TIMEOUT_MS/fetchUpstream은 callGeminiText와 공유(중복 방지,
// §0 "(a)가 나을 수 있는 유일한 지점" 대응).
const FITTING_RESULTS_FOLDER = "fitting_results";
const FITTING_CACHE_COL = "fitting_cache";
const WARDROBE_COL = "wardrobe";

// Gemini 이미지 응답에서 base64 이미지 데이터를 꺼낸다 - 클라이언트의
// _extractImageFromResponse(gemini_service.dart)와 같은 파싱 규칙
// (candidates[0].content.parts[].inlineData.data)만 서버가 캐시 쓰기
// 목적으로 한 번 더 수행하는 것. 클라이언트 파싱 로직은 안 바뀐다 -
// 이 함수는 원본 응답을 그대로 반환하고, 클라이언트는 지금처럼 자기가
// 직접 파싱해서 화면에 쓴다.
function extractImageBytes(response: unknown): Buffer | null {
  const candidates = (response as {candidates?: unknown} | null)?.candidates;
  if (!Array.isArray(candidates) || candidates.length === 0) return null;
  const content = (candidates[0] as {content?: unknown} | null)?.content;
  const parts = (content as {parts?: unknown} | null)?.parts;
  if (!Array.isArray(parts)) return null;
  for (const part of parts) {
    const inlineData = (part as {inlineData?: unknown} | null)?.inlineData;
    const data = (inlineData as {data?: unknown} | null)?.data;
    if (typeof data === "string" && data.length > 0) {
      return Buffer.from(data, "base64");
    }
  }
  return null;
}

// StorageService.uploadFittingResult + FirestoreService.cacheFittingResult
// (둘 다 Dart)를 서버 쪽에서 대응하는 구현.
//
// [정정 2026-08-08, 배포 전] 최초 구현은 firebaseStorageDownloadTokens를
// 명시 생성했었다 — 틀렸다. fitting_results/는 TOKEN_REVOKE_PREFIXES에
// 있어 revokeTokenOnUpload가 이 업로드를 그대로 잡아 곧바로 토큰을
// 회수한다. 즉 토큰을 만들어봤자 즉시 죽고, 회수되기 전 짧은 창(트리거가
// 실행되기까지의 시간) 동안만 실제로 유효한 다운로드 URL이 존재하는
// 상태가 된다 — 3.12절이 닫으려 했던 "토큰 있는 URL이 잠깐이라도
// 살아있는 창"을 새 경로로 다시 여는 것이었다. 배경 제거 트리거
// (functions_bg_removal/main.py의 _legacy_download_url)와 같은 방식으로
// 바꾼다 — **토큰을 아예 만들지 않는다.** 업로드는 메타데이터 없이 plain
// save, imageUrl은 token 파라미터가 처음부터 빈 문자열인 "죽은 채로
// 시작하는" URL이다(경로 역산용 모양만 유지 — pathFromDownloadUrl의
// 정규식은 token 값과 무관하게 경로만 뽑으므로 정상 동작).
// 정식 접근 경로는 여전히 fitting_cache 문서 id + getSignedImageUrls다
// (firestore_service.dart의 기존 주석과 동일 성격).
//
// 확인(§1.4a, 배포 전): 이 토큰 없는 imageUrl은 fitting_room_screen.dart의
// 실제 표시 경로 3곳(973/980/1004행 부근)에서 전부 SignedNetworkImage의
// fallbackUrl로만 쓰인다(973행 fittingImage!=null 분기는 imageUrl 자체를
// 안 씀) — 신선한 결과는 메모리 바이트로, 캐시 히트는 서명 URL 리졸버로
// 그린다. imageUrl을 직접 fetch하는 경로(raw CachedNetworkImage, 1030행)는
// fittingCacheKey가 없는 예외 케이스 전용인데, 서버 경로는 uid가 항상
// 있어(onCall 인증 필수) 캐시 키가 항상 계산되므로 이 예외 분기에 안
// 걸린다 — 무해함 확인.
//
// 필드 구성(§1.4b, 배포 전): cacheFittingResult(Dart)와 정확히 같은 3필드
// (imageUrl/ownerUid/createdAt)만 쓴다 — imagePath를 추가로 넣었던 최초
// 구현은 되돌렸다. 이유: 플래그 꺼짐 구간(지금)에도, 켜진 뒤에도 클라이언트
// 응답을 받으면 기존 _cacheFittingResultSilently가 같은 문서를 merge
// 없이 .set()으로 다시 쓴다(§1.5) — 그 쓰기엔 imagePath가 없으므로 서버가
// 넣은 값이 그대로 지워진다. 필드가 없어져도 기능은 안 깨진다
// (pathFromDownloadUrl 역산 폴백이 그대로 동작) 하지만 "쓰기 순서에 따라
// 필드가 있다 없다 하는" 스키마 드리프트를 만들 이유가 없어 아예 넣지
// 않는 쪽으로 정리했다 — 두 경로가 항상 같은 모양의 문서를 만든다.
async function writeFittingCacheServerSide(
  cacheKey: string,
  imageBytes: Buffer,
  ownerUid: string
): Promise<void> {
  const bucket = getStorage().bucket();
  const path = `${FITTING_RESULTS_FOLDER}/${cacheKey}.jpg`;
  await bucket.file(path).save(imageBytes, {contentType: "image/jpeg"});
  const imageUrl =
    `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/` +
    `${encodeURIComponent(path)}?alt=media&token=`;

  await getFirestore().collection(FITTING_CACHE_COL).doc(cacheKey).set({
    imageUrl,
    ownerUid,
    createdAt: FieldValue.serverTimestamp(),
  });
}

// maxInstances(S1/3) - 근거는 callGeminiText 위 주석(n=1, 순차 클라이언트
// 루프) 참고. 9개 함수 중 이 함수만 5로 낮게 잡는 이유: timeoutSeconds가
// 320이라 인스턴스 하나가 점유하는 시간이 길고, 상류(Gemini) 호출 비용까지
// 곱해진다 - 같은 남용 시도라도 이 함수에서 열어두는 동시 창이 더 비싸다.
export const generateFittingImage = onCall(
  {secrets: [geminiApiKey], region: "asia-northeast3", timeoutSeconds: 320, maxInstances: 5},
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "로그인이 필요합니다.");
    }
    const uid = request.auth.uid;
    const reqId = randomUUID().slice(0, 8);
    const startedAt = Date.now();

    // [appCheck] 계측(S2-a) - reqId 있는 자리에 둔다. 근거·판정 기준은
    // callGeminiText 위 주석 참고.
    console.log(`[appCheck] fn=generateFittingImage uid=${uid} reqId=${reqId} hasApp=${request.app != null}`);

    const {userPhotoId, clothingItemIds, requestBody} = (request.data ?? {}) as {
      userPhotoId?: unknown;
      clothingItemIds?: unknown;
      requestBody?: unknown;
    };
    if (typeof userPhotoId !== "string" || userPhotoId === "") {
      throw new HttpsError("invalid-argument", "userPhotoId가 필요합니다.");
    }
    if (
      !Array.isArray(clothingItemIds) ||
      clothingItemIds.length === 0 ||
      !clothingItemIds.every((id) => typeof id === "string" && id !== "")
    ) {
      throw new HttpsError("invalid-argument", "clothingItemIds가 필요합니다.");
    }
    if (requestBody === null || typeof requestBody !== "object") {
      throw new HttpsError("invalid-argument", "requestBody가 필요합니다.");
    }
    const clothingIds = clothingItemIds as string[];

    console.log(
      `[generateFittingImage] start reqId=${reqId} uid=${uid} ` +
        `userPhotoId=${userPhotoId} clothingCount=${clothingIds.length}`
    );

    // 소유권 검증(§1.4, signed_url_policy.ts와 같은 원칙) - 캐시 키
    // 계산보다 먼저. 신뢰 안 되는 id로 캐시를 오염시키지 않기 위해
    // 검증이 먼저, 계산이 나중이다.
    const db = getFirestore();
    const allIds = [userPhotoId, ...clothingIds];
    const ownerDocs = await Promise.all(
      allIds.map(async (id) => {
        const snap = await db.collection(WARDROBE_COL).doc(id).get();
        const data = snap.data();
        return {id, exists: snap.exists, ownerUid: data?.ownerUid as string | undefined};
      })
    );
    const ownership = verifyFittingOwnership(ownerDocs, uid);
    if (!ownership.allowed) {
      console.log(
        `[generateFittingImage] done reqId=${reqId} elapsedMs=${Date.now() - startedAt} ` +
          `outcome=rejected reason=ownership:${ownership.reason} deniedId=${ownership.deniedId}`
      );
      throw new HttpsError("permission-denied", "옷장 아이템 소유권을 확인할 수 없습니다.");
    }

    const cacheKey = buildFittingCacheKey(userPhotoId, clothingIds);

    // 요청 본문 스키마 계측(S3-b) - 페이로드 크기 검사보다 앞에 둔다.
    // callGeminiText와 같은 근거(형식이 틀린 요청이 아래
    // checkAndRecordRateLimit에 도달해 정상 사용자의 할당량을 깎으면
    // 안 된다). request_shape.ts는 총체적이라 이 try/catch에 도달하지
    // 않아야 정상이다 - 도달했다면 그 자체가 결함이므로 로그로
    // 드러내되 fail-open 원칙(5.21.7)에 따라 요청은 통과시킨다.
    let shape: RequestShapeDecision | null;
    try {
      shape = evaluateRequestShape(requestBody, "image", REQUEST_SHAPE_CONFIG);
    } catch (e) {
      console.log(`[requestShape] evaluator_failed reqId=${reqId} err=${String(e)}`);
      shape = null;
    }
    if (shape) {
      logRequestShape("generateFittingImage", reqId, uid, shape);
      if (!shape.allowed && REQUEST_SHAPE_ENFORCE) {
        throw new HttpsError("invalid-argument", "허용되지 않은 요청 형식입니다.", {
          violations: shape.violations,
        });
      }
    }

    const requestBodyJson = JSON.stringify(requestBody);
    const requestBytes = Buffer.byteLength(requestBodyJson, "utf8");
    // kind는 항상 "image" - 이 함수는 가상 피팅 전용이라 kindForModel
    // 파생이 필요 없다(callGeminiText는 model 화이트리스트가 여러
    // 종류라 파생이 필요했지만, 여긴 처음부터 이미지 하나뿐).
    const payloadDecision = evaluatePayloadLimit(requestBytes, "image", PAYLOAD_LIMIT_CONFIG);
    if (!payloadDecision.allowed) {
      console.log(
        `[generateFittingImage] done reqId=${reqId} elapsedMs=${Date.now() - startedAt} ` +
          "outcome=rejected reason=payload_limit"
      );
      throw new HttpsError("invalid-argument", "요청 페이로드가 너무 큽니다.", {
        requestBytes,
        limitBytes: payloadDecision.limitBytes,
      });
    }

    await checkAndRecordRateLimit(uid, "image");

    try {
      const key = geminiApiKey.value();
      const endpoint =
        `${GEMINI_BASE_URL}/models/gemini-3.1-flash-image:generateContent?key=${key}`;
      const upstream = await fetchUpstream(endpoint, requestBodyJson, reqId, startedAt);

      let text: string;
      try {
        text = await upstream.text();
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        throw new HttpsError(
          "data-loss",
          `업스트림 응답 본문을 읽는 중 연결이 끊겼습니다: ${message}`
        );
      }
      if (!upstream.ok) {
        const message = extractUpstreamErrorMessage(text);
        throw new HttpsError("internal", message, {
          upstreamStatus: upstream.status,
          upstreamMessage: message,
        });
      }

      let parsed: unknown;
      try {
        parsed = JSON.parse(text);
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        throw new HttpsError(
          "internal",
          `Gemini 응답이 유효한 JSON이 아닙니다: ${message}`,
          {reason: "invalid-json"}
        );
      }

      // 캐시 쓰기 실패는 이 호출 자체를 실패로 만들지 않는다 - Gemini
      // 생성 자체는 이미 성공했으므로, 클라이언트가 응답을 받으면 기존
      // _cacheFittingResultSilently가 어차피 한 번 더 쓴다(§1.5, 중복
      // 허용 - 멱등이라 안전). 여기서 던지면 "생성은 됐는데 캐시
      // 저장을 못 했다"는 이유로 정상 응답이 에러로 뒤집히는 게 더
      // 나쁘다.
      let cached = false;
      const imageBytes = extractImageBytes(parsed);
      if (imageBytes) {
        try {
          await writeFittingCacheServerSide(cacheKey, imageBytes, uid);
          cached = true;
        } catch (err) {
          const message = err instanceof Error ? err.message : String(err);
          console.log(
            `[generateFittingImage] reqId=${reqId} 캐시 쓰기 실패(생성은 성공, 무시): ${message}`
          );
        }
      }

      console.log(
        `[generateFittingImage] done reqId=${reqId} elapsedMs=${Date.now() - startedAt} ` +
          `outcome=success upstreamStatus=${upstream.status} ` +
          `responseBytes=${Buffer.byteLength(text, "utf8")} cached=${cached}`
      );
      return parsed;
    } catch (err) {
      const code = err instanceof HttpsError ? err.code : "unknown";
      const message = err instanceof Error ? err.message : String(err);
      // callGeminiText와 같은 계측 공백 메움(§6-가 참고) - 같은 키·같은
      // 위치, 없으면 생략.
      const upstreamStatus = extractUpstreamStatus(err);
      console.log(
        `[generateFittingImage] done reqId=${reqId} elapsedMs=${Date.now() - startedAt} ` +
          "outcome=error " +
          (upstreamStatus !== undefined ? `upstreamStatus=${upstreamStatus} ` : "") +
          `code=${code} message=${message}`
      );
      throw err;
    }
  }
);

// 순차 합성(docs/task_sequential_fitting_v1.md §d) - 피팅 1회당 정확히
// 1번만 호출되는 전용 콜러블. 순차 루프의 개별 이미지 호출은
// callGeminiText(중간 단계)/generateFittingImage(마지막 단계, 조건부)를
// 그대로 쓰고 "image" 카운트를 그대로 먹는다 - 이 함수는 "이게 피팅
// 시도 하나의 시작이다"를 세는 것만 담당한다. 클라이언트는 순차 루프
// 진입 직전 이 콜러블을 1번 호출하고, resource-exhausted가 오면 루프를
// 시작하지 않는다(재시도 대상 아님 - 상한 초과는 결정론적 실패).
// maxInstances(S1/3) - 근거는 callGeminiText 위 주석 참고.
export const beginFittingAttempt = onCall(
  {region: "asia-northeast3", maxInstances: 10},
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "로그인이 필요합니다.");
    }
    // [appCheck] 계측(S2-a) - reqId 없음. 근거·판정 기준은 callGeminiText
    // 위 주석 참고.
    console.log(`[appCheck] fn=beginFittingAttempt uid=${request.auth.uid} hasApp=${request.app != null}`);
    await checkAndRecordRateLimit(request.auth.uid, "fitting");
    return {ok: true};
  }
);

// ── 서명 URL 이행(docs/task_signed_urls_v1.md) A-2 ──────────────────
// 서명 요청 단위는 경로가 아니라 문서 ID다(§3-2) - 클라이언트가 경로
// 문자열을 보내면 유출 URL → 경로 추출 → 재서명이라는 재발급 루프가
// 생긴다. 이 함수가 문서를 직접 읽고 접근 정책(signed_url_policy.ts)을
// 검사한 뒤 그 문서에 기록된(또는 기존 URL에서 역산한) 경로에만 서명한다.
//
// 서명 URL은 Firestore에 저장하지 않는다(§3-3) - 응답으로만 나가고
// 서버도 클라이언트도 영속화하지 않는다.
const SIGNED_URL_EXPIRES_MS = 60 * 60 * 1000; // 60분(§3-3) - 클라이언트는 80% 시점에 갱신(A-3).
const SIGNED_URL_COLLECTIONS: readonly SignedUrlCollection[] = [
  "wardrobe",
  "demo_wardrobe",
  "fitting_cache",
];

function isSignedUrlCollection(value: unknown): value is SignedUrlCollection {
  return typeof value === "string" &&
    (SIGNED_URL_COLLECTIONS as readonly string[]).includes(value);
}

// maxInstances(S1/3) - 근거는 callGeminiText 위 주석 참고.
export const getSignedImageUrls = onCall(
  {region: "asia-northeast3", maxInstances: 10},
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "로그인이 필요합니다.");
    }
    // [appCheck] 계측(S2-a) - reqId 없음. 근거·판정 기준은 callGeminiText
    // 위 주석 참고.
    console.log(`[appCheck] fn=getSignedImageUrls uid=${request.auth.uid} hasApp=${request.app != null}`);
    const uid = request.auth.uid;

    const {items} = (request.data ?? {}) as {items?: unknown};
    if (!Array.isArray(items)) {
      throw new HttpsError("invalid-argument", "items 배열이 필요합니다.");
    }
    const parsedItems: SignedUrlRequestItem[] = [];
    for (const raw of items) {
      const collection = (raw as {collection?: unknown} | null)?.collection;
      const id = (raw as {id?: unknown} | null)?.id;
      if (!isSignedUrlCollection(collection) || typeof id !== "string" || id === "") {
        throw new HttpsError(
          "invalid-argument",
          "items의 각 항목은 {collection, id} 형태여야 합니다."
        );
      }
      parsedItems.push({collection, id});
    }

    const batchCheck = validateBatch(parsedItems);
    if (!batchCheck.valid) {
      throw new HttpsError(
        "invalid-argument",
        batchCheck.reason === "empty" ?
          "items가 비어 있습니다." :
          `items는 최대 ${MAX_BATCH_SIZE}개까지입니다.`
      );
    }

    // signCount는 textCount/imageCount와 분리된 별도 필드(rate_limit.ts) -
    // 계수 시점은 상류(Storage 서명) 호출 전, 콜 1건당 1이다(배치 크기와
    // 무관 - textCount/imageCount와 같은 "호출 1건" 단위를 유지한다).
    await checkAndRecordRateLimit(uid, "sign");

    const db = getFirestore();
    const bucket = getStorage().bucket();
    const results: Record<string, {urls: string[]; expiresAt: string}> = {};

    await Promise.all(
      parsedItems.map(async (item) => {
        const snap = await db.collection(item.collection).doc(item.id).get();
        const data = snap.data();
        const docFields: DocFields = {
          exists: snap.exists,
          ownerUid: data?.ownerUid as string | undefined,
          imagePath: data?.imagePath as string | undefined,
          imageUrl: data?.imageUrl as string | undefined,
          cutoutPath: data?.cutoutPath as string | undefined,
          cutoutImageUrl: data?.cutoutImageUrl as string | undefined,
        };
        const decision = decideSignedUrlAccess(item, docFields, uid);
        if (!decision.allowed) {
          console.log(
            `[getSignedImageUrls] 거부 uid=${uid} collection=${item.collection} ` +
            `id=${item.id} reason=${decision.reason}`
          );
          return; // 응답에서 생략 - 클라이언트는 없는 id를 기존 URL 폴백 신호로 본다(A-3).
        }

        try {
          const expires = Date.now() + SIGNED_URL_EXPIRES_MS;
          const urls = await Promise.all(
            decision.paths.map(async (path) => {
              const [url] = await bucket.file(path).getSignedUrl({
                version: "v4",
                action: "read",
                expires,
              });
              return url;
            })
          );
          results[item.id] = {urls, expiresAt: new Date(expires).toISOString()};
        } catch (err) {
          // 개별 항목의 서명 실패가 배치 전체를 죽이면 안 된다 - 이 항목만
          // 응답에서 빠지고(클라이언트 폴백), 나머지는 계속 처리한다.
          console.error(
            `[getSignedImageUrls] 서명 실패 uid=${uid} collection=${item.collection} id=${item.id}:`,
            err
          );
        }
      })
    );

    console.log(
      `[getSignedImageUrls] uid=${uid} 요청 ${parsedItems.length}건 중 ` +
      `${Object.keys(results).length}건 서명 성공`
    );
    return results;
  }
);

// FCM 무효 토큰 정리(handoff_2026-08-07.md §6 "FCM 무효 토큰이 정리되지
// 않는다") - sendTestPush/runScheduledCheckCore 둘이 같은 로직을 쓴다.
// 두 벌이 되면 한쪽만 고쳐지는 종류의 버그가 된다.
//
// tokens[i] <-> responses[i] 인덱스 대응은 firebase-admin
// sendEachForMulticast 문서가 명시적으로 보장한다 - "The responses list
// obtained from the return value corresponds to the order of tokens/fids
// in the MulticastMessage."(node_modules/firebase-admin/lib/messaging/
// messaging.d.ts). 호출부는 sendEachForMulticast에 넘긴 tokens 배열을
// 필터·정렬·중복 제거 없이 그대로 넘겨야 한다 - 어긋나면 살아있는
// 토큰을 지우고 죽은 토큰을 남기는 사고가 나고, 증상이 "가끔 푸시가
// 안 온다"라 원인 추적이 매우 어렵다. 길이가 안 맞으면(어긋났다는
// 신호) 잘못 지우느니 정리를 통째로 건너뛴다.
//
// 삭제는 부가 작업 - 실패해도 발송 성공(sentCount/successCount)을
// 뒤집지 않는다. 개별 삭제 실패는 로그만 남기고 조용히 넘어간다
// (fitting_job_controller.dart의 _cacheFittingResultSilently와 같은 패턴).
async function cleanupInvalidTokens(
  uid: string,
  tokens: string[],
  responses: SendResponse[]
): Promise<void> {
  if (tokens.length !== responses.length) {
    console.error(
      `[fcmTokenCleanup] tokens/responses 길이 불일치 uid=${uid} ` +
      `tokens=${tokens.length} responses=${responses.length} - 정리 건너뜀`
    );
    return;
  }

  const results: TokenSendResult[] = responses.map((r, i) => ({
    token: tokens[i],
    success: r.success,
    errorCode: r.error?.code,
  }));

  const plan = planTokenCleanup(results);
  if (plan.length === 0) return;

  const db = getFirestore();
  for (const item of plan) {
    if (item.action === "diagnostic") {
      // fcm_token_cleanup.ts의 DIAGNOSTIC_ONLY_CODE 판정 근거 참고 -
      // 삭제하지 않고 눈에 띄게 로깅만 한다.
      console.log(
        `[fcmTokenCleanup] 진단(삭제 안 함, ${item.errorCode}) ` +
        `uid=${uid} token=${item.token.slice(0, 12)}...`
      );
      continue;
    }
    try {
      await db.collection("users").doc(uid).collection("fcm_tokens").doc(item.token).delete();
      console.log(
        `[fcmTokenCleanup] 삭제 uid=${uid} token=${item.token.slice(0, 12)}... ` +
        `code=${item.errorCode}`
      );
    } catch (err) {
      console.error(
        `[fcmTokenCleanup] 삭제 실패(무시) uid=${uid} token=${item.token.slice(0, 12)}...:`,
        err
      );
    }
  }
}

// B단계 진단용 테스트 푸시 - 호출한 uid의 모든 등록 기기로 발송한다.
// A-1 함정 1과 같은 이유로 onCall + request.auth 검사: onRequest로 만들면
// 누구나 호출 가능한 무료 푸시 게이트웨이가 된다. 스케줄러(C단계)는 아직
// 안 만든다 - 이 함수는 "토큰이 등록돼 있으면 서버가 이 기기로 알림을
// 보낼 수 있는가"만 확인하는 용도다.
// maxInstances(S1/3) - 근거는 callGeminiText 위 주석 참고. 진단용 호출이라
// 3으로 낮게 잡는다.
export const sendTestPush = onCall(
  {region: "asia-northeast3", maxInstances: 3},
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "로그인이 필요합니다.");
    }
    // [appCheck] 계측(S2-a) - reqId 없음. 근거·판정 기준은 callGeminiText
    // 위 주석 참고.
    console.log(`[appCheck] fn=sendTestPush uid=${request.auth.uid} hasApp=${request.app != null}`);

    const uid = request.auth.uid;
    const tokensSnapshot = await getFirestore()
      .collection("users")
      .doc(uid)
      .collection("fcm_tokens")
      .get();

    const tokens = tokensSnapshot.docs.map((doc) => doc.id);
    if (tokens.length === 0) {
      // 등록된 토큰이 없는 것은 오류가 아니라 "아직 이 기기가 토큰을 못
      // 올렸다"는 정상 상태(예: 권한 거부, 갱신 전)이므로 예외 대신
      // 빈 결과를 돌려주고 클라이언트가 문구로 안내하게 한다.
      return {sentCount: 0, tokenCount: 0};
    }

    // 로컬 알림(notification_service.dart)과 같은 채널을 지정해야 사용자
    // 알림 설정이 하나로 유지된다(함정 6). data 없이 notification만 보내면
    // 앱이 백그라운드/종료 상태일 때 OS가 직접 시스템 트레이에 그려주므로,
    // 지금 단계(토큰 배선 확인)에서는 이걸로 충분하다 - 탭했을 때 특정
    // 화면으로 보내는 딥링크는 C단계에서 실제 트리거와 함께 설계한다.
    const response = await getMessaging().sendEachForMulticast({
      tokens,
      notification: {
        title: "DOT 테스트 푸시",
        body: "서버에서 보낸 FCM 테스트 알림입니다.",
      },
      android: {
        notification: {channelId: FCM_NOTIFICATION_CHANNEL_ID},
      },
    });

    console.log(
      `[sendTestPush] uid=${uid} tokenCount=${tokens.length} ` +
      `successCount=${response.successCount} failureCount=${response.failureCount}`
    );

    await cleanupInvalidTokens(uid, tokens, response.responses);

    return {
      sentCount: response.successCount,
      tokenCount: tokens.length,
    };
  }
);

// ── C단계 — 서버 스케줄러 트리거 ──────────────────────────────
// 엔진(OutfitMatcher 이하)은 부르지 않는다. "추천이 없는 예정일"만 판정해
// FCM으로 깨우고, 조합 생성은 클라이언트가 깨어났을 때 기존 runProactiveCheck
// 경로가 그대로 한다(함정 7 - shouldReplanForWeather의 예보 임계값 로직은
// 서버에 복제하지 않는다).

const PROACTIVE_HORIZON_DAYS = 3; // agent_planner.dart의 _proactiveHorizonDays와 동일
// 클라이언트 invocationLog(background_agent.dart)와 같은 값으로 맞춘다 -
// 다르면 "기기 발화 vs 서버 발화" 비교표를 만들 때 한쪽만 먼저 잘려 왜곡된다.
const SERVER_INVOCATION_LOG_CAP = 500;
const KST_OFFSET_MS = 9 * 60 * 60 * 1000;

// 서버(Cloud Functions) 런타임 시각은 UTC다. calendar/recommendations의
// date/targetDate는 기기 로컬(한국, KST) 자정으로 정규화돼 저장되므로
// (agent_planner.dart의 _todayMidnight), 서버도 KST 기준 자정을 계산해야
// 같은 날짜로 비교된다. 사용자가 전부 한국 기준이라 타임존 라이브러리 없이
// 고정 오프셋으로 충분하다.
function kstMidnight(base: Date): Date {
  const kst = new Date(base.getTime() + KST_OFFSET_MS);
  const y = kst.getUTCFullYear();
  const m = kst.getUTCMonth();
  const d = kst.getUTCDate();
  return new Date(Date.UTC(y, m, d) - KST_OFFSET_MS);
}

// "YYYY-MM-DD" 문자열도 KST 기준으로 만들어야 한다. Date.toISOString()은
// UTC 기준이라, KST 자정으로 저장된 값(예: KST 8/2 00:00 = UTC 8/1 15:00)을
// 그대로 넣으면 날짜 부분이 하루 당겨진다 - 실측으로 확인된 버그(§2-12류
// 재발). kstMidnight()과 같은 +9시간 이동 방식을 그대로 재사용한다.
function toKstDateString(date: Date): string {
  const kst = new Date(date.getTime() + KST_OFFSET_MS);
  const y = kst.getUTCFullYear();
  const m = String(kst.getUTCMonth() + 1).padStart(2, "0");
  const d = String(kst.getUTCDate()).padStart(2, "0");
  return `${y}-${m}-${d}`;
}

// 함정 9 - 지금은 users 컬렉션을 통째로 순회한다(사용자 2명뿐이라 지금은
// 문제없음). 나중에 "최근 활동 기준으로 좁히기"를 넣을 자리를 이 함수
// 하나로 열어둔다 - 호출부(스케줄 함수)는 이 함수의 반환 목록만 알면 되므로
// 내부 구현만 바꾸면 된다. 처리량 상한도 이 자리에 나중에 추가할 것.
// 주의: users/{uid} 루트 문서는 프로필을 저장한 사용자만 존재한다(마이페이지
// 미방문 사용자는 문서가 없을 수 있음) - 지금 사용자 2명은 둘 다 프로필을
// 저장해 문제없지만, 사용자가 늘면 이 가정이 깨질 수 있다는 걸 남겨둔다.
async function getActiveUids(): Promise<string[]> {
  const snapshot = await getFirestore().collection("users").get();
  return snapshot.docs.map((doc) => doc.id);
}

// 오늘(KST)~+3일의 'planned' 예정 중, "아직 열려 있는"(dismissed==false) 추천이
// 없는 가장 가까운 날짜 하나를 찾는다. 판정 기준은 클라이언트의
// recommendationForDateSilently(firestore_service.dart)와 완전히 동일하게
// targetDate==date && dismissed==false만 본다 - userChoice 조건은 넣지 않는다.
//
// 원래는 userChoice==null도 같이 걸었는데, 이게 버그였다: Firestore의
// where('field','==',null)은 필드가 명시적으로 null로 저장된 문서만 매치하고,
// 필드가 아예 없는 문서는 매치하지 않는다. recommendation_entry.dart:151이
// userChoice가 null이면 필드를 아예 안 쓰므로(`if (userChoice != null)
// 'userChoice': userChoice,`), 미응답 추천은 이 조건으로 절대 안 잡혀
// recSnap이 항상 비어 있었다 - 즉 미확인 추천이 있어도 서버는 매번 "없음"으로
// 판정해 3시간마다 중복 푸시를 보내는 구조적 버그였다(2026-08-02 실기기
// 검증에서 발견). 판정 기준은 클라이언트와 동일하게 유지한다 - 어긋나면
// 조용히 갈린다(함정 7의 축소판이 실제로 여기서 일어났다).
// 여러 날짜가 걸려도 하나만 반환한다 - 나머지는 앱이 깨어나면 기존
// runProactiveCheck가 한 번에 다 처리한다.
async function findNextUntriggeredDate(uid: string): Promise<Date | undefined> {
  const db = getFirestore();
  const today = kstMidnight(new Date());
  const horizon = new Date(today.getTime() + PROACTIVE_HORIZON_DAYS * 24 * 60 * 60 * 1000);

  // status 필터는 여기서(TS) 건다 - calendarEntriesForRange(클라이언트)와
  // 동일하게 date 범위만 쿼리에 걸어 복합 인덱스를 새로 안 만들어도 되게 한다.
  const calendarSnap = await db
    .collection("users").doc(uid).collection("calendar")
    .where("date", ">=", Timestamp.fromDate(today))
    .where("date", "<=", Timestamp.fromDate(horizon))
    .orderBy("date")
    .get();

  for (const doc of calendarSnap.docs) {
    const data = doc.data();
    if (data.status !== "planned") continue;

    const entryDate = data.date as FirebaseFirestore.Timestamp;
    const recSnap = await db
      .collection("users").doc(uid).collection("recommendations")
      .where("targetDate", "==", entryDate)
      .where("dismissed", "==", false)
      .limit(1)
      .get();

    if (recSnap.empty) {
      return entryDate.toDate();
    }
  }
  return undefined;
}

// agent_meta/background에 서버 계측을 기록한다. 기존 클라이언트 필드
// (invokeCount·invocationLog·lastRunAt 등, background_agent.dart)와 이름이
// 겹치지 않도록 전부 server 접두어를 쓴다(함정 8) - 반드시 set(..., {merge:
// true})만 쓴다. update()는 문서가 아직 없는 uid의 첫 실행에서 에러가 나고,
// merge 없는 set()은 기존 필드를 통째로 지워 4주 표본이 날아간다 - 이 저장소가
// C단계에서 되돌릴 수 없는 유일한 사고로 지목한 지점이다.
//
// 트랜잭션으로 감싼다 - 캡 도달 후 배열을 통째로 다시 쓰는 분기는 get()
// 시점 스냅샷 기반이라, get()과 set() 사이에 다른 실행이 끼면 그 기록이
// 조용히 덮어써질 수 있었다(read-modify-write 경합). 3시간 자연 주기끼리는
// 안 겹치지만, 검증 단계에서 triggerScheduledCheckTest를 짧은 간격으로
// 여러 번 수동 호출하면 이 경합이 훨씬 자주 발생할 수 있어 지금 고친다.
// Firestore 트랜잭션은 낙관적 동시성 제어로 충돌 시 자동 재시도하므로
// read-modify-write 전체가 원자적이 된다.
//
// 클라이언트 invocationLog(background_agent.dart)는 이 경합을 감수하기로
// 이미 결정한 상태다(500회에 한 번꼴, 그쪽 주석 참고) - 서버 쪽에만 트랜잭션을
// 추가하는 이유는 검증 단계의 수동 호출이 그 "드문 경우"를 훨씬 자주 만들 수
// 있기 때문이다.
//
// 배열 항목 형태 - sendResult가 있으면(실제 발송을 시도한 경우)
// {at, triggered, successCount, failureCount}, 없으면(발송 대상이 없거나
// targetDate 자체가 없던 경우) 기존과 동일하게 {at, triggered}만 남는다.
// 2026-08-02 실기기 검증 중 sendEachForMulticast 결과(성공/실패)를 아예
// 로그·기록 어느 쪽에도 안 남기고 있던 계측 공백을 발견해 추가했다 -
// "서버가 보냈다(triggered:true)"와 "FCM이 실제로 받아들였다"는 다른
// 사실인데 후자를 확인할 방법이 없었다(그날 Doze로 인한 지연 하나를
// 조사하는 데도 로그만으로는 안 돼 토큰에 직접 재발송해 확인해야 했다).
// **이미 쌓인 옛 항목은 {at, triggered}뿐이라 이 필드가 없다** - 이 로그를
// 나중에 읽는 쪽은 successCount/failureCount를 optional로 다뤄야 한다
// (2026-08-02 이전 항목엔 없음). 클라이언트 invocationLog와는 어차피
// 항목 형태가 이제 갈리므로, 나란히 비교할 땐 공통 필드(at, triggered)만
// 본다.
// pushId(docs/task_agent_cadence_v1.md §3-2) - 이 발송을 클라이언트의
// serverTapLog와 매칭할 키. 발송이 아예 없었으면(토큰 0개) 매칭할 대상
// 자체가 없으므로 undefined로 둔다. 이 필드는 §4-2 전환 기준(uid당 매칭
// 가능 30건)에 도달하기 전까지는 어떤 판정 로직도 읽지 않는다 - 지금은
// 기록만 한다.
async function recordServerInvocation(
  uid: string,
  triggered: boolean,
  sendResult?: {successCount: number; failureCount: number; pushId?: string}
): Promise<void> {
  const db = getFirestore();
  const docRef = db.collection("users").doc(uid).collection("agent_meta").doc("background");
  const now = Timestamp.now();

  try {
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(docRef);
      const currentLog = (snap.data()?.serverInvocationLog as unknown[] | undefined) ?? [];
      const entry = sendResult ?
        {
          at: now,
          triggered,
          successCount: sendResult.successCount,
          failureCount: sendResult.failureCount,
          ...(sendResult.pushId ? {pushId: sendResult.pushId} : {}),
        } :
        {at: now, triggered};
      const nextLog = currentLog.length >= SERVER_INVOCATION_LOG_CAP ?
        [...currentLog.slice(currentLog.length - SERVER_INVOCATION_LOG_CAP + 1), entry] :
        [...currentLog, entry];

      tx.set(docRef, {
        serverInvokeCount: FieldValue.increment(1),
        serverInvocationLog: nextLog,
        serverLastRunAt: now,
      }, {merge: true});
    });
  } catch (err) {
    // 계측 실패는 판정 자체를 막지 않는다 - 이미 로그로 남길 것(console.error)
    // 외에 할 수 있는 게 없고, 이 함수 호출 시점엔 이미 판정·발송이 끝나 있다.
    console.error(`[C단계] agent_meta 계측 실패 uid=${uid}:`, err);
  }
}

// onSchedule과 테스트용 onCall이 공유하는 핵심 로직 - sendTestPush와 같은
// 패턴이다. 이 환경엔 gcloud가 없어 Cloud Scheduler를 수동 발화시킬 방법이
// 없으므로, 3시간을 기다리지 않고 로직 자체를 즉시 검증하려면 이 분리가
// 필수다.
//
// [2] 중복 호출(WorkManager와 FCM 탭이 거의 동시에 겹치는 경우) - 락을
// 넣지 않았다. 경합 창이 수백ms~초 단위로 좁고, 겹쳐도 최악이 "같은 날짜
// 추천 두 개"이지 데이터 손상이 아니다. 락을 넣으면 락에 막혀 스킵된 실행을
// invokeCount/serverInvokeCount에 어떻게 셀지가 애매해져 t0부터 쌓은 계측
// 표본의 해석이 바뀐다(함정 8의 연장선) - 실측으로 관측된 적 없는 문제를
// 막으려다 확실한 계측을 훼손하는 셈이라 지금은 손대지 않는다. 같은 날짜에
// 추천이 둘 생기는 게 실제로 관측되면 그때 다시 판단한다.
async function runScheduledCheckCore(
  uid: string
): Promise<{triggered: boolean; targetDate?: string}> {
  const targetDate = await findNextUntriggeredDate(uid);

  if (!targetDate) {
    await recordServerInvocation(uid, false);
    return {triggered: false};
  }

  const targetDateStr = toKstDateString(targetDate);

  const tokensSnap = await getFirestore()
    .collection("users").doc(uid).collection("fcm_tokens").get();
  const tokens = tokensSnap.docs.map((doc) => doc.id);

  let sendResult: {successCount: number; failureCount: number; pushId?: string} | undefined;

  if (tokens.length > 0) {
    // [3] data 페이로드로 서버 발화임을 클라이언트가 구분할 수 있게 한다 -
    // 안 그러면 탭 이후 경로에서 기기 발화와 서버 발화가 다시 섞인다(함정 8이
    // 막으려는 것이 서버 쪽 기록만은 아니다). 채널은 B단계와 동일하게
    // agent_recommendation.
    //
    // pushId(docs/task_agent_cadence_v1.md §3-2) - reqId(위 다른 함수들의
    // randomUUID().slice(0,8))와 달리 자르지 않는다. reqId는 사람이 로그에서
    // grep하는 용도라 8자로 충분하지만, 이건 두 개의 캡 500 배열
    // (serverInvocationLog ↔ 클라이언트 serverTapLog)을 매칭하는 키라
    // 충돌 여지를 줄이는 쪽을 택한다.
    const pushId = randomUUID();
    const response = await getMessaging().sendEachForMulticast({
      tokens,
      notification: {
        title: "DOT",
        body: "다가오는 일정에 맞는 코디를 준비했어요",
      },
      data: {source: "server_scheduler", targetDate: targetDateStr, pushId},
      android: {notification: {channelId: FCM_NOTIFICATION_CHANNEL_ID}},
    });
    sendResult = {successCount: response.successCount, failureCount: response.failureCount, pushId};
    await cleanupInvalidTokens(uid, tokens, response.responses);
  }

  await recordServerInvocation(uid, true, sendResult);
  console.log(
    `[C단계] uid=${uid} targetDate=${targetDateStr} triggered=true tokenCount=${tokens.length} ` +
    `successCount=${sendResult?.successCount ?? "n/a"} failureCount=${sendResult?.failureCount ?? "n/a"}`
  );
  return {triggered: true, targetDate: targetDateStr};
}

// 3시간 주기 - 기존 WorkManager(main.dart)와 동일한 주기로 시작한다.
// onSchedule은 Firebase가 내부적으로 만드는 Pub/Sub 토픽 + Cloud Scheduler
// 잡으로 트리거되어 공개 HTTP 엔드포인트가 아예 없다 - onRequest + 수동
// Cloud Scheduler 조합과 달리 A-1 함정 1과 같은 무방비 엔드포인트 리스크가
// 구조적으로 생기지 않는다.
// maxInstances(S1/3) - 근거는 callGeminiText 위 주석 참고. 스케줄 트리거는
// 중첩 실행이 흔치 않으므로 3으로 낮게 잡는다.
// [appCheck] 계측(S2-a) 대상 아님 - 위 문단대로 공개 HTTP 엔드포인트가
// 없어 클라이언트가 직접 호출하지 않으므로 App Check가 적용될 자리
// 자체가 없다(docs/task_hardening_v2.md §3-2).
export const scheduledProactiveCheck = onSchedule(
  {schedule: "every 3 hours", region: "asia-northeast3", maxInstances: 3},
  async () => {
    const uids = await getActiveUids();
    for (const uid of uids) {
      try {
        await runScheduledCheckCore(uid);
      } catch (err) {
        // uid 하나 실패가 나머지 uid 처리를 막으면 안 된다.
        console.error(`[C단계] uid=${uid} 처리 실패:`, err);
      }
    }
  }
);

// 수동 발화 테스트용 - 호출한 uid 하나만 즉시 처리한다. sendTestPush와 같은
// 이유로 onCall + request.auth 검사(A-1 함정 1). 3시간 주기를 기다리지 않고
// 스케줄 로직 자체를 실기기로 즉시 검증할 유일한 경로다.
// maxInstances(S1/3) - 근거는 callGeminiText 위 주석 참고. 수동 발화 테스트용이라
// 3으로 낮게 잡는다.
export const triggerScheduledCheckTest = onCall(
  {region: "asia-northeast3", maxInstances: 3},
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "로그인이 필요합니다.");
    }
    // [appCheck] 계측(S2-a) - reqId 없음. 근거·판정 기준은 callGeminiText
    // 위 주석 참고.
    console.log(`[appCheck] fn=triggerScheduledCheckTest uid=${request.auth.uid} hasApp=${request.app != null}`);
    return await runScheduledCheckCore(request.auth.uid);
  }
);

// ── C-4b — 신규 업로드 토큰 처리(docs/task_signed_urls_v1.md §12) ──────
// A안(업로드 시 토큰 미생성)·B안(클라이언트 updateMetadata로 제거)은 실측으로
// 폐기됐다 - Firebase Storage REST(v0, 모든 클라이언트 SDK가 쓰는 계층)가
// firebaseStorageDownloadTokens 커스텀 메타데이터 키를 클라이언트 권한으로
// 건드리는 시도를 생성·수정 양쪽 다 400 "Not allowed to set custom metadata
// for firebaseStorageDownloadTokens"로 원천 차단한다(storage.rules의
// allow write와 무관 - REST 계층에서 이미 막힌다). 이 키를 지울 수 있는 건
// Admin SDK(원시 GCS JSON API 경유, revoke.py가 이미 이 경로로 성공)뿐이라
// C(서버 트리거)·D(주기 스윕) 조합으로만 구현 가능하다.
//
// revoke.py와 동일한 대상 프리픽스로 명시 제한한다 - 프리픽스 밖 객체까지
// 건드리면 이번 트랙의 원인이었던 사고(1곳만 배선 확인하고 전체 회수)와
// 같은 성격의 "범위 밖까지 건드림" 재발이다.
const TOKEN_REVOKE_PREFIXES = ["wardrobe_images/", "wardrobe_cutouts/", "fitting_results/"];
const TOKEN_KEY = "firebaseStorageDownloadTokens";

function isTokenRevocablePath(path: string): boolean {
  return TOKEN_REVOKE_PREFIXES.some((prefix) => path.startsWith(prefix));
}

// revoke.py의 "메타데이터 dict에서 키 하나만 지우고 patch"와 동일한 로직 -
// Admin SDK(@google-cloud/storage)는 raw GCS JSON API를 거치므로 REST(v0)의
// 클라이언트 차단 가드에 걸리지 않는다. 반환값은 (D) 스윕이 "몇 건 남아있었는지"
// 로그로 남기기 위한 것 - 이 숫자가 (C)의 건강 지표다(0이면 트리거가 잘 도는
// 것, 0이 아니면 트리거가 놓치는 경로가 있다는 신호).
async function revokeTokenIfPresent(
  bucket: ReturnType<ReturnType<typeof getStorage>["bucket"]>,
  path: string
): Promise<"revoked" | "already_clean"> {
  const file = bucket.file(path);
  const [metadata] = await file.getMetadata();
  const custom = (metadata.metadata ?? {}) as Record<string, string>;
  if (!(TOKEN_KEY in custom)) return "already_clean";

  const nextCustom = {...custom};
  delete nextCustom[TOKEN_KEY];
  await file.setMetadata({metadata: nextCustom});
  return "revoked";
}

// (C) 업로드 감지 즉시 토큰 회수. 업로드 자체(putFile/putData)는 이미
// finalize된 뒤에만 이 트리거가 발화하므로 실패해도 업로드를 막을 방법도
// 필요도 없다 - catch로 로그만 남기고 함수를 정상 종료한다(재시도 안 함,
// opts.retry 기본값 false).
// maxInstances(S1/3) - 근거는 callGeminiText 위 주석 참고.
// [appCheck] 계측(S2-a) 대상 아님 - Storage 이벤트 트리거라 공개 HTTP
// 엔드포인트가 없다(scheduledProactiveCheck와 같은 이유,
// docs/task_hardening_v2.md §3-2).
export const revokeTokenOnUpload = onObjectFinalized(
  {region: "asia-northeast3", maxInstances: 5},
  async (event) => {
    const path = event.data.name;
    if (!isTokenRevocablePath(path)) return;

    try {
      const bucket = getStorage().bucket(event.data.bucket);
      const result = await revokeTokenIfPresent(bucket, path);
      console.log(`[revokeTokenOnUpload] path=${path} result=${result}`);
    } catch (err) {
      // 업로드 자체는 이미 끝난 뒤라 여기서 실패해도 사용자에게 영향 없음 -
      // (D) 일 1회 스윕이 놓친 건을 회수한다. 로그만 남긴다.
      console.error(`[revokeTokenOnUpload] 회수 실패 path=${path}:`, err);
    }
  }
);

// (D) 일 1회 스윕 - (C)가 놓친 건(함수 장애·배포 공백 등)의 안전망.
// 잔여 토큰 건수를 로그로 남긴다 - 0이 계속 나오면 (C)가 정상 작동 중이라는
// 뜻이고, 0이 아닌 값이 반복되면 (C)가 놓치는 경로가 있다는 신호다.
// maxInstances(S1/3) - 근거는 callGeminiText 위 주석 참고. 일 1회 스윕은
// 중첩 실행이 흔치 않으므로 3으로 낮게 잡는다.
// [appCheck] 계측(S2-a) 대상 아님 - scheduledProactiveCheck와 같은 이유
// (공개 HTTP 엔드포인트 없음, docs/task_hardening_v2.md §3-2).
export const sweepStorageTokens = onSchedule(
  {schedule: "every 24 hours", region: "asia-northeast3", maxInstances: 3},
  async () => {
    const bucket = getStorage().bucket();
    let revoked = 0;
    let scanned = 0;

    for (const prefix of TOKEN_REVOKE_PREFIXES) {
      const [files] = await bucket.getFiles({prefix});
      for (const file of files) {
        scanned++;
        try {
          const result = await revokeTokenIfPresent(bucket, file.name);
          if (result === "revoked") revoked++;
        } catch (err) {
          console.error(`[sweepStorageTokens] 회수 실패 path=${file.name}:`, err);
        }
      }
    }

    // C-4b 설계(§12)의 "(C)의 건강 지표" - revoked가 계속 0이면 트리거가
    // 놓치는 게 없다는 뜻, 0이 아니면 트리거 지연/실패 경로가 있다는 신호.
    console.log(`[sweepStorageTokens] scanned=${scanned} revoked=${revoked}`);
  }
);
