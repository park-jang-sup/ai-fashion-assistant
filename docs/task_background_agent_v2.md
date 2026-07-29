# 작업 지시서 — 백그라운드 자율 실행과 로컬 알림 (v2)

대상 저장소: `park-jang-sup/ai-fashion-assistant`
목표: 앱을 열지 않아도 에이전트 루프가 개시되고, 새 추천이 준비되면 알림이 뜬다.

**이 지시서는 3단계로 나뉘며, 각 단계는 독립적으로 검증되고 되돌릴 수 있다.
앞 단계의 검증 관문을 통과하기 전에는 다음 단계를 시작하지 말 것.**

---

## 0. 선행 조건 — 코드 작업 전에

**GCP 콘솔에서 Gemini API 일일 할당량 상한과 결제 알림을 설정할 것.**
백그라운드 실행은 호출 빈도를 늘린다. 키가 유출됐을 때의 손실 규모를 상수로
묶어두는 것이 먼저다. 10분이면 되고 비용은 0이다.

이것이 끝나기 전에는 아래 작업을 시작하지 말 것.

---

## 0.1 전 단계 공통 규칙

### 킬 스위치

B단계에서 도입하는 모든 백그라운드 코드는 컴파일 타임 플래그 하나로 완전히
꺼져야 한다. 이 저장소는 `USE_EMULATOR`, `RUN_SIMILARITY_CHECK`로 이미 같은
패턴을 쓰고 있으므로 그대로 따른다.

```dart
// lib/main.dart 상단 부근
const kEnableBackgroundAgent =
    bool.fromEnvironment('BG_AGENT', defaultValue: true);
```

`--dart-define=BG_AGENT=false`로 빌드하면 등록 코드가 통째로 건너뛰어져
현재와 완전히 동일하게 동작해야 한다. 시연 촬영 직전에 이상이 발견되면
이 빌드로 되돌린다.

### 시작 경로 격리

`main()`에 들어가는 모든 신규 초기화 코드는 예외를 밖으로 던지지 않는다.

```dart
if (kEnableBackgroundAgent && defaultTargetPlatform == TargetPlatform.android) {
  try {
    await BackgroundAgent.register();
  } catch (e) {
    debugPrint('[BG] 등록 실패(무시하고 앱 계속): $e');
  }
}
```

**이 저장소는 릴리스 빌드에서만 터지는 네이티브 결함을 이미 한 번 겪었다.**
(디버그 100% 정상 / 릴리스 100% 크래시) 네이티브 플러그인을 앱 시작 경로에
넣는 것은 같은 계열의 위험이며, **백그라운드가 안 되는 것과 앱이 안 뜨는 것은
전혀 다른 문제**다. 후자는 절대 발생해서는 안 된다.

### 검증 관문은 반드시 릴리스 APK로

각 단계 끝의 검증은 `flutter build apk --release` 산출물을 실기기에 설치해서
수행한다. 디버그 빌드 통과는 관문 통과가 아니다.

---

# A단계 — 로컬 알림만 (반나절)

백그라운드 없음. 알림 인프라만 깐다. **이 단계는 위험이 0이며, 여기서 멈춰도
남는 것이 있다.**

## A.1 의존성

```yaml
dependencies:
  flutter_local_notifications: ^17.2.3
```

버전은 현재 Flutter/Dart SDK 제약에 맞춰 조정할 것. 충돌하면 임의로 고치지
말고 **어떤 제약이 걸리는지 먼저 보고**할 것.

`android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
```

## A.2 `lib/services/notification_service.dart` 신설

```dart
static Future<void> init();                                  // 플러그인 초기화
static Future<bool> requestPermissionIfNeeded();             // Android 13+ 런타임 권한
static Future<void> showRecommendationReady(String label);   // 발송
```

- 채널 id `agent_recommendation`, 이름 "코디 추천", 중요도 **`defaultImportance`**.
  `high`로 두면 헤드업 배너로 떠서 방해가 된다.
- `showRecommendationReady`의 문구
  - 제목: `코디 준비됐어요`
  - 본문: `$label 일정에 맞는 코디를 준비해뒀어요` (label 예: `내일 [결혼식]`)

## A.3 권한 요청 흐름

Android 13(API 33) 이상은 `POST_NOTIFICATIONS`가 런타임 권한이다.
**앱 첫 실행 시** 요청한다(`main.dart` 또는 홈 화면 진입 시점).
백그라운드 콜백에서는 UI가 없어 권한을 요청할 수 없다.

