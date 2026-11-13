// claude_adapter.ts 단위 테스트 — payload_limit.test.ts와 같은 방식.
// 요청 대조는 tools/text_probe가 만든 픽스처(fixtures/claude_probe_fixtures.json,
// `node probe.mjs fixtures`)를 쓴다 — 프로브가 C에 실제로 보낸 요청과 같은
// 함수로 만든 요청이다(이미지 base64만 앞 64자로 잘라 양쪽에 같게 둠).
// 응답 픽스처는 프로브 결과에 남은 C의 실제 본문·토큰·stop_reason으로 다시
// 만든 Messages 응답 모양이다.
import * as assert from "node:assert";
import {readFileSync} from "node:fs";
import {join} from "node:path";
import {
  claudeEffortFor,
  claudeMaxTokensFor,
  createClaudeStreamTranslator,
  fromClaudeResponse,
  toClaudeRequest,
} from "./claude_adapter";

function run(name: string, fn: () => void): void {
  try {
    fn();
    console.log(`PASS: ${name}`);
  } catch (err) {
    console.error(`FAIL: ${name}`);
    throw err;
  }
}

// 컴파일 결과는 lib/에서 돌므로 src/fixtures를 상대 경로로 읽는다.
const fixtures = JSON.parse(
  readFileSync(join(__dirname, "..", "src", "fixtures", "claude_probe_fixtures.json"), "utf8")
);
const MODEL = "claude-sonnet-5-5";

// ── 요청: 프로브와 같은 요청 ───────────────────────────────────────
for (const f of fixtures.requests) {
  run(`요청 ${f.task}(effort ${f.effort}${f.stream ? ", 스트리밍" : ""}) — 프로브가 C에 보낸 요청과 같다`, () => {
    assert.deepStrictEqual(toClaudeRequest(f.geminiRequest, MODEL, f.stream), f.claudeRequest);
  });
}

run("effort — thinkingBudget 0이면 low, 아니면 medium", () => {
  assert.strictEqual(claudeEffortFor({thinkingConfig: {thinkingBudget: 0}}), "low");
  assert.strictEqual(claudeEffortFor({temperature: 0.7, maxOutputTokens: 3000}), "medium");
  assert.strictEqual(claudeEffortFor({thinkingConfig: {thinkingBudget: 512}}), "medium");
  assert.strictEqual(claudeEffortFor(undefined), "medium");
});

run("max_tokens — 800 이하는 그대로, 그 외 max(값, 4000)", () => {
  assert.strictEqual(claudeMaxTokensFor({maxOutputTokens: 800}), 800); // 속성 추출·사이즈표
  assert.strictEqual(claudeMaxTokensFor({maxOutputTokens: 2000}), 4000); // 주간 플랜
  assert.strictEqual(claudeMaxTokensFor({maxOutputTokens: 3000}), 4000); // 분석
  assert.strictEqual(claudeMaxTokensFor({maxOutputTokens: 8000}), 8000);
  assert.strictEqual(claudeMaxTokensFor({}), 4000);
});

run("temperature·responseMimeType 등 Gemini 설정은 Claude 요청에 실리지 않는다", () => {
  const body = toClaudeRequest({contents: [{parts: [{text: "x"}]}],
    generationConfig: {temperature: 0.2, responseMimeType: "application/json", maxOutputTokens: 800}}, MODEL, false);
  assert.deepStrictEqual(Object.keys(body).sort(), ["max_tokens", "messages", "model", "output_config", "thinking"]);
});

run("이미지는 base64 image 블록, 순서 유지, mimeType 그대로", () => {
  const body = toClaudeRequest({contents: [{parts: [
    {text: "a"}, {inlineData: {mimeType: "image/png", data: "QUJD"}}, {text: "b"},
  ]}]}, MODEL, false) as any;
  assert.deepStrictEqual(body.messages[0].content, [
    {type: "text", text: "a"},
    {type: "image", source: {type: "base64", media_type: "image/png", data: "QUJD"}},
    {type: "text", text: "b"},
  ]);
});

run("systemInstruction → system", () => {
  const body = toClaudeRequest({systemInstruction: {parts: [{text: "규칙"}]}, contents: [{parts: [{text: "x"}]}]}, MODEL, false);
  assert.strictEqual(body.system, "규칙");
});

run("형태가 예상과 다르면 예외(호출부가 503 폴백으로 바꾼다)", () => {
  for (const bad of [null, {}, {contents: []}, {contents: [{parts: [{foo: 1}]}]}, {contents: [{parts: "x"}]}]) {
    assert.throws(() => toClaudeRequest(bad, MODEL, false));
  }
});

