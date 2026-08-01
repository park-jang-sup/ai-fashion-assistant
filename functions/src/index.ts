import {onCall, HttpsError} from "firebase-functions/v2/https";
import {defineSecret} from "firebase-functions/params";

const geminiApiKey = defineSecret("GEMINI_API_KEY");

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
    // 않고 바이트 수만 남긴다.
    console.log(
      `[callGeminiText] model=${model} requestBytes=${Buffer.byteLength(requestBodyJson, "utf8")}`
    );

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