권한이 거부되면 알림만 발송되지 않고 나머지는 정상 동작한다. **이때 오류를
던지거나 경고 로그를 남기지 말 것** — 사용자의 선택이다.

## A.4 설정 화면에 테스트 버튼

`lib/screens/settings_screen.dart`에 "테스트 알림 보내기" 항목을 추가한다.
누르면 `showRecommendationReady('내일 [결혼식]')`을 호출한다.

## ✅ A단계 관문

1. `flutter build apk --release` → 실기기 설치 → **앱이 정상 실행된다**
2. 설정에서 테스트 버튼 → 알림이 뜬다
3. 권한을 거부한 상태에서도 앱이 정상 동작하고 크래시하지 않는다

세 개 다 통과해야 B단계로 간다.

---

# B단계 — 빈 백그라운드 (반나절)

**이 단계가 진짜 관문이다.** 에이전트 로직은 붙이지 않는다. 콜백이
타임스탬프만 찍는다. 여기서 안 돌면 그건 기기·OS 문제지 코드 문제가 아니고,
그때 멈춰도 잃는 것이 거의 없다(A단계 알림은 남는다).

## B.1 의존성

```yaml
dependencies:
  workmanager: ^0.5.2
```

`AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
```

## B.2 Firestore 규칙 먼저 추가

**이 저장소의 `firestore.rules`는 상위 match가 서브컬렉션을 커버하지 않아
서브컬렉션마다 별도 블록을 둔다.** `agent_meta`는 신규 서브컬렉션이므로
규칙을 추가하지 않으면 쓰기가 거부되고, 백그라운드는 조용히 실패한다.

```
// 백그라운드 실행 메타(마지막 실행 시각·결과) — 본인 것만.
match /users/{uid}/agent_meta/{docId} {
  allow read, write: if request.auth != null && request.auth.uid == uid;
}
```

규칙을 배포한 뒤 코드 작업을 시작할 것.

## B.3 `lib/services/background_agent.dart` 신설

### 진입점

```dart
@pragma('vm:entry-point')
void backgroundCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    return await BackgroundAgent.run(force: inputData?['force'] == true);
  });
}
```

`@pragma('vm:entry-point')`가 없으면 릴리스 빌드에서 트리 셰이킹으로 제거된다.
**디버그에서는 정상, 릴리스에서만 안 도는 형태로 나타난다.**

### 아이솔레이트 초기화

백그라운드 콜백은 **별도 아이솔레이트**에서 실행되므로 `main()`의 초기화가
하나도 적용되어 있지 않다. 콜백 안에서 다시 해야 한다.

```dart
WidgetsFlutterBinding.ensureInitialized();
await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
```

App Check는 현재 강제(enforce)되지 않으므로 초기화하지 않는다. **나중에 강제로
전환하면 여기서도 `activate`가 필요해진다**는 점을 주석으로 남길 것.

### 인증 복원 — 가장 실수하기 쉬운 지점

`Firebase.initializeApp()` **직후에 `FirebaseAuth.instance.currentUser`를 읽으면
거의 확실히 null이다.** 인증 상태의 디스크 복원이 비동기라 아직 끝나지 않았을
뿐이며, 로그인이 안 되어 있다는 뜻이 아니다. 다음처럼 기다린다.

```dart
// authStateChanges()는 복원이 끝나면 첫 값을 흘린다. 무한 대기를 막기 위해
// 타임아웃을 두고, 타임아웃 시에는 아무것도 하지 않는다.
final user = await FirebaseAuth.instance
    .authStateChanges()
    .firstWhere((u) => u != null)
    .timeout(const Duration(seconds: 10), onTimeout: () => null);
if (user == null) return true;   // 재시도해도 달라지지 않음
```

**절대 금지: 백그라운드에서 `signInAnonymously()`를 호출하지 말 것.**
현재 이 호출은 `login_screen.dart`(사용자가 버튼을 누르는 경로)에만 있다.
백그라운드에서 부르면 **새 익명 uid가 생성되어 유령 계정 아래에 추천이 쌓이고,
사용자는 그것을 영영 볼 수 없다.** `users/{uid}` 격리 구조라 화면상 아무 증상이
없어 발견도 어렵다. null이면 그냥 아무것도 하지 않고 종료한다.

### 실행 빈도 가드

