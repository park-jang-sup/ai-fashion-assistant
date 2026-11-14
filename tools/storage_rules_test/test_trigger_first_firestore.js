// 배경 제거 트리거가 앱보다 먼저 wardrobe 문서를 만든 경우(보안 최소 조치 S2-2) — firestore.rules(바꾸지 않음)
// 에뮬레이터 검증. 트리거가 ownerUid를 함께 쓰면 뒤이은 앱의 set(merge)가 통과하고, 예전처럼 ownerUid 없이
// 쓰면 막힌다(11/13의 주인 없는 문서).
//   (저장소 루트에서) firebase emulators:exec --only firestore --project demo-trigger-first "node tools/storage_rules_test/test_trigger_first_firestore.js"
const fs = require('fs');
const path = require('path');
const {initializeTestEnvironment} = require('@firebase/rules-unit-testing');

const RULES = fs.readFileSync(path.join(__dirname, '..', '..', 'firestore.rules'), 'utf8');
const rows = [];
async function check(id, what, expect, fn) {
  let got;
  try {
    await fn();
    got = 'ALLOW';
  } catch (e) {
    got = /permission|denied|PERMISSION_DENIED/i.test(`${e.code} ${e.message}`) ? 'DENY' : `ERROR(${e.code || e.message})`;
  }
  rows.push({id, what, expect, got, ok: got === expect});
}

// 앱의 addWardrobeItem과 같은 모양(set merge)
const appWrite = {
  imageUrl: 'https://x/o/wardrobe_images%2Fa.jpg?alt=media&token=t',
  imagePath: 'wardrobe_images/a.jpg',
  category: '상의',
  createdAt: new Date(),
  ownerUid: 'alice',
};

async function main() {
  const env = await initializeTestEnvironment({
    projectId: 'demo-trigger-first',
    firestore: {rules: RULES, host: 'localhost', port: 8080},
  });
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    // 새 트리거: 누끼 필드 + ownerUid
    await db.collection('wardrobe').doc('newTrigger').set({cutoutPath: 'wardrobe_cutouts/a.png', cutoutImageUrl: 'u', ownerUid: 'alice'}, {merge: true});
    // 예전 트리거: 누끼 필드만
    await db.collection('wardrobe').doc('oldTrigger').set({cutoutPath: 'wardrobe_cutouts/b.png', cutoutImageUrl: 'u'}, {merge: true});
  });
  const alice = env.authenticatedContext('alice').firestore();
  const bob = env.authenticatedContext('bob').firestore();
  await check('T-1', '새 트리거가 먼저 쓴 문서 — 주인(앱)의 set(merge)', 'ALLOW',
      () => alice.collection('wardrobe').doc('newTrigger').set(appWrite, {merge: true}));
  await check('T-2', '새 트리거가 먼저 쓴 문서 — 앱 쓰기 뒤 누끼 필드가 남는다', 'ALLOW', async () => {
    const snap = await alice.collection('wardrobe').doc('newTrigger').get();
    if (!snap.data().cutoutPath || snap.data().imagePath !== 'wardrobe_images/a.jpg') throw new Error('fields');
  });
  await check('T-3', '새 트리거가 먼저 쓴 문서 — 다른 계정의 쓰기', 'DENY',
      () => bob.collection('wardrobe').doc('newTrigger').set({...appWrite, ownerUid: 'bob'}, {merge: true}));
  await check('T-4', '예전 트리거(ownerUid 없음)가 먼저 쓴 문서 — 앱의 set(merge)는 막힌다(지금의 결함)', 'DENY',
      () => alice.collection('wardrobe').doc('oldTrigger').set(appWrite, {merge: true}));
  await check('T-5', '트리거보다 앱이 먼저 — 새 문서 만들기', 'ALLOW',
      () => alice.collection('wardrobe').doc('appFirst').set(appWrite, {merge: true}));
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
