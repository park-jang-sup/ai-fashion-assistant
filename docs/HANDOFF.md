# DOT 프로젝트 인수인계 — 2026-07-30

새 대화에서 작업을 이어받기 위한 문서. **먼저 이 문서를 읽고, 그다음 저장소를 클론해
대조할 것.** 이 문서의 내용과 저장소가 어긋나면 저장소가 옳다.

---

## 0. 3분 요약

- **무엇** — Flutter + Firebase + Gemini 기반 개인 스타일링 에이전트. 관찰·기억·추론·행동·학습 5단계 루프.
- **저장소** — `https://github.com/park-jang-sup/ai-fashion-assistant`
- **Firebase 프로젝트** — `ai-fashion-assistant-personal` (팀 프로젝트 `eb206`은 사용하지 않음)
- **논문** — `DOT_paper_rev4.md` / `.pdf`. 개정 4판, 33쪽. 개발 기록이자 방법론 보고서.
- **목표** — 논문은 부산물. **앱 자체의 결함 보완과 고도화가 주 목적.**
- **마감** — 대회 제출 **8/28 18:00**(자정 아님). 발표 8/25 전후.
- **테스트** — `flutter test` 137개 전량 통과 기준.

### 지금 상태 한 줄

백그라운드 자율 실행(A·B·C·관문4)과 다중 사용자 격리·계정 승격(D·E)까지 완료·검증됨.
**남은 작업은 F′(심사위원 실행 경로 확보) 하나.**

---

## 1. 대화 상대에 대한 요청

이 프로젝트는 지금까지 다음 방식으로 진행되었다. 이어받는다면 같은 방식을 유지해 주기 바란다.

- **측정 없이 고치지 않는다.** 결함을 발견하면 먼저 그 수정의 효과를 측정할 장치를 만든다. 논문 6.5.1절이 이 원칙을 일곱 규칙으로 정식화했다.
- **판정 기준을 결과 보기 전에 정한다.** 리포트를 실행하기 전에 "이 값이 X 이상이면 채택"을 문서로 고정한다.
- **논문에 인용한 심볼은 저장소에 대조한다.** 개정 3판 초고에서 미구현 코드를 구현했다고 쓴 오류가 있었다. `grep -rn "심볼\b" lib/ test/` (단어 경계 필수 — `shouldReplan`은 `shouldReplanForWeather`에 부분 일치한다).
- **검증 관문은 릴리스 APK로만 통과시킨다.** 이 저장소는 릴리스 전용 결함을 세 번 겪었다.
- **작업은 Claude Code에 지시서(md)로 넘긴다.** `docs/task_*.md` 형식. 금지 사항 절을 반드시 포함한다.
- **수치를 옮길 때 무엇을 세는지 함께 기록한다.** `test()` 선언 수(107)와 `flutter test` 실행 수(137)를 혼동한 적이 있다.

---

## 2. 완료된 작업 (시간순)

### 2-1. 조합 품질 트랙 (개정 3판)

측정 6회, 적용 4건. 전부 `TpoMatchPolicy` 정책 주입 방식의 A/B로 판단했다.

| 항목 | 결과 |
|---|---|
| 무채색 보너스 게이팅 | **보류** — 이 옷장에서 효과 0/9. 인과 진단이 틀렸음이 드러남 |
| 뼈대 슬롯 3→4 | **적용** — 신발 포함률 3/9 → 9/9 |
| 차선 임계값 60→70 | **적용** — 실측 최저 65라 60은 도달 불가였음 |
| `optionalMissing` | **적용** — 포멀 3종 × 신발 부재 안내 |
| 폭·색상(qualityV2) | **보류** — 무채색 독점 때문에 변별력 없음. 게이팅이 전제조건 |
| 최근 노출 감점 0.4 | **적용** — 커버리지 12.6% → 33.3%, 격식 지표 불변 |

리포트는 `test/tpo_policy_report_test.dart`가 표1~15를 출력한다.
`tools/export_for_kaggle/output/items.json`이 로컬에 있을 때만 실행됨(gitignore 대상).

### 2-2. 캘린더 중복 게이트 수정

새 옷 등록 추천이 같은 날짜 일정 추천을 영구 차단하던 문제.
`triggerItemId`가 빈 문자열인 문서만 게이트 대상으로 하고, 문서 선택을 결정론화했다.
`selectDateRecommendation`이 순수 함수로 분리되어 있다.

### 2-3. 백그라운드 자율 실행 (개정 4판)

