// text_model_routes.ts 단위 테스트 — payload_limit.test.ts와 같은 방식.
import * as assert from "node:assert";
import {kindForModel} from "./payload_limit";
import {
  resolveModelRoute,
  TEXT_FALLBACK_ALIAS,
  TEXT_MODEL_ROUTES,
  TEXT_PRIMARY_ALIAS,
} from "./text_model_routes";

function run(name: string, fn: () => void): void {
  try {
    fn();
    console.log(`PASS: ${name}`);
  } catch (err) {
    console.error(`FAIL: ${name}`);
    throw err;
  }
}

const route = (m: string) => resolveModelRoute(m, kindForModel(m));

run("text-primary → claude:claude-sonnet-5-5", () => {
  assert.deepStrictEqual(route(TEXT_PRIMARY_ALIAS), {provider: "claude", model: "claude-sonnet-5-5"});
});

run("text-fallback → gemini:gemini-3.5-flash", () => {
  assert.deepStrictEqual(route(TEXT_FALLBACK_ALIAS), {provider: "gemini", model: "gemini-3.5-flash"});
});

run("배포된 APK의 기존 모델명은 자기 자신(gemini)으로 풀린다", () => {
  assert.deepStrictEqual(route("gemini-3.5-flash"), {provider: "gemini", model: "gemini-3.5-flash"});
  assert.deepStrictEqual(route("gemini-3.1-flash-lite"), {provider: "gemini", model: "gemini-3.1-flash-lite"});
});

run("이미지 모델은 Claude로 가지 않는다(자기 자신, gemini)", () => {
  for (const m of ["gemini-3.1-flash-image", "gemini-nano-banana-2.1"]) {
    assert.deepStrictEqual(route(m), {provider: "gemini", model: m});
  }
});

run("kind가 image면 별칭 이름이어도 gemini 자기 자신 — 이미지 요청이 Claude로 새지 않는다", () => {
  assert.deepStrictEqual(resolveModelRoute(TEXT_PRIMARY_ALIAS, "image"), {provider: "gemini", model: TEXT_PRIMARY_ALIAS});
});

run("주 모델과 폴백은 서로 다른 제공자다(제공자 장애에도 동작)", () => {
  const p = TEXT_MODEL_ROUTES[TEXT_PRIMARY_ALIAS];
  const f = TEXT_MODEL_ROUTES[TEXT_FALLBACK_ALIAS];
  assert.notStrictEqual(p.provider, f.provider);
  assert.notStrictEqual(p.model, f.model);
});

run("폴백은 Gemini다 — Claude 주 모델이 실패하면 Gemini로 끝낸다", () => {
  assert.strictEqual(TEXT_MODEL_ROUTES[TEXT_FALLBACK_ALIAS].provider, "gemini");
});

run("별칭은 text로 분류된다 — 페이로드·호출량 검사가 지금 텍스트 요청과 똑같이 적용", () => {
  assert.strictEqual(kindForModel(TEXT_PRIMARY_ALIAS), "text");
  assert.strictEqual(kindForModel(TEXT_FALLBACK_ALIAS), "text");
});

run("gemini-3.8-flash는 표에 없다(2단계 결정 3 — 쓰지 않음)", () => {
  assert.ok(!Object.values(TEXT_MODEL_ROUTES).some((r) => r.model === "gemini-3.8-flash"));
});

console.log("전부 통과");