// ── 응답 ──────────────────────────────────────────────────────────
for (const [task, resp] of Object.entries(fixtures.responses) as [string, any][]) {
  run(`응답 ${task} — text 블록 본문이 parts[0].text로, 클라이언트 파싱 모양 그대로`, () => {
    const r = fromClaudeResponse(resp, MODEL);
    assert.ok(r.ok);
    const body = (r as any).body;
    assert.strictEqual(body.candidates[0].content.parts[0].text, resp.content[0].text);
    assert.strictEqual(body.candidates[0].finishReason, "STOP");
    assert.strictEqual(body.modelVersion, MODEL);
    assert.strictEqual(body.usageMetadata.candidatesTokenCount, resp.usage.output_tokens ?? 0);
  });
}

run("응답 — thinking 등 text가 아닌 블록은 건너뛰고 text 블록만 잇는다", () => {
  const r = fromClaudeResponse({content: [{type: "thinking", thinking: ""}, {type: "text", text: "가"}, {type: "text", text: "나"}],
    stop_reason: "end_turn", usage: {}}, MODEL) as any;
  assert.strictEqual(r.body.candidates[0].content.parts[0].text, "가나");
});

run("응답 — max_tokens로 끊기면 MAX_TOKENS(클라이언트 JSON 파싱이 실패하면 기존 FormatException 폴백)", () => {
  const r = fromClaudeResponse({content: [{type: "text", text: "{\"a\""}], stop_reason: "max_tokens", usage: {}}, MODEL) as any;
  assert.strictEqual(r.body.candidates[0].finishReason, "MAX_TOKENS");
});

run("거절 — stop_reason refusal이면 실패", () => {
  assert.deepStrictEqual(fromClaudeResponse({content: [{type: "text", text: "x"}], stop_reason: "refusal"}, MODEL),
    {ok: false, reason: "refusal"});
});

run("거절 — text 블록이 비었거나 공백뿐이면 실패", () => {
  assert.deepStrictEqual(fromClaudeResponse({content: [], stop_reason: "end_turn"}, MODEL), {ok: false, reason: "empty-text"});
  assert.deepStrictEqual(fromClaudeResponse({content: [{type: "text", text: "  "}], stop_reason: "end_turn"}, MODEL),
    {ok: false, reason: "empty-text"});
});

run("응답 형태가 아니면 실패(예외 없음)", () => {
  for (const bad of [null, "x", {}, {content: "x"}]) assert.strictEqual(fromClaudeResponse(bad, MODEL).ok, false);
});

// ── 스트리밍 ──────────────────────────────────────────────────────
run("스트리밍 — text_delta마다 Gemini 청크 하나, 이어 붙이면 원문과 같다", () => {
  const t = createClaudeStreamTranslator();
  const chunks = fixtures.stream.events.map((e: unknown) => t.push(e)).filter(Boolean) as any[];
  assert.strictEqual(chunks.length, fixtures.stream.events.filter((e: any) => e.type === "content_block_delta").length);
  assert.strictEqual(chunks.map((c) => c.candidates[0].content.parts[0].text).join(""), fixtures.stream.text);
  assert.deepStrictEqual(t.finish(), {ok: true, text: fixtures.stream.text});
});

run("스트리밍 — ping·message_start 등은 청크를 만들지 않는다", () => {
  const t = createClaudeStreamTranslator();
  for (const e of [{type: "message_start"}, {type: "ping"}, {type: "content_block_start"}, {type: "message_stop"}]) {
    assert.strictEqual(t.push(e), null);
  }
});

run("스트리밍 — 거절·빈 본문·error 이벤트는 finish에서 실패", () => {
  const a = createClaudeStreamTranslator();
  a.push({type: "content_block_delta", delta: {type: "text_delta", text: "부분"}});
  a.push({type: "message_delta", delta: {stop_reason: "refusal"}});
  assert.deepStrictEqual(a.finish(), {ok: false, reason: "refusal"});
  const b = createClaudeStreamTranslator();
  b.push({type: "message_delta", delta: {stop_reason: "end_turn"}});
  assert.deepStrictEqual(b.finish(), {ok: false, reason: "empty-text"});
  const c = createClaudeStreamTranslator();
  c.push({type: "content_block_delta", delta: {type: "text_delta", text: "x"}});
  c.push({type: "error", error: {type: "overloaded_error", message: "Overloaded"}});
  assert.deepStrictEqual(c.finish(), {ok: false, reason: "error: Overloaded"});
});

console.log("전부 통과");
