// Gemini 형식 ↔ Claude Messages API 변환기 — docs/task_text_model_v1.md §4-B·
// 2단계 결정 1·2·4.
//
// 클라이언트는 지금처럼 Gemini 형식 요청(contents/parts/generationConfig)을
// 보내고, 응답도 Gemini 형식(candidates[0].content.parts[0].text)으로 받는다.
// 이 파일은 그 사이를 바꾸는 순수 함수만 담는다(네트워크 없음) — 클라이언트
// 파싱 코드는 바뀌지 않는다.
//
// 요청 규칙(프로브가 C에 보낸 요청과 같다 — claude_adapter.test.ts가
// tools/text_probe 픽스처로 대조한다):
// - parts의 text → text 블록, inlineData → base64 image 블록(순서 유지).
// - systemInstruction → system. temperature 등 샘플링 값은 버린다(Sonnet 5.5는
//   기본값이 아니면 400 — 프로브 §3-2 실측).
// - thinking: between_tools(사고 끔 — disabled는 400, 프로브 실측).
// - effort: generationConfig.thinkingConfig.thinkingBudget이 0이면 low(JSON
//   호출), 아니면 medium(분석·자기평가·스트리밍 분석).
// - max_tokens: 프로브 정책 그대로 — maxOutputTokens가 800 이하면 그 값(속성
//   추출·사이즈표, 프로브 T2에서 800으로 잘림 없음 확인), 그 외에는
//   max(maxOutputTokens, 4000)(분석 3000·주간 플랜 2000 → 4000).
//
// 응답 규칙: type이 text인 블록만 이어 붙여 parts[0].text에 넣는다.
// stop_reason이 refusal이거나 본문이 비어 있으면 실패로 돌려준다 — 호출부가
// 다른 Claude 오류와 똑같이 503으로 바꿔 클라이언트 폴백(Gemini)을 타게 한다.

export const CLAUDE_API_URL = "https://api.anthropic.com/v1/messages";
export const CLAUDE_API_VERSION = "2023-06-01";
export const CLAUDE_THINKING = {type: "between_tools"} as const;
const MAX_TOKENS_SMALL_LIMIT = 800;
const MAX_TOKENS_FLOOR = 4000;

type Json = Record<string, unknown>;

const isObject = (v: unknown): v is Json => typeof v === "object" && v !== null && !Array.isArray(v);

export class ClaudeAdapterError extends Error {}

export function claudeEffortFor(generationConfig: unknown): "low" | "medium" {
  const tc = isObject(generationConfig) ? generationConfig.thinkingConfig : undefined;
  return isObject(tc) && tc.thinkingBudget === 0 ? "low" : "medium";
}

export function claudeMaxTokensFor(generationConfig: unknown): number {
  const mot = isObject(generationConfig) ? generationConfig.maxOutputTokens : undefined;
  if (typeof mot === "number" && mot > 0 && mot <= MAX_TOKENS_SMALL_LIMIT) return mot;
  return Math.max(typeof mot === "number" ? mot : 0, MAX_TOKENS_FLOOR);
}

function toBlocks(parts: unknown): Json[] {
  if (!Array.isArray(parts)) throw new ClaudeAdapterError("parts가 배열이 아닙니다");
  return parts.map((p) => {
    if (isObject(p) && typeof p.text === "string") return {type: "text", text: p.text};
    const d = isObject(p) ? (p.inlineData ?? p.inline_data) : undefined;
    if (isObject(d) && typeof d.data === "string") {
      const mime = d.mimeType ?? d.mime_type;
      return {type: "image", source: {type: "base64", media_type: typeof mime === "string" ? mime : "image/jpeg", data: d.data}};
    }
    throw new ClaudeAdapterError("변환할 수 없는 part");
  });
}

