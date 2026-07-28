# 작업 정리 (2026-07-28 — 추천 중복 게이트 수정, 실기기 검증, 조합 품질/다양성 A/B 리그 2건 반영)

`docs/session_2026-07-27_summary.md`(TPO 정책 실측 A/B, skeleton 슬롯 격상,
optionalMissing)를 이어받아 `main` 브랜치 위에서 작업. 이번 세션은 전부
커밋 완료 상태 — 미완료 워킹트리 변경 없음, `personal/main`까지 push 완료.

## 1. `recommendationForDateSilently` 중복 게이트 버그 수정 (커밋 `f6d825e`)

### 배경 — 두 가지 문제
- **문제 1**: `generateRecommendationForNewItem`(새 옷 등록 계기 추천)이
  `targetDate`를 등록일로 채우는데, 중복 게이트 쿼리가 `triggerItemId`를
  안 봐서 같은 날짜의 **일정 기반** 추천과 구분하지 못했다. 새 옷 추천이
  먼저 저장되면 그 날짜의 진짜 일정 추천이 "이미 존재 — 스킵"으로
  영구히 안 만들어질 수 있었다.
- **문제 2**: `limit(1)`에 `orderBy`가 없어 같은 날짜에 미dismiss 문서가
  둘 이상이면 어느 게 반환될지 비결정적이었고, `shouldReplan`의
  `replanCount` 상한 체크가 문서 선택에 따라 켜졌다 꺼졌다 했다.

### 구현
- `FirestoreService.selectDateRecommendation(candidates)` 순수 함수 신규
  — 복합 인덱스를 피하려고 쿼리 필터는 그대로 두고(`targetDate` +
  `dismissed` equality, `limit`만 1→5) 후보 리스트를 받아 Dart에서
  `triggerItemId.isEmpty`(일정 기반)만 남기고 `createdAt` 최신순 정렬 →
  `(target, toDismiss)`를 돌려준다. Firestore 없이 테스트 가능.
- `recommendationForDateSilently`가 위 함수로 대상 1건을 고르고, 남은
  일정 기반 중복 문서는 `unawaited(dismissRecommendation(...))`로 조용히
  정리(실패해도 이미 찾은 target 반환에 영향 없도록).
- `agent_planner.dart`는 호출 시그니처/동작 계약이 그대로라 수정 불필요.

### 테스트
`test/recommendation_date_gate_test.dart`(신규) — 새 옷 추천만/일정
추천만/혼합/일정 추천 2건 이상/빈 리스트 5케이스 + 리뷰 중 지적받아
강화한 케이스(혼합 상황에서 정리 대상에 새 옷 추천이 **절대** 안
섞이는지 명시적 단언) 총 6케이스. `flutter test` 전체 106개 통과.

## 2. 실기기 검증 (Galaxy S23, Android 16)

`flutter run -d <device>`로 로그를 실시간 캡처하며 사용자가 직접 앱을
조작, 백그라운드에서 로그만 분석·해설하는 방식으로 진행.

- **확인된 정상 동작**: `[PLAN] 7/29 추천 이미 존재 — 스킵`이 같은
  날짜에 반복 체크돼도 일관되게 나옴(§1 수정 후 문서 선택 안정성 확인).
  새 옷 등록 → 속성 추출 → 후보 3개 생성 → 자기평가(83점 채택) →
  Firestore 저장 → 피드백 대조까지 파이프라인 전체가 로그로 추적됨.
- **문제1 재현은 보류**: `calendar_screen.dart`의 `_isFuture(day) =>
  day.isAfter(_today)`(엄격한 미래 판정) 때문에 UI에서 오늘/과거 날짜엔
  일정 등록 자체가 불가능(착장 기록하기만 가능) — 그래서 "새 옷 등록일
  = 일정 등록일"인 충돌 상황을 지금 당장 UI로 못 만든다. 재현하려면
  기기 날짜를 미래로 바꾸거나 하루 기다려야 해서, 순수 함수 테스트로
  이미 검증됐다는 이유로 사용자가 이 시나리오는 생략하기로 결정.
- **발견한 별개 이슈(미해결, 낮은 우선순위)**: personal Firebase
  프로젝트에서 App Check API가 비활성화돼 있어(`403`) placeholder
  토큰으로 대체되고 있음 — 지금은 강제(enforce) 모드가 아니라 Firestore
  요청 자체는 통과하지만, 나중에 enforcement를 켜면 막힐 수 있음.
- `flutter run` 디버그 세션이 화면 잠금/앱 전환 시 "Lost connection to
  device"로 두 차례 끊김 — 앱 자체 크래시 아님, 재연결로 해결.

## 3. 조합 품질 A/B 리그 반영 (커밋 `c3ee633`)

### 경위
외부에서 Dart 툴체인 없이 작성된 `_ref/combo_quality_policy.patch` +
동일 내용의 `_ref/*.dart` 3벌(`outfit_matcher.dart`,
`outfit_matcher_test.dart`, `tpo_policy_report_test.dart`)을 검토 요청
받음. `git apply --check`로 클린 적용 확인 + 디스포저블 worktree에 실제
적용해 `_ref/*.dart`와 바이트 단위 동일함(줄바꿈 방식만 다름) 검증 후,
CRLF를 벗긴 clean diff를 사용자에게 보여주고 승인받아 반영.

