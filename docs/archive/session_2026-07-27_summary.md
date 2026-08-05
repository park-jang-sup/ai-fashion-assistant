# 작업 정리 (2026-07-27 — TPO 정책 실측 A/B, skeleton 슬롯/threshold 실측 픽스, optionalMissing, README 전면 개편)

`docs/archive/session_2026-07-26_summary.md`(선제 추천 배지/재계획 + 포멀 태그 +
임베딩 유사 옷 UI)를 이어받아 `main` 브랜치 위에서 작업. 외부 작업
지시서(`docs/task_formality_policy_ab.md`)로 시작했지만, 지시서의 4절
판단 기준 자체가 실측에서 빗나가 결과적으로 지시서가 예상 못 한 두 개의
진짜 원인을 찾아 고치는 세션이 됐다. 이번 세션은 전부 커밋 완료 상태 —
미완료 워킹트리 변경 없음, `personal/main`까지 push 완료.

## 1. TpoMatchPolicy 도입 + 실측 옷장 A/B 리포트 (커밋 `933f322`)

### 배경
`outfit_matcher.dart`의 `findForTpo`엔 두 개의 알려진 결함이 있었다 —
(A) 무채색 보너스가 격식 필터를 무력화(포멀 목표에서도 무채색이면
`_formalityFitScore=0`인 아이템이 +1로 구제됨), (B) `hasCore`가 상의·
하의만 검사해 아우터/신발만 격식 미달인 경우가 조용히 조합에서 빠짐.
수정 자체는 한 줄이지만 모든 추천의 후보 구성이 달라질 수 있어, 지시서는
"고치기 전에 실측 옷장으로 먼저 측정하라"고 못박았다.

### 구현
- `TpoMatchPolicy` 클래스 신규 — `gateNeutralBonus`/`requiredCategories`/
  `optionalCategories` 필드, 기본값(`current`)은 리팩터링 전과 완전히
  동일. `proposed`(게이팅 켠 버전)는 프리셋으로만 존재, 기본값 아님.
  `findForTpo`에 `policy` 파라미터 추가(기본 `current`) — 정책 없이
  호출하는 기존 호출부는 한 비트도 안 바뀜.
- `test/tpo_policy_report_test.dart`(신규) — `items.json` 없으면 skip,
  있으면 TPO 9종 × `{current, proposed}`로 표1(정책 비교)/표2
  (mismatchedCategories)/표3(무채색 구제 현황)/표4(역효과 감지) 출력 +
  `proposed`에서 조합 자체가 비는 태그가 있으면 실패시키는 단언 1개.

### 검증 — 리팩터링 무손상 확인
`outfit_matcher_test.dart`/`color_rule_verification_test.dart`가 **수정
없이** 통과하는 것 확인. 추가로, `git stash`를 `outfit_matcher.dart` 한
파일에만 걸어(`--` pathspec으로 범위 제한) 리팩터링 전 코드로 잠깐
되돌린 뒤 정책 없이 호출한 9개 태그 결과를 덤프 → 리팩터링 후 코드와
diff로 완전 동일함을 확인 → `stash pop` 후 `git status`가 stash 전과
동일한지까지 재확인. 임시로 만든 비교용 테스트 파일은 확인 후 삭제(커밋
없음).

### 리포트 결과 — "판단 불가"
9개 태그 전부 `current == proposed`(후보 동일, isFallback 둘 다 발화
안 함). 표3을 보면 포멀 3종에서 구제 수가 컸는데도(상의 20개 중 17개
구제) 결과가 안 바뀐 이유는, 이 옷장(103벌)이 카테고리마다 진짜로
격식 적합한 아이템을 3~4벌씩 이미 갖고 있어서 구제된 아이템이 애초에
`topTwo` 밖이었기 때문. **이 실측 옷장으로는 결함 A의 효과를 검증할 수
없었다** — 지시서 4절의 "목적 달성"/"과도" 신호 둘 다 안 나옴.

## 2. skeleton 슬롯 경쟁 발견 — 표5·표6·표7 (커밋 `344bfda`, `797ea05`)

