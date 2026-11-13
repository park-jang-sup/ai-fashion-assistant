// strip_thought_signature.ts 단위 테스트 — payload_limit.test.ts와 같은 방식.
import * as assert from "node:assert";
import {stripThoughtSignatures} from "./strip_thought_signature";

function run(name: string, fn: () => void): void {
  try {
    fn();
    console.log(`PASS: ${name}`);
  } catch (err) {
    console.error(`FAIL: ${name}`);
    throw err;
  }
}

// inspect 실측과 같은 형태(키 이름·위치) — 값은 짧은 대역값.
function sampleResponse(): Record<string, unknown> {
  return {
    candidates: [{
      content: {
        role: "model",
        parts: [{inlineData: {mimeType: "image/jpeg", data: "IMG"}, thoughtSignature: "SIG".repeat(10)}],
      },
      finishReason: "STOP",
      index: 0,
    }],
    usageMetadata: {promptTokenCount: 6056, candidatesTokenCount: 1471},
    modelVersion: "gemini-nano-banana-2.1",
    responseId: "r1",
  };
}

run("thoughtSignature 키를 지우고 inlineData는 그대로 둔다", () => {
  const out = stripThoughtSignatures(sampleResponse()) as any;
  assert.deepStrictEqual(out.candidates[0].content.parts, [{inlineData: {mimeType: "image/jpeg", data: "IMG"}}]);
});

run("finishReason·index·role·usageMetadata·modelVersion·responseId는 그대로", () => {
  const out = stripThoughtSignatures(sampleResponse()) as any;
  assert.strictEqual(out.candidates[0].finishReason, "STOP");
  assert.strictEqual(out.candidates[0].index, 0);
  assert.strictEqual(out.candidates[0].content.role, "model");
  assert.deepStrictEqual(out.usageMetadata, {promptTokenCount: 6056, candidatesTokenCount: 1471});
  assert.strictEqual(out.modelVersion, "gemini-nano-banana-2.1");
  assert.strictEqual(out.responseId, "r1");
});

run("thought: true인 part는 뺀다(최종 이미지 part는 남김)", () => {
  const input = {candidates: [{content: {parts: [
    {inlineData: {mimeType: "image/jpeg", data: "THOUGHT"}, thought: true, thoughtSignature: "S"},
    {text: "draft", thought: true},
    {inlineData: {mimeType: "image/jpeg", data: "FINAL"}, thoughtSignature: "T"},
  ]}}]};
  const out = stripThoughtSignatures(input) as any;
  assert.deepStrictEqual(out.candidates[0].content.parts, [{inlineData: {mimeType: "image/jpeg", data: "FINAL"}}]);
});

run("snake_case thought_signature도 지운다", () => {
  const input = {candidates: [{content: {parts: [{inline_data: {data: "X"}, thought_signature: "S"}]}}]};
  const out = stripThoughtSignatures(input) as any;
  assert.deepStrictEqual(out.candidates[0].content.parts, [{inline_data: {data: "X"}}]);
});

run("thought가 true가 아니면(false·누락) part를 남긴다", () => {
  const input = {candidates: [{content: {parts: [{text: "a", thought: false}, {text: "b"}]}}]};
  const out = stripThoughtSignatures(input) as any;
  assert.deepStrictEqual(out.candidates[0].content.parts, [{text: "a", thought: false}, {text: "b"}]);
});

run("후보가 여러 개면 전부 처리한다", () => {
  const input = {candidates: [
    {content: {parts: [{text: "a", thoughtSignature: "S"}]}},
    {content: {parts: [{text: "b", thoughtSignature: "T"}]}},
  ]};
  const out = stripThoughtSignatures(input) as any;
  assert.deepStrictEqual(out.candidates.map((c: any) => c.content.parts), [[{text: "a"}], [{text: "b"}]]);
});

run("입력을 변형하지 않는다", () => {
  const input = sampleResponse();
  const before = JSON.stringify(input);
  stripThoughtSignatures(input);
  assert.strictEqual(JSON.stringify(input), before);
});

run("멱등 — 두 번 적용해도 한 번과 같다", () => {
  const once = stripThoughtSignatures(sampleResponse());
  assert.deepStrictEqual(stripThoughtSignatures(once), once);
});

run("축소 효과 — 서명이 빠진 만큼 직렬화 크기가 준다", () => {
  const input = sampleResponse();
  const out = stripThoughtSignatures(input);
  assert.ok(JSON.stringify(out).length < JSON.stringify(input).length);
});

run("총체성 — 예상 형태가 아니면 같은 값을 그대로 돌려준다(예외 없음)", () => {
  const odd: unknown[] = [
    null, undefined, 42, "text", [], [1, 2],
    {}, {error: {code: 400, message: "bad"}}, {candidates: "x"}, {candidates: null},
  ];
  for (const v of odd) assert.strictEqual(stripThoughtSignatures(v), v);
});

run("총체성 — candidate·content·parts가 이상해도 그 원소는 그대로 둔다", () => {
  const input = {candidates: [null, 3, {content: null}, {content: {parts: "x"}}, {content: {parts: [null, 1, "s"]}}]};
  const out = stripThoughtSignatures(input) as any;
  assert.deepStrictEqual(out.candidates, [null, 3, {content: null}, {content: {parts: "x"}}, {content: {parts: [null, 1, "s"]}}]);
});

console.log("전부 통과");
