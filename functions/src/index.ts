import {onCall, HttpsError} from "firebase-functions/v2/https";
import {defineSecret} from "firebase-functions/params";

const geminiApiKey = defineSecret("GEMINI_API_KEY");

// 클라이언트 GeminiService의 _textModel/textModelFallback과 이 배열은 반드시
// 같은 커밋에서 함께 바꾼다. 어긋나면 폴백 경로만 조용히 invalid-argument로
// 죽는다 - 이 저장소는 모델을 이미 두 번 갈아탔다(gemini-3-flash-preview →
// 3.5-flash, 2.5-flash → 3.1-flash-lite).
// A-2에서 이미지 합성 모델(gemini-3.1-flash-image)을 옮길 때 이 배열에 추가한다.
const ALLOWED_MODELS = ["gemini-3.5-flash", "gemini-3.1-flash-lite"];

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
      headers: {"Content-Type": "application/json"},
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

    const key = geminiApiKey.value();
    const endpoint = request.acceptsStreaming ?
      `${GEMINI_BASE_URL}/models/${model}:streamGenerateContent?alt=sse&key=${key}` :
      `${GEMINI_BASE_URL}/models/${model}:generateContent?key=${key}`;

    const upstream = await fetchUpstream(endpoint, JSON.stringify(requestBody));

    if (!request.acceptsStreaming) {
      const text = await upstream.text();
      if (!upstream.ok) {
        const message = extractUpstreamErrorMessage(text);
        throw new HttpsError("internal", message, {
          upstreamStatus: upstream.status,
          upstreamMessage: message,
        });
      }
      return JSON.parse(text);
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
      const {done, value} = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, {stream: true});
      const lines = buffer.split("\n");
      buffer = lines.pop() ?? "";
      for (const line of lines) {
        if (!line.startsWith("data:")) continue;
        const jsonStr = line.slice(5).trim();
        if (!jsonStr) continue;
        response?.sendChunk(JSON.parse(jsonStr));
      }
    }
    // 최종 반환값은 쓰지 않는다 - 클라이언트가 청크를 누적해 직접 파싱한다.
    return {};
  }
);
