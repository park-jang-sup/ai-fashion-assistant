// lib/services/fitting_job_controller.dart의 _buildFittingCacheKey와
// 반드시 같은 해시를 내야 하는 순수 함수(docs/task_fitting_server_cache_v1.md
// §1.3) — 서버가 클라이언트가 만든 캐시 키를 그대로 믿지 않고 직접
// 재계산하기 위함(3.12.2 원리: 결과물이 아니라 식별자를 받아 서버가
// 계산·검증한다). 어긋나면 캐시가 영원히 미스가 되는데 증상이 조용해
// 발견이 늦다 — fitting_cache_key.test.ts가 Dart 쪽과 같은 입력·같은
// 출력을 고정 벡터로 확인한다.
//
// Dart 원본(fitting_job_controller.dart fittingCacheKeyFor):
//   final sortedClothingIds = [...clothingItemIds]..sort();
//   final raw = '$fittingCacheKeyVersion:$userPhotoId:${sortedClothingIds.join(',')}';
//   return sha256.convert(utf8.encode(raw)).toString();
// sha256(UTF-8 bytes)는 표준 알고리즘이라 Dart의 crypto 패키지와 Node의
// crypto 모듈이 같은 입력에 항상 같은 hex(소문자)를 낸다 — 구현체 차이가
// 아니라 "정렬 규칙이 같은가"만 실제로 검증해야 할 지점이다.
import {createHash} from "node:crypto";

// 캐시 키 버전(docs/task_fitting_quality_v2.md §4-1) - 모델·프롬프트가
// 바뀌어도 같은 조합이면 옛 결과를 캐시에서 돌려줘 개선이 안 보인다.
// 원문 앞에 버전을 붙여 새 모델 결과만 서로 맞게 한다. 접두사 없는 옛
// 키(v1 이전 결과)는 그대로 남지만 다시 조회되지 않는다. Dart
// fittingCacheKeyFor와 같은 값을 써야 한다.
export const FITTING_CACHE_KEY_VERSION = "v2";

export function buildFittingCacheKey(userPhotoId: string, clothingItemIds: string[]): string {
  const sorted = [...clothingItemIds].sort();
  const raw = `${FITTING_CACHE_KEY_VERSION}:${userPhotoId}:${sorted.join(",")}`;
  return createHash("sha256").update(raw, "utf8").digest("hex");
}
