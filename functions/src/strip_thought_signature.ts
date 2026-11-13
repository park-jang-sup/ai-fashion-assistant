// 이미지 응답 축소 — docs/task_fitting_quality_v2.md §7 [1].
//
// gemini-nano-banana-2.1 응답의 80~85%가 thoughtSignature다(프로브 inspect
// 실측 2026-11-13: 응답 4.7~6.8MB 중 서명 3.8~5.7MB, 최종 이미지 약 1MB,
// thought 이미지 0). 서명은 다음 턴에 되돌려 보내 추론 맥락을 잇는 용도인데
// 가상 피팅은 단일 턴이라 쓰지 않는다. 그래서 클라이언트로 돌려주기 전에
// candidates[*].content.parts[*]에서 thoughtSignature 키를 지우고
// thought: true인 part(추론 중간 산출물)는 뺀다. 그 외 필드(inlineData,
// text, finishReason, usageMetadata 등)는 그대로 둔다.
//
// 총체적(total) 순수 함수다 — 입력이 예상 형태가 아니면(객체 아님,
// candidates 없음, 오류 응답 등) 아무것도 바꾸지 않고 같은 값을 돌려주며
// 예외를 던지지 않는다. 입력은 변형하지 않는다(바뀌는 경로만 얕게 복사) —
// generateFittingImage가 원본에서 Storage용 이미지를 꺼내는 순서와 무관하게
// 저장 이미지가 같게 하려는 것.

type JsonObject = Record<string, unknown>;

const SIGNATURE_KEYS = ["thoughtSignature", "thought_signature"];

function isObject(v: unknown): v is JsonObject {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function stripParts(parts: unknown[]): unknown[] {
  return parts
    .filter((p) => !(isObject(p) && p.thought === true))
    .map((p) => {
      if (!isObject(p) || !SIGNATURE_KEYS.some((k) => k in p)) return p;
      const copy: JsonObject = {...p};
      for (const k of SIGNATURE_KEYS) delete copy[k];
      return copy;
    });
}

export function stripThoughtSignatures(response: unknown): unknown {
  if (!isObject(response) || !Array.isArray(response.candidates)) return response;
  const candidates = response.candidates.map((c) => {
    if (!isObject(c) || !isObject(c.content) || !Array.isArray(c.content.parts)) return c;
    return {...c, content: {...c.content, parts: stripParts(c.content.parts)}};
  });
  return {...response, candidates};
}
