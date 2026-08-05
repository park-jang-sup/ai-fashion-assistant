// signed_url_policy.ts 단위 테스트 — rate_limit.test.ts와 같은 패턴
// (node:assert, tsc로 컴파일 후 node로 실행).
import * as assert from "node:assert";
import {
  decideSignedUrlAccess,
  pathFromDownloadUrl,
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

console.log("전부 통과");