주기는 3시간으로 등록하되 콜백 첫 줄에서 최소 간격을 검사한다. 긴 주기(24h)로
등록하면 OS가 실행을 크게 미루는 경향이 있어, **짧은 주기 + 가드** 조합이
실제 발화 신뢰성이 높다.

```dart
static const _minInterval = Duration(hours: 10);
```

마지막 실행 시각은 `SharedPreferences`가 아니라 **Firestore**에 기록한다.
`users/{uid}/agent_meta/background` 문서:

| 필드 | 타입 | 의미 |
|---|---|---|
| `startedAt` | Timestamp | 이번 실행 **시작** 시각 |
| `lastRunAt` | Timestamp | 마지막 **완료** 시각 |
| `lastResultCreated` | int | 그때 만들어진 추천 건수 |
| `lastError` | String? | 실패 사유(성공 시 null) |

**`startedAt`을 시작 시점에 먼저 쓰는 것이 중요하다.** 이것이 없으면
"실행이 아예 안 걸렸다"와 "실행되다 OS에 죽었다"가 구분되지 않는다.
`startedAt > lastRunAt`이면 완료되지 못한 실행이 있었다는 뜻이다.

Firestore를 쓰는 이유는 진단이다 — 백그라운드가 안 돌고 있어도 앱 화면만
봐서는 알 수 없는데, 이 문서를 보면 즉시 확인된다.

**가드 쓰기·읽기가 실패하면 실행하지 않는다.** 이 저장소의 "폴백은 아무것도
하지 않음" 원칙 그대로다. 가드가 동작하지 않는 채로 파이프라인이 도는 것보다
낫다.

### 판정 로직의 순수 함수 분리

```dart
@visibleForTesting
static bool shouldRunNow({
  required DateTime? lastRunAt,
  required DateTime now,
  required bool force,
  Duration minInterval = _minInterval,
})
```

이 작업은 대부분 플랫폼 통합이라 순수 함수로 뺄 수 있는 부분이 적지만,
**이것 하나는 반드시 분리해 테스트한다.**

테스트 케이스:

1. 최초 실행(`lastRunAt == null`) → 실행
2. 간격 미달 → 미실행
3. 간격 충족 → 실행
4. `force == true`면 간격 무시 → 실행
5. **`lastRunAt`이 미래(기기 시각 변경 등) → 실행**

5번이 중요하다. 시각이 미래로 기록되어 있으면 영영 실행되지 않을 수 있으므로
그 경우 실행하는 쪽으로 폴백한다.

### B단계 `run()`의 본문

```
1. Firebase 초기화        → 실패하면 false 반환(WorkManager 재시도)
2. 인증 복원 대기         → null이면 true 반환
3. agent_meta/background 읽기 → 실패하면 true 반환(아무것도 안 함)
4. shouldRunNow 검사      → false면 true 반환
5. startedAt 기록
6. (B단계에서는 여기가 비어 있다)
7. lastRunAt / lastResultCreated=0 / lastError=null 기록
8. true 반환
```

### 반환값

- `true` — 성공, 또는 재시도해도 달라지지 않는 상황. 다음 주기까지 대기.
- `false` — **Firebase 초기화 자체가 실패한 경우로 한정.**

이 프로젝트는 이미 태스크 큐(`agent_tasks`)로 자체 재시도 기제를 갖고 있으므로,
WorkManager의 재시도까지 겹치면 호출이 이중으로 늘어난다.

## B.4 등록

`main.dart`에서 **Android일 때만**, 킬 스위치가 켜져 있을 때만, try-catch 안에서.

```dart
await Workmanager().initialize(backgroundCallbackDispatcher, isInDebugMode: false);
await Workmanager().registerPeriodicTask(
  'dot-proactive-check',
  'proactiveCheck',
  frequency: const Duration(hours: 3),
  existingWorkPolicy: ExistingWorkPolicy.keep,
  constraints: Constraints(networkType: NetworkType.connected),
);
```

- `existingWorkPolicy: keep`이 중요하다. 앱을 열 때마다 `replace`하면 주기가
  계속 리셋되어 **영영 실행되지 않는다.**
- iOS는 Background Fetch가 OS 재량이라 하루 한 번도 보장되지 않으므로 제외한다.
  이 결정을 주석으로 명시할 것.

## B.5 설정 화면 — 수동 트리거와 상태 표시

**이 두 가지가 없으면 검증이 불가능하다.** 3시간을 기다려야 한 번 확인할 수
있기 때문이다.

### 즉시 실행 버튼