A·B·C 3단계로 분할 착수. 관문 전부 통과.

- **A** — `flutter_local_notifications ^17.2.3`. 코어 라이브러리 디슈가링 필요(릴리스 빌드 실패 → `build.gradle.kts` 수정)
- **B** — `workmanager` **0.5.2는 안 됨**(Flutter v1 임베딩 shim 제거) → `^0.9.0`, `ExistingPeriodicWorkPolicy`
- **C** — `runProactiveCheck` 반환값 확장, 처리 건수 상한, 로그 드레인 3초, 알림 발송
- **관문 4** — 앱 미실행 상태에서 OS가 프로세스 생성(`Start proc ... for service`) → 발화 확인.
  이후 빈도 가드 간격 경과 시점에 **파이프라인 완주 + 잠금화면 알림** 실측

안전장치: 킬 스위치 `BG_AGENT`, 시작 경로 try-catch 격리, 빈도 가드,
백그라운드에서 `signInAnonymously()` 절대 금지.

### 2-4. 다중 사용자 격리 (D단계)

- 복합 인덱스 `ownerUid` + `createdAt` 배포
- 백필 118건, 자체 검증 "누락 0건" 통과
- `wardrobeStream(uid)` 필터, `addWardrobeItem`의 `ownerUid` **required**
- 접근 규칙을 소유자 단위로 조임
- `fitting_cache`의 `allow read` → `allow get, write` + `allow list: if false`

### 2-5. 계정 승격 (E단계)

- `google_sign_in ^6.2.1` → 6.3.0
- **SHA-1은 디버그 키의 것**(릴리스 빌드가 디버그 키로 서명됨) — `73:52:08:C4:7D:06:76:F6:EC:E8:77:38:CD:2D:F4:51:44:01:06:DA`
- 설정 화면 `linkWithCredential`(식별자 보존) / 로그인 화면 `signInWithCredential`
- `credential-already-in-use` → 확인 다이얼로그 후 전환. 자동 전환 경로 없음
- 관문 1(식별자 보존 연동)·2(삭제 후 재설치 복구) 통과. **관문 3 미검증**

---

## 3. 남은 작업 — F′단계

지시서: `docs/task_demo_ready.md` (있으면 그것을, 없으면 아래로 재구성)

### 배경 — 참가자 모집이 불가능해졌고, D단계가 신규 진입을 막았다

원래 F는 "실사용자 배포 후 데이터 수집"이었으나 참가자를 구할 수 없게 되었다.
APK를 실행할 사람은 **심사위원**이다.

그런데 D단계 격리 이후 새 계정으로 로그인하면 옷장이 0건이라 빈 화면이 된다.
격리 이전에는 전역 옷장이라 누구나 118벌을 봤다. **개선이 진입을 막은 것**이다.
논문 5.11.6절에 기록되어 있다.

### F′.1 — 샘플 옷장 시드

- 후크: `wardrobe_screen.dart`의 `_buildEmptyState()` — `items.isEmpty`일 때만 렌더링되므로 시드 후 버튼이 자연히 사라진다
- **전체 118벌을 시드한다.** 큐레이션 12~16벌이 아니다 — 논문의 실측 수치(표5·9·13·14)가 이 118벌 위에서 산출되었으므로, 일부만 넣으면 앱에서 보이는 결과와 논문 수치가 어긋난다
- **이미지는 복제하지 않는다.** `storage.rules`가 `request.auth != null` read이므로 기존 `imageUrl`·`cutoutImageUrl`을 그대로 재사용한다. Firestore 문서만 만든다
- **`createdAt`은 원본 값을 그대로 복사한다.** 옷장 순회 순서가 동점 처리를 결정하므로(5.8.5, 5.10), 임의 시각을 주면 같은 118벌인데도 논문과 다른 추천이 나온다
- **`ownerUid`는 내보내지 않는다.** 시드 함수가 현재 로그인 사용자의 uid로 채워야 한다
- 각 문서에 `isSample: true` — 지표 집계 제외, 나중에 골라 삭제 가능
- `WriteBatch` 상한 500이라 118은 한 배치. 임베딩 포함 시 문서당 약 6KB, 총 700KB 안팎
- 임베딩은 **포함한다** — "비슷한 옷" 섹션이 살아야 3.7절이 시연된다

### F′.2 — 신규 계정 완주 검증 (이 단계가 F′의 핵심)

**반드시 새 구글 계정으로.** 본인 계정으로 확인하면 의미가 없다.

