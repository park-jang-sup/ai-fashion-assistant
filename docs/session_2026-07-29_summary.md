# 작업 정리 (2026-07-29 — 백그라운드 자율 실행 A·B·C단계 전체 구현 + 실기기 관문 검증)

`docs/task_background_agent_v2.md` 지시서를 따라 A→B→C 3단계를 순서대로
구현하고 각 단계 관문을 실기기(Galaxy S23 Ultra, Android 16)에서 검증했다.
전 단계 관문 통과, 전부 커밋 완료 상태.

커밋: `6d1a751`(디슈가링) → `cfecf98`(A단계) → `3398e74`(B단계) →
`dd27ddf`(날씨 카운터, B단계 배선 포함) → `7bcda08`(C단계) →
`d953a2f`(지시서+후기 문서).

## 0. 선행 조건 확인

GCP 콘솔 Gemini API 할당량/결제 알림 설정은 사용자가 사전 확인
(선불 충전 방식이라 자동 청구 위험 없음, 결제 알림 설정됨, 할당량 기본값
확인함). 이 확인을 받은 뒤에만 코드 작업 시작.

## 1. A단계 — 로컬 알림 인프라 (커밋 `6d1a751`, `cfecf98`)

### 구현
- `flutter_local_notifications: ^17.2.3` 추가 — SDK 제약과 충돌 없이
  정확히 17.2.3으로 해결(캐럿 없이 pin하면 22.2.0으로 올라가는 것만 확인,
  지시서 지정 버전 그대로 사용).
- `lib/services/notification_service.dart` 신설 — `init()`/
  `requestPermissionIfNeeded()`/`showRecommendationReady()`, 채널
  `agent_recommendation`(defaultImportance — high는 헤드업 배너로 방해됨).