### 배경 — §1의 "판단 불가"에서 파고든 후속 질문
"그러면 왜 실사용에서 isFallback이 한 번도 안 켜지나?"를 표5(필터 순도
— scored 중 무채색 보너스 뺀 순수 격식 적합 비율)로 추적하다가, 결함
A/B와는 다른 **세 번째 원인**을 발견: `_buildCombosFromRanked`의
`ordered.take(3)`이 상의·하의·아우터·신발 4개 카테고리 중 우선순위+점수
상위 3개만 스켈레톤에 넣고 나머지 1개는 조합에서 조용히 뺀다 — 매번
아우터·신발 중 하나가 탈락(표7: 아우터 6/9, 신발 3/9, 합이 정확히 9).

### 구현
- `TpoMatchPolicy.maxSkeletonCategories`(기본 3, 리팩터링 시점 기준
  현행과 동일) 필드 추가, `skeleton4`/`skeleton3` 프리셋. `_buildCombosFromRanked`
  시그니처에 파라미터로 추가해 하드코딩된 `take(3)`을 교체.
- `test/tpo_policy_report_test.dart`에 표5(9태그×4카테고리 전체 필터
  순도, "이때만 정책 확대할지 알려면 포멀만 봐선 안 됨"), 표6(current 3칸
  vs skeleton4 4칸 — 1번 후보 카테고리 구성/후보수/탈락 카테고리/점수차),
  표7(current 1번 후보에 아우터/신발 포함 횟수) 추가.
- **잡은 버그**: 표6 초안에서 동점(점수차 0.00) 케이스가 실제 결과와
  어긋남 — `_buildCombosFromRanked`는 리스트가 작아(≤4) 삽입정렬(안정
  정렬)이 적용돼 동점 시 "카테고리 최초 등장 순서"가 타이브레이커가
  되는데, 처음엔 고정된 `['상의','하의','아우터','신발']` 순서로
  시뮬레이션해서 여행/운동/일상에서 우열이 뒤집혔음. wardrobe 순회 중
  최초 등장 순서를 그대로 보존하도록 고쳐서 표7과 정확히 일치(6+3=9)
  하게 맞춤.

### 결정 — 표6/표7 근거로 기본값 3→4 격상
"필터 순도가 낮으니 게이팅하자"가 아니라 **"매번 하나가 조용히
탈락하니 슬롯을 늘리자"**가 실측이 가리킨 답이었다. `maxSkeletonCategories`
기본값을 4로 올림 — `flutter test` 전체(94개) 통과 확인 후 반영, 비교용
`skeleton3` 프리셋은 남겨둠.

## 3. `_lowScoreFloor` 60→`threshold`(70) 참조 + 새 옷 추천 안내 추가 (커밋 `57fb8e9`)

### 배경
사용자가 Firestore에서 최근 추천 4건의 `candidateScores`를 직접
조회(`[96]`, `[68,82]`, `[65,65,65]`, `[68,88]`) — 관측 최저값이 65인데
`AgentPlanner._lowScoreFloor`가 60으로 박혀 있어 **도달 불가능한
임계값**이었다. isFallback이 "점수 낮음" 경로로는 한 번도 안 켜진 두
번째 진짜 원인.

### 구현
- `_lowScoreFloor`를 리터럴 `60` 대신 `OutfitSelfEvaluator.threshold`
  (컴파일 타임 상수, 70)를 그대로 참조하도록 변경 — 두 상수가 다시는
  따로 놀 수 없게 값 자체를 공유. `outfit_self_evaluator.dart`의
  `threshold` 쪽에도 역참조 주석 추가(양쪽에서 관계가 보이게).
- `buildFallbackNote`의 `tpoTag`를 `String?`로 바꿔 null 케이스 추가 —
  null이면 `[태그]` 대괄호를 안 붙임. `generateRecommendationForNewItem`
  (새 옷 등록 경로, TPO 개념 없음)에서 `isFallback`/`fallbackNote`를 아예
  안 채우던 걸 채우도록 추가 — 이 경로는 점수가 낮아도 사용자에게 아무
  신호가 안 갔던 갭.
- 테스트 4케이스 추가(tpoTag=null 조합 3가지 + 기존 케이스는 무수정 통과).

## 4. 자기 평가 점수 분포 모니터 (커밋 `dfcfe34`)

Firestore `users/{uid}/recommendations`의 `candidateScores`를 읽기 전용
으로 조회해 점수 히스토그램(5점 단위)/후보 간 점수 차 분포/60~69 데드존
비율/`repairAttempted` 전후 변화율을 출력하는 Python 스크립트. 처음엔
`tools/diagnose_recommendation_scores.py`(일회성, 확인 후 삭제 예정)로
만들었으나, §3의 실제 버그를 찾는 데 결정적이었던 걸 확인하고 사용자
판단으로 **상시 도구로 격상** — `tools/score_distribution_report/`로
옮기고 README.md/requirements.txt를 붙여 커밋. `repairAttempted=true`
건의 전/후 점수 쌍이 `candidateScores` 배열 길이 3 이상일 때 인덱스로
특정 불가능하다는 한계를 README에 명시(길이==2인 명확한 케이스만 비교,
나머지는 모호 케이스로 별도 집계).

