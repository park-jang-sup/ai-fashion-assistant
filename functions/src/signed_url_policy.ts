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

// ── 경로 검사(보안 최소 조치 S2-1) ──────────────────────────────────
// wardrobe 문서의 경로는 문서 주인이 마음대로 적을 수 있다(firestore.rules가 경로 필드를 검사하지 않는다) —
// 남의 파일 경로를 자기 문서에 적어 서명을 받는 것을 막는다. storage.rules(읽기: ownerUid 본인 또는
// demo == 'true')와 같은 조건이다. demo_wardrobe·fitting_cache 요청은 이 검사를 하지 않는다(지금 그대로).
//   ① 경로가 demo_wardrobe 문서들이 가리키는 경로 집합에 있으면 허용(isDemo 사본 문서가 여기 걸린다)
//   ② 아니면 파일 메타데이터의 ownerUid가 호출자와 같을 때 허용
//   ③ 그 밖에는 그 경로만 서명하지 않는다
export type PathDenyReason = "file-missing" | "no-owner-metadata" | "other-owner";

export interface FileMeta {
  exists: boolean;
  ownerUid?: string;
}

export interface PathDecision {
  allowed: boolean;
  via?: "demo" | "owner";
  reason?: PathDenyReason;
}

export function decidePathOwnership(
  path: string,
  demoPaths: ReadonlySet<string>,
  file: FileMeta | undefined,
  callerUid: string
): PathDecision {
  if (demoPaths.has(path)) return {allowed: true, via: "demo"};
  if (!file || !file.exists) return {allowed: false, reason: "file-missing"};
  if (!file.ownerUid) return {allowed: false, reason: "no-owner-metadata"};
  if (file.ownerUid !== callerUid) return {allowed: false, reason: "other-owner"};
  return {allowed: true, via: "owner"};
}

// demo_wardrobe 문서들이 가리키는 경로 — 경로 필드가 있으면 그것, 없으면 다운로드 URL에서 역산.
export function demoPathsFromDocs(docs: Iterable<Partial<DocFields>>): Set<string> {
  const out = new Set<string>();
  for (const d of docs) {
    for (const p of [d.imagePath ?? pathFromDownloadUrl(d.imageUrl), d.cutoutPath ?? pathFromDownloadUrl(d.cutoutImageUrl)]) {
      if (p) out.add(p);
    }
  }
  return out;
}

// 모드 — "log"(기록: 거부할 것을 로그에만, 지금처럼 서명)·"enforce"(적용: 실제로 거부). 값이 없거나
// 모르는 값이면 log(안전한 쪽).
export type PathCheckMode = "log" | "enforce";
export function pathCheckMode(raw: string | undefined): PathCheckMode {
  return raw?.trim().toLowerCase() === "enforce" ? "enforce" : "log";
}

// 한 문서의 경로별 판정을 응답 URL 자리로 바꾼다. enforce에서 거부한 경로는 빈 문자열로 둔다 — 앱은
// 자리 번호(0 원본, 1 누끼)로 URL을 고르므로 자리를 지켜야 한다. 모든 경로가 거부되면 null(응답에서 생략 —
// 앱은 없는 id를 기존 URL 폴백 신호로 본다). log에서는 판정과 무관하게 모두 서명할 경로로 둔다.
export function pathsToSign(
  paths: string[],
  decisions: PathDecision[],
  mode: PathCheckMode
): (string | null)[] | null {
  if (mode === "log") return paths;
  const out = paths.map((p, i) => (decisions[i]?.allowed ? p : null));
  return out.every((p) => p === null) ? null : out;
}

// 동시 실행 상한 — 메타데이터 조회를 한 요청 안에서 동시에 하되 과하지 않게(200건 요청 대비).
export function createLimiter(max: number): <T>(task: () => Promise<T>) => Promise<T> {
  let active = 0;
  const queue: (() => void)[] = [];
  const next = () => {
    if (active >= max) return;
    const run = queue.shift();
    if (run) run();
  };
  return <T>(task: () => Promise<T>) =>
    new Promise<T>((resolve, reject) => {
      queue.push(() => {
        active++;
        task().then(resolve, reject).finally(() => {
          active--;
          next();
        });
      });
      next();
    });
}

export const PATH_CHECK_CONCURRENCY = 16;