시드 **전에** 0벌 상태를 먼저 본다. 논문 5.8.1에 "현 데이터에서 도달 불가"로 기록한
shortfall 분기가 신규 계정에서 처음 실행될 수 있다.

- 0벌 상태에서 5개 탭 크래시 없음
- 시드 후 118벌 표시, `isSample: true` 확인
- 신규 계정에서 **추천 카드 생성** ← 격리·시드·추천 파이프라인이 끝까지 이어졌다는 뜻
- 신규 계정에서 **잠금화면 알림**
- 본인 계정 옷장 118벌이 **그대로** (시드가 본인 데이터를 오염시키지 않았는지)

### F′.3 — 지표 집계

`tools/user_study_report/`. `isSample: true`는 전부 제외.
옷장 규모·구성, 속성 추출률, 임베딩 보유율, 옷장 커버리지, 추천 채택률,
백그라운드 발화 간격.

---

## 4. 반드시 알아야 할 함정

### 4-1. 앱을 삭제하고 재설치하지 말 것

`adb install -r`만 쓴다. 삭제 후 재설치하면 익명 식별자가 새로 발급되고
WorkManager 예약이 초기화된다. **하루에 식별자가 넷으로 분화되어 옷장 소유권이
끊긴 사고가 실제로 있었다**(논문 5.11.4). Android Studio Run 버튼과
`flutter run`도 기존 앱을 지울 수 있다.

계정 승격 이후에는 같은 구글 계정으로 로그인하면 복구되지만, 그래도 피하는 게 좋다.

### 4-2. Firebase 명령에 `--project` 명시

`.firebaserc`가 개인 프로젝트를 가리켜도 **명령줄 도구의 전역 캐시가 그보다 우선**한다.
이 때문에 접근 규칙이 무관한 이전 프로젝트에 배포된 사고가 있었다(5.11.3).

```bash
firebase deploy --only firestore:rules --project ai-fashion-assistant-personal
```

### 4-3. 배포 순서를 바꾸지 말 것

```
1. 복합 인덱스 배포 → 콘솔 활성화 확인까지 대기
2. 백필 dry-run → 검토 → 적용
3. 앱 릴리스     ← 규칙은 아직 이전 것
4. 규칙 배포
```

백필이 규칙보다 먼저(규칙 먼저면 백필 불가), 앱이 규칙보다 먼저(반대면 구버전이
권한 오류로 죽음). **문서에 적어뒀는데도 실행 단계에서 역전된 사고가 있었다**(5.11.2).

### 4-4. 릴리스 APK로 검증

디버그 빌드가 통과하는 것과 릴리스가 빌드되는 것은 별개다.
이 저장소에서 세 번 겪었다 — ONNX 배경 제거 크래시(5.7), 디슈가링,
workmanager v1 shim(5.11.1).

### 4-5. `debugPrint`는 릴리스에서 안 찍힌다

백그라운드 검증 시 Flutter 로그를 기대하면 안 된다. `WM-` 태그(WorkManager
네이티브)나 `dumpsys jobscheduler`를 봐야 한다.

### 4-6. PowerShell 파이프 버퍼링

`adb logcat | findstr`가 실시간으로 안 흐른다. `adb logcat -d > all.txt`로
덤프 후 파일에서 찾을 것.

### 4-7. 서비스 계정 키

`C:\Users\hse09\key\ai-fashion-assistant-personal-firebase-adminsdk-fbsvc-47679dd51a.json`
저장소 밖에 있고, 스크립트는 저장소 안 경로를 거부한다. `--credentials` 인자로 넘긴다.
`pip`가 정책에 막히면 `python -m pip`.

### 4-8. 테스트 수 137의 근거

`test()` 선언은 107개다. 차이는 세 요인 — 색상 정규화 검증이 28개 항목을 순회하며
테스트를 생성(선언 1 → 실행 28), 실측 데이터 부재 시에만 생성되는 대체 선언 2개가
데이터가 있으면 실행되지 않는다. `107 - 1 - 2 + 28 = 137`.

---

## 5. 알려진 결함 (의도적으로 남긴 것)

