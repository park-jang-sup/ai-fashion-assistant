# 작업 정리 (2026-07-26 — 선제 추천 차선책 배지 + 예보 변화 자동 재계획)

`docs/session_2026-07-25_summary_2.md`(세션2, CLIP 임베딩 A단계 + 궁합 규칙
보강 + Firebase 개인 이관)를 이어받아 `main` 브랜치 위에서 작업. 이번 세션은
전부 커밋 완료 상태 — 미완료 워킹트리 변경 없음.

## 1. 선제 추천 차선책(fallback) 사유를 홈 화면 배지로 노출 (커밋 `e9602e9`)

### 배경
`OutfitMatcher.findForTpo`(레벨 4, 선제 추천)는 격식에 맞는 조합이 없으면
차선책으로 채우고 `isFallback=true`를 반환하는데, 지금까지 이 정보는
`agent_logs`(AI 비서 활동 내역 화면)에만 남고 홈 화면 추천 카드는 전혀
쓰지 않았다 — 왜 차선책인지 사용자가 알 방법이 없었다.

### 범위 결정
- `TpoMatchResult.shortfall`(조합 자체 불가) 케이스는 **의도적으로 제외**.
  `relaxed`가 점수 필터 없이(`topTwo((_) => true)`) 상의·하의가 완전히 없을
  때만 트리거되는데, 지금 옷장(103~112벌) 규모에서는 사실상 도달 불가능한
  안전망이라 판단. 실데이터(대회 제출용) 삭제/변형 없이 검증하기로 함.
- `isFallback=true`의 **두 가지 서로 다른 원인**만 구분해서 배지로 노출:
  1. `match.isFallback`(카테고리 자체가 격식에 안 맞음)
  2. `outcome.bestScore < _lowScoreFloor`(격식은 맞는데 궁합 점수가 낮음)

### 구현
- `outfit_matcher.dart`: `TpoMatchResult`에 `mismatchedCategories`(격식에
  안 맞아 `scored`에서 빠지고 `relaxed`에만 남은 카테고리) 필드 추가.
  `_outfitCategories`가 Set이라 순서 보장이 안 돼 별도 `categoryOrder`
  리스트로 고정(카테고리 추가 시 수동 동기화 필요, 주석 남김).
  - **제약 확인**: `hasCore`가 상의·하의만 보므로 이 분기 자체가 상의/하의
    중 하나 이상이 빠졌을 때만 진입 — 아우터·신발만 단독으로 부족한
    경우는 지금 구조상 감지 불가(조합에서 조용히 빠질 뿐). 별개의 기존
    갭이라 이번 범위 밖으로 남김.
- `recommendation_entry.dart`: `fallbackNote`(String?) 필드 추가
  (`repairNote`와 동일 패턴).
- `agent_planner.dart`: 순수 함수 `buildFallbackNote()` 신규 — 원인별로
  다른 문구 생성, `mismatchedCategories`가 비면(드문 경우) 억지 문구 대신
  `null` 반환해 배지 자체를 안 띄움. Firestore/Gemini 의존 없이 단위
  테스트 가능하도록 분리한 게 포인트.
- `home_screen.dart`: `_RecommendationCardBody`에 `entry.fallbackNote !=
  null`일 때만 이미지 아래·제목 위에 앰버(`AppColors.amberPale`/`amber`)
  배지 삽입. 빨강 계열은 안 씀(경고지 에러가 아니므로).
- 새 옷 등록 파이프라인(`generateRecommendationForNewItem`)은
  `findForTpo`를 안 써서 손대지 않음 — 배지는 선제 추천(레벨 1) 경로에서만
  나타남.

### 테스트 (필수로 추가, 실기기 재현 어려운 부분을 대신 커버)
- `test/outfit_matcher_test.dart`: `findForTpo — mismatchedCategories`
  그룹 2케이스 — (1) 상의·아우터가 격식 안 맞으면 fallback+`['상의',
  '아우터']`, (2) 전부 격식 적합이면 fallback 아님+빈 배열.
- `test/agent_planner_fallback_note_test.dart`(신규): `buildFallbackNote`
  4케이스 — 카테고리 차선(문구+점수 포함), mismatch 빈 배열(null), 궁합
  점수 낮음(다른 문구), 기준 이상(null). 전부 Firestore/Gemini 없이
  순수 함수 직접 호출로 검증.