// Gemini 형식 requestBody → Claude Messages 요청 본문. 형태가 예상과 다르면
// ClaudeAdapterError — 호출부가 503(폴백)으로 바꾼다.
export function toClaudeRequest(requestBody: unknown, model: string, stream: boolean): Json {
  if (!isObject(requestBody) || !Array.isArray(requestBody.contents) || requestBody.contents.length === 0) {
    throw new ClaudeAdapterError("contents가 없습니다");
  }
  const messages = requestBody.contents.map((c) => {
    if (!isObject(c)) throw new ClaudeAdapterError("content가 객체가 아닙니다");
    return {role: c.role === "model" ? "assistant" : "user", content: toBlocks(c.parts)};
  });
  const gc = requestBody.generationConfig;
  const body: Json = {
    model,
    max_tokens: claudeMaxTokensFor(gc),
    messages,
    thinking: {...CLAUDE_THINKING},
    output_config: {effort: claudeEffortFor(gc)},
  };
  const si = requestBody.systemInstruction ?? requestBody.system_instruction;
  if (isObject(si) && Array.isArray(si.parts)) {
    const text = si.parts.map((p) => (isObject(p) && typeof p.text === "string" ? p.text : "")).join("\n").trim();
    if (text) body.system = text;
  }
  if (stream) body.stream = true;
  return body;
}

const FINISH = {end_turn: "STOP", stop_sequence: "STOP", max_tokens: "MAX_TOKENS"} as Record<string, string>;

function geminiChunk(text: string, extra: Json = {}): Json {
  return {candidates: [{content: {role: "model", parts: [{text}]}, index: 0, ...extra}]};
}

export type ClaudeConversion = {ok: true; body: Json} | {ok: false; reason: string};

// Claude 비스트리밍 응답 → Gemini 형식 응답.
export function fromClaudeResponse(response: unknown, model: string): ClaudeConversion {
  if (!isObject(response) || !Array.isArray(response.content)) return {ok: false, reason: "invalid-response"};
  if (response.stop_reason === "refusal") return {ok: false, reason: "refusal"};
  const text = response.content
    .filter((b) => isObject(b) && b.type === "text" && typeof b.text === "string")
    .map((b) => (b as Json).text as string)
    .join("");
  if (!text.trim()) return {ok: false, reason: "empty-text"};
  const usage = isObject(response.usage) ? response.usage : {};
  const input = typeof usage.input_tokens === "number" ? usage.input_tokens : 0;
  const output = typeof usage.output_tokens === "number" ? usage.output_tokens : 0;
  const stop = typeof response.stop_reason === "string" ? response.stop_reason : "";
  return {ok: true, body: {
    ...geminiChunk(text, {finishReason: FINISH[stop] ?? "STOP"}),
    usageMetadata: {promptTokenCount: input, candidatesTokenCount: output, totalTokenCount: input + output},
    modelVersion: typeof response.model === "string" ? response.model : model,
  }};
}

// Claude 스트리밍 이벤트(SSE data JSON) → Gemini 형식 청크. text_delta마다
// 클라이언트가 지금 읽는 모양(candidates[0].content.parts[0].text)의 청크를
// 하나씩 만든다. finish()는 끝에 거절·빈 본문이면 실패를 돌려준다.
export function createClaudeStreamTranslator() {
  let text = "";
  let stopReason: string | null = null;
  let errorMessage: string | null = null;
  return {
    push(event: unknown): Json | null {
      if (!isObject(event)) return null;
      if (event.type === "content_block_delta" && isObject(event.delta) &&
          event.delta.type === "text_delta" && typeof event.delta.text === "string") {
        text += event.delta.text;
        return event.delta.text ? geminiChunk(event.delta.text) : null;
      }
      if (event.type === "message_delta" && isObject(event.delta) && typeof event.delta.stop_reason === "string") {
        stopReason = event.delta.stop_reason;
      }
      if (event.type === "error") {
        errorMessage = isObject(event.error) && typeof event.error.message === "string" ? event.error.message : "stream error";
      }
      return null;
    },
    finish(): {ok: true; text: string} | {ok: false; reason: string} {
      if (errorMessage) return {ok: false, reason: `error: ${errorMessage}`};
      if (stopReason === "refusal") return {ok: false, reason: "refusal"};
      if (!text.trim()) return {ok: false, reason: "empty-text"};
      return {ok: true, text};
    },
  };
}
