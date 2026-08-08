// fcm_token_cleanup.ts 단위 테스트 - rate_limit.test.ts/payload_limit.test.ts와
// 같은 방식(node:assert 직접 사용, tsc로 컴파일된
// lib/fcm_token_cleanup.test.js를 node로 실행. package.json의 "test" 스크립트 참고).
import * as assert from "node:assert";
import {classifyTokenError, planTokenCleanup, TokenSendResult} from "./fcm_token_cleanup";

function run(name: string, fn: () => void): void {
  try {
    fn();
    console.log(`PASS: ${name}`);
  } catch (err) {
    console.error(`FAIL: ${name}`);
    throw err;
  }
}

run("classifyTokenError - registration-token-not-registered는 delete", () => {
  assert.strictEqual(classifyTokenError("messaging/registration-token-not-registered"), "delete");
});

run("classifyTokenError - installation-id-not-registered는 delete(도달 불가 경로지만 판정은 유지)", () => {
  assert.strictEqual(classifyTokenError("messaging/installation-id-not-registered"), "delete");
});

run("classifyTokenError - invalid-registration-token은 diagnostic(삭제 안 함)", () => {
  assert.strictEqual(classifyTokenError("messaging/invalid-registration-token"), "diagnostic");
});

run("classifyTokenError - mismatched-credential은 keep", () => {
  assert.strictEqual(classifyTokenError("messaging/mismatched-credential"), "keep");
});

run("classifyTokenError - third-party-auth-error(APNs 인증서)는 keep", () => {
  assert.strictEqual(classifyTokenError("messaging/third-party-auth-error"), "keep");
});

run("classifyTokenError - invalid-argument(페이로드 문제)는 keep", () => {
  assert.strictEqual(classifyTokenError("messaging/invalid-argument"), "keep");
});

run("classifyTokenError - rate-limit 계열은 전부 keep", () => {
  assert.strictEqual(classifyTokenError("messaging/device-message-rate-exceeded"), "keep");
  assert.strictEqual(classifyTokenError("messaging/message-rate-exceeded"), "keep");
  assert.strictEqual(classifyTokenError("messaging/topics-message-rate-exceeded"), "keep");
});

run("classifyTokenError - 코드 없음(undefined)은 keep", () => {
  assert.strictEqual(classifyTokenError(undefined), "keep");
});

run("classifyTokenError - 모르는 코드는 keep(모르면 유지 원칙)", () => {
  assert.strictEqual(classifyTokenError("messaging/some-future-code-not-in-list"), "keep");
});

run("planTokenCleanup - 성공한 토큰은 계획에 안 들어감", () => {
  const results: TokenSendResult[] = [{token: "tok-a", success: true}];
  assert.deepStrictEqual(planTokenCleanup(results), []);
});

run("planTokenCleanup - keep 판정은 계획에 안 들어감", () => {
  const results: TokenSendResult[] = [
    {token: "tok-a", success: false, errorCode: "messaging/internal-error"},
  ];
  assert.deepStrictEqual(planTokenCleanup(results), []);
});

// 핵심 케이스 - 3개 중 2번째만 실패(not-registered). 인덱스가 아니라
// 토큰 문자열로 결과를 내므로, 여기서 어긋나면(예: 1번째나 3번째
// 토큰이 지워지면) 이 테스트가 바로 잡아낸다.
run("planTokenCleanup - 일부만 실패(3개 중 2번째만 not-registered) - 그 토큰만 삭제 계획", () => {
  const results: TokenSendResult[] = [
    {token: "tok-live-1", success: true},
    {token: "tok-dead", success: false, errorCode: "messaging/registration-token-not-registered"},
    {token: "tok-live-2", success: true},
  ];
  const plan = planTokenCleanup(results);
  assert.strictEqual(plan.length, 1);
  assert.strictEqual(plan[0].token, "tok-dead");
  assert.strictEqual(plan[0].action, "delete");
});

run("planTokenCleanup - 실패가 섞여도 diagnostic과 delete가 각각 올바른 토큰에 붙는다", () => {
  const results: TokenSendResult[] = [
    {token: "tok-invalid-format", success: false, errorCode: "messaging/invalid-registration-token"},
    {token: "tok-live", success: true},
    {token: "tok-not-registered", success: false, errorCode: "messaging/registration-token-not-registered"},
    {token: "tok-rate-limited", success: false, errorCode: "messaging/device-message-rate-exceeded"},
  ];
  const plan = planTokenCleanup(results);
  assert.strictEqual(plan.length, 2);
  const byToken = Object.fromEntries(plan.map((p) => [p.token, p.action]));
  assert.strictEqual(byToken["tok-invalid-format"], "diagnostic");
  assert.strictEqual(byToken["tok-not-registered"], "delete");
  assert.strictEqual(byToken["tok-rate-limited"], undefined); // keep - 계획에 없음
  assert.strictEqual(byToken["tok-live"], undefined);
});

run("planTokenCleanup - 전부 성공이면 빈 계획", () => {
  const results: TokenSendResult[] = [
    {token: "tok-1", success: true},
    {token: "tok-2", success: true},
  ];
  assert.deepStrictEqual(planTokenCleanup(results), []);
});

console.log("전부 통과");