```dart
await Workmanager().registerOneOffTask(
  'dot-bg-manual-${DateTime.now().millisecondsSinceEpoch}',
  'proactiveCheck',
  inputData: {'force': true},
);
```

`force: true`가 빈도 가드를 우회한다.

### 지연 실행 버튼 (시연용) — 반드시 넣을 것

```dart
await Workmanager().registerOneOffTask(
  'dot-bg-delayed-${DateTime.now().millisecondsSinceEpoch}',
  'proactiveCheck',
  initialDelay: const Duration(seconds: 30),
  inputData: {'force': true},
);
```

**이것이 시연영상의 핵심 장치다.** 즉시 실행 버튼은 앱이 열린 상태에서 알림을
띄우므로 "앱을 안 켜도 준비된다"의 증명이 되지 못한다 — 버튼을 누르니 알림이
뜬 화면일 뿐이다. 30초 지연을 주면 **버튼 → 앱 완전 종료 → 잠금화면 알림**
순서로 촬영할 수 있고, 실제로 백그라운드 아이솔레이트에서 도는 것이므로
연출이 아니다.

### 상태 표시

버튼 아래에 `agent_meta/background`의 값을 표시한다.

- `lastRunAt` — 마지막 완료 시각
- `startedAt > lastRunAt`이면 "마지막 실행이 완료되지 않음" 경고
- `lastError`가 있으면 함께 표시

이것이 "백그라운드가 안 돌고 있는데 모르는" 상황을 막는 유일한 장치다.

## ✅ B단계 관문

1. `flutter build apk --release` → 실기기 설치 → **앱이 정상 실행된다**
2. 설정에서 즉시 실행 → `lastRunAt`이 갱신된다
3. **앱을 완전히 종료(최근 앱에서 스와이프)한 뒤** 지연 실행 → 30초 뒤
   `lastRunAt`이 갱신된다
4. 앱을 종료한 채로 몇 시간 방치 → 주기 실행으로 `lastRunAt`이 갱신된다
5. `--dart-define=BG_AGENT=false`로 빌드하면 백그라운드가 전혀 등록되지 않고
   앱은 현재와 동일하게 동작한다

**3번까지 통과하면 C단계로 갈 수 있다.** 4번은 시간이 걸리므로 C단계와
병행해서 관찰한다. 4번이 끝내 안 되면 그 자체가 결론이며, 그때는 C단계를
중단하고 서버 사이드 경로를 재검토한다.

### 촬영·검증용 기기 설정

Android 설정 → 배터리 → 앱별 관리에서 이 앱을 **제한 없음**으로 설정할 것.
삼성 기기의 배터리 최적화가 특히 공격적이라 기본 설정에서는 주기가 지켜지지
않을 수 있다. **다만 이 설정을 바꾼 상태의 결과를 "잘 된다"로 일반화하지 말
것** — 기본 설정에서의 동작을 따로 관찰해 기록한다.

---

# C단계 — 에이전트 연결 (하루)

B가 안정적으로 돌 때만 시작한다.

## C.1 `runProactiveCheck`의 반환값 확장

알림 문구를 만들려면 "무엇이 준비됐는지"를 알아야 한다. 현재는 `Future<void>`다.

`lib/services/agent_planner.dart`:

```dart
static Future<({int created, String? firstLabel})> runProactiveCheck(String uid)
```

- `created` — 이번 실행에서 새로 저장된 추천 건수
- `firstLabel` — 첫 번째 추천의 표시용 라벨(예: `내일 [결혼식]`).
  `_relativeLabel(plan.date)`와 `plan.tpoTag`를 조합한다. `_relativeLabel`은
  private이므로 문자열 조립은 `agent_planner.dart` 내부에서 한다. 없으면 null.

**제약:**

- 기존 동작을 바꾸지 말 것. 반환값 추가만 허용한다.
- 기존 호출부(`main.dart`의 `AppShell.initState`)는 반환값을 쓰지 않으므로
  수정하지 않는다.
- `catch` 절에서도 `(created: 0, firstLabel: null)`을 반환해 조용한 실패
  원칙을 유지한다.

## C.2 백그라운드 처리량 제한

**WorkManager의 실행 시간 한도는 약 10분이다.** 한도를 넘으면 OS가 프로세스를
죽이고, 그때 `lastRunAt`은 갱신되지 않은 채로 남는다.

현재 파이프라인의 상수로 최악을 계산하면:

