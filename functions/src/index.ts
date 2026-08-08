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

// 업스트림이 멈추면 함수 자체 타임아웃까지 무한정 붙들리므로, 클라이언트의
// 기존 .timeout(60초)와 같은 의도로 그보다 살짝 짧게 직접 끊는다.
const UPSTREAM_TIMEOUT_MS = 55_000;

function extractUpstreamErrorMessage(rawBody: string): string {
  try {
    const parsed = JSON.parse(rawBody);
    return (parsed?.error?.message as string | undefined) ?? "알 수 없는 오류";
  } catch {
    return "알 수 없는 오류";
  }
}

async function fetchUpstream(endpoint: string, body: string): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), UPSTREAM_TIMEOUT_MS);
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
const RATE_LIMIT_CONFIG: RateLimitConfig = {textLimit: 60, imageLimit: 20, signLimit: 120};

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
export const callGeminiText = onCall(
  {secrets: [geminiApiKey], region: "asia-northeast3", timeoutSeconds: 60},
  async (request, response) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "로그인이 필요합니다.");
    }

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
    console.log(`[callGeminiText] model=${model} requestBytes=${requestBytes}`);

    // 호출량 상한과 같은 model→kind 파생을 쓴다(payload_limit.ts
    // kindForModel - 단일 출처, 이전엔 여기 인라인 삼항연산자였다).
    const kind = kindForModel(model);

    // 페이로드 크기 상한(handoff_2026-08-07.md §6 (4)) - 근거·상한값
    // 도출 과정은 payload_limit.ts 상단 주석 참고.
    //
    // 설계판단(가): 이 검사를 호출량 상한(checkAndRecordRateLimit)보다
    // 앞에 둔다. 상한 초과 요청은 현실적으로 악의적 남용이 아니라
    // 클라이언트 버그 조건(예: 리사이즈 누락)에 가깝고, 그런 요청
    // 때문에 정상 사용자의 시간당 호출 할당량이 깎이면 안 된다. 대가로
    // "값싼 거부를 무제한 반복"할 수 있는 문이 열리지만 - 이 경로는
    // Gemini를 타지 않으므로 비용은 함수 호출 자체뿐이다. 그 천장은
    // 원래 maxInstances가 잡아야 하는데, **이 함수엔 현재 maxInstances가
    // 설정돼 있지 않다**(코드 확인 - onCall 옵션에 secrets/region/
    // timeoutSeconds뿐) - 이 트레이드오프의 다른 절반이 아직 안 닫혀
    // 있다는 뜻이며, 별도 항목으로 남긴다(이번 범위 아님).
    const payloadDecision = evaluatePayloadLimit(requestBytes, kind, PAYLOAD_LIMIT_CONFIG);
    if (!payloadDecision.allowed) {
      console.log(
        `[payloadLimit] 초과 uid=${request.auth.uid} kind=${kind} ` +
          `requestBytes=${requestBytes} limitBytes=${payloadDecision.limitBytes}`
      );
      // 설계판단(나): upstream 오류가 details에 upstreamStatus/
      // upstreamMessage를 싣는 것과 같은 형식으로, 로그 없이도 원인을
      // 알 수 있게 requestBytes/limitBytes/kind를 싣는다.
      throw new HttpsError("invalid-argument", "요청 페이로드가 너무 큽니다.", {
        requestBytes,
        limitBytes: payloadDecision.limitBytes,
        kind,
      });
    }

    // 계수 시점은 상류 호출 전 - 실패할 요청도 셈한다(실패를 반복 때리는
    // 것도 남용이다). resource-exhausted를 던지면 여기서 함수가 끝나
    // fetchUpstream은 아예 호출되지 않는다.
    await checkAndRecordRateLimit(request.auth.uid, kind);

    const key = geminiApiKey.value();
    const endpoint = request.acceptsStreaming ?
      `${GEMINI_BASE_URL}/models/${model}:streamGenerateContent?alt=sse&key=${key}` :
      `${GEMINI_BASE_URL}/models/${model}:generateContent?key=${key}`;

    const upstream = await fetchUpstream(endpoint, requestBodyJson);

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
        return JSON.parse(text);
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
    // 최종 반환값은 쓰지 않는다 - 클라이언트가 청크를 누적해 직접 파싱한다.
    return {};
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

export const getSignedImageUrls = onCall(
  {region: "asia-northeast3"},
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "로그인이 필요합니다.");
    }
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
export const sendTestPush = onCall(
  {region: "asia-northeast3"},
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "로그인이 필요합니다.");
    }

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
async function recordServerInvocation(
  uid: string,
  triggered: boolean,
  sendResult?: {successCount: number; failureCount: number}
): Promise<void> {
  const db = getFirestore();
  const docRef = db.collection("users").doc(uid).collection("agent_meta").doc("background");
  const now = Timestamp.now();

  try {
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(docRef);
      const currentLog = (snap.data()?.serverInvocationLog as unknown[] | undefined) ?? [];
      const entry = sendResult ?
        {at: now, triggered, successCount: sendResult.successCount, failureCount: sendResult.failureCount} :
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

  let sendResult: {successCount: number; failureCount: number} | undefined;

  if (tokens.length > 0) {
    // [3] data 페이로드로 서버 발화임을 클라이언트가 구분할 수 있게 한다 -
    // 안 그러면 탭 이후 경로에서 기기 발화와 서버 발화가 다시 섞인다(함정 8이
    // 막으려는 것이 서버 쪽 기록만은 아니다). 채널은 B단계와 동일하게
    // agent_recommendation.
    const response = await getMessaging().sendEachForMulticast({
      tokens,
      notification: {
        title: "DOT",
        body: "다가오는 일정에 맞는 코디를 준비했어요",
      },
      data: {source: "server_scheduler", targetDate: targetDateStr},
      android: {notification: {channelId: FCM_NOTIFICATION_CHANNEL_ID}},
    });
    sendResult = {successCount: response.successCount, failureCount: response.failureCount};
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
export const scheduledProactiveCheck = onSchedule(
  {schedule: "every 3 hours", region: "asia-northeast3"},
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
export const triggerScheduledCheckTest = onCall(
  {region: "asia-northeast3"},
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "로그인이 필요합니다.");
    }
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
export const revokeTokenOnUpload = onObjectFinalized(
  {region: "asia-northeast3"},
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
export const sweepStorageTokens = onSchedule(
  {schedule: "every 24 hours", region: "asia-northeast3"},
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
