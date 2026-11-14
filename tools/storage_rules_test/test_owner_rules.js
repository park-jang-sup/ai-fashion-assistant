// storage.rules 보안 최소 조치(안 1) 에뮬레이터 검증 — 케이스별 ALLOW/DENY 표를 출력한다.
//   (저장소 루트에서) firebase emulators:exec --only storage --project demo-storage-rules-test "node tools/storage_rules_test/test_owner_rules.js"
//
// 사람: alice(주인), bob(다른 계정), 로그인 안 함. 파일은 규칙을 끈 채로 심는다.
const fs = require('fs');
const path = require('path');
const {initializeTestEnvironment, assertSucceeds, assertFails} = require('@firebase/rules-unit-testing');

const RULES = fs.readFileSync(path.join(__dirname, '..', '..', 'storage.rules'), 'utf8');
const JPG = new Uint8Array([0xff, 0xd8, 0xff, 1, 2, 3]);
const BIG = new Uint8Array(11 * 1024 * 1024);

const rows = [];
async function check(id, what, expect, fn) {
  let got;
  try {
    await fn();
    got = 'ALLOW';
  } catch (e) {
    got = /permission|denied|unauthorized|403/i.test(`${e.code} ${e.message}`) ? 'DENY' : `ERROR(${e.code || e.message})`;
  }
  rows.push({id, what, expect, got, ok: got === expect});
}

async function seed(env, files) {
  await env.withSecurityRulesDisabled(async (ctx) => {
    for (const [p, meta] of files) {
      await ctx.storage().ref(p).put(JPG, {contentType: p.endsWith('.png') ? 'image/png' : 'image/jpeg', ...(meta ? {customMetadata: meta} : {})});
    }
  });
}

