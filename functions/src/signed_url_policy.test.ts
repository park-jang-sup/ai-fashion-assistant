// signed_url_policy.ts 단위 테스트 — rate_limit.test.ts와 같은 패턴
// (node:assert, tsc로 컴파일 후 node로 실행).
import * as assert from "node:assert";
import {
  createLimiter,
  decidePathOwnership,
  decideSignedUrlAccess,
  demoPathsFromDocs,
  pathCheckMode,
  pathFromDownloadUrl,
  pathsToSign,
  validateBatch,
  DocFields,
} from "./signed_url_policy";

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

run("wardrobe — 소유자 일치는 허용, imagePath로 서명", () => {
  const doc: DocFields = {exists: true, ownerUid: CALLER, imagePath: "wardrobe_images/a.jpg"};
  const result = decideSignedUrlAccess({collection: "wardrobe", id: "item1"}, doc, CALLER);
  assert.strictEqual(result.allowed, true);
  assert.deepStrictEqual(result.paths, ["wardrobe_images/a.jpg"]);
});

run("wardrobe — 소유 불일치는 거부(owner-mismatch)", () => {
  const doc: DocFields = {exists: true, ownerUid: "someone-else", imagePath: "wardrobe_images/a.jpg"};
  const result = decideSignedUrlAccess({collection: "wardrobe", id: "item1"}, doc, CALLER);
  assert.strictEqual(result.allowed, false);
  assert.strictEqual(result.reason, "owner-mismatch");
  assert.deepStrictEqual(result.paths, []);
});

run("미존재 문서는 컬렉션과 무관하게 거부(not-found)", () => {
  const doc: DocFields = {exists: false};
  for (const collection of ["wardrobe", "demo_wardrobe", "fitting_cache"] as const) {
    const result = decideSignedUrlAccess({collection, id: "ghost"}, doc, CALLER);
    assert.strictEqual(result.allowed, false, collection);
    assert.strictEqual(result.reason, "not-found", collection);
  }
});

run("demo_wardrobe — ownerUid 없어도(공용 세트) 인증만으로 허용", () => {
  const doc: DocFields = {exists: true, imagePath: "wardrobe_images/demo.jpg"};
  const result = decideSignedUrlAccess({collection: "demo_wardrobe", id: "demo1"}, doc, CALLER);
  assert.strictEqual(result.allowed, true);
  assert.deepStrictEqual(result.paths, ["wardrobe_images/demo.jpg"]);
});

run("fitting_cache — 레거시(ownerUid 없음)는 인증만으로 허용, 경로는 문서 id로 유도", () => {
  const doc: DocFields = {exists: true, imageUrl: "https://x/fitting_results/legacy.jpg"};
  const result = decideSignedUrlAccess({collection: "fitting_cache", id: "legacyKey"}, doc, CALLER);
  assert.strictEqual(result.allowed, true);
  assert.deepStrictEqual(result.paths, ["fitting_results/legacyKey.jpg"]);
});

run("fitting_cache — ownerUid 있으면 대조, 불일치는 거부", () => {
  const doc: DocFields = {exists: true, ownerUid: "someone-else"};
  const result = decideSignedUrlAccess({collection: "fitting_cache", id: "cacheKey"}, doc, CALLER);
  assert.strictEqual(result.allowed, false);
  assert.strictEqual(result.reason, "owner-mismatch");
});

run("fitting_cache — ownerUid 있고 일치하면 허용", () => {
  const doc: DocFields = {exists: true, ownerUid: CALLER};
  const result = decideSignedUrlAccess({collection: "fitting_cache", id: "cacheKey"}, doc, CALLER);
  assert.strictEqual(result.allowed, true);
  assert.deepStrictEqual(result.paths, ["fitting_results/cacheKey.jpg"]);
});

run("path 필드 없어도 기존 URL에서 경로 역산(Phase B 백필 전 폴백)", () => {
  const doc: DocFields = {
    exists: true,
    ownerUid: CALLER,
    imageUrl: "https://firebasestorage.googleapis.com/v0/b/x.appspot.com/o/wardrobe_images%2F1.jpg?alt=media&token=abc",
    cutoutImageUrl: "https://firebasestorage.googleapis.com/v0/b/x.appspot.com/o/wardrobe_cutouts%2F1.png?alt=media&token=def",
  };
  const result = decideSignedUrlAccess({collection: "wardrobe", id: "item1"}, doc, CALLER);
  assert.strictEqual(result.allowed, true);
  assert.deepStrictEqual(result.paths, ["wardrobe_images/1.jpg", "wardrobe_cutouts/1.png"]);
});

run("imagePath 필드가 있으면 URL 역산보다 우선한다", () => {
  const doc: DocFields = {
    exists: true,
    ownerUid: CALLER,
    imagePath: "wardrobe_images/explicit.jpg",
    imageUrl: "https://x/o/wardrobe_images%2Fold.jpg?alt=media",
  };
  const result = decideSignedUrlAccess({collection: "wardrobe", id: "item1"}, doc, CALLER);
  assert.deepStrictEqual(result.paths, ["wardrobe_images/explicit.jpg"]);
});

run("경로를 하나도 못 구하면 no-path로 거부(빈 문서·깨진 URL)", () => {
  const doc: DocFields = {exists: true, ownerUid: CALLER};
  const result = decideSignedUrlAccess({collection: "wardrobe", id: "item1"}, doc, CALLER);
  assert.strictEqual(result.allowed, false);
  assert.strictEqual(result.reason, "no-path");
});

run("pathFromDownloadUrl — 형식이 아니면 undefined", () => {
  assert.strictEqual(pathFromDownloadUrl(undefined), undefined);
  assert.strictEqual(pathFromDownloadUrl("https://example.com/not-a-storage-url"), undefined);
});

