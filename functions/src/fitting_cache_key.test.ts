// fitting_cache_key.ts 단위 테스트 — payload_limit.test.ts와 같은 방식.
// **착수 필수조건**(docs/task_fitting_server_cache_v1.md §1.3/§6-1):
// Dart(fitting_job_controller.dart의 _buildFittingCacheKey)와 같은
// 입력에 같은 해시를 내는지를 고정 벡터로 확인한다. 이 테스트가
// 깨지면 서버 캐시 쓰기 전체가 무의미해진다(캐시 키가 안 맞으면
// 클라이언트 조회는 영원히 미스).
import * as assert from "node:assert";
import {buildFittingCacheKey} from "./fitting_cache_key";

function run(name: string, fn: () => void): void {
  try {
    fn();
    console.log(`PASS: ${name}`);
  } catch (err) {
    console.error(`FAIL: ${name}`);
    throw err;
  }
}

// 고정 벡터 — Dart 쪽 계산: sortedClothingIds = ['a','b'] (이미 정렬됨
// 유지 확인용), raw = 'TEST_U:a,b', sha256(utf8(raw)) 소문자 hex.
// sha256은 표준 알고리즘이라 Python hashlib.sha256('TEST_U:a,b'.encode())
// .hexdigest()로 교차검증한 값과 동일해야 한다(구현체 무관).
const FIXTURE_EXPECTED = "8f6b3aa991bcbc456d8e0b7e0e85b5cb96fb3c92fb42f15cef0f6e667911e847";

run("buildFittingCacheKey — 고정 벡터(userPhotoId=TEST_U, ['a','b']) — Dart/Python 교차검증값과 일치", () => {
  assert.strictEqual(buildFittingCacheKey("TEST_U", ["a", "b"]), FIXTURE_EXPECTED);
});

run("buildFittingCacheKey — 입력 순서 무관(정렬 후 계산) — Dart의 ..sort()와 동일 동작", () => {
  assert.strictEqual(buildFittingCacheKey("TEST_U", ["b", "a"]), FIXTURE_EXPECTED);
});

run("buildFittingCacheKey — 원본 배열을 변형하지 않는다(정렬은 복사본에)", () => {
  const ids = ["b", "a"];
  buildFittingCacheKey("TEST_U", ids);
  assert.deepStrictEqual(ids, ["b", "a"]);
});

run("buildFittingCacheKey — 옷 1장(리스트 길이 1)도 동일 규칙", () => {
  const key = buildFittingCacheKey("U1", ["only"]);
  assert.strictEqual(key.length, 64);
  assert.match(key, /^[0-9a-f]{64}$/);
});

run("buildFittingCacheKey — 서로 다른 조합은 서로 다른 키", () => {
  const k1 = buildFittingCacheKey("U1", ["a", "b"]);
  const k2 = buildFittingCacheKey("U1", ["a", "c"]);
  assert.notStrictEqual(k1, k2);
});

console.log("전부 통과");