async function main() {
  const env = await initializeTestEnvironment({
    projectId: 'demo-storage-rules-test',
    storage: {rules: RULES, host: 'localhost', port: 9199},
  });
  await seed(env, [
    ['wardrobe_images/own.jpg', {ownerUid: 'alice'}],
    ['wardrobe_images/own_del.jpg', {ownerUid: 'alice'}],
    ['wardrobe_images/demo.jpg', {ownerUid: 'alice', demo: 'true'}],
    ['wardrobe_images/demo_del.jpg', {ownerUid: 'alice', demo: 'true'}],
    ['wardrobe_images/legacy.jpg', null],
    ['wardrobe_cutouts/own.png', {ownerUid: 'alice'}],
    ['wardrobe_cutouts/demo.png', {ownerUid: 'alice', demo: 'true'}],
    ['wardrobe_cutouts/legacy.png', null],
    ['fitting_results/own.jpg', {ownerUid: 'alice'}],
    ['fitting_results/old_unowned.jpg', null],
  ]);
  const alice = env.authenticatedContext('alice').storage();
  const bob = env.authenticatedContext('bob').storage();
  const anon = env.unauthenticatedContext().storage();
  const put = (s, p, meta, bytes = JPG, type = 'image/jpeg') =>
    s.ref(p).put(bytes, {contentType: type, ...(meta ? {customMetadata: meta} : {})});

  // ── wardrobe_images: 읽기
  await check('I-R1', '옷 사진: 주인이 자기 파일 읽기', 'ALLOW', () => alice.ref('wardrobe_images/own.jpg').getDownloadURL());
  await check('I-R2', '옷 사진: 다른 계정이 남의 파일 읽기', 'DENY', () => bob.ref('wardrobe_images/own.jpg').getDownloadURL());
  await check('I-R3', '옷 사진: 다른 계정이 데모 파일 읽기', 'ALLOW', () => bob.ref('wardrobe_images/demo.jpg').getDownloadURL());
  await check('I-R4', '옷 사진: 로그인 안 한 사람이 데모 파일 읽기', 'DENY', () => anon.ref('wardrobe_images/demo.jpg').getDownloadURL());
  await check('I-R5', '옷 사진: 주인 표시 없는 옛 파일 — 다른 계정', 'DENY', () => bob.ref('wardrobe_images/legacy.jpg').getDownloadURL());
  await check('I-R6', '옷 사진: 주인 표시 없는 옛 파일 — 누구든(일괄 표시 전)', 'DENY', () => alice.ref('wardrobe_images/legacy.jpg').getDownloadURL());
  await check('I-L1', '옷 사진: 목록 보기(주인)', 'DENY', () => alice.ref('wardrobe_images').listAll());
  // ── wardrobe_images: 올리기·덮어쓰기·삭제
  await check('I-W1', '옷 사진: 새로 올리기, ownerUid=본인', 'ALLOW', () => put(alice, 'wardrobe_images/new1.jpg', {ownerUid: 'alice'}));
  await check('I-W2', '옷 사진: 새로 올리기, ownerUid=남', 'DENY', () => put(alice, 'wardrobe_images/new2.jpg', {ownerUid: 'bob'}));
  await check('I-W3', '옷 사진: 새로 올리기, 메타데이터 없음', 'DENY', () => put(alice, 'wardrobe_images/new3.jpg', null));
  await check('I-W4', '옷 사진: 새로 올리기, demo 표시를 직접 달기', 'DENY', () => put(alice, 'wardrobe_images/new4.jpg', {ownerUid: 'alice', demo: 'true'}));
  await check('I-W5', '옷 사진: 10MB 넘는 파일', 'DENY', () => put(alice, 'wardrobe_images/big.jpg', {ownerUid: 'alice'}, BIG));
  await check('I-W6', '옷 사진: 이미지가 아닌 파일', 'DENY', () => put(alice, 'wardrobe_images/x.txt', {ownerUid: 'alice'}, JPG, 'text/plain'));
  // 앱(uploadWardrobeImage)이 싣는 메타데이터 그대로 올리고, 바로 getDownloadURL — 업로드 직후 읽기
  await check('I-W7', '옷 사진: 앱과 같은 메타데이터(wardrobeDocId·ownerUid·category)로 올리기', 'ALLOW',
      () => put(alice, 'wardrobe_images/app.jpg', {wardrobeDocId: 'doc1', ownerUid: 'alice', category: '상의'}));
  await check('I-R7', '옷 사진: 올린 직후 본인 읽기(getDownloadURL)', 'ALLOW', () => alice.ref('wardrobe_images/app.jpg').getDownloadURL());
  await check('I-R8', '옷 사진: 방금 올린 파일 — 다른 계정 읽기', 'DENY', () => bob.ref('wardrobe_images/app.jpg').getDownloadURL());
  await check('I-U1', '옷 사진: 주인이 자기 파일 덮어쓰기', 'ALLOW', () => put(alice, 'wardrobe_images/own.jpg', {ownerUid: 'alice'}));
  await check('I-U2', '옷 사진: 다른 계정이 남의 파일 덮어쓰기(자기 uid로)', 'DENY', () => put(bob, 'wardrobe_images/own.jpg', {ownerUid: 'bob'}));
  await check('I-U3', '옷 사진: 다른 계정이 데모 파일 덮어쓰기', 'DENY', () => put(bob, 'wardrobe_images/demo.jpg', {ownerUid: 'bob'}));
  await check('I-U4', '옷 사진: 다른 계정이 주인 없는 옛 파일 덮어쓰기', 'DENY', () => put(bob, 'wardrobe_images/legacy.jpg', {ownerUid: 'bob'}));
  await check('I-D1', '옷 사진: 다른 계정이 남의 파일 삭제', 'DENY', () => bob.ref('wardrobe_images/own_del.jpg').delete());
  await check('I-D2', '옷 사진: 다른 계정이 데모 파일 삭제', 'DENY', () => bob.ref('wardrobe_images/demo_del.jpg').delete());
  await check('I-D3', '옷 사진: 다른 계정이 주인 없는 옛 파일 삭제', 'DENY', () => bob.ref('wardrobe_images/legacy.jpg').delete());
  await check('I-D4', '옷 사진: 주인이 자기 파일 삭제', 'ALLOW', () => alice.ref('wardrobe_images/own_del.jpg').delete());
  await check('I-D5', '옷 사진: 주인이 자기 데모 파일 삭제', 'ALLOW', () => alice.ref('wardrobe_images/demo_del.jpg').delete());

  // ── wardrobe_cutouts
  await check('C-W1', '누끼: 메타데이터 없이 올리기', 'DENY', () => put(alice, 'wardrobe_cutouts/nometa.png', null, JPG, 'image/png'));
  await check('C-W2', '누끼: ownerUid=본인으로 올리기', 'ALLOW', () => put(alice, 'wardrobe_cutouts/new.png', {ownerUid: 'alice'}, JPG, 'image/png'));
  await check('C-R1', '누끼: 올린 직후 본인 읽기(getDownloadURL)', 'ALLOW', () => alice.ref('wardrobe_cutouts/new.png').getDownloadURL());
  await check('C-R2', '누끼: 다른 계정이 남의 누끼 읽기', 'DENY', () => bob.ref('wardrobe_cutouts/new.png').getDownloadURL());
  await check('C-W3', '누끼: ownerUid=남으로 올리기', 'DENY', () => put(alice, 'wardrobe_cutouts/x.png', {ownerUid: 'bob'}, JPG, 'image/png'));
  await check('C-W4', '누끼: demo 표시를 직접 달기', 'DENY', () => put(alice, 'wardrobe_cutouts/d.png', {ownerUid: 'alice', demo: 'true'}, JPG, 'image/png'));
  await check('C-W5', '누끼: 5MB 넘는 파일', 'DENY', () => put(alice, 'wardrobe_cutouts/big.png', {ownerUid: 'alice'}, new Uint8Array(6 * 1024 * 1024), 'image/png'));
  await check('C-R3', '누끼: 다른 계정이 데모 누끼 읽기', 'ALLOW', () => bob.ref('wardrobe_cutouts/demo.png').getDownloadURL());
  await check('C-R4', '누끼: 다른 계정이 남의 옛 누끼(주인 표시 있음) 읽기', 'DENY', () => bob.ref('wardrobe_cutouts/own.png').getDownloadURL());
  await check('C-R5', '누끼: 주인 표시 없는 옛 누끼 읽기(일괄 표시 전)', 'DENY', () => alice.ref('wardrobe_cutouts/legacy.png').getDownloadURL());
  await check('C-U1', '누끼: 다른 계정이 데모 누끼 덮어쓰기', 'DENY', () => put(bob, 'wardrobe_cutouts/demo.png', {ownerUid: 'bob'}, JPG, 'image/png'));
  await check('C-U2', '누끼: 다른 계정이 남의 누끼 덮어쓰기', 'DENY', () => put(bob, 'wardrobe_cutouts/own.png', {ownerUid: 'bob'}, JPG, 'image/png'));
  await check('C-U3', '누끼: 주인이 자기 누끼 덮어쓰기', 'ALLOW', () => put(alice, 'wardrobe_cutouts/own.png', {ownerUid: 'alice'}, JPG, 'image/png'));
  await check('C-D1', '누끼: 다른 계정이 데모 누끼 삭제', 'DENY', () => bob.ref('wardrobe_cutouts/demo.png').delete());
  await check('C-D2', '누끼: 다른 계정이 주인 없는 옛 누끼 삭제', 'DENY', () => bob.ref('wardrobe_cutouts/legacy.png').delete());
  await check('C-D3', '누끼: 주인이 자기 누끼 삭제', 'ALLOW', () => alice.ref('wardrobe_cutouts/new.png').delete());
  await check('C-L1', '누끼: 목록 보기', 'DENY', () => alice.ref('wardrobe_cutouts').listAll());

  // ── fitting_results
  await check('F-W1', '피팅 결과: 메타데이터 없이 올리기', 'DENY', () => put(alice, 'fitting_results/nometa.jpg', null));
  await check('F-W2', '피팅 결과: ownerUid=본인으로 새로 올리기', 'ALLOW', () => put(alice, 'fitting_results/new.jpg', {ownerUid: 'alice'}));
  await check('F-R1', '피팅 결과: 올린 직후 본인 읽기(getDownloadURL)', 'ALLOW', () => alice.ref('fitting_results/new.jpg').getDownloadURL());
  await check('F-U1', '피팅 결과: 같은 조합 다시 만들기 — 본인 파일 덮어쓰기', 'ALLOW', () => put(alice, 'fitting_results/own.jpg', {ownerUid: 'alice'}));
  await check('F-U2', '피팅 결과: 주인 표시 없는 옛 결과 덮어쓰기(캐시 갱신만 실패)', 'DENY', () => put(alice, 'fitting_results/old_unowned.jpg', {ownerUid: 'alice'}));
  await check('F-W3', '피팅 결과: ownerUid=남으로 올리기', 'DENY', () => put(alice, 'fitting_results/x.jpg', {ownerUid: 'bob'}));
  await check('F-R2', '피팅 결과: 다른 계정이 남의 결과 읽기', 'DENY', () => bob.ref('fitting_results/own.jpg').getDownloadURL());
  await check('F-U3', '피팅 결과: 다른 계정이 남의 결과 덮어쓰기', 'DENY', () => put(bob, 'fitting_results/own.jpg', {ownerUid: 'bob'}));
  await check('F-D1', '피팅 결과: 다른 계정이 남의 결과 삭제', 'DENY', () => bob.ref('fitting_results/own.jpg').delete());
  await check('F-D2', '피팅 결과: 주인이 자기 결과 삭제', 'ALLOW', () => alice.ref('fitting_results/new.jpg').delete());
  await check('F-L1', '피팅 결과: 목록 보기', 'DENY', () => alice.ref('fitting_results').listAll());
  await check('X-1', '그 밖의 경로: 올리기', 'DENY', () => put(alice, 'other/x.jpg', {ownerUid: 'alice'}));
  await env.cleanup();

  console.log('| 케이스 | 내용 | 기대 | 결과 | |');
  console.log('|---|---|---|---|---|');
  for (const r of rows) console.log(`| ${r.id} | ${r.what} | ${r.expect} | ${r.got} | ${r.ok ? '○' : '✗'} |`);
  const bad = rows.filter((r) => !r.ok).length;
  console.log(`\n${rows.length}건 중 기대와 다른 결과 ${bad}건`);
  if (bad) process.exitCode = 1;
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
