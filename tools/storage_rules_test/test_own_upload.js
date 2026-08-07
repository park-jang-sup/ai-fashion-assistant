// storage.rules의 wardrobe_images/ isOwnUpload() 실측 전용 스크립트.
// firebase emulators:exec --only storage 로 storage 에뮬레이터가 뜬
// 상태에서만 동작한다(단독 실행 시 에뮬레이터 미기동으로 실패).
//
// 4케이스, 판정 기준은 사전 등록됨(사용자 지시):
//   1) ownerUid == 인증 uid 메타데이터 업로드 → 반드시 allow
//   2) ownerUid != 인증 uid 메타데이터 업로드 → 반드시 deny
//   3) customMetadata 없는 업로드           → 관측만(우리 경로엔 없는 케이스)
//   4) 삭제(request.resource == null)        → 반드시 allow (핵심 — 여기서
//      deny가 나오면 storage.rules의 request.resource == null 단락이
//      실제로 동작 안 한다는 뜻이라 배포하면 안 된다)

const fs = require('fs');
const path = require('path');
const {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} = require('@firebase/rules-unit-testing');

const RULES_PATH = path.join(__dirname, '..', '..', 'storage.rules');
const BYTES = new Uint8Array([1, 2, 3, 4]); // 내용은 무관 — 크기/타입 검사만 isValidImage가 함

async function main() {
  const testEnv = await initializeTestEnvironment({
    projectId: 'demo-storage-rules-test',
    storage: {
      rules: fs.readFileSync(RULES_PATH, 'utf8'),
      host: 'localhost',
      port: 9199,
    },
  });

  const results = {};

  try {
    // 케이스 1: ownerUid == 인증 uid
    const alice = testEnv.authenticatedContext('alice');
    try {
      await assertSucceeds(
        alice
          .storage()
          .ref('wardrobe_images/case1.jpg')
          .put(BYTES, { contentType: 'image/jpeg', customMetadata: { ownerUid: 'alice' } })
      );
      results.case1_matching_owner = 'ALLOW (예상대로)';
    } catch (e) {
      results.case1_matching_owner = `DENY (예상과 다름! ${e.message}`;
    }

    // 케이스 2: ownerUid != 인증 uid (alice가 인증됐는데 메타데이터엔 bob)
    try {
      await assertFails(
        alice
          .storage()
          .ref('wardrobe_images/case2.jpg')
          .put(BYTES, { contentType: 'image/jpeg', customMetadata: { ownerUid: 'bob' } })
      );
      results.case2_mismatched_owner = 'DENY (예상대로)';
    } catch (e) {
      results.case2_mismatched_owner = `ALLOW (예상과 다름! ${e.message}`;
    }

    // 케이스 3: customMetadata 자체가 없음 — 관측만, 통과 판정에 안 씀
    try {
      await alice
        .storage()
        .ref('wardrobe_images/case3.jpg')
        .put(BYTES, { contentType: 'image/jpeg' });
      results.case3_no_metadata = 'ALLOW (관측값, 우리 경로엔 이 케이스 없음)';
    } catch (e) {
      results.case3_no_metadata = `DENY (관측값, 우리 경로엔 이 케이스 없음) — ${e.code || e.message}`;
    }

    // 케이스 4(핵심): 삭제 — request.resource == null 단락이 실제로
    // 먹히는지. 규칙을 끈 상태로 먼저 파일을 심어둔다(세팅 자체가
    // isOwnUpload()에 걸리면 안 되므로).
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await ctx
        .storage()
        .ref('wardrobe_images/case4_delete_me.jpg')
        .put(BYTES, { contentType: 'image/jpeg' });
    });
    try {
      await assertSucceeds(
        alice.storage().ref('wardrobe_images/case4_delete_me.jpg').delete()
      );
      results.case4_delete = 'ALLOW (예상대로 — 삭제 안 죽음)';
    } catch (e) {
      results.case4_delete = `DENY (핵심 위험 적중! 삭제가 막힘 — ${e.message}`;
    }
  } finally {
    await testEnv.cleanup();
  }

  console.log('\n=== 실측 결과 ===');
  for (const [k, v] of Object.entries(results)) {
    console.log(`${k}: ${v}`);
  }
}

main().catch((e) => {
  console.error('실행 자체 실패:', e);
  process.exit(1);
});
