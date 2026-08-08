// payload_limit.ts 단위 테스트 — rate_limit.test.ts와 같은 방식
// (node:assert 직접 사용, tsc로 컴파일된 lib/payload_limit.test.js를
// node로 실행. package.json의 "test" 스크립트 참고).
import * as assert from "node:assert";
import {evaluatePayloadLimit, kindForModel, PayloadLimitConfig} from "./payload_limit";

const CONFIG: PayloadLimitConfig = {textLimitBytes: 4_000_000, imageLimitBytes: 16_000_000};

function run(name: string, fn: () => void): void {
  try {
    fn();
    console.log(`PASS: ${name}`);
  } catch (err) {
    console.error(`FAIL: ${name}`);
    throw err;
  }
}

run("kindForModel — 이미지 모델이면 image", () => {
  assert.strictEqual(kindForModel("gemini-3.1-flash-image"), "image");
});

run("kindForModel — 텍스트 모델(3.5-flash)이면 text", () => {
  assert.strictEqual(kindForModel("gemini-3.5-flash"), "text");
});

run("kindForModel — 텍스트 폴백 모델(3.1-flash-lite)이면 text", () => {
  assert.strictEqual(kindForModel("gemini-3.1-flash-lite"), "text");
});

run("kindForModel — 알 수 없는 model 문자열은 text로 떨어진다(더 낮은 상한 쪽 방어)", () => {
  assert.strictEqual(kindForModel("some-unknown-model"), "text");
  assert.strictEqual(kindForModel(""), "text");
});

run("text 상한 미만 — 허용", () => {
  const decision = evaluatePayloadLimit(3_999_999, "text", CONFIG);
  assert.strictEqual(decision.allowed, true);
  assert.strictEqual(decision.limitBytes, CONFIG.textLimitBytes);
});

run("text 상한 경계값(==) — 허용(상한은 포함 경계)", () => {
  const decision = evaluatePayloadLimit(4_000_000, "text", CONFIG);
  assert.strictEqual(decision.allowed, true);
});

run("text 상한 초과(경계값+1) — 거부", () => {
  const decision = evaluatePayloadLimit(4_000_001, "text", CONFIG);
  assert.strictEqual(decision.allowed, false);
  assert.strictEqual(decision.limitBytes, CONFIG.textLimitBytes);
});

run("image 상한 미만 — 허용", () => {
  const decision = evaluatePayloadLimit(15_999_999, "image", CONFIG);
  assert.strictEqual(decision.allowed, true);
  assert.strictEqual(decision.limitBytes, CONFIG.imageLimitBytes);
});

run("image 상한 경계값(==) — 허용", () => {
  const decision = evaluatePayloadLimit(16_000_000, "image", CONFIG);
  assert.strictEqual(decision.allowed, true);
});

run("image 상한 초과(경계값+1) — 거부", () => {
  const decision = evaluatePayloadLimit(16_000_001, "image", CONFIG);
  assert.strictEqual(decision.allowed, false);
  assert.strictEqual(decision.limitBytes, CONFIG.imageLimitBytes);
});

run("kind별 상한이 독립적으로 적용된다 — text 상한 초과 값도 image 기준으로는 통과", () => {
  const decision = evaluatePayloadLimit(5_000_000, "image", CONFIG);
  assert.strictEqual(decision.allowed, true);
  assert.strictEqual(decision.limitBytes, CONFIG.imageLimitBytes);
});

run("0바이트 — 허용(음수·NaN 방어는 호출부 책임, 여기선 순수 비교만)", () => {
  const decision = evaluatePayloadLimit(0, "text", CONFIG);
  assert.strictEqual(decision.allowed, true);
});

console.log("전부 통과");
