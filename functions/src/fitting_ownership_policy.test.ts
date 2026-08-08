// fitting_ownership_policy.ts 단위 테스트 — signed_url_policy.test.ts와
// 같은 방식.
import * as assert from "node:assert";
import {verifyFittingOwnership, WardrobeOwnerDoc} from "./fitting_ownership_policy";

function run(name: string, fn: () => void): void {
  try {
    fn();
    console.log(`PASS: ${name}`);
  } catch (err) {
    console.error(`FAIL: ${name}`);
    throw err;
  }
}

const CALLER = "uid-caller";

run("전부 존재 + 전부 소유자 일치 — 허용", () => {
  const docs: WardrobeOwnerDoc[] = [
    {id: "a", exists: true, ownerUid: CALLER},
    {id: "b", exists: true, ownerUid: CALLER},
  ];
  const result = verifyFittingOwnership(docs, CALLER);
  assert.strictEqual(result.allowed, true);
});

run("하나라도 미존재 — 거부(not-found)", () => {
  const docs: WardrobeOwnerDoc[] = [
    {id: "a", exists: true, ownerUid: CALLER},
    {id: "b", exists: false},
  ];
  const result = verifyFittingOwnership(docs, CALLER);
  assert.strictEqual(result.allowed, false);
  assert.strictEqual(result.reason, "not-found");
  assert.strictEqual(result.deniedId, "b");
});

run("하나라도 소유자 불일치 — 거부(owner-mismatch)", () => {
  const docs: WardrobeOwnerDoc[] = [
    {id: "a", exists: true, ownerUid: CALLER},
    {id: "b", exists: true, ownerUid: "uid-other"},
  ];
  const result = verifyFittingOwnership(docs, CALLER);
  assert.strictEqual(result.allowed, false);
  assert.strictEqual(result.reason, "owner-mismatch");
  assert.strictEqual(result.deniedId, "b");
});

run("ownerUid 필드 자체가 없는 문서(레거시) — owner-mismatch로 거부(인증만 허용하는 예외 없음)", () => {
  const docs: WardrobeOwnerDoc[] = [{id: "a", exists: true, ownerUid: undefined}];
  const result = verifyFittingOwnership(docs, CALLER);
  assert.strictEqual(result.allowed, false);
  assert.strictEqual(result.reason, "owner-mismatch");
});

run("빈 배열 — 허용(검사할 게 없음, 상위에서 옷 0장은 별도로 막음)", () => {
  const result = verifyFittingOwnership([], CALLER);
  assert.strictEqual(result.allowed, true);
});

run("첫 번째 거부에서 즉시 멈춘다 — 이후 항목은 안 보고 첫 사유만 반환", () => {
  const docs: WardrobeOwnerDoc[] = [
    {id: "a", exists: false},
    {id: "b", exists: true, ownerUid: "uid-other"},
  ];
  const result = verifyFittingOwnership(docs, CALLER);
  assert.strictEqual(result.deniedId, "a");
  assert.strictEqual(result.reason, "not-found");
});

console.log("전부 통과");
