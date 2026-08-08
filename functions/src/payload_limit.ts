// 프록시(callGeminiText) 페이로드 크기 상한 판정 — 순수 함수로 분리해
// 단위 테스트한다(rate_limit.ts와 같은 검증 원칙,
// docs/handoff_2026-08-07.md §6 (4) "프록시 페이로드 크기 상한").
//
// 근거(2026-08-08 세션 측정 — 코드 수정·배포 없이 Cloud Functions 로그와
// Storage만 읽어 측정. 이 세션에서는 재측정하지 않는다):
//
//   실측 (1) 현재 옷장 최악 조합 — 본인 계정 카테고리별(전신/상의/하의/
//     아우터/신발/액세서리) 최대 파일 6개를 Storage에서 직접 조회해
//     합산. raw 618,040B → base64 824,060B(≈824KB). 같은 기간 Cloud
//     Functions 로그의 실제 관측 최댓값(842,061B)과 근접 — "파일
//     재조합"과 "로그 관측"이라는 서로 다른 방법이 비슷한 값을 내
//     교차검증됨.
//
//   실측 (2) picker 설정이 이론상 허용하는 최악 — 등록용 picker는
//     imageQuality:80, max 1440(lib/screens/wardrobe_screen.dart:572-576).
//     1440×1440 랜덤 노이즈(JPEG가 가장 못 줄이는 콘텐츠)를 실제 JPEG
//     인코더로 quality=80 인코딩해 측정: raw 1,384,759B → base64
//     1,846,348B(≈1.76MB).
//       - 텍스트 경로(gemini-3.5-flash/gemini-3.1-flash-lite): 이
//         모델군이 한 요청에 첨부하는 사진은 최대 1장(extractAttributes/
//         사이즈표 OCR/무프로필 analyzeOutfitFromAttributes 중 하나) —
//         이론상 최악 ≈ 1.76MB.
//       - 이미지 경로(gemini-3.1-flash-image, 가상 피팅): 슬롯이 전신
//         1장 + 카테고리(상의/하의/아우터/신발/액세서리) 5장 = 최대
//         6장(lib/screens/fitting_room_screen.dart:1576) — 이론상 최악
//         raw 8.31MB → base64 ≈10.56MB. (matching engine의
//         maxSkeletonCategories=4는 추천 스켈레톤 값이고 피팅 슬롯 수와
//         무관 — 혼동 금지.)
//     caveat: 위 인코딩은 PIL JPEG 인코더로 측정했고 실기기(Android
//     Bitmap.compress/iOS UIImageJPEGRepresentation)와 바이트 단위로
//     동일하지 않다 — 자릿수(MB) 신뢰 구간으로 다룬다.
//
// 상한 값(확정 — 임의 변경·재측정 금지):
//   text  4MB  — 이론상 최악(1.76MB) 대비 2.3배 여유.
//   image 16MB — 이론상 최악(10.56MB) 대비 1.5배 여유.
//   두 여유 모두 PIL/실기기 인코더 차이와 프롬프트 텍스트 변동폭을
//   흡수하도록 잡은 것으로 판단. 상한은 (1) 관측 최댓값이 아니라
//   (2) picker 이론상 최악에서 나왔다 — 옷장 내용이 바뀌어 지금보다
//   크거나 압축이 덜 되는 사진이 올라와도 정상 사용이 죽지 않게 하려는
//   목적.
export const PAYLOAD_LIMIT_CONFIG: PayloadLimitConfig = {
  textLimitBytes: 4 * 1024 * 1024,
  imageLimitBytes: 16 * 1024 * 1024,
};

export type PayloadKind = "text" | "image";

// 호출량 상한(index.ts checkAndRecordRateLimit)이 쓰는 model→kind
// 파생과 같은 로직 — 단일 출처로 두 판정이 같이 바뀌게 한다(index.ts의
// 기존 인라인 삼항연산자를 그대로 옮긴 것, 동작 변경 없음).
// 화이트리스트 밖의 model 문자열이 오면 "text"로 취급한다 — index.ts는
// 이 함수를 호출하기 전에 이미 ALLOWED_MODELS로 걸러내므로 실제로는
// 도달하지 않지만, 이 함수 자체는 미지의 model에 대해 더 낮은(4MB)
// 상한 쪽으로 방어적으로 떨어진다.
export function kindForModel(model: string): PayloadKind {
  return model === "gemini-3.1-flash-image" ? "image" : "text";
}

export interface PayloadLimitConfig {
  textLimitBytes: number;
  imageLimitBytes: number;
}

export interface PayloadLimitDecision {
  allowed: boolean;
  limitBytes: number;
}

function limitBytesFor(kind: PayloadKind, config: PayloadLimitConfig): number {
  return kind === "image" ? config.imageLimitBytes : config.textLimitBytes;
}

// requestBytes == limitBytes는 허용(상한은 포함 경계) — 초과(>)만 거부한다.
export function evaluatePayloadLimit(
  requestBytes: number,
  kind: PayloadKind,
  config: PayloadLimitConfig
): PayloadLimitDecision {
  const limitBytes = limitBytesFor(kind, config);
  return {allowed: requestBytes <= limitBytes, limitBytes};
}
