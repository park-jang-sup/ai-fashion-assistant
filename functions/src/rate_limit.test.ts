// rate_limit.ts 단위 테스트 — jest 등 테스트 러너가 functions/에 없어
// node:assert로 직접 짠다(tsc로 컴파일된 lib/rate_limit.test.js를
// node로 실행, package.json의 "test" 스크립트 참고). 실패하면 assert가
// 던지고 프로세스가 0이 아닌 코드로 종료한다.
import * as assert from "node:assert";
import {evaluateRateLimit, utcHourBucket, RateLimitState} from "./rate_limit";

const CONFIG = {textLimit: 3, imageLimit: 2, signLimit: 2};

function run(name: string, fn: () => void): void {
  try {
    fn();
    console.log(`PASS: ${name}`);
  } catch (err) {
    console.error(`FAIL: ${name}`);
    throw err;
  }
}

run("첫 호출 — 상태 없음이면 카운트 1로 시작하고 허용", () => {
  const now = new Date("2026-08-06T10:15:00Z");
  const decision = evaluateRateLimit(undefined, now, "text", CONFIG);
  assert.strictEqual(decision.allowed, true);
  assert.strictEqual(decision.nextState.textCount, 1);
  assert.strictEqual(decision.nextState.imageCount, 0);
  assert.strictEqual(decision.nextState.signCount, 0);
  assert.strictEqual(decision.nextState.rejectedCount, 0);
  assert.strictEqual(decision.nextState.bucket, utcHourBucket(now));
});

run("한도 미만 — 계속 허용하며 카운트만 누적", () => {
  const now = new Date("2026-08-06T10:15:00Z");
  const state: RateLimitState = {bucket: utcHourBucket(now), textCount: 1, imageCount: 0, signCount: 0, rejectedCount: 0};
  const decision = evaluateRateLimit(state, now, "text", CONFIG);
  assert.strictEqual(decision.allowed, true);
  assert.strictEqual(decision.nextState.textCount, 2);
});

run("한도 직전(count == limit-1) — 허용하고 카운트가 한도에 도달", () => {
  const now = new Date("2026-08-06T10:15:00Z");
  const state: RateLimitState = {bucket: utcHourBucket(now), textCount: 2, imageCount: 0, signCount: 0, rejectedCount: 0};
  const decision = evaluateRateLimit(state, now, "text", CONFIG);
  assert.strictEqual(decision.allowed, true);
  assert.strictEqual(decision.nextState.textCount, 3);
});

run("한도 도달(count == limit) — 거부하고 rejectedCount만 증가, textCount는 그대로", () => {
  const now = new Date("2026-08-06T10:15:00Z");
  const state: RateLimitState = {bucket: utcHourBucket(now), textCount: 3, imageCount: 0, signCount: 0, rejectedCount: 0};
  const decision = evaluateRateLimit(state, now, "text", CONFIG);
  assert.strictEqual(decision.allowed, false);
  assert.strictEqual(decision.nextState.textCount, 3);
  assert.strictEqual(decision.nextState.rejectedCount, 1);
});

run("한도 초과 직후 연속 거부 — rejectedCount가 계속 누적", () => {
  const now = new Date("2026-08-06T10:15:00Z");
  const state: RateLimitState = {bucket: utcHourBucket(now), textCount: 3, imageCount: 0, signCount: 0, rejectedCount: 4};
  const decision = evaluateRateLimit(state, now, "text", CONFIG);
  assert.strictEqual(decision.allowed, false);
  assert.strictEqual(decision.nextState.rejectedCount, 5);
});

run("텍스트/이미지/서명 카운트는 독립 — 이미지가 한도여도 텍스트는 영향 없음", () => {
  const now = new Date("2026-08-06T10:15:00Z");
  const state: RateLimitState = {bucket: utcHourBucket(now), textCount: 0, imageCount: 2, signCount: 0, rejectedCount: 0};
  const decision = evaluateRateLimit(state, now, "text", CONFIG);
  assert.strictEqual(decision.allowed, true);
  assert.strictEqual(decision.nextState.textCount, 1);
  assert.strictEqual(decision.nextState.imageCount, 2);
  assert.strictEqual(decision.nextState.signCount, 0);
});