- `flutter analyze` 클린, 전체 테스트(77개) 통과.

### 실기기 검증 (SM S918N)
- 캘린더에 "출근"(세미포멀) 일정 태그를 실제로 등록해 앱 재시작 →
  `[PLAN] TPO(세미포멀) 매칭 성공: 후보 3개 (격식 적합)` 로그 확인, 홈
  화면에도 배지 없이 정상 카드 노출 — **"배지가 없어야 할 때 없음"(정상
  경로) 확인**.
- 다만 지금 옷장(112벌)이 세미포멀을 충분히 커버하고 앱의 TPO 태그가
  캐주얼/세미포멀뿐(포멀 태그 UI 자체가 없음)이라, **"배지가 떠야 할 때
  뜸"(fallback 경로)은 실데이터를 안 건드리는 한 실기기에서 재현 불가로
  확인** — 계획 단계에서 예상했던 대로, 이 경로는 단위 테스트가 대신
  검증한 것으로 정리.
- 검증용으로 등록했던 7/27 "출근" 캘린더 항목은 확인 후 앱에서 직접 삭제,
  워킹트리/Firestore 잔여물 없음.

### 이번 세션에서 확인된 원칙
- 실기기 UI를 adb `input tap` 좌표로 조작할 땐 화면 스크린샷의 축소 비율
  눈대중 계산보다 `uiautomator dump`로 정확한 bounds를 뽑아 중심좌표를
  쓰는 게 훨씬 안정적(이번에 좌표 눈대중으로 여러 번 탭이 빗나감).
- 순수 로직(문구 분기 등)을 Firestore/Gemini 호출과 분리된 정적 함수로
  빼두면, 실기기 재현이 어려운 케이스도 단위 테스트로 온전히 커버할 수
  있다 — 이번 `buildFallbackNote` 분리가 그 예.

## 2. 예보 변화 감지 → 선제 추천 자동 재계획 (커밋 `51e80ce`)

### 배경
자기 평가 루프가 "점수가 낮으면 고친다"는 있었지만, "일정을 잡아둔 뒤
예보 자체가 바뀌면" 대응하는 장치가 없었다 — 맑을 줄 알고 준비한 코디가
비 예보로 바뀌어도 그대로 남아있었다. 이번 작업은 이 자기 수리 루프를
시간축으로 확장한 것.

### 핵심 설계 — 새 파이프라인을 만들지 않음
`runProactiveCheck`의 기존 중복방지 게이트(추천이 이미 있으면 스킵)를
그대로 두되, 게이트 앞에서 예보를 비교해 재계획이 필요하면 기존 추천을
`dismissRecommendation`으로 무효화해 게이트를 통과시키는 방식. 그 뒤로는
`_prepareRecommendationFor`가 평소처럼 다시 돌아 자기 평가 루프·평가
3회 캡·`fallbackNote` 배지까지 전부 그대로 재사용된다.

### 구현
- `firestore_service.dart`: `hasRecommendationForDateSilently`(bool 반환)를
  `recommendationForDateSilently`(엔트리 전체 반환)로 교체 — 재계획
  판단에 스냅샷/`replanCount`가 필요해서. `targetDate`+`dismissed` 둘 다
  equality 필터라(orderBy 없음) 새 복합 인덱스 불필요, 배포 승인 없이 진행.
- `recommendation_entry.dart`: `forecastPrecipProbability`/
  `forecastMaxTempC`(생성 시점 예보 스냅샷), `replanCount`(기본 0) 필드 추가.
- `agent_planner.dart`: 순수 함수 `shouldReplanForWeather()` 신규 —
  강수확률이 50%(`WeatherService.rainProbabilityThreshold`) 경계를
  넘나들거나 최고기온이 5도 이상 달라졌을 때만 `replan: true`. 그 미만
  변화는 예보의 정상적인 흔들림으로 보고 무시(매 앱 실행마다 Gemini
  재호출되는 것을 막는 핵심 장치). 스냅샷 없음/현재 예보 조회 실패는
  안전하게 `false`. `_prepareRecommendationFor`에 `replanCount`/
  `previousItemIds` 파라미터 추가, 재계획 시 새 예보로 스냅샷 갱신 +
  이전 조합에서 빠진 아이템을 활동 로그에 한 줄 남김.
