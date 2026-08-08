// lib/services/fitting_job_controller.dart의 _buildFittingCacheKey와
// 반드시 같은 해시를 내야 하는 순수 함수(docs/task_fitting_server_cache_v1.md
// §1.3) — 서버가 클라이언트가 만든 캐시 키를 그대로 믿지 않고 직접
// 재계산하기 위함(3.12.2 원리: 결과물이 아니라 식별자를 받아 서버가
// 계산·검증한다). 어긋나면 캐시가 영원히 미스가 되는데 증상이 조용해
// 발견이 늦다 — fitting_cache_key.test.ts가 Dart 쪽과 같은 입력·같은
// 출력을 고정 벡터로 확인한다.
//
// Dart 원본(fitting_job_controller.dart:285-292):
//   final sortedClothingIds = clothingItems.map((i) => i.id).toList()..sort();
//   final raw = '${userPhoto.id}:${sortedClothingIds.join(',')}';
//   return sha256.convert(utf8.encode(raw)).toString();
// sha256(UTF-8 bytes)는 표준 알고리즘이라 Dart의 crypto 패키지와 Node의
// crypto 모듈이 같은 입력에 항상 같은 hex(소문자)를 낸다 — 구현체 차이가
// 아니라 "정렬 규칙이 같은가"만 실제로 검증해야 할 지점이다.
import {createHash} from "node:crypto";

export function buildFittingCacheKey(userPhotoId: string, clothingItemIds: string[]): string {
  const sorted = [...clothingItemIds].sort();
  const raw = `${userPhotoId}:${sorted.join(",")}`;
  return createHash("sha256").update(raw, "utf8").digest("hex");
}