## 5. 홈 추천 카드에 죽은 출력 3개 연결 (커밋 `7955f16`)

`RecommendationEntry`의 `confidenceNote`(채택률 기반 자기 성능 인지)/
`weatherNote`(날씨 근거)/`repairNote`(진단-수리 표시) — 모델에만 있고
어디서도 렌더링하지 않던 죽은 출력 3개를 홈 화면에 연결.
`fallbackNote`(경고, amber 풀폭 배너)와 겹치지 않도록 새 배너를 쌓지
않고, 셋 중 하나라도 있으면 공용 회색 컨테이너 하나에 아이콘+텍스트
색상만 종류별로 다르게(weatherNote=teal, confidenceNote=blue,
repairNote=purple) 줄줄이 묶는 `_AgentNoteLine` 위젯으로 구현 — 여러
개가 동시에 있어도 배너가 쌓이는 느낌 없이 카드 세로 길이가 완만하게만
늘어남.

## 6. optionalMissing — 격식 미달 선택 카테고리 안내 (커밋 `2c97312`)

### 배경
§2에서 skeleton 슬롯을 4로 올려 아우터/신발이 조합에서 탈락하는 문제는
없앴지만, **탈락하지 않고 조합엔 들어가는데 격식은 안 맞는** 경우(표5의
순도 0 카테고리)는 여전히 사용자에게 안 보였다. 표5를 9태그×4카테고리
전체로 확장해 발화 범위부터 확인 — 순도 0인 (태그,카테고리) 쌍은
**포멀 3종 × 신발뿐(3/9개 태그)**, 필수 카테고리(상의·하의) 오염은
0건. 캐주얼/세미포멀 6개 태그는 전 카테고리 순도 1.00.

### 구현
- `outfit_matcher.dart`: `TpoMatchResult.optionalMissing`(기본
  `const []`) 추가. `findForTpo` 내부에 `isGenuineFit`(무채색 보너스
  제외 순수 격식 적합 여부)/`optionalMissingFrom` 로컬 헬퍼를 둬서
  hasCore 성공 분기(`scored` 기준)·fallback 분기(`relaxed` 기준) 양쪽에서
  계산 — isFallback과 무관하게 채워질 수 있다는 게 `mismatchedCategories`
  (isFallback=true에서만 채워짐)와의 핵심 차이.
- `recommendation_entry.dart`: `optionalNote`(String?) 추가 —
  `fallbackNote`와 동일 패턴, 마이그레이션 불필요.