### 구현
- `TpoMatchPolicy`에 `candidatesPerCategory`(기본 2)/
  `usePairwiseColorScore`(기본 false)/`forceEnumerated`(기본 false) 3개
  필드와 `useEnumeratedCombos`/`effectiveCandidatesPerCategory` 게터 추가.
  세 값이 전부 기본이면 `useEnumeratedCombos=false`라 기존
  `_buildCombosFromRanked` 경로가 그대로 실행 — `current` 정책의 산출물은
  한 비트도 안 바뀜.
  프리셋: `enumeratedOnly`(생성기 효과 분리용 기준선)/`wideCandidates`/
  `pairwiseColor`/`qualityV2`.
- 새 생성기 `_buildCombosByEnumeration` — 카테고리별 후보를 전수 조합해
  조합 단위로 채점(격식 점수 + 옵션으로 쌍별 색상 점수). 곱집합이 상한
  (2000)을 넘으면 **카테고리를 자르지 않고 폭(width)만 줄이는**
  `resolveEnumerationWidth`(`@visibleForTesting`, 순수 함수)로 방어 —
  "매번 하나가 조용히 탈락"하던 §2026-07-27의 실패 패턴을 반복하지 않게
  설계.
- 리포트 표8~표12(`tpo_policy_report_test.dart`) — 1번 후보 변화의
  축별 귀속(생성기/폭/색상 분리), 옷장 커버리지, 색상 품질, 후보 다양성,
  미니 조합 채택 현황.

### 리포트 결과 (실측 옷장 87벌)
1번 후보 변화 생성기/폭/색상/합산 전부 **0/9**(이 옷장에서 세 축 다
무효) — 폭을 72→144벌로 넓혀도 등장 아이템은 54개로 그대로(활용률
75.0%→37.5%). 병목이 조합 단계가 아니라 그 앞 `topPerCategory` 상위 N
컷이라는 게 드러나 §4로 이어짐. `flutter test` 120개 통과.

## 4. 다양성(최근 노출 감점) A/B 리그 반영 (커밋 `35820db`)

### 경위
동일한 방식(patch + `_ref/*.dart` 5벌 검증 → clean diff 리뷰 → 승인 →
적용)으로 `_ref/diversity_recency.patch` 반영.
`agent_planner.dart`/`outfit_matcher.dart`/
`test/agent_planner_recency_test.dart`(신규)/`test/outfit_matcher_test.dart`/
`test/tpo_policy_report_test.dart` 5개 파일 대상.

### 구현
- `TpoMatchPolicy.recencyPenalty`(기본 0.0, 이 시점) 필드 추가 — 아이템
  점수 단계(조합 점수 아님)에 감점을 넣어 §3에서 드러난 병목을 직접
  겨냥. `keep`(격식 통과/`isFallback` 판정)에는 영향 없고 **정렬 순서만**
  바꿈. `applyRecency = recencyPenalty > 0 && recentItemIds.isNotEmpty`.
- `AgentPlanner.recentItemIdsFrom(recent, now, {window: 14일})`
  (`@visibleForTesting`, 순수 함수) — 최근 추천 이력에서 창 안의
  `itemIds`를 모두 모음. `userChoice`로 안 거름(노출 자체가 기준, 거절된
  조합도 다시 1순위로 올릴 이유 없음).
- `_prepareRecommendationFor`가 `FirestoreService.recentRecommendationsSilently`
  (기존 함수 재사용)로 이력을 가져와 `findForTpo` 호출에 주입.
- 프리셋: `diversityTieBreak`(0.4, 격식 등급 못 넘음)/`diversityModerate`
  (1.0, 무채색 보너스급)/`diversityStrong`(2.0, 격식 인접 등급까지 넘음).

### 리포트 결과 — 표13~표15
표13: 카테고리별 최고점 동점 규모 평균 10.67벌(384벌 중 66벌만 채택,
318벌이 순회 순서로 탈락) — 회전 가능 여지가 컸다는 게 정량적으로 확인됨.
표14(9태그 순차 시뮬레이션, recent 누적): 감점 0.0→0.4→1.0→2.0으로
커버리지 12.6%→33.3%→37.9%→43.7%, **isFallback 태그 수는 전 구간 0/9로
불변** — 회전이 TPO 정확도를 깨지 않고 늘어남을 확인. `flutter test`
131개 통과.

## 5. `recencyPenalty` 기본값 0.0→0.4 적용 (커밋 `3b9a42b`)

### 근거
표14 실측(커버리지 12.6%→33.3%, isFallback 0/9 유지)과, 0.4가 격식
적합도 인접 간격의 최솟값(0.5)보다 작아 **격식 등급을 절대 못 넘고
동점 집합 안에서만** 재정렬한다는 이론적 안전장치 둘 다 근거로 채택.

### 구현
- `TpoMatchPolicy` 생성자 기본값 `recencyPenalty: 0.4`로 변경, 필드
  주석 갱신.
