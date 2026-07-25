# Firestore 복합 인덱스 대응표

`firestore.indexes.json`은 JSON이라 주석을 못 넣는다 — 각 인덱스 항목이
어느 쿼리 때문에 필요한지 여기에 기록한다. **인덱스를 추가/삭제할 때마다
이 표도 같이 갱신할 것.**

| 인덱스 | 대상 쿼리(파일:함수) | 화면/기능 | 왜 필요한가 |
|---|---|---|---|
| `recommendations`(COLLECTION) — `dismissed` ASC + `createdAt` DESC | `lib/services/firestore_service.dart`의 `recommendationStream()` | 홈 화면 "오늘의 추천 코디" 카드 | `where('dismissed', ==)` + `orderBy('createdAt')`(다른 필드) 조합이라 자동 단일 인덱스로 안 됨 |

`queryScope: COLLECTION`인 이유: `recommendations`는 `users/{uid}/recommendations`
서브컬렉션 하나로만 쓰이고(`collectionGroup()`으로 여러 uid를 가로질러 쿼리하는
코드는 없음, 2026-07 조사로 확인됨) — 특정 경로 전용 인덱스면 충분하다.
전 uid를 가로지르는 쿼리가 생기면 그때 `COLLECTION_GROUP`으로 바꿔야 한다.

## 인덱스가 필요 없는 이유가 있는 쿼리 (참고용, 재발 방지 체크리스트)

같은 파일의 나머지 쿼리는 아래 이유로 복합 인덱스가 필요 없다 — 새 쿼리를
추가할 때 이 표와 비교해서 판단할 것:

- `where` 없이 `orderBy`만: `wardrobeStream`, `getRecentHistorySilently`,
  `recentRecommendationsSilently`, `agentLogStream`, `scrapStream`.
- `where` 단일 필드(equality 또는 단방향 range)만, `orderBy` 없음:
  `recommendationsSinceSilently`, `hasRecommendationForDateSilently`,
  `enqueueAgentTaskSilently`, `duePendingAgentTasksSilently`, `isScrapped`.
- `where` 양방향 range + `orderBy`가 **같은 필드**(자동 단일 인덱스로 충분):
  `recommendationsInDateRangeSilently`(orderBy 자체가 없음),
  `calendarEntriesForMonth`, `calendarEntriesForRange`(둘 다 `date` 필드로
  range+orderBy).

`collectionGroup()` 쿼리, 함수 하나에 `orderBy` 2회 이상 쓰는 쿼리는
2026-07 기준 앱 전체에 없음.