```
AgentSweeper : _maxPerRun 2 × _stepDelay 3초
runProactive : _proactiveHorizonDays 3 (오늘~+3일, 최대 4건)
               × (Gemini 평가 최대 3회 + _planStepDelay 3초)
```

정상 네트워크에서는 2분 안쪽이지만, 응답이 느리거나 수리 루프가 다 돌면
늘어난다. 따라서 **백그라운드 실행에서는 가장 가까운 일정 1~2건만 처리한다.**

`runProactiveCheck`에 처리 상한 파라미터를 추가한다.

```dart
static Future<({int created, String? firstLabel})> runProactiveCheck(
  String uid, {
  int? maxPlans,   // null이면 현행(제한 없음) — 앱 내 호출은 영향 없음
})
```

백그라운드에서는 `maxPlans: 2`로 호출한다. 앱 내 호출은 인자를 넘기지 않으므로
동작이 바뀌지 않는다.

## C.3 실행 순서

B.3의 6번 자리를 채운다.

```
6-1. AgentSweeper.run(uid)
6-2. 3초 대기            (기존 main.dart와 동일한 취지 — API 호출 분산)
6-3. AgentPlanner.runProactiveCheck(uid, maxPlans: 2)
6-4. created > 0 이면 NotificationService.showRecommendationReady(firstLabel)
6-5. 로그 드레인 대기    (C.4)
```

## C.4 조용한 실패 방지 — 로그 드레인

**이 항목이 가장 놓치기 쉽다.**

`_prepareRecommendationFor`는 활동 로그를 `unawaited(...)`로 던진다. 앱 안에서는
아이솔레이트가 계속 살아 있어 문제가 없지만, **WorkManager 아이솔레이트는
콜백이 반환되는 순간 종료**되므로 완료되지 않은 Firestore 쓰기가 잘려나갈 수
있다. 그 결과 백그라운드 실행에서는 활동 로그가 누락되거나 일부만 남는다.

`agent_planner.dart`의 `unawaited`를 전부 `await`로 바꾸는 것은 범위가 크고
동기 흐름의 지연을 늘리므로 **하지 말 것.** 대신 콜백 반환 직전에 짧은 드레인
대기를 둔다.

```dart
// unawaited로 던져진 Firestore 쓰기가 완료될 시간을 준다.
// 보장이 아니라 유예다 — 근본 해법은 로그 쓰기를 await로 바꾸는 것.
await Future.delayed(const Duration(seconds: 3));
```

이 한계를 주석으로 명시할 것.

## C.5 알림 발송 조건

`created > 0`일 때만 발송한다. 스킵됐을 때도 알림을 보내면 사용자가 금방 끈다.
하루 한 건을 넘지 않도록 B.3의 빈도 가드(10시간)가 이미 상한 역할을 한다.

## ✅ C단계 관문

1. **수동 트리거** — 설정에서 즉시 실행. 활동 로그에 평소와 같은 서사가
   남는지 확인. 로그가 비어 있으면 C.4의 드레인 문제이거나 Firebase 초기화
   문제다.
2. **앱 종료 상태** — 캘린더에 내일 일정을 등록하고 홈 카드를 닫은 뒤,
   지연 실행 버튼 → 앱 완전 종료 → **잠금화면에 알림이 뜬다.**
3. **빈도 가드** — 주기 실행이 10시간 이내면 걸러지는지 `lastRunAt`으로 확인.
   수동 트리거는 `force`라 항상 실행되어야 한다.
4. **미완료 감지** — 실행 중 강제 종료시켰을 때 `startedAt > lastRunAt` 상태가
   설정 화면에 표시되는지 확인.

---

## 알려진 한계 — 이번 작업에서 다루지 않음

아래는 인지하되 이번 범위에서 해결하지 않는다. 지시서와 코드 주석에 남길 것.

### 동시 실행 경합

앱 실행 트리거(`AppShell.initState`)는 그대로 남으므로, 백그라운드가 도는 중에
사용자가 앱을 열면 `runProactiveCheck`가 겹쳐 돈다. 둘 다 "추천 없음"을 읽고
둘 다 만들어 같은 날짜에 문서가 두 개 생길 수 있다.

**락을 걸지 않는다.** 복잡도가 크게 늘고, 중복 게이트 수정(`selectDateRecommendation`)이
이미 같은 날짜의 잉여 문서를 자동으로 정리하므로 자가 치유되며, 겹칠 확률
자체가 낮다(하루 2회 × 수 초). 다만 그 구간에서 Gemini 호출이 이중으로 발생할
수 있다는 점은 사실이다.