- `diversityOff = TpoMatchPolicy(recencyPenalty: 0.0)` 프리셋 신규 —
  리포트에서 "감점 없음" 기준선 비교를 계속 쓸 수 있게 유지.
  `tpo_policy_report_test.dart`의 표14 `'0.0 (현행)'` 행도 이제
  `diversityOff`를 참조하도록 교체(그대로 두면 `current`와 값이 같아져
  표14의 두 행이 중복되는 문제 방지).
- **이 변경으로 깨진 테스트 1건**: `outfit_matcher_test.dart`의 "감점
  0이거나 recent가 비면 현행과 완전히 동일하다"의 두 번째 서브케이스가
  암묵적으로 `policy: TpoMatchPolicy.current`(이제 감점 0이 아님)에
  의존하고 있었음 — `policy: TpoMatchPolicy.diversityOff` 명시로 원래
  의도 복원.
- 기본값 변경이 사고가 아니라 의도임을 증언하는 테스트 신규 추가 —
  `TpoMatchPolicy.current.recencyPenalty == 0.4` /
  `diversityOff.recencyPenalty == 0.0`을 값으로, 같은 옷장·같은
  recent로 `current` vs `diversityOff` 결과 시그니처가 실제로
  달라짐(`isNot`)을 동작으로 함께 단언.

### 결과
`flutter test` **132개 전체 통과**, `flutter analyze` 이슈 변화 없음
(기존 무관 warning 1건 + `tpo_policy_report_test.dart`의 사소한
`unnecessary_brace_in_string_interps` info 1건만 유지, 둘 다 미수정).

## 작업 방식 메모 — 외부 patch 반영 절차

이번 세션에서 두 번(§3, §4) 반복된 패턴을 다음 세션에도 그대로 쓸 것:
1. `_ref/` 폴더의 patch를 `git apply --check`로 드라이런.
2. 디스포저블 `git worktree`에 실제 적용해 `_ref/*.dart`(동봉된 "완성본"
   사본)와 CRLF 무시하고 바이트 단위 비교 — patch와 사본이 정말 같은
   내용인지 검증.
3. CRLF 벗긴 clean diff를 파일별로 사용자에게 제시, 승인 받은 뒤에만
   실제 트리에 `git apply`.
4. `flutter analyze && flutter test` — `_ref/` 자체는 프로젝트 밖
   사본이라 상대경로 import가 깨져 나는 에러는 무시 대상이라고 명시.
5. 승인 후 `_ref/` 삭제, 지정된 파일만 `git add`(전체 add 금지) 후 커밋.

## 다음 세션 시작 시 할 일

이전 세션(§2026-07-27)에서 이월된 것 중 이번에도 미착수:
1. **CLIP 임베딩 RAG 통합(B단계)**.
2. **신규 옷 등록 시 서버사이드 임베딩 생성 경로**(Vertex AI vs Replicate
   미정, 신규 등록분은 계속 embedding null).
3. 배경제거 TFLite 교체 스파이크.
4. (선택) personal Firebase 프로젝트 App Check API 활성화 — 이번 세션
   실기기 검증 중 재확인(§2), 지금은 비강제라 급하지 않음.
5. (선택) iOS 실기기 테스트.
6. (선택, 급하지 않음) 무채색 보너스 게이팅(`TpoMatchPolicy.proposed`)은
   이 옷장에선 효과 0이라 보류 상태 유지.
7. (선택) `fallbackNote`(amber 배너) 자체의 실기기 육안 확인.
8. (신규) §3에서 폭(`candidatesPerCategory`)·색상(`usePairwiseColorScore`)
   축은 이 옷장 기준 효과 0으로 확인됐지만 기본값은 안 건드림 — 실측
   옷장이 바뀌거나(아이템 다양성 증가) 재평가가 필요하면 표8~표12로
   재확인.
9. (신규) `recencyPenalty` 상향(0.4→1.0/2.0)은 표14에서 커버리지가 더
   오르는 걸 확인했지만 실측 없이 올리지 않기로 함 — 사용자 체감(회전이
   부족하다는 피드백)이 쌓이면 재검토.

## 참고 파일 위치

- 중복 게이트 순수 함수: `lib/services/firestore_service.dart`
  (`selectDateRecommendation`)
- 조합 품질/다양성 정책: `lib/services/outfit_matcher.dart`
  (`TpoMatchPolicy`, `_buildCombosByEnumeration`, `resolveEnumerationWidth`)
- 최근 노출 이력 집계: `lib/services/agent_planner.dart`
  (`recentItemIdsFrom`, `_recencyWindow`, `_matchPolicy`)
- 실측 리포트(표1~15): `test/tpo_policy_report_test.dart`
- 관련 테스트: `test/recommendation_date_gate_test.dart`(신규),
  `test/agent_planner_recency_test.dart`(신규),
  `test/outfit_matcher_test.dart`
- 이전 세션 실기기 검증 이슈(§2026-07-27 부록)와 이번 App Check 관찰은
  둘 다 personal Firebase 프로젝트 설정 이슈로 별개 트랙.