run("이미지 한도 도달 — 거부", () => {
  const now = new Date("2026-08-06T10:15:00Z");
  const state: RateLimitState = {bucket: utcHourBucket(now), textCount: 0, imageCount: 2, signCount: 0, rejectedCount: 0};
  const decision = evaluateRateLimit(state, now, "image", CONFIG);
  assert.strictEqual(decision.allowed, false);
  assert.strictEqual(decision.nextState.imageCount, 2);
  assert.strictEqual(decision.nextState.rejectedCount, 1);
});

run("서명(sign) 카운트 — 독립적으로 누적되고 한도에서 거부", () => {
  const now = new Date("2026-08-06T10:15:00Z");
  const state: RateLimitState = {bucket: utcHourBucket(now), textCount: 5, imageCount: 5, signCount: 1, rejectedCount: 0};
  const ok = evaluateRateLimit(state, now, "sign", CONFIG);
  assert.strictEqual(ok.allowed, true);
  assert.strictEqual(ok.nextState.signCount, 2);
  assert.strictEqual(ok.nextState.textCount, 5);
  const denied = evaluateRateLimit(ok.nextState, now, "sign", CONFIG);
  assert.strictEqual(denied.allowed, false);
  assert.strictEqual(denied.nextState.signCount, 2);
  assert.strictEqual(denied.nextState.rejectedCount, 1);
});

run("레거시 문서(signCount 필드 없음)도 같은 버킷이면 0으로 취급 — NaN 오염 방지", () => {
  const now = new Date("2026-08-06T10:15:00Z");
  // 스키마 확장 전에 저장된 문서를 흉내낸다 — as로 signCount 없는 형태를 강제.
  const legacyState = {bucket: utcHourBucket(now), textCount: 1, imageCount: 0, rejectedCount: 0} as RateLimitState;
  const decision = evaluateRateLimit(legacyState, now, "sign", CONFIG);
  assert.strictEqual(decision.allowed, true);
  assert.strictEqual(decision.nextState.signCount, 1);
  assert.ok(!Number.isNaN(decision.nextState.signCount));
});

run("버킷 전환(같은 날 다음 시간) — 카운트·거부수 전부 리셋 후 1로 시작", () => {
  const prevHour = new Date("2026-08-06T10:59:59Z");
  const nextHour = new Date("2026-08-06T11:00:00Z");
  const state: RateLimitState = {bucket: utcHourBucket(prevHour), textCount: 3, imageCount: 2, signCount: 1, rejectedCount: 9};
  const decision = evaluateRateLimit(state, nextHour, "text", CONFIG);
  assert.strictEqual(decision.allowed, true);
  assert.strictEqual(decision.nextState.bucket, utcHourBucket(nextHour));
  assert.strictEqual(decision.nextState.textCount, 1);
  assert.strictEqual(decision.nextState.imageCount, 0);
  assert.strictEqual(decision.nextState.signCount, 0);
  assert.strictEqual(decision.nextState.rejectedCount, 0);
});

run("버킷 전환(자정·월·연도 경계) — 문자열 버킷 키가 올바르게 갈린다", () => {
  const dec31 = new Date("2026-12-31T23:59:59Z");
  const jan1 = new Date("2027-01-01T00:00:00Z");
  assert.notStrictEqual(utcHourBucket(dec31), utcHourBucket(jan1));
  const state: RateLimitState = {bucket: utcHourBucket(dec31), textCount: 3, imageCount: 0, signCount: 0, rejectedCount: 1};
  const decision = evaluateRateLimit(state, jan1, "text", CONFIG);
  assert.strictEqual(decision.allowed, true);
  assert.strictEqual(decision.nextState.textCount, 1);
});

run("같은 버킷 안에서는 리셋되지 않는다(경계 오탐 방지)", () => {
  const t1 = new Date("2026-08-06T10:00:00Z");
  const t2 = new Date("2026-08-06T10:59:59Z");
  assert.strictEqual(utcHourBucket(t1), utcHourBucket(t2));
  const state: RateLimitState = {bucket: utcHourBucket(t1), textCount: 3, imageCount: 0, signCount: 0, rejectedCount: 0};
  const decision = evaluateRateLimit(state, t2, "text", CONFIG);
  assert.strictEqual(decision.allowed, false);
  assert.strictEqual(decision.nextState.textCount, 3);
});

console.log("전부 통과");
