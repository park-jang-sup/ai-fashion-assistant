// 트리거만 쓴 wardrobe 문서(ownerUid·cutoutPath·cutoutImageUrl만, createdAt·category·imageUrl 없음)가
// 앱(1.0.0+3, 81d9cee)의 wardrobe 쿼리에 나오는지 — 앱과 같은 쿼리를 firestore.rules(바꾸지 않음) 아래
// 에뮬레이터에서 돌린다. 보안 최소 조치 S2-2 배포 전 확인.
//   (저장소 루트에서) firebase emulators:exec --only firestore --project demo-trigger-only "node tools/storage_rules_test/test_trigger_only_doc_queries.js"
const fs = require('fs');
const path = require('path');
const {initializeTestEnvironment} = require('@firebase/rules-unit-testing');

const RULES = fs.readFileSync(path.join(__dirname, '..', '..', 'firestore.rules'), 'utf8');
const rows = [];
function row(id, what, expect, got) {
  rows.push({id, what, expect, got, ok: expect === got});
}

async function main() {
  const env = await initializeTestEnvironment({
    projectId: 'demo-trigger-only',
    firestore: {rules: RULES, host: 'localhost', port: 8080},
  });
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    const now = new Date();
    await db.collection('wardrobe').doc('full').set({
      imageUrl: 'u', imagePath: 'wardrobe_images/a.jpg', category: '상의', createdAt: now, ownerUid: 'alice',
    });
    await db.collection('wardrobe').doc('body').set({
      imageUrl: 'u', imagePath: 'wardrobe_images/b.jpg', category: '전신', createdAt: now, ownerUid: 'alice',
    });
    await db.collection('wardrobe').doc('demoCopy').set({
      imageUrl: 'u', category: '하의', createdAt: now, ownerUid: 'alice', isDemo: true,
    });
    // 새 트리거가 앱보다 먼저 쓴 문서(앱의 쓰기가 실패하면 그대로 남는다)
    await db.collection('wardrobe').doc('triggerOnly').set({
      cutoutPath: 'wardrobe_cutouts/c.png', cutoutImageUrl: 'u', ownerUid: 'alice',
    });
  });
  const db = env.authenticatedContext('alice').firestore();
  const ids = (snap) => snap.docs.map((d) => d.id).sort().join(',');

  // FirestoreService.wardrobeStream — 옷장 목록, 코디보드, 피팅룸, 홈, 캘린더, 에이전트 도구(옷장 조회·요약·
  // 미리 보기), 백그라운드 에이전트(AgentPlanner), 추천이 모두 이 쿼리를 쓴다.
  const stream = await db.collection('wardrobe').where('ownerUid', '==', 'alice').orderBy('createdAt', 'desc').get();
  row('Q-1', 'wardrobeStream(ownerUid ==, orderBy createdAt) — 트리거만 쓴 문서는 빠진다', 'body,demoCopy,full', ids(stream));
  // FirestoreService.fullBodyItems — 전신 사진 기본값·"다른 전신 사진으로"
  const bodies = await db.collection('wardrobe').where('ownerUid', '==', 'alice').where('category', '==', '전신').get();
  row('Q-2', 'fullBodyItems(category == 전신) — 빠진다', 'body', ids(bodies));
  // FirestoreService.firstDemoFullBodyItem / clearDemoWardrobe(isDemo == true)
  const demo = await db.collection('wardrobe').where('ownerUid', '==', 'alice').where('isDemo', '==', true).get();
  row('Q-3', 'clearDemoWardrobe·firstDemoFullBodyItem(isDemo == true) — 빠진다', 'demoCopy', ids(demo));
  // 문서 하나 읽기(getWardrobeItemSilently)는 id를 알아야 한다 — 그 id는 위 목록에서만 온다. 주인이면 읽힌다.
  const one = await db.collection('wardrobe').doc('triggerOnly').get();
  row('Q-4', '문서 하나 읽기(id를 알 때) — 주인에게는 읽힌다(목록에 없어 앱이 id를 얻지 못한다)', 'readable', one.exists ? 'readable' : 'missing');
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