- `agent_planner.dart`: `buildOptionalNote` 순수 함수를 `buildFallbackNote`
  와 완전히 별개로 신규 추가("조합 전체가 차선" vs "특정 선택 카테고리만
  격식 미달"은 성격이 다름). 예시 문구("결혼식에 어울리는 신발이 옷장에
  없어 가장 가까운 것으로 맞췄어요")가 받침 있는 명사 뒤 조사를 정확히
  요구해서, `_withSubjectParticle`(이/가 선택, `outfit_self_evaluator.dart`
  의 `_withObjectParticle`과 같은 방식) 헬퍼를 새로 추가.
- **김에 잡은 기존 버그**: `buildFallbackNote`가 `'$categories가'`를
  하드코딩하고 있어서, mismatchedCategories가 `['신발']`뿐인 경우
  "신발가"라는 틀린 문구가 나올 수 있었음(받침 있는 명사는 "이"가 맞음).
  방금 만든 `_withSubjectParticle`을 재사용해 같이 수정 — 기존 테스트
  7개는 `contains('상의·아우터')`처럼 조사 없는 부분 문자열만 확인하고
  있어서 전부 무수정 통과(아무도 조사 자체를 단언한 적이 없어서 이 버그가
  안 잡혔던 것).
- `_prepareRecommendationFor`에서 `optionalNote` 계산해 저장.
  `generateRecommendationForNewItem`(TPO 없음)은 지시대로 제외.
- `home_screen.dart`: `optionalNote`를 `Icons.info_outline`+amber로,
  fallbackNote 배너 다음·weatherNote 앞에 배치.
- 테스트: `buildOptionalNote` 4케이스(신발만/복수 카테고리/빈 리스트/
  tpoTag null) 추가.

### 결과
`flutter test` 101개 전체 통과(§1 최초 93개 → 세션 내내 누적). 실질
발화 대상은 **포멀 3종 태그의 신발 배지 하나** — 나머지 6개 태그·
아우터·필수 카테고리는 이 옷장 기준으로는 조용함.

## 7. README.md 전면 개편 (커밋 `f5a8573`)

`lib/` 전체·`pubspec.yaml`·`.gitignore`·`tools/`를 훑어 점검한 뒤 반영.

- 기존 README에 전혀 없던 기능 문서화: 착장 캘린더 + AI 코디 에이전트
  (선제 추천/자기평가 루프/진단-수리/실패 대응/날씨 반영/피드백 학습/
  주간 플랜), AI 비서 활동 내역, 스크랩, AI 옷장의 임베딩 기반 "비슷한
  옷" 추천.
- **발견한 결함**: 기존 스크린샷 표가 `assets/screenshots/*.png`를
  참조하는데 `assets/` 디렉토리가 완전히 빈 채로 커밋돼 있어(git
  히스토리에도 없음) 전부 깨진 링크였음 — 표를 걷어내고 화면 구성을
  텍스트로 정리.
- `lib/config/env.dart`가 `.gitignore` 대상이라 새로 클론하면 파일
  자체가 없다는 걸 확인 — 실제 키 값은 노출하지 않고 클래스/필드명
  템플릿만 추가. `flutter test` 실행법과 일부 테스트가 로컬 전용 실측
  데이터 없으면 자동 스킵된다는 점도 명시.
- 프로젝트 구조 섹션 신설(`lib/` 하위 폴더 역할, `tools/`는 앱 코드와
  무관한 오프라인 스크립트라는 점).

## (부록) 실기기 검증 완료 — optionalMissing/홈 카드 UI

세션 종료 시점엔 앱 빌드·설치까지만 되고 실제 UI 확인은 못 한 채였는데,
바로 이어서 실기기(SM S918N) 검증까지 마쳤다.

### 막혔던 것 — 오래된 추천 문서가 재계산을 가로막음
캘린더에 "모레=결혼식" 일정을 새로 등록해도 `runProactiveCheck`가 매번
"추천 이미 존재 — 스킵"만 찍었다. 원인 추적:
- `recommendationForDateSilently`는 **날짜로만** 중복을 체크하고
  `targetTpoTag`는 안 본다 — 그래서 같은 날짜에 예전 태그("출근")로 이미
  만들어진, 아직 `dismissed=false`인 추천이 남아 있으면 새 태그("결혼식")
  일정이 등록돼도 무조건 스킵된다.
- 사용자가 처음엔 "캘린더 전체 삭제"를 제안했지만, 그건 (a) 막고 있는
  컬렉션 자체가 아니고(`recommendations`가 문제, `outfit_calendar_entry`가
  아님) (b) `AgentStats` 채택률 학습 이력까지 되돌릴 수 없이 날리는
  과잉 조치라 판단해 실행하지 않고 대안을 제시 → 정밀하게 문제의 문서
  하나만 `dismissed=true`로 바꾸는 쪽으로 합의.
- 서비스 계정 키 확인 과정에서 실수로 옛 팀 프로젝트(`eb206`) 키를 먼저
  받았음을 확인하고 걸러냄 — 반드시 앱이 실제로 쓰는
  `ai-fashion-assistant-personal` 키인지 `firebase_options.dart`의
  `projectId`와 대조 확인.
- 읽기 전용 dry-run 스크립트로 `dismissed=false`인 전체 문서를 나열해
  실제 원인 문서(`targetDate`=7/29, `targetTpoTag`=출근, 오늘 이른 시간
  생성된 이전 테스트 잔재)를 특정 → 사용자 확인 후 그 문서 하나만
  `dismissed=true`로 갱신. 나머지 16건(과거 피드백 이력 등)은 손대지
  않음. 스크립트는 일회성으로 만들어 작업 후 즉시 삭제(커밋 없음).
- 부수 발견: 이 환경의 `google-cloud-firestore` 클라이언트 버전은
  `CollectionReference.doc()` 별칭이 없고 정식 메서드 `.document()`만
  지원 — Firestore 관련 일회성 스크립트를 다시 짤 땐 `.document()`를 쓸 것.

### 확인 결과 — 전부 예상대로 동작
- `optionalNote`: "결혼식에 어울리는 신발이 옷장에 없어 가장 가까운
  것으로 맞췄어요" — 표5가 예측한 그대로(포멀×신발) 실측 데이터에서
  재현됨. 로그에도 `[PLAN] TPO(포멀) 매칭 성공: 후보 3개 (격식 적합),
  선택 카테고리 순도 0=[신발]`로 그대로 찍힘.
- `weatherNote`: "더운 날씨 예보라 가볍게 준비했어요" — 오늘(26°C)이
  아니라 **대상 날짜(7/29)의 예보** 기준이라 다르게 나온 것, 정상 동작.
- 홈 카드에 `optionalNote`+`weatherNote`가 동시에 떠도 레이아웃이
  깨지지 않음(그룹 컨테이너 설계 의도대로).
- `confidenceNote`: 이번엔 안 떴는데, 결혼식 태그 과거 이력이 1건뿐이라
  `tagStat.total >= 2` 조건 미달 — 표본 부족 가드가 정상 작동한 것.
- 새 옷 등록(`generateRecommendationForNewItem`) 경로로 두 번 테스트:
  1번째 72점 통과, 2번째는 `candidateScores=[65,65,72]`(수리 시도 후에도
  후보1 미달, 후보2가 72점으로 최종 채택) — `repairAttempted=true`,
  `repairNote="하의 교체(색상 개선)"`가 뜨고 `fallbackNote`는 안 떴다.
  **여기서 세션 중 설명을 정정함** — `fallbackNote`와 `repairNote`는
  서로 다른 조건이다: `fallbackNote`는 **최종 채택 점수**가
  `_lowScoreFloor` 미만일 때만, `repairNote`는 **과정 중 수리를
  시도했는지**(최종 점수 무관)로 결정된다. 항상 같이 뜨는 게 아니다.
  홈 카드에서도 보라색 repairNote 줄만 뜨고 amber fallbackNote 배너는
  안 뜨는 것으로 실측 확인됨.
- `fallbackNote`(amber 배너) 자체는 이번 세션엔 육안 확인 못 함(최종
  채택 점수가 70 밑으로 나오는 케이스를 못 만남) — 다음에 필요하면 계속.

## 다음 세션 시작 시 할 일

이전 세션(§2026-07-26)에서 이월된 것 중 이번에도 미착수:
1. **CLIP 임베딩 RAG 통합(B단계)**.
2. **신규 옷 등록 시 서버사이드 임베딩 생성 경로**(Vertex AI vs Replicate
   미정, 신규 등록분은 계속 embedding null).
3. 배경제거 TFLite 교체 스파이크.
4. (선택) personal Firebase 프로젝트 App Check API 활성화.
5. (선택) iOS 실기기 테스트.

~~6. Android 실기기로 skeleton4/optionalMissing 배지 실제 확인~~ —
**완료**(위 부록 참고).

7. (선택, 급하지 않음) 무채색 보너스 게이팅(`TpoMatchPolicy.proposed`)은
   이번 실측상 이 옷장에선 효과가 0이라 우선순위 낮음 — 손대지 않고
   보류 상태 유지.
8. (선택) `fallbackNote`(amber 배너) 자체의 실기기 육안 확인 — 최종
   채택 점수가 70 밑으로 나오는 케이스 필요.

## 참고 파일 위치

- TpoMatchPolicy/optionalMissing: `lib/services/outfit_matcher.dart`
- 자기평가 임계값/차선 문구: `lib/services/agent_planner.dart`
  (`buildFallbackNote`, `buildOptionalNote`, `_withSubjectParticle`),
  `lib/services/outfit_self_evaluator.dart`(`threshold`)
- 모델: `lib/models/recommendation_entry.dart`(`optionalNote` 등)
- 홈 카드 UI: `lib/screens/home_screen.dart`(`_AgentNoteLine`)
- 실측 리포트(표1~7): `test/tpo_policy_report_test.dart`
- 관련 테스트: `test/outfit_matcher_test.dart`,
  `test/color_rule_verification_test.dart`,
  `test/agent_planner_fallback_note_test.dart`
- 점수 분포 모니터: `tools/score_distribution_report/`
- 작업 지시서 원본+후기: `docs/task_formality_policy_ab.md`