| 항목 | 상태 | 근거 |
|---|---|---|
| 무채색 보너스가 격식 필터 오염 | 보류 | 이 옷장에서 효과 0. 게이팅 시 신발 소멸(5.8.3) |
| `hasCore`가 상의·하의만 검사 | 보류 | 필수 카테고리 판정 변경은 영향이 큼(5.8.4) |
| 색상 엔진이 주력 경로에서 무변별 | 보류 | 무채색 게이팅이 전제조건(5.8.8) |
| 재계획 전제가 날씨만 | 미구현 | 설계는 정리됨. `shouldReplan`은 저장소에 없다(3.4.4) |
| 자격증명 중복 다이얼로그 | 미검증 | 재현 비용이 이득보다 큼(3.10) |
| 진단 문서 오류 필드 | 도달 불가 | 호출 함수들이 예외를 삼킨다(5.11.7) |
| API 키 클라이언트 내장 | 유지 | 서버 프록시가 근본 해법. 할당량 상한으로 완화 |
| 예보 좌표 고정 | 유지 | 설정 화면 지역 선택으로 해소 가능 |
| 위젯·통합 테스트 없음 | 유지 | 137종이 전부 순수 함수 |
| iOS 백그라운드 | 미지원 | OS 재량이라 보장 불가 |

---

## 6. 논문 상태

`DOT_paper_rev4.md` — 1,526줄, PDF 33쪽.

### 층위 구조 (5장)

| 절 | 층위 | 질문 |
|---|---|---|
| 5.8 | 설계 | 구현한 코드가 실행되는가 |
| 5.9 | 데이터 무결성 | 기제들이 서로를 훼손하지 않는가 |
| 5.10 | 목적 정합성 | 실행된 것이 목적에 부합하는가 |
| 5.11 | 운영 | 검증한 것이 실제 배포 형태에서도 성립하는가 |

### 다음 개정 시 갱신할 것

- **6.1 표** — F′ 완료 후 수치
- **7.1** — F′로 해소되는 항목(신규 계정 진입) 이동
- **부록 C** — 개정 4판 커밋 해시를 실제 값으로 채울 것(현재 단계명만)
- **부록 D 제목** — "(개정 3판)"으로 되어 있음. 표가 늘면 갱신
- **백그라운드 발화 간격** — 진단 계측이 표본을 모으는 중. 며칠 뒤 `agent_meta`에서
  `lastInvokedAt` 시계열을 뽑아 "등록 3시간 / 실측 중앙값 N / 최대 지연 M" 표를
  만들면 7.2-1의 서버 이전 판단 근거가 된다. **배터리 설정은 기본으로 두고 측정할 것** —
  그게 실사용자 환경의 진짜 신뢰성이다

### 논문에 없는 것 (쓰지 말 것)

- `shouldReplan` / `premiseReplaced` — 설계만 했고 저장소에 없다
- 참가자 모집·동의 절차 — 대상이 없다
- App Distribution 배포 — 심사위원에게 파일로 전달한다

---

## 7. 저장소 지도

```
lib/
  main.dart                     앱 진입, WorkManager 등록, 킬 스위치
  services/
    agent_planner.dart          선제 추천·주간 플랜·피드백 감지 (가장 큼)
    background_agent.dart       백그라운드 콜백, 빈도 가드
    outfit_matcher.dart         로컬 후보 생성, TpoMatchPolicy
    outfit_self_evaluator.dart  자기 평가·진단-수리
    firestore_service.dart      DB 접근, selectDateRecommendation
    notification_service.dart   로컬 알림
    google_auth_service.dart    자격증명 생성
    gemini_service.dart         LLM 호출, 프롬프트
    embedding_service.dart      코사인 유사도
    color_taxonomy.dart         색상 3축 정규화
  screens/                      5탭 + agent_log_screen
test/                           13개 파일, 137종
tools/
  backfill_owner_uid/           D단계 백필
  score_distribution_report/    평가 점수 분포
  export_for_kaggle/            옷장 내보내기 (output/은 gitignore)
  migrate_to_personal/          프로젝트 이관 (완료)
docs/
  task_*.md                     작업 지시서들
  session_*_summary.md          세션 기록
firestore.rules / firestore.indexes.json / storage.rules
```

---

## 8. 이어받은 직후 할 일

```bash
git clone https://github.com/park-jang-sup/ai-fashion-assistant
cd ai-fashion-assistant
flutter test          # 137개 통과 확인
flutter analyze       # 기존 info 1건 외 클린
git log --oneline -20
ls docs/
```

그다음 **F′.1 착수 전에** 한 가지를 먼저 확인할 것 —
`agent_meta/background`에 `lastInvokedAt`·`invokeCount`·`skipCount`가
쌓이고 있는지. 안 쌓이면 진단 패치가 설치된 APK에 반영되지 않은 것이고,
7.2-1의 판단 근거가 될 데이터가 모이지 않는다.