run("빈 요청 배열은 배치 검증에서 거부(empty)", () => {
  const result = validateBatch([]);
  assert.strictEqual(result.valid, false);
  assert.strictEqual(result.reason, "empty");
});

run("배치 상한(200) 이내는 허용", () => {
  const items = Array.from({length: 200}, (_, i) => ({collection: "wardrobe" as const, id: `item${i}`}));
  const result = validateBatch(items);
  assert.strictEqual(result.valid, true);
});

run("배치 상한(200) 초과는 거부(too-large)", () => {
  const items = Array.from({length: 201}, (_, i) => ({collection: "wardrobe" as const, id: `item${i}`}));
  const result = validateBatch(items);
  assert.strictEqual(result.valid, false);
  assert.strictEqual(result.reason, "too-large");
});

// ── 경로 검사(보안 최소 조치 S2-1) ──
const DEMO = demoPathsFromDocs([
  {imageUrl: "https://firebasestorage.googleapis.com/v0/b/bkt/o/wardrobe_images%2Fdemo.jpg?alt=media&token="},
  {imagePath: "wardrobe_images/demo2.jpg", cutoutPath: "wardrobe_cutouts/demo2.png"},
]);

run("경로 검사 — 데모 경로 집합: 다운로드 URL 역산과 경로 필드 모두", () => {
  assert.deepStrictEqual([...DEMO].sort(), ["wardrobe_cutouts/demo2.png", "wardrobe_images/demo.jpg", "wardrobe_images/demo2.jpg"]);
});

run("경로 검사 — 본인 파일(메타데이터 ownerUid == 호출자) 허용", () => {
  const d = decidePathOwnership("wardrobe_images/mine.jpg", DEMO, {exists: true, ownerUid: CALLER}, CALLER);
  assert.deepStrictEqual(d, {allowed: true, via: "owner"});
});

run("경로 검사 — 데모 경로는 파일 메타데이터 없이 허용(isDemo 사본 문서의 경로)", () => {
  // isDemo 사본 문서는 호출자 소유지만 파일은 원본 주인 것 — 데모 집합으로 허용한다.
  const copyDoc: DocFields = {exists: true, ownerUid: CALLER, imageUrl: "https://firebasestorage.googleapis.com/v0/b/bkt/o/wardrobe_images%2Fdemo.jpg?alt=media&token="};
  const access = decideSignedUrlAccess({collection: "wardrobe", id: "copy1"}, copyDoc, CALLER);
  assert.strictEqual(access.allowed, true);
  const d = decidePathOwnership(access.paths[0], DEMO, undefined, CALLER);
  assert.deepStrictEqual(d, {allowed: true, via: "demo"});
});

run("경로 검사 — 남의 파일 경로를 적은 내 문서는 거부(other-owner)", () => {
  const myDoc: DocFields = {exists: true, ownerUid: CALLER, imagePath: "wardrobe_images/victim.jpg"};
  const access = decideSignedUrlAccess({collection: "wardrobe", id: "mine"}, myDoc, CALLER);
  assert.strictEqual(access.allowed, true); // 문서 주인 검사는 통과하지만
  const d = decidePathOwnership(access.paths[0], DEMO, {exists: true, ownerUid: "uid-victim"}, CALLER);
  assert.deepStrictEqual(d, {allowed: false, reason: "other-owner"});
});

run("경로 검사 — 메타데이터 없는 파일·없는 파일은 거부", () => {
  assert.deepStrictEqual(decidePathOwnership("wardrobe_images/legacy.jpg", DEMO, {exists: true}, CALLER), {allowed: false, reason: "no-owner-metadata"});
  assert.deepStrictEqual(decidePathOwnership("wardrobe_images/gone.jpg", DEMO, {exists: false}, CALLER), {allowed: false, reason: "file-missing"});
});

run("경로 검사 — 기록 모드는 거부하지 않는다(모든 경로 서명), 적용 모드는 거부한 자리만 비운다", () => {
  const paths = ["wardrobe_images/a.jpg", "wardrobe_cutouts/a.png"];
  const decisions = [{allowed: true, via: "owner" as const}, {allowed: false, reason: "no-owner-metadata" as const}];
  assert.deepStrictEqual(pathsToSign(paths, decisions, "log"), paths);
  assert.deepStrictEqual(pathsToSign(paths, decisions, "enforce"), ["wardrobe_images/a.jpg", null]);
  assert.strictEqual(pathsToSign(paths, [decisions[1], decisions[1]], "enforce"), null); // 모두 거부 — 항목 생략
});

run("경로 검사 — 모드 값: enforce만 적용, 없거나 모르는 값은 기록", () => {
  assert.strictEqual(pathCheckMode(undefined), "log");
  assert.strictEqual(pathCheckMode("log"), "log");
  assert.strictEqual(pathCheckMode(" ENFORCE "), "enforce");
  assert.strictEqual(pathCheckMode("on"), "log");
});

async function limiterTest(): Promise<void> {
  const limit = createLimiter(3);
  let active = 0;
  let peak = 0;
  const done = await Promise.all(
    Array.from({length: 20}, (_, i) =>
      limit(async () => {
        active++;
        peak = Math.max(peak, active);
        await new Promise((r) => setTimeout(r, 2));
        active--;
        return i;
      })
    )
  );
  assert.deepStrictEqual(done, Array.from({length: 20}, (_, i) => i));
  assert.ok(peak <= 3, `동시 실행 ${peak}`);
  console.log("PASS: 경로 검사 — 동시 실행 상한(3) 안에서 20건 모두 끝남");
}

limiterTest().then(
  () => console.log("전부 통과"),
  (err) => {
    console.error("FAIL: 동시 실행 상한", err);
    process.exitCode = 1;
  }
);