- `main.dart`에 Android 전용 + try-catch로 감싸 초기화 호출(0.1절 "시작
  경로 격리" 패턴).
- `settings_screen.dart`에 "테스트 알림 보내기" 행 추가.

### 예상 못한 것 — 릴리스 빌드 전용 결함
`flutter_local_notifications`의 AAR이 **코어 라이브러리 디슈가링**을
요구해서 첫 릴리스 빌드가 `checkReleaseAarMetadata` 에러로 실패했다.
디버그에서는 안 드러나는 문제. `android/app/build.gradle.kts`에
`isCoreLibraryDesugaringEnabled = true` + `desugar_jdk_libs:2.1.4`
의존성 추가로 해결(별도 승인 없이 바로 적용 — pubspec 버전 조정이 아니라
Gradle 표준 설정이라 판단).

### 실기기 검증
릴리스 APK 설치 → 정상 실행 → 테스트 알림 정상 발송(`dumpsys
notification`으로 직접 확인) → 권한 거부 상태에서도 크래시 없이 알림만
안 뜸. 3개 관문 전부 통과.

## 2. B단계 — 빈 백그라운드 골격 (커밋 `3398e74`)

### 구현
- `workmanager` 의존성, `RECEIVE_BOOT_COMPLETED` 권한.
- `firestore.rules`에 `agent_meta` 서브컬렉션 규칙 추가 후 배포.
- `lib/services/background_agent.dart` 신설 — 진입점(`@pragma('vm:entry-point')`),
  아이솔레이트 재초기화, 인증 복원 대기(10초 타임아웃, null이면 종료,
  **signInAnonymously 절대 호출 안 함**), `shouldRunNow` 순수 함수(최소
  간격 10시간, force 우회, 미래 시각 폴백), `run()` 8단계(B단계는 6번
  자리 비워둠).
- `main.dart`에 킬 스위치(`kEnableBackgroundAgent =
  bool.fromEnvironment('BG_AGENT', defaultValue: true)`) + Android 전용
  + try-catch로 WorkManager 등록.
- `settings_screen.dart`에 즉시 실행/지연 실행(30초, 시연용) 버튼 +
  `agent_meta/background` 실시간 상태 표시(StreamBuilder).
- `test/background_agent_test.dart` 신규 — `shouldRunNow` 5케이스.

### 예상 못한 것 1 — Firestore 배포가 엉뚱한 프로젝트로 나감
`firebase deploy --only firestore:rules` 실행 시 이 디렉터리의 CLI 활성
프로젝트가 `.firebaserc`의 `default: ai-fashion-assistant-personal`이
아니라 **전역 캐시에 남아있던 `ai-fashion-assistant-eb206`**(앱과 무관한
프로젝트)로 잡혀 있었다. 첫 배포가 그쪽으로 나갔음(다행히 규칙 추가만이라
기존 내용 훼손 없음, 그 프로젝트는 미사용으로 확인). `firebase use
ai-fashion-assistant-personal`로 전환 후 재배포, CLI 활성 프로젝트도
바로잡음. **교훈**: 이 저장소처럼 여러 Firebase 프로젝트를 오간 이력이
있으면 배포 전에 `firebase use`로 활성 프로젝트를 반드시 재확인할 것.

### 예상 못한 것 2 — workmanager 0.5.2가 릴리스에서 컴파일 실패
지시서 지정 버전(`^0.5.2`)의 네이티브 Kotlin 코드가 Flutter v1 임베딩
호환 shim(`ShimPluginRegistry`, `PluginRegistrantCallback` 등)을
참조하는데, 현재 Flutter(3.41.6)에서 그 shim이 완전히 제거되어
`Unresolved reference` 컴파일 에러가 났다. `^0.9.0`(federated 플러그인
구조로 재작성됨, v1 임베딩 문제 없음)으로 올려 해결. API는 거의 동일 —
`registerPeriodicTask`의 `existingWorkPolicy` 타입만 `ExistingWorkPolicy`
→ `ExistingPeriodicWorkPolicy`로 변경. 사용자에게 명시적으로 보고 후 승인
받고 진행.

### 실기기 검증
릴리스 APK 설치 → 정상 실행. 즉시 실행 → `lastRunAt` 갱신(WorkManager
`Worker result SUCCESS` 로그로 확인). **지연 실행(30초) + 앱 완전
종료** → 새 프로세스(pid 변경 확인)로 백그라운드 워커가 뜨고 `lastRunAt`
갱신, 경고/오류 없음 — 헤드리스 아이솔레이트가 실제로 도는 것을 확인.
킬 스위치(`--dart-define=BG_AGENT=false`) 빌드 컴파일 확인. 관문 4번
(장시간 방치 후 주기 실행)은 시간 관계상 관찰 보류.

## 3. C단계 — 에이전트 연결 (커밋 `dd27ddf`, `7bcda08`)

### 구현
- `AgentPlanner.runProactiveCheck`: `Future<void>` → `Future<({int
  created, String? firstLabel})>`로 확장 + `maxPlans` 옵션 파라미터
  추가. **하위호환 보장**: `maxPlans`가 null이면 `take()` 자체가
  스킵되어 처리량 제한 없음, 기존 호출부(`main.dart:187`)는 반환값을
  안 쓰므로 문법/동작 둘 다 영향 없음. `_prepareRecommendationFor`도
  `void`→`bool`로 바꿨지만 각 조기 종료 지점의 반환문만 치환 — Firestore
  읽기/쓰기·Gemini 호출·로그 순서와 내용은 한 줄도 안 바뀜(git diff로
  검증). catch절은 항상 `(created: 0, firstLabel: null)`로 조용한 실패
  원칙 유지.
- `background_agent.dart`의 6번 자리를 채움: AgentSweeper.run → 3초
  대기 → `runProactiveCheck(uid, maxPlans: 2)` → `created > 0`이면
  `NotificationService.showRecommendationReady(firstLabel)`(초기화도
  이 아이솔레이트에서 새로 필요) → **로그 드레인 3초 대기**(unawaited로
  던져진 활동 로그 Firestore 쓰기가 아이솔레이트 종료로 잘려나가는 것을
  완화, 근본 해법 아님을 주석으로 명시) → `lastResultCreated`/`lastError`
  실제 값 기록.
- 이어서 진단 카운터 추가(사용자 요청): `WeatherService.lastFetchOk`
  정적 필드(아이솔레이트별 독립이라 오염 없음) → `agent_meta/background`에
  `lastWeatherOk`(bool, 마지막 상태) + `weatherOkCount`/
  `weatherTotalCount`(`FieldValue.increment`, 필드 없으면 0부터 시작)
  누적 카운터로 기록.

### 실기기 검증 — 예상 못한 것들 (전부 문서에 이미 알려진 한계로 흡수됨)
- **수동 트리거**: 활동 로그 서사·알림 문구(`내일 [결혼식] 일정에 맞는
  코디를 준비해뒀어요`) 정확히 일치. 통과.
- **앱 종료 상태**: 지연 실행 버튼 클릭 시각과 로그 타임스탬프를
  대조해 **정확히 30초 후** 새 프로세스에서 실행됨을 확인. 통과.
- **삼성 배터리 최적화가 실행 도중 프로세스를 정지시킨 사례 관찰**: 첫
  지연 실행 시도가 TPO 매칭 성공 직후 아무 로그 없이 끊겼고, 약 100초
  후 WorkManager 자동 재시도로 완전히 성공했다. 지시서의 "실행 시각의
  비보장" 절에서 이미 경고한 내용과 일치 — 코드 버그 아님, 배터리 설정을
  "제한 없음"으로 바꾸면 개선 가능.
- **동시 실행 경합 실제 관측**: 위 정지-재시도가 풀리는 과정에서 같은
  날짜(7/31)에 추천이 2건(75점, 82점) 동시 생성됨 — 지시서의 "알려진
  한계" 절에서 이미 락을 걸지 않기로 결정한 시나리오가 실제로 발생했고,
  중복 게이트가 자동 정리하는 것도 함께 확인(자가 치유 확인).
- **미완료 감지**: `adb shell am force-stop`으로 실행 도중 강제 종료 →
  설정 화면에 `⚠ 마지막 실행이 완료되지 않음` 경고 정상 표시. 통과.
  (첫 시도는 WorkManager 워커가 시작되기 전에 죽여서 실패 — 워커 시작
  로그(`Starting work for ...BackgroundWorker`)를 실시간으로 잡아서
  타이밍을 맞춰야 했음.)
- **날씨 API 콜드스타트 실패**: 앱이 막 재시작된 직후(프로세스 새로 뜬
  직후) 날씨 API가 DNS 조회 실패로 몇 차례 실패했다 — 기존 null 폴백
  경로가 정상 동작해 크래시 없이 넘어갔지만, 배경 실행 직후 네트워크
  스택이 완전히 준비 안 됐을 수 있다는 실측 관찰. 이번 세션에 추가한
  `weatherOkCount`/`weatherTotalCount`가 이 실패율을 앞으로 정량적으로
  추적할 수 있게 해준다.

### 테스트
`flutter analyze` 신규 이슈 0개(기존 무관 info 1건만 유지),
`flutter test` **137개 전체 통과**(B단계 132+5 유지, C단계에서 깨진
테스트 없음).

## 작업 방식 메모

- **릴리스 전용 결함이 이번 세션에서만 두 번 실측됨**(디슈가링,
  workmanager v1 shim) — 0.1절 "검증 관문은 반드시 릴리스 APK로"가 실제로
  작동한 사례. 디버그 빌드만 봤다면 둘 다 놓쳤을 것.
- **pubspec 버전을 지시서와 다르게 올릴 때는 먼저 보고 후 승인받고
  진행** — 이번 세션에서 workmanager(0.5.2→0.9.0)에 대해 실제로 이
  절차를 따름. 사용자가 API 차이(existingWorkPolicy 타입)까지 미리
  확인한 뒤 승인.
- **Firebase 인프라 배포(규칙 등)는 실행 전 항상 사용자 승인** — 이번
  세션에도 지켜짐. 다만 활성 프로젝트가 예상과 다를 수 있다는 걸 배포
  *전*에 확인하는 절차가 없었던 게 이번 실수의 원인 — 다음부터는 배포
  전에 `firebase use`로 현재 활성 프로젝트를 먼저 출력해서 보여줄 것.
- **실기기 로그 분석은 logcat 필터를 태그 단위로 정밀하게 좁혀야 함** —
  넓은 필터(`Notification`, `permission`, WorkManager 공용 태그)는 다른
  앱/시스템 서비스 노이즈가 압도적으로 많이 섞여 들어온다. `flutter:V
  AndroidRuntime:E *:S`(우리 앱의 debugPrint 태그만) + 필요시 특정 문자열
  grep(`fluttercommunity.workmanager`, `fashionai`)로 좁히는 게 효과적.

## 다음에 할 일

1. **관문 4번(장시간 방치 후 주기 실행) 미관찰** — 3시간 주기 등록은
   돼 있지만 실측 간격 기록은 아직 없음. 기본 배터리 설정과 "제한 없음"
   설정 양쪽에서 며칠간 `lastRunAt` 시각을 모아 중앙값/최대 지연을
   판단할 것(지시서 "알려진 한계 — 실행 시각의 비보장" 절 참고).
2. **테스트용 캘린더 일정(7/30, 7/31)과 그로 인해 생성된 추천 문서
   2~3건 정리 여부 미확정** — 사용자에게 삭제 의향을 물었으나 아직 답
   없음. 다음 세션 시작 시 확인.
3. `docs/task_background_agent_v2.md`에 후기 섹션을 추가해뒀음(커밋
   `d953a2f`) — 다음에 유사 작업(백그라운드/네이티브 플러그인 추가) 시
   먼저 참고할 것.
4. 이전 세션(§2026-07-28)에서 이월된 것들은 이번에도 미착수: CLIP 임베딩
   RAG 통합(B단계), 신규 옷 등록 서버사이드 임베딩 경로, 배경제거 TFLite
   교체 스파이크, personal Firebase App Check 활성화, iOS 실기기 테스트.

## 참고 파일 위치

- 백그라운드 진입점/파이프라인: `lib/services/background_agent.dart`
- 로컬 알림: `lib/services/notification_service.dart`
- 선제 추천(반환값 확장): `lib/services/agent_planner.dart`
  (`runProactiveCheck`, `_prepareRecommendationFor`)
- 날씨 성공률 계측: `lib/services/weather_service.dart`(`lastFetchOk`)
- 진단 필드 읽기/쓰기: `lib/services/firestore_service.dart`
  (`getBackgroundAgentMeta`, `setBackgroundAgentMeta`,
  `backgroundAgentMetaStream`)
- 설정 화면 진단 UI: `lib/screens/settings_screen.dart`
  ("백그라운드 에이전트(진단)" 섹션)
- 관련 테스트: `test/background_agent_test.dart`(신규)
- 작업 지시서(후기 포함): `docs/task_background_agent_v2.md`