- 비용 통제 3요소(전부 필수로 반영): **임계값**(50%/5도) · **날짜당 재계획
  상한 2회**(`_maxReplanPerDate`, 초과 시 로그만 남기고 중단) ·
  **스냅샷 갱신**(재계획 시 새 예보로 덮어써 같은 변화로 반복 재계획 방지).

### 검토 중 발견해 추가로 고친 것 (커밋 반영)
사용자 확인 요청으로 재점검하다 실제 빈틈을 하나 찾음:
- **채택률 집계 안전 확인**: `AgentStats.compute`가 쓰는
  `recommendationsSinceSilently`는 `createdAt` range만 걸고 `dismissed`는
  아예 안 봐서, 재계획으로 dismiss해도 채택률 수치는 안 깨짐(논문 5.4절
  채택률 지표 안전 확인됨).
- **진짜 빈틈**: 같은 날짜가 기록·확정되면 `isPlanned`가 꺼져 `planned`
  루프에서 원천 제외되지만, `detectFeedbackForCalendarEntry`가 착장을
  기록할 때 ±3일 범위에서 "가장 가까운" 추천 하나에 `userChoice`를
  붙이는 구조라 **아직 planned인 다른 날짜의 추천이 먼저 사용자 반응을
  가질 수 있음**을 확인. 이 경우 예보가 바뀌면 이미 사용자가 반응한
  추천을 조용히 dismiss해버릴 뻔했음 → `existing.userChoice != null`이면
  재계획 대상에서 아예 제외하는 가드 추가.

### 테스트 (필수)
- `test/agent_planner_weather_replan_test.dart`(신규): `shouldReplanForWeather`
  6케이스 — 강수확률 경계 통과(20→80, true)/미통과(20→40, false), 최고기온
  6도차(true)/2도차(false), 스냅샷 없음(false, 크래시 없음), 현재 예보
  조회 실패(false) 전부 순수 함수 직접 호출로 검증.
- `flutter analyze` 클린, 전체 테스트(79개) 통과.
- 실기기로 실제 예보 변화를 재현해 검증하지는 않음(예보가 실제로 바뀌길
  기다리거나 조작이 필요해 이번엔 단위 테스트로 대체) — 다음에 필요하면
  검증 방법을 더 찾아볼 것.

## 다음 세션 시작 시 할 일 (이전 세션에서 이월, 이번 세션엔 미착수)

1. **CLIP 임베딩 RAG 통합(B단계)** — `getRelevantHistorySilently`의
   태그+아이템겹침 관련도 점수를 임베딩 유사도로 보강/교체할지 설계.
2. **신규 옷 등록 시 서버사이드 임베딩 생성 경로** — Vertex AI multimodal
   embeddings vs Replicate 택일 미정. 백필된 옷만 embedding 있고 신규
   등록분은 계속 null.
3. 배경제거 TFLite 교체 스파이크 —
   `docs/tflite_background_removal_spike_notes.md` 참고해 세그멘테이션
   모델 조사부터 새로 시작.
4. (선택, 급하지 않음) personal Firebase 프로젝트 App Check API 활성화.
5. (선택) iOS 실기기 테스트 — Mac 환경 확보 시 바로 가능(설정은 이미 완료).

## 참고 파일 위치

- 이번 배지 기능: `lib/services/outfit_matcher.dart`(mismatchedCategories),
  `lib/services/agent_planner.dart`(buildFallbackNote),
  `lib/models/recommendation_entry.dart`(fallbackNote),
  `lib/screens/home_screen.dart`(_RecommendationCardBody 배지 UI)
- 예보 재계획: `lib/services/agent_planner.dart`(shouldReplanForWeather,
  runProactiveCheck), `lib/services/firestore_service.dart`
  (recommendationForDateSilently), `lib/models/recommendation_entry.dart`
  (forecastPrecipProbability/forecastMaxTempC/replanCount)
- 관련 테스트: `test/outfit_matcher_test.dart`,
  `test/agent_planner_fallback_note_test.dart`,
  `test/agent_planner_weather_replan_test.dart`
- 유사 옷 검색/궁합 규칙(이전 세션): `lib/services/embedding_service.dart`,
  `lib/services/color_taxonomy.dart`
- Firebase 이관 도구: `tools/migrate_to_personal/`
