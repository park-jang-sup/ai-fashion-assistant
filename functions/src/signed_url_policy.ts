// getSignedImageUrls(docs/task_signed_urls_v1.md A-2) 접근 정책 판정 —
// Firestore 문서를 직접 검사하지 않고 순수 함수로 분리해 node로 단위
// 테스트한다(rate_limit.ts와 같은 원칙).
//
// 서명 요청 단위는 경로가 아니라 문서 ID다(§3-2) — 클라이언트가 경로
// 문자열을 직접 보내면 유출 URL → 경로 추출 → 재서명이라는 재발급
// 루프가 생긴다. 이 모듈은 "이 uid가 이 문서에 접근해도 되는가"와
// "된다면 어느 경로에 서명할까"만 결정하고, 경로 자체는 서버가 이미
// 읽은 문서 필드에서만 나온다.

export type SignedUrlCollection = "wardrobe" | "demo_wardrobe" | "fitting_cache";

export interface SignedUrlRequestItem {
  collection: SignedUrlCollection;
  id: string;
}

// Firestore에서 읽은 원본 문서를 판정에 필요한 최소 형태로 옮긴 것 —
// Admin SDK 의존 없이 테스트하기 위한 경계.
export interface DocFields {
  exists: boolean;
  ownerUid?: string;
  // path 필드(A-3 이후 신규 업로드, Phase B 이후 기존 문서)가 있으면
  // 그걸 쓰고, 없으면 기존 다운로드 URL 필드에서 역산한다 — Phase B
  // 백필 전에도 기존 119벌이 전부 서명 가능해야 한다(관문 A).
  imagePath?: string;
  imageUrl?: string;
  cutoutPath?: string;
  cutoutImageUrl?: string;
}

export type PolicyDenyReason = "not-found" | "owner-mismatch" | "no-path";

export interface PolicyResult {
  allowed: boolean;
  reason?: PolicyDenyReason;
  paths: string[];
}

// Firebase Storage 다운로드 URL(.../o/{encodedPath}?alt=media&token=...)
// 에서 경로를 역산한다. tools/backfill_image_paths(Phase B)가 쓸 규칙과
// 동일 — 여기서는 path 필드가 아직 없는 문서의 즉석 폴백으로 쓴다.
export function pathFromDownloadUrl(url: string | undefined): string | undefined {
  if (!url) return undefined;
  const match = url.match(/\/o\/([^?]+)/);
  if (!match) return undefined;
  try {
    return decodeURIComponent(match[1]);
  } catch {
    return undefined;
  }
}

// 컬렉션별 정책(§3-2 표) 그대로:
//   wardrobe      — doc.ownerUid == caller
//   demo_wardrobe — 인증만(onCall의 auth 검사로 이미 충분, 추가 검사 없음)
//   fitting_cache — ownerUid 있으면 caller와 대조, 없으면(레거시) 인증만
//                   (§8-2, 사용자 승인 — 레거시 캐시 인증만 허용을 채택.
//                   후자를 거부하면 기존에 잘 되던 레거시 캐시 열람이
//                   깨지는 기능 회귀가 된다)
export function decideSignedUrlAccess(
  item: SignedUrlRequestItem,
  doc: DocFields,
  callerUid: string
): PolicyResult {
  if (!doc.exists) {
    return {allowed: false, reason: "not-found", paths: []};
  }

  if (item.collection === "wardrobe") {
    if (doc.ownerUid !== callerUid) {
      return {allowed: false, reason: "owner-mismatch", paths: []};
    }
  } else if (item.collection === "fitting_cache") {
    if (doc.ownerUid !== undefined && doc.ownerUid !== callerUid) {
      return {allowed: false, reason: "owner-mismatch", paths: []};
    }
  }
  // demo_wardrobe: 추가 검사 없음.

  const paths: string[] = [];
  if (item.collection === "fitting_cache") {
    // 캐시 키는 문서 id 자체(fitting_job_controller.dart의 SHA-256 키
    // 체계) — storage_service.dart의 '$_fittingResultsFolder/$cacheKey.jpg'와
    // 동일한 경로 유도.
    paths.push(`fitting_results/${item.id}.jpg`);
  } else {
    const imagePath = doc.imagePath ?? pathFromDownloadUrl(doc.imageUrl);
    if (imagePath) paths.push(imagePath);
    const cutoutPath = doc.cutoutPath ?? pathFromDownloadUrl(doc.cutoutImageUrl);
    if (cutoutPath) paths.push(cutoutPath);
  }

  if (paths.length === 0) {
    return {allowed: false, reason: "no-path", paths: []};
  }
  return {allowed: true, paths};
}

// 옷장 화면이 119벌을 한 콜로 해결해야 한다(§3-2) — 상한은 남용 방지용.
export const MAX_BATCH_SIZE = 200;

export interface BatchValidation {
  valid: boolean;
  reason?: "empty" | "too-large";
}

export function validateBatch(items: SignedUrlRequestItem[]): BatchValidation {
  if (items.length === 0) return {valid: false, reason: "empty"};
  if (items.length > MAX_BATCH_SIZE) return {valid: false, reason: "too-large"};
  return {valid: true};
}
