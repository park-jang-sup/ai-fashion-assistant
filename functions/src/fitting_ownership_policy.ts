// generateFittingImage(docs/task_fitting_server_cache_v1.md §1.4) 소유권
// 판정 — signed_url_policy.ts의 decideSignedUrlAccess와 같은 원칙으로
// Admin SDK 읽기와 분리해 node로 단위 테스트한다. 가상 피팅에 쓰이는
// 이미지(전신 사진 + 옷들)는 전부 호출자 본인의 wardrobe 문서여야
// 한다 — demo_wardrobe나 타인 문서는 이 흐름의 대상이 아니다.

export interface WardrobeOwnerDoc {
  id: string;
  exists: boolean;
  ownerUid?: string;
}

export type FittingOwnershipDenyReason = "not-found" | "owner-mismatch";

export interface FittingOwnershipResult {
  allowed: boolean;
  reason?: FittingOwnershipDenyReason;
  deniedId?: string;
}

// 검증이 먼저, 캐시 키 계산은 그 다음(§1.4) — 하나라도 거부되면 즉시
// 멈추고 나머지는 검사하지 않는다(불필요한 Firestore 읽기 결과를
// 더 쌓을 이유가 없음, 첫 거부 사유만 있으면 충분).
export function verifyFittingOwnership(
  docs: WardrobeOwnerDoc[],
  callerUid: string
): FittingOwnershipResult {
  for (const doc of docs) {
    if (!doc.exists) {
      return {allowed: false, reason: "not-found", deniedId: doc.id};
    }
    if (doc.ownerUid !== callerUid) {
      return {allowed: false, reason: "owner-mismatch", deniedId: doc.id};
    }
  }
  return {allowed: true};
}