### 옷장 문서 페이로드

`runProactiveCheck`는 매 실행마다 `wardrobeStream().first`로 옷장 전체를
읽는데, 512차원 임베딩 벡터가 옷장 문서 안에 들어 있어 **1회 약 1MB, 문서
87건**이 오간다. 백그라운드가 하루 여러 번 돌면 이 비용이 그만큼 늘어난다.

지금 당장 문제가 되는 규모는 아니지만, **임베딩 벡터를 별도 컬렉션으로
분리하는 작업의 우선순위가 이 작업으로 인해 올라간다.** 별도 지시서로 다룬다.

### 실행 시각의 비보장

Android WorkManager는 실행 시각을 보장하지 않으며, 제조사 배터리 최적화의
영향을 크게 받는다. iOS는 대상에서 제외했다.

**B단계 4번 관문(방치 후 주기 실행)의 결과를 며칠간 기록할 것.** 등록 주기
3시간에 대해 실측 간격의 중앙값과 최대 지연을 모으면, 이 경로의 신뢰성이
요구 수준에 미치는지 판단할 근거가 된다. 기본 배터리 설정과 "제한 없음" 설정
양쪽에서 각각 관찰한다.

---

## 금지 사항

- **백그라운드 콜백에서 `signInAnonymously()`를 호출하지 말 것.**
  유령 계정이 생기고 증상 없이 진행된다.
- `FirebaseAuth.instance.currentUser`를 `initializeApp()` 직후에 바로 읽고
  판단하지 말 것. `authStateChanges()`로 복원을 기다린다.
- `agent_planner.dart`의 `unawaited` 로그 호출을 `await`로 바꾸지 말 것.
- `runProactiveCheck`의 기존 동작을 바꾸지 말 것. 반환값과 선택적 파라미터
  추가만 허용한다.
- iOS 경로를 만들지 말 것. Android 전용으로 두고 사유를 주석에 남긴다.
- 알림 중요도를 `high`로 두지 말 것.
- `existingWorkPolicy`를 `replace`로 두지 말 것.
- 실행 주기를 15분으로 두지 말 것.
- 백그라운드 콜백에서 UI 관련 코드(`AgentActivity`, `ScaffoldMessenger` 등)를
  호출하지 말 것. 아이솔레이트에 UI가 없다.
- 각 단계의 관문을 통과하기 전에 다음 단계를 시작하지 말 것.

---

## 완료 보고 형식

단계별로 나누어 보고할 것.

**A단계**
1. `flutter analyze` / `flutter test` 결과 (기존 132종 유지)
2. 릴리스 APK 설치 후 앱 실행 여부
3. 알림 수신 캡처
4. 권한 거부 상태에서의 동작

**B단계**
1. `flutter analyze` / `flutter test` 결과 (기존 132종 + `shouldRunNow` 5케이스)
2. `shouldRunNow` 테스트 케이스별 결과
3. B단계 관문 1~5 각각의 통과 여부. 실패한 항목은 **어디서 어떻게 막혔는지**
4. `agent_meta/background` 문서의 실제 내용 (캡처 또는 값 나열)
5. 관문 4번(주기 실행) 관찰 기록 — 시각별 `lastRunAt` 목록

**C단계**
1. `flutter analyze` / `flutter test` 결과
2. 변경 파일 목록과 각 파일에서 한 일
3. C단계 관문 1~4 각각의 통과 여부
4. 잠금화면 알림 캡처
5. 백그라운드 실행 1회의 소요 시간(`startedAt` → `lastRunAt` 차이)

---

## 후기 (2026-07-28)

A·B·C 전 단계 관문 통과. 지시서가 예상하지 못한 것 두 가지:

- workmanager 0.5.2는 Flutter v1 임베딩 shim을 참조해 현재 SDK에서
  네이티브 컴파일이 실패한다. 0.9.0으로 올려 해결
  (existingWorkPolicy → ExistingPeriodicWorkPolicy).
- flutter_local_notifications가 코어 라이브러리 디슈가링을 요구해
  릴리스 빌드가 처음 실패했다. build.gradle.kts에 설정 추가로 해결.

둘 다 디버그에서는 드러나지 않고 릴리스 빌드에서만 터졌다 —
0.1절의 "검증 관문은 반드시 릴리스 APK로"가 실제로 작동한 사례.
