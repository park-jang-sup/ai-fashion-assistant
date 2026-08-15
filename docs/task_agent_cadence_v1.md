# 작업 지시서 — 발화 정책 자기 조정 + 반응 계측 (task_agent_cadence_v1)

**[갱신 2026-08-15] (a) 구현·배포·실기기 검증 완료.** 최초 커밋은
설계 등록만이었으나(아래 원문 유지), 이후 (a)(발송-탭 매칭 계측)를
구현해 배포하고 실기기로 검증까지 마쳤다 — 결과는 §9-2·§9-3.

**[갱신 2026-08-15, 이어서] (b) 클라이언트 측 구현 완료(5/5 커밋).**
§4~§8을 따라 순서대로 커밋했다 — 반응률 산출 순수 함수(`f11129f`)
→ 판정 순수 함수(`88568ad`) → `agent_meta` 상태 배선(`a0fd97a`) →
`agent_logs` 기록(`0860849`) → 정책 객체 주입·diff 0 확인(`06a27d9`).
전체 테스트 218/218 통과, `flutter analyze` 통과. **아직 배포·실기기
검증은 안 했다** — (a)와 달리 이번 커밋들은 로컬에만 있다.

**미완, 등록만: §8의 서버 측 게이트.** `runScheduledCheckCore`가
`adjustedIntervalHours`+`serverLastRunAt`으로 발화 여부를 스스로
거르는 부분은 사용자가 지시한 5단계 순서(반응률 산출→판정→
`agent_meta` 배선→`agent_logs`→정책 객체 주입)에 없어 이번 트랙에서
다루지 않았다. 지금은 클라이언트(`shouldRunNow`)만
`adjustedIntervalHours`를 읽는다 — 서버는 여전히 3시간마다 무조건
확인하고 `findNextUntriggeredDate`(추천 존재 여부)로만 발화를
거른다. 별도 승인 후 진행한다.

**이번 커밋은 설계 등록만 한다. 구현은 승인 후.**(원문, 착수 시점
서술로 보존) 아래 §2의 실측(표본 카운트)만 예외 — 읽기 전용 쿼리로,
설계 자체(§6·§8)가 그 결과에 의존하므로 승인 전에 먼저 실행했다.

## 0. 이 문서의 위치와 승계 원칙

**승계 원칙은 옮겨 적지 않는다** — `docs/task_selfeval_followup_v1.md`
§0(그 문서가 가리키는 `task_selfeval_validity_v1.md` §0 →
`task_hardening_v2.md` §0으로 이어지는 사슬)을 그대로 참조한다. 판정
기준 사전 등록, 계측 우선, 미확정 불인정, 재빌드 대조, "무료 진단
먼저" 원칙 — 전부 그 링크를 따라간다.

**기록 원칙**도 `docs/handoff_2026-08-07.md` §2를 그대로 따른다(원문을
지우지 않고 정정 블록을 덧붙인다, 실측치에 재현 코드를 남긴다 등).

이 트랙은 직전 세션의 읽기 전용 조사(App Check 기동 확인 + 발화 정책
전제 확인, 커밋 없음)를 승계한다. 그 조사가 확인한 것:
- App Check `activate()`는 fire-and-forget 전환이 완료돼 앱 기동을
  막지 않는다(디버그 실기기 확인, 릴리스는 구조적으로 같은 경로이나
  미실측) — 이 트랙과는 별개 축이므로 더 다루지 않는다.
- `RecommendationEntry.userChoice`가 반응 신호로 존재하지만
  "무시"(무반응)를 정의하지 못한다.
- FCM 탭은 계측되지만(`serverTapCount` 등) 발송과 1:1로 매칭되지 않는다.
- 발화 주기(서버 3시간 크론, 클라이언트 WorkManager 3시간 등록,
  클라이언트 `_minInterval` 10시간)는 전부 코드 상수다.
- `users/{uid}/agent_meta/background`가 이미 클라이언트·서버가 공유하는
  런타임 상태 문서다.

이 문서는 그 결론을 전제로 실제 설계를 고정한다.

## 1. 범위 (A)

**포함**:
- (a) 발송-탭 매칭 계측 배선. 데이터는 배선 이후 자연히 쌓인다.
- (b) 발화 정책 자기 조정. 지금 있는 신호(`userChoice`)로 먼저 동작하고,
  (a)가 쌓은 데이터로 입력만 나중에 교체한다.

계측을 배선하는 것과 그 데이터를 활용하는 것은 다른 단계다. 배선은
지금 가능하고 축적은 시간이 한다 — hardening 트랙 S2-a(계측 먼저,
강제는 나중)·S3-b와 같은 순서.

**제외**(사유 명시):
- **매칭 가중치 학습** — 코디 매칭 알고리즘(`OutfitMatcher`,
  `TpoMatchPolicy`)의 점수 산식을 반응 신호로 재학습하는 것. 이 트랙이
  건드리는 것은 "언제 알릴지"(발화 주기)이지 "무엇을 추천할지"(매칭
  로직)가 아니다. 별도 축.
- **도구 선택** — 에이전트가 어떤 도구/경로를 쓸지 스스로 정하는 것.
  이 시스템은 지금 도구가 하나(로컬 필터+LLM 평가)뿐이라 선택할 대상
  자체가 없다. 별도 축.

## 2. 사전 실측 — 현재 표본 수 (읽기 전용, 승인 전 실행)

Firestore Admin SDK로 `users/*/recommendations`를 전량 조회했다(쓰기
없음, 스크래치패드의 임시 스크립트로 실행, 저장소에 커밋하지 않음 —
필요하면 §9의 도구로 정식화한다).

**전체**: 계정 3개, `recommendations` 문서 76건.

| `userChoice` | 건수 |
|---|---|
| `null`(무반응 후보) | 57 |
| `rejected_with_alternative` | 16 |
| `accepted` | 3 |

논문 5.4절의 "측정 시점 채택률 43%"는 분모가 문서에 없었다 — 이번
실측(3/19 = 15.8%, 반응 기록분 기준)과 직접 비교할 수 없다. 다른
시점·다른 표본이므로 불일치로 취급하지 않는다.

**uid별 분포 및 최근 5건**(가장 최근이 왼쪽):

| uid(앞 8자) | 총 건수 | 최근 5건 | 최근 5건 중 가장 오래된 것의 경과 시간 |
|---|---|---|---|
| `BDDOIl08` | 35 | `rejected, null, null, null, null` | 92.9시간 |
| `JmllppO9` | 23 | `rejected, null, rejected, null, null` | 445.0시간 |
| `yPyw4DC2` | 18 | `null, null, null, null, null` | 303.3시간 |

세 계정 모두 총 건수가 18건 이상이라 "최근 5건" 판정 창이 항상 채워진다
— **표본 부족(§4-3) 상황은 현재 이 3개 계정에서는 발생하지 않는다.**
이는 §6(시연 가능성)의 근거가 된다.

### 2-1. [갱신 2026-08-15] (a) 실기기 검증이 표본을 바꿨다

**원 실측(위 §2 본문)은 지우지 않는다** — 설계(N=72시간, §4-1)의
근거였던 값이므로 그대로 보존한다. 이 절은 §9-3의 실기기 검증
과정에서 데이터가 실제로 바뀐 뒤 다시 조회한 결과다.

**변화 원인**: §9-3 검증 중 캘린더 일정 2건(2026-08-16 '일상',
2026-08-18 '일상·모임')을 실제로 추가했고, 그 결과 알림 탭 2회
(경로 1·경로 2)가 각각 `AgentPlanner.runProactiveCheck`을 실행시켜
`recommendations` 문서 2건이 새로 생겼다 — 둘 다 `BDDOIl08` 계정,
둘 다 `userChoice=null`(당연히 아직 반응 없음).

**전체 재조회(읽기 전용)**: 계정 3개, 문서 **78건**(76 → +2).

| `userChoice` | 건수 | 원 실측 대비 |
|---|---|---|
| `null` | 59 | +2 |
| `rejected_with_alternative` | 16 | 변화 없음 |
| `accepted` | 3 | 변화 없음 |

**uid별 "최근 5건" 재확인 — N=72시간 규칙 적용해 응답/무반응/판정보류로
분류**(단순 `null` 개수가 아니라 §4-1의 실제 판정 결과로 다시 셌다):

| uid | 응답 | 무반응(72h+) | 판정보류(<72h) | 비고 |
|---|---|---|---|---|
| `BDDOIl08` | 1 | **1** | 3 | **검증으로 생성된 2건(0.13h·0.21h)이 판정보류로 창을 차지 — §7 갱신 필요** |
| `JmllppO9` | 2 | 3 | 0 | 이번 검증과 무관, 변화 없음 |
| `yPyw4DC2` | 0 | 5 | 0 | 이번 검증과 무관, 변화 없음(단 `PcszB3DMVUfY2a5piRWD`가 `dismissed=true`로 최근 5건에 섞여 있음 — 아래 참고) |

**부수 확인 — `dismissed=true` 문서가 "최근 5건"에 섞여 있었다.**
`yPyw4DC2`의 단순 `createdAt` 내림차순 최근 5건 중 4번째
(`PcszB3DMVUfY2a5piRWD`, 303.6시간 전)가 `dismissed=true`다. §5-1이
이미 "`dismissed=true`는 반응 후보에서 제외한다"고 설계해 뒀으므로
이 문서는 실제 구현에서는 창에 들어가지 않고 6번째 문서
(`ZnNq9CLtfWhrZVSTpxGS`, 322.3시간 전, `null`)가 대신 들어간다 —
치환해도 결론(5/5 무반응)은 바뀌지 않지만, **"최근 5건을
`createdAt`만으로 뽑으면 안 된다"는 §5-1 설계가 실측으로도 이미
필요했음이 확인됐다.** 순수 함수 구현·테스트(§9-1)에 이 문서
(`PcszB3DMVUfY2a5piRWD`)를 픽스처로 그대로 쓸 수 있다.

### 3-1. 확인된 결함 (재확인)

`recordServerInvocation`(`functions/src/index.ts:1231-1262`)이 쓰는
`serverInvocationLog`(캡 500, `SERVER_INVOCATION_LOG_CAP`,
`index.ts:1109`)와, `fcm_service.dart`의 `_handleMessageTap`이 쓰는
`serverTapCount`/`serverTapAt`은 **같은 문서(`agent_meta/background`)의
서로 다른 누적 필드**일 뿐, 개별 알림 단위로 조인할 키가 없다. "이
알림을 보냈는데 안 열었다"를 개별 판정할 수 없고, 기간 단위 근사치
(발송 수 − 탭 수)만 가능하다.

### 3-2. 설계 — 서버가 발급한 id를 클라이언트가 회수한다

**서버(`functions/src/index.ts`)**: `runScheduledCheckCore`
(`index.ts:1276-1318`)가 `sendEachForMulticast` 호출 직전 `pushId =
crypto.randomUUID()`(Node 18+ 전역, 새 의존성 없음)를 발급한다.

- `data: {source: "server_scheduler", targetDate: targetDateStr,
  pushId}`로 페이로드에 실어 보낸다.
- `recordServerInvocation`의 `entry`(`index.ts:1244-1246`)에도 같은
  `pushId`를 추가한다 — `serverInvocationLog`의 기존 캡핑·트랜잭션
  구조를 그대로 재사용한다(새 상한 로직을 만들지 않는다).

**클라이언트(`lib/services/fcm_service.dart`)**: `_handleMessageTap`
(`fcm_service.dart:165-207`)이 `message.data['pushId']`를 읽어, 기존
`serverTapCount`/`serverTapAt`과 **같은 트랜잭션**으로 새 캡핑 배열
`serverTapLog`(cap 500, `serverInvocationLog`와 동일한 값 — 발송·탭이
1:1에 가까우므로 같은 상한이면 충분하다)에 `{pushId, tappedAt:
now, isColdStart}`를 추가한다.

**주의 — 두 id를 혼동하지 않는다.** `message.messageId`(FCM 시스템
id, 기존 재소비 필터 §3에서 이미 사용 중, `fcm_service.dart:119-127`
주석)와 이번에 추가하는 `pushId`(우리가 발급하는 매칭 키)는 목적이
다르다. `messageId`는 "같은 탭 이벤트를 두 번 처리하지 않기 위한
것"이고 `pushId`는 "이 알림이 어느 발송 기록에 대응하는지 찾기 위한
것"이다. 코드 주석에 이 구분을 명시한다 — 다음 사람이 하나로
합치려 들지 않도록.

### 3-3. 저장 위치 — 별도 컬렉션이 아니라 기존 문서의 캡핑 배열

**결정: `agent_meta/background`에 필드 추가.** 별도 컬렉션(예:
`users/{uid}/push_log/{pushId}`)을 검토했으나 기각 — 이유:

- 발송 빈도가 3시간에 최대 1건이므로 데이터 규모가 애초에 작다
  (`serverInvocationLog`가 이미 이 규모에서 캡 500으로 30일치 이상을
  감당한다는 사실이 실측으로 확인돼 있다, `background_agent.dart:194`
  주석).
- 별도 컬렉션은 정리(TTL/스윕) 정책이 새로 필요하다
  (`sweepStorageTokens`처럼). 캡핑 배열은 쓰기 시점에 스스로 잘려
  정리 비용이 없다.
- 매칭 자체가 "두 캡 500 배열에서 같은 `pushId`를 찾는" 선형 스캔이라,
  이 규모(최대 500×2)에서 성능 문제가 없다.

**트레이드오프로 남기는 것**: 캡에 닿아 오래된 항목이 잘리면 그
항목의 매칭 여부는 이후 영원히 알 수 없게 된다. 500건은 3시간 주기
기준 약 62일치라 이번 트랙의 관측 목적(§4-2 전환 기준 30건)에는
넉넉하다 — 넉넉함의 근거를 여기 남긴다.

### 3-4. 이 계측만으로는 아무것도 바뀌지 않는다

`serverTapLog`를 배선해도 발화 정책은 그대로다. §4의 판정 함수는
1단계(현재)에서 이 필드를 참조하지 않는다 — 데이터가 쌓이는 동안
아무 동작 변화가 없는 것이 **의도된 상태**다. `pushId` 발급·기록
코드 옆에 "이 필드는 §4-2 전환 기준(매칭 30건) 전까지 쓰이지 않는다,
`docs/task_agent_cadence_v1.md §3-4·§4-2` 참고"를 주석으로 남긴다 —
다음 사람이 "왜 넣었는데 안 쓰지"라고 묻지 않도록.

## 4. (b) 반응의 정의

### 4-1. 1단계(지금) — `userChoice` 기반, N=72시간

`userChoice`가 `null`인 문서를 두 상태로 나눈다:
- **판정 보류** — 생성 후 72시간(3일) 미만. 아직 반응할 시간이 남아
  있다고 본다.
- **무반응** — 생성 후 72시간 이상 지났는데도 `null`.

**N=72시간으로 정한 근거**: 3.5.1절의 피드백 매칭이 **±3일(72시간)
완화**로 캘린더 기록을 추천에 연결한다(`DOT_paper_rev9.md` 3.5.1절,
5.9절). 72시간보다 짧은 N을 쓰면, 아직 매칭 창이 열려 있어 나중에
`userChoice`가 채워질 수도 있는 문서를 "무반응"으로 성급히 확정하는
모순이 생긴다 — 그 문서가 나중에 실제로 `accepted`로 채워지면 이미
내려진 "무반응" 판단과 데이터가 어긋난다. N을 매칭 창의 바깥 경계에
맞추면 이 모순이 구조적으로 없어진다. 응답성(더 빨리 알아채고
싶다)보다 이 정합성을 우선한다 — §4-3 표본 부족 시 "유지"를 안전한
기본값으로 삼은 것과 같은 방향의 선택이다.

**§2 실측 데이터로 실현 가능성을 확인했다**: 세 계정의 "최근 5건" 중
`null`인 항목은 전부 경과 시간이 48.9~445시간이었다(BDDOIl08의 두
번째 항목만 49.4시간으로 72시간 미만 — 이 항목만 "판정 보류"로
빠지고 나머지는 "무반응"으로 셈된다). 즉 N=72시간을 적용해도 세
계정 전부 최근 5건 안에서 실제로 "무반응 3건 이상"을 만족한다(아래
§6 표 참고) — 정합성을 우선한 선택이 시연 가능성을 희생하지 않았다.

### 4-2. `AgentStats.compute`와의 해석 충돌 — 양쪽에 명시한다

`AgentStats.compute`(`agent_stats.dart:54`)는 `userChoice == null`인
문서를 채택률 집계에서 **전부 제외**한다("아직 반응 없음"). 이번
설계는 같은 `null`을 72시간 기준으로 "판정 보류"와 "무반응"으로
**갈라 다르게 쓴다**. 같은 필드를 두 곳이 다른 전제로 소비하는
상태다(5.8.8절 "두 정책 사이의 숨은 의존 관계"와 같은 계열 —
독립인 줄 알았던 두 소비처가 사실 같은 원본 데이터에 기대고 있다).

두 소비처 모두 정당하다 — `AgentStats`는 "확정된 결과만으로 채택률을
말한다"는 목적이고, 이번 설계는 "충분히 기다려도 답이 없으면 그
자체가 신호"라는 목적이다. 목적이 다르므로 통합하지 않는다. 대신
**양쪽 코드에 상호 참조 주석을 남긴다** — `agent_stats.dart:54` 위에
"이 null 제외 관례는 `cadence_policy.dart`의 72시간 무반응 판정과
다른 기준이다, 한쪽만 고치면 어긋난다"를, 새로 작성할
`response_signal.dart`에는 역방향 참조를 남긴다.

### 4-3. 표본 부족 시 동작 — 판정하지 않고 유지한다

판정 창(최근 5건)에 못 미치면(즉 해당 uid의 `recommendations` 총
건수가 5 미만이면) **판정하지 않고 현재 간격을 유지한다.** 근거:
- 잘못된 조정(반응할 시간도 없었는데 성급히 간격을 넓히거나 좁히는
  것)의 비용이, 판정을 미뤄 기본값을 유지하는 비용보다 크다 —
  5.9절 "폴백 방향이 아무것도 하지 않음으로 향하도록 설계"와 같은
  방향의 실패 안전성.
- 표본 부족은 신규 계정 초기에만 발생한다. 그 시점엔 애초에 추천
  자체가 적어 "발화가 과도해진다"는 위험도 낮으므로 유지의 실질
  비용이 작다.

**결정한 뒤 결과를 보고 바꾸지 않는다** — §2 실측(기존 3개 계정
전부 표본 충분)이 이 결정을 편하게 만들었다고 해서, 새 계정에서
이 분기가 자주 밟히더라도 지금 여기서 다시 바꾸지 않는다.

### 4-4. 2단계(데이터 축적 후) — 매칭 기반으로 전환

판정 함수(§5) 자체는 바꾸지 않는다. 입력 산출부(§5-2)만 `userChoice`
기반에서 §3의 발송-탭 매칭 기반으로 교체한다.

**전환 기준(사전 등록)**: 어느 uid든 `serverTapLog`와
`serverInvocationLog`가 **매칭 가능한 쌍(발송 기록에 대응하는 탭
유무를 판정할 수 있는 건, 즉 발송 후 캡에 밀려나지 않은 건) 30건**
이상 쌓이면 그 uid는 매칭 기반으로 전환한다. 30이라는 값은
임의값임을 명시한다 — 다만 하한 없이 "데이터가 쌓이면"으로만 두면
전환 시점을 결과를 보고 정하게 되므로, 최소선을 지금 고정해 둔다.
uid별로 독립 전환한다(전원이 30건에 동시 도달할 이유가 없다).

## 5. 판정 함수 — 순수 함수로 분리

### 5-1. 반응률 산출부와 판정부를 분리한다

판정 함수만 추상화하면 "반응률을 어떻게 산출하는가"가 테스트 밖에
남는다. 시각 비교, 최근 N건의 정렬 기준, 재계획으로 무효화
(`dismissed=true`)된 문서의 처리 — 이런 배선이 실제로 틀리기 쉬운
자리다(함수가 통과해도 입력이 틀리면 결과가 틀린다는 게 5.18절의
요지와 같은 자리).

**`lib/services/response_signal.dart`(신설)** — 순수 함수.

```dart
// (이력, 현재 시각, 무반응 기준) → 표본 구성. Firestore/시각 의존 없음
// — now를 인자로 받아 테스트에서 고정한다.
({
  int sampleSize,       // 판정에 실제로 쓰인 건수(판정 보류 제외)
  int respondedCount,   // accepted + rejected_with_alternative
  int noResponseCount,  // null이고 now - createdAt >= noResponseAfter
  int pendingCount,     // null이고 아직 noResponseAfter 미만(참고용, 판정에 미포함)
}) summarizeRecentResponses({
  required List<RecommendationEntry> recentEntries, // 이미 최근 N건으로 잘라 넘김 — 정렬 책임은 호출부
  required DateTime now,
  Duration noResponseAfter = const Duration(hours: 72),
})
```

- `dismissed=true`(재계획으로 무효화된 문서)는 호출부가 넘기기 전에
  걸러낸다고 가정하지 않는다 — 이 함수 안에서 명시적으로 제외한다
  (호출부가 깜빡해도 안전하도록, `AgentStats.compute`가 `dismissed`를
  아예 참조하지 않는 것과 다른 선택임을 주석에 남긴다 — 5.9절이
  이미 "채택률 집계는 dismissed와 무관해도 안전하다"고 확인했지만,
  이번 신호는 "재계획으로 사라진 추천"까지 반응 후보에 넣으면 존재하지
  않는 알림에 대한 무반응을 세게 되므로 같은 논리가 성립하지 않는다).

### 5-2. `lib/services/cadence_policy.dart`(신설, 이름 검토 완료 — 유지)

순수 함수. `functions/src/rate_limit.ts`(`evaluateRateLimit`,
Firestore/시각 의존 없이 상태+설정+현재시각을 받아 판정만 반환하는
결)와 같은 결로 만든다.

**입력을 추상화한다** — `userChoice`나 `RecommendationEntry`를 직접
받지 않고 §5-1이 낸 요약(`sampleSize`/`respondedCount`/
`noResponseCount`)만 받는다. §4-4에서 입력 산출부가 매칭 기반으로
바뀌어도 이 함수와 그 단위 테스트는 그대로 쓴다 — `TpoMatchPolicy`
(`outfit_matcher.dart:56`)가 정책을 객체로 분리해 재료(옷장)가 바뀌어도
정책 코드는 그대로 쓰는 것과 같은 발상.

```dart
class CadenceDecision {
  final int recommendedIntervalHours;
  final String reason; // 활동 로그에 그대로 쓸 수 있는 한국어 문장
  final bool changed;  // currentIntervalHours와 다른가
  const CadenceDecision({...});
}

CadenceDecision judgeCadence({
  required int currentIntervalHours,
  required int sampleSize,
  required int respondedCount,
  required int noResponseCount,
  required int acceptedCount, // respondedCount의 부분집합 — 채택 규칙 전용
})
```

**규칙 초안**(값은 구현 승인 시 재확인):
- `sampleSize < 5` → 판정하지 않음(§4-3), `changed=false`.
- `noResponseCount >= 3`(5건 중) → 간격 2배, **상한 12시간**.
- `acceptedCount >= 3`(5건 중) → 간격 절반, **하한 3시간**.
- 그 외 → 유지.

**상한·하한을 두는 이유**: 조정이 폭주하면 알림이 아예 안 오거나
(무반응이 계속돼 간격이 무한히 늘어남) 과도해진다(채택이 계속돼
간격이 무한히 줄어듦). 이 프로젝트의 "비용·동작 상한" 원칙(S1의
`maxInstances`, rate_limit.ts의 시간당 상한)과 같은 방향 — 판단
로직이 스스로 만든 조정값이 그 판단 로직 자신을 위험한 상태로
몰아넣지 않게 막는다. 하한 3시간은 현재 기본 주기와 같다 — "지금보다
더 자주는 안 간다"는 보수적 시작점이다. 상한 12시간은 클라이언트
`_minInterval`(10시간)보다 약간 크게 잡아, 조정이 걸려도 최소
하루 한 번 이상은 확인 기회가 남게 한다.

## 6. 관찰 가능성

### 6-1. 조정이 일어날 때 — `agent_logs`에 두 건으로 나눠 남긴다

기존 관례(새 옷 등록 파이프라인이 `new_item_detected` →
`candidates_generated` → `candidate_evaluated` → ... 로 단계를 나눠
쌓는 것, §8 실기기 검증에서 재확인)를 따라 판단과 결과를 별도
`AgentLogEntry`로 남긴다:

```
eventType: cadence_signal_detected
message: "최근 추천 5건 중 3건이 반응 없음을 감지했습니다"

eventType: cadence_adjusted
message: "발화 간격을 3시간에서 6시간으로 조정합니다"
```

### 6-2. 조정이 없을 때 — `agent_logs`에는 안 남기고, `agent_meta`에는 남긴다

**결정**: 사용자 대상 서사 채널(`agent_logs`)에는 "유지" 판단을
남기지 않는다. 진단 채널(`agent_meta/background`)에는 매번 남긴다
— `lastCadenceCheckAt`(Timestamp), `lastCadenceReason`(String,
`changed=false`일 때도 채움).

**근거**: `agent_logs`는 최종 사용자가 활동 로그 화면에서 읽는
서사다. 3시간마다(±10시간 주기 기준으로도 하루 2~3회) "유지합니다"가
쌓이면 정작 의미 있는 조정 이벤트가 그 사이에 묻힌다 — 시끄러움의
비용이 "안 보임"의 비용보다 크다고 판단했다. 반면 `agent_meta`는
이미 `lastRunAt`/`invocationLog` 등 "서사로는 안 보이지만 관측은
되는" 진단값을 쌓아 온 문서이므로, 같은 성격의 값을 추가하는 것이
기존 관례와 맞다. 즉 **"판단했으나 유지했다"가 완전히 안 보이는
것은 아니다** — 설정 화면의 진단 스트림(`backgroundAgentMetaStream`,
`firestore_service.dart:694`)을 통해 확인 가능하다.

## 7. 시연 가능성

**판정 창을 최근 5건으로 잡은 것 자체가 이미 소수 이력 발동을
보장한다**(§5-2). §2 실측이 이를 실측으로 뒷받침한다(원 실측 —
아래 [갱신]에서 재확인).

| 규칙 | 현재(§2 실측)로 이미 충족하는 계정 |
|---|---|
| 무반응 3건 이상 → 간격 2배 | **3개 전부**(BDDOIl08 4건, JmllppO9 3건, yPyw4DC2 5건 — 모두 N=72h 적용 후) |
| 채택 3건 이상 → 간격 절반 | **없음** — 전체 76건 중 `accepted`가 3건뿐이고 한 계정에 몰려 있지 않다 |

**시연용 이력 상태를 만들 경로가 있는가 — 없다(확인).**
`userChoice`를 수동으로 설정하는 화면·도구가 코드베이스 어디에도
없다(grep 확인, `calendar_screen.dart`의 "이 코디로 확정" 버튼이
유일한 쓰기 경로이고 이것도 자동 `accepted`일 뿐 수동 지정이 아니다).

**결론과 대응**:
- **간격 확대(무반응) 규칙**은 별도 준비 없이 기존 3개 계정 중
  하나로 즉시 시연 가능하다.
- **간격 축소(채택) 규칙**은 시연 전 실제 사용 경로("이 코디로
  확정" 버튼)를 3회 반복해 자연스럽게 조건을 만든다 — 이는 인위로
  실패·폴백을 만드는 것과 다르다(금지 대상 아님, 정상 기능을 정상
  경로로 반복 사용하는 것). 이번 트랙 산출물에 "시연 전 체크리스트:
  대상 계정에서 예정 일정 3건을 원탭 확정" 항목으로 등록한다.
- 조정 결과는 `agent_meta`에 즉시 반영되고(§6-2), 기존 "즉시 실행
  (테스트)" WorkManager 버튼(설정 화면)과 `triggerScheduledCheckTest`
  onCall 함수가 이미 있어 3~10시간을 기다리지 않고 판정 로직을
  즉시 재실행해 볼 수 있다 — 새 시연용 트리거를 만들 필요가 없다.

### 7-1. [갱신 2026-08-15] `BDDOIl08` 시연 조건이 검증 자체로 깨졌다

**아이러니한 결과: (a)를 실기기로 검증하는 과정이 그 검증에 쓴
계정의 시연 준비 상태를 훼손했다.** §2-1의 재조회 결과:

| uid | 무반응 3건 이상(간격 확대) | 이번 검증 영향 |
|---|---|---|
| `BDDOIl08` | **더 이상 미충족(1건뿐)** | §9-3 검증이 만든 판정보류 2건이 이전 창(무반응 3건)을 밀어냄 |
| `JmllppO9` | 충족(3건) | 무관, 변화 없음 |
| `yPyw4DC2` | 충족(5건) | 무관, 변화 없음 |

**원인**: `triggerScheduledCheckTest`로 알림을 2회 발화·탭했고, 그
탭이 `runProactiveCheck`를 실행시켜 `BDDOIl08`에 `null` 추천 2건이
막 생성됐다. 이 2건은 생성된 지 1시간도 안 돼(0.13h·0.21h) N=72시간
문턱에 한참 못 미치므로 "무반응"이 아니라 "판정보류"로 분류되고,
"최근 5건" 창이 최신순이라 이 2건이 창의 앞자리를 차지해 이전에
무반응이었던 오래된 문서들을 창 밖으로 밀어냈다.

**결론 — 판정 자체는 뒤집히지 않는다, 시연 계정 선택만 바뀐다.**
§7 원 결론("무반응 규칙은 별도 준비 없이 즉시 시연 가능")은
**여전히 유효**하다 — 다만 **어느 계정으로**가 바뀐다. `BDDOIl08`
대신 `JmllppO9` 또는 `yPyw4DC2`를 쓰면 지금도 별도 준비 없이 즉시
시연 가능하다. `BDDOIl08`은 72시간이 더 지나면(2026-08-18 이후)
이번에 생긴 2건도 무반응으로 넘어가 다시 충족하게 된다 — 급하면
다른 두 계정을, 여유가 있으면 시간이 해결한다.

**설계에 대한 함의 — 새로 등록할 것은 없다.** 이 현상은 §4-1이
이미 사전 등록한 규칙(N=72시간, 판정보류와 무반응의 구분)이 실측
데이터에서 처음으로 실제로 작동한 사례다 — 규칙이 고장 난 게
아니라 규칙대로 정확히 동작했다. 다만 **"검증 활동 자체가 다음
판정에 입력으로 들어간다"**는 사실은 (b) 구현 후 반복 검증할 때마다
계속 재발할 수 있으므로, §9(검증 설계)에 "판정 함수 실기기 검증은
계정 상태를 변화시킨다 — 검증 직후 §2-1 재조회 없이 결과를 해석하지
않는다"를 원칙으로 덧붙여 둔다.

## 8. 구조 변경의 범위 (H)

**결정: 서버 크론(3시간)과 클라이언트 WorkManager 등록 주기(3시간)는
바꾸지 않는다. 그 안의 게이팅 값만 조정 가능하게 만든다.**

**근거 — 두 상수는 "바꾸기 어렵다" 정도가 아니라 "바꾸는 동작 자체가
위험하다":**

- **클라이언트**: `main.dart:132`의
  `existingWorkPolicy: ExistingPeriodicWorkPolicy.keep`이 의도적으로
  선택돼 있다. 주석(`main.dart:129-131`)이 이유를 직접 설명한다 —
  "앱을 열 때마다 replace하면 주기가 계속 리셋되어 영영 실행되지
  않는다." 즉 WorkManager periodic task의 `frequency`를 런타임에
  바꾸려면 `replace` 정책으로 전환해야 하는데, 이는 이미 한 번
  회피된 문제를 다시 불러들이는 것이다. 이 상수는 손대지 않는다.
- **서버**: `onSchedule({schedule: "every 3 hours", ...})`
  (`index.ts:1330-1331`)은 Cloud Scheduler 잡 자체라 바꾸려면 함수
  재배포가 필요하고, uid별로 다른 크론을 가질 수도 없다(크론은 uid
  단위가 아니라 함수 단위).

**대신 이미 있는 게이팅 지점에 조정값을 얹는다:**

- **클라이언트** — `BackgroundAgent.shouldRunNow`
  (`background_agent.dart:36-46`)는 이미 `minInterval`을 인자로 받는
  구조다(`@visibleForTesting`, 기본값 `_minInterval`=10시간). 호출부
  (`background_agent.dart:187-189`)가 이미 읽어 둔 `meta`에서
  `adjustedIntervalHours`를 꺼내 넘기기만 하면 된다 — **함수
  시그니처를 안 바꿔도 되는 최소 변경.**
- **서버** — `runScheduledCheckCore`(`index.ts:1276`)에는 아직 이런
  게이트가 없다(현재는 `findNextUntriggeredDate`만으로 발화 여부를
  정한다 — 대상 날짜에 추천이 이미 있으면 안 보내고, 없으면 매
  3시간 틱마다 계속 보낸다). `serverLastRunAt`(이미 기록 중,
  `index.ts:1254`)과 `adjustedIntervalHours`를 비교하는 조건을
  `findNextUntriggeredDate` 호출 앞에 추가한다 — **새 필드 없이
  기존 `serverLastRunAt`을 재사용.**

**판정은 어디서 하는가 — 클라이언트에서만 한다, 중복 구현하지
않는다.** `AgentPlanner.runProactiveCheck`(추천 생성 "브레인")가
이미 클라이언트에만 있고 서버는 발송만 담당하는 구조(FCM 탭 처리 시
서버가 아니라 클라이언트가 `runProactiveCheck`를 도는 것과 같은
분업, `fcm_service.dart:46-51` 주석)를 그대로 따른다. `§5`의
`judgeCadence`도 클라이언트(`BackgroundAgent.run`)에서만 호출하고,
그 결과(`adjustedIntervalHours`)만 `agent_meta`에 써서 서버가
읽어가게 한다 — TS로 같은 로직을 다시 구현하지 않는다(로직 두 벌이
갈리는 위험, §4-2가 지적한 것과 같은 종류의 위험을 새로 만들지
않기 위함).

### 8-1. [갱신 2026-08-15] 착수 전 확인 — 서버 게이트 없이 성립하는가, 그리고 구현

**질문**: 클라이언트만 조정값을 읽는 지금 상태에서, 실제로 관측
가능한 알림 빈도가 줄어드는가?

**코드로 확인한 결과 — 성립하지 않는다.**

1. **`shouldRunNow`의 `minInterval`은 `adjustedIntervalHours`를
   읽는다** — 1단계(b) 3/5(`a0fd97a`)에서 이미 배선함. 확인.
2. **서버 발화(FCM)와 클라이언트 자체 발화(WorkManager)는 서로
   다른 게이트를 지난다:**
   - 클라이언트 주기 실행(`BackgroundAgent.run`, WorkManager가
     3시간마다 틱) — `shouldRunNow(minInterval: adjustedIntervalHours)`를
     지난다. 스킵되면 `AgentPlanner.runProactiveCheck`도, 로컬 알림
     (`NotificationService.showRecommendationReady`)도 안 뜬다 —
     **이 경로는 조정이 실제로 막는다.**
   - 서버 발화(`scheduledProactiveCheck` → `runScheduledCheckCore`) —
     **변경 전에는 `adjustedIntervalHours`를 전혀 참조하지 않았다.**
     `findNextUntriggeredDate`(대상 날짜에 추천이 이미 있는지)로만
     발화 여부를 정하고, 있으면 매 3시간 틱마다 계속 FCM을 보낸다.
   - FCM 탭 처리(`fcm_service.dart`의 `_handleMessageTap`)도
     `AgentPlanner.runProactiveCheck`를 직접 부를 뿐 `shouldRunNow`를
     거치지 않는다 — 애초에 이 경로는 "주기적 확인"이 아니라 "탭에
     대한 즉시 반응"이라 간격 개념 자체가 적용 대상이 아니다(별도
     쟁점 아님, 명시만 해 둔다).
3. **서버가 3시간마다 보내는 알림은 클라이언트 게이트와 완전히
   무관하게 도착한다(변경 전 기준).** §9-3의 실기기 검증에서 실제로
   관측한 알림(`"코디 추천 — 다가오는 일정에 맞는 코디를 준비했어요"`,
   `channel=agent_recommendation`)이 바로 이 서버 발화 경로다 —
   즉 **시연에서 실제로 보이는 알림이 조정과 무관한 경로였다.**

**판단 — 사용자가 예고한 "후자"였다, 서버 게이트를 이번에 함께
구현한다.** 로그에는 "6시간으로 조정합니다"가 뜨는데 실제 알림은
그대로 3시간마다 온다면, 이번 트랙의 목적("판단이 관찰 가능한 형태로
드러나게 한다")과 정면으로 어긋나는 상태로 배포하는 것이다. 구현
범위가 크지 않고(§8이 이미 설계해 둔 지점에 조건 하나를 추가하는
정도) 클라이언트 판정 로직을 서버에 복제하지 않아도 되므로(§8
"판정은 클라이언트에서만" 원칙 유지), 이번에 함께 구현한다.

**구현 — §8 원 설계에서 한 가지 정정.** 원 설계는 "기존
`serverLastRunAt`을 재사용"이라고 적었으나, 실제로 그 필드는
`recordServerInvocation`이 **매 호출마다(발화 여부와 무관하게)**
갱신하는 "마지막 체크인 시각"이었다 — 이걸 그대로 쓰면 3시간마다
갱신되는 값과 3시간 간격을 비교하는 셈이라 게이트가 사실상
항상 무력화된다. 대신 **새 필드 `serverLastSentAt`**(실제 발송을
시도했을 때만, 즉 `sendResult`가 있을 때만 기록)을 추가했다 —
`functions/src/index.ts`의 `recordServerInvocation` 안, 기존
`serverInvocationLog`·`serverLastRunAt` 쓰기와 같은 트랜잭션에
얹었다(새 쓰기 왕복 없음).

판정 자체는 `functions/src/cadence_gate.ts`에 순수 함수
`evaluateCadenceGate`로 분리했다(rate_limit.ts의 `evaluateRateLimit`과
같은 결 — Firestore/시각 의존 없이 단위 테스트). `index.ts`의
`isCadenceGateBlocking`은 Firestore 읽기만 하는 얇은 래퍼다.
`adjustedIntervalHours`/`serverLastSentAt` 중 하나라도 없으면(아직
한 번도 조정 안 됨, 또는 한 번도 발송 안 함) 항상 통과시킨다 —
이 기능 도입 이전과 diff 0. 단위 테스트 6건(경계값 포함) 통과,
`tsc --noEmit`·`npm test` 전체 통과.

**등록만 하는 한계 — onCall 응답만으로는 사유가 안 갈린다.**
`triggerScheduledCheckTest`의 `{"triggered":false}}` 응답은 "대상
날짜 없음"과 "간격 게이트로 보류"를 구분하지 않는다(§9-3의 최초
발화 실패 조사에서 이미 겪은 것과 같은 한계). 구분하려면 Cloud
Functions 로그의 `cadenceGate로 보류` 줄을 봐야 한다 — 이 줄을
새로 추가했다.

## 9. 검증 설계

### 9-0. 배포 전 확인 — 구버전 클라이언트 호환성 (2026-08-15, 코드 확인만)

서버를 먼저 배포하면(§9-1) 구버전 앱(아직 `pushId`를 모르는 클라이언트)과
신버전 서버가 잠시 공존한다. `pushId`는 FCM data 페이로드에 새로
추가되는 필드이므로, 구버전 클라이언트가 이 필드를 만났을 때 문제가
없는지 코드로 확인했다.

**`_handleMessageTap`(`fcm_service.dart:165-215`)이 `message.data`에서
읽는 키는 정확히 셋뿐이다** — `source`(181행), `targetDate`(182행,
디버그 출력용 문자열 보간), 그리고 이번에 추가한 `pushId`(195행).
**맵 전체를 순회하거나 알려지지 않은 키를 검사해 분기하는 코드는
없다** — `message.data`는 `Map<String, dynamic>`이고, 구버전 코드는
`pushId`라는 키 자체를 참조하지 않으므로 존재해도 완전히 무시된다.
알 수 없는 키가 있을 때 분기가 달라지는 경로는 코드 전체에 없음을
확인했다(같은 파일 전체 재검토).

네이티브 계층도 확인했다 — `android/`에 `FirebaseMessagingService`를
상속한 커스텀 코드가 없다(grep 0건). FCM data 페이로드 파싱은 전부
`firebase_messaging` Flutter 플러그인이 처리하고, 이 저장소는 그
위에 별도 검사를 얹지 않는다.

**결론: 문제없음.** 구버전 클라이언트가 신버전 서버의 알림을 받아도
기존 동작(§0가 인용한 diff 0 요구)이 그대로 유지된다 — `pushId`는
구버전 코드 입장에서 존재하지 않는 것과 동일하게 취급된다. 서버 먼저
배포하는 순서를 그대로 진행한다.

### 9-1. (b) 구현 시 적용할 단위 테스트 설계 (사전 등록, 아직 미구현)

- **판정 함수 단위 테스트**(`test/cadence_policy_test.dart`) — 경계값
  포함: `sampleSize` 4/5 경계, `noResponseCount` 2/3 경계,
  `acceptedCount` 2/3 경계, 상한(12h)·하한(3h) 클램프, 두 조건이
  동시에 성립할 수 없음을 확인(무반응 3건과 채택 3건은 5건 표본에서
  동시 성립 불가 — 이걸 코드가 아니라 테스트로 못박아 둔다).
- **반응률 산출부 단위 테스트**(`test/response_signal_test.dart`) —
  N=72시간 경계, `dismissed=true` 제외, 정렬 기준(최근 5건이 실제로
  "생성 시각 기준 최근"인지).
- **정책 객체 주입 A/B** — `TpoMatchPolicy` 방식을 따른다. 기본값을
  현행(조정 없음, 항상 3시간)과 동일하게 두어 **diff 0을 먼저
  확인**한 뒤, 정책을 조정형으로 바꿔 diff가 §7 표의 값과 일치하는지
  확인한다.
- **실기기 검증 항목**((b) 구현 후 별도 지시서에서 구체화):
  1. ~~`serverTapLog`/`serverInvocationLog`에 `pushId`가 실제로 같은
     값으로 남는지~~ — **(a) 구현으로 이미 착수, 결과는 §9-3.**
  2. §7 체크리스트대로 확정 3회 후 실기기에서 간격 축소 로그
     확인.
  3. `agent_meta.adjustedIntervalHours`가 바뀐 뒤 클라이언트
     `shouldRunNow`와 서버 게이트 양쪽이 새 값을 실제로 읽는지.

### 9-2. (a) 서버 배포 로그 확인 (2026-08-15)

`firebase deploy --only functions --project ai-fashion-assistant-personal`
실행. hardening 트랙 §2 절차를 그대로 따른다.

- **delete 라인 0건 — 확인.** 로그 전체에 delete 계열 라인 없음.
- **update 대상 정확히 9개 — 확인.** `sendTestPush` / `callGeminiText`
  / `getSignedImageUrls` / `scheduledProactiveCheck` /
  `triggerScheduledCheckTest` / `beginFittingAttempt` /
  `generateFittingImage` / `revokeTokenOnUpload` / `sweepStorageTokens`
  전부 "Successful update operation". `bg_removal_on_upload`(별도
  코드베이스, 이번 변경과 무관)는 "Skipped (No changes detected)".
- **함수 개수 배포 전후 동일 — 확인(간접).** delete·create 라인이
  0건이므로(전부 update 또는 skip) 논리적으로 성립한다(S1 배포 때와
  같은 근거 구조).

이 시점부터 커밋 `76a2cf0`(`feat: 발송-탭 매칭 계측(pushId) 배선 -
발화 정책 자기 조정 1단계(a)`)이 가리키는 코드가 프로덕션에 떠 있다
— 배포 후 커밋(hardening S1과 같은 패턴).

### 9-3. (a) 실기기 매칭 확인 — 완료(2026-08-15)

§0 승계 규약대로 설치 시각·커밋 해시 대조, 콜드스타트/백그라운드
두 경로 각각의 매칭 결과를 여기 기록한다. 아래 체크리스트가 전부
채워지기 전까지 (b) 착수하지 않는다.

- [x] **앱 재빌드·설치·`lastUpdateTime` 대조 — 통과(2026-08-15).**
      대상 커밋 `76a2cf0`. `flutter build apk --release`(130.2초) →
      `adb install -r`(`04:24:06Z`~`04:24:34Z`) → 기기(`R3CW10DF8CW`)
      `dumpsys package`의 `lastUpdateTime=2026-08-15 13:24:34`(KST,
      UTC+9 → `04:24:34Z`) — 설치 완료 시각과 정확히 일치.
- [x] **서버 발화 알림 1건 수신 — 통과, 단 우회 조사 필요했음.**
      최초 시도(`triggerScheduledCheckTest`, `04:27:14Z`)는
      `{"triggered":false}` — 원인 조사(읽기 전용) 결과 이 uid
      (`BDDOIl08...`)의 향후 4일 캘린더에 `planned` 일정이 아예
      없었다(응답만으로는 "일정 없음"과 "이미 추천 있어 막힘"이
      구분되지 않는다는 점도 여기 기록해 둔다 — 둘 다 `triggered:false`
      로 뭉뚱그려진다). 사용자가 2026-08-16 '일상' 일정을 앱에서
      직접 생성 → 재호출(`04:29:59Z`) → `{"triggered":true,
      "targetDate":"2026-08-16"}`.
- [x] **`serverInvocationLog`에 `pushId` 기록 — 확인.** 최신 항목:
      `{triggered: true, at: 04:29:59.614Z, successCount: 1,
      failureCount: 5, pushId: 'e5c1751c-64a2-46c1-8b49-f37d9d278578'}`.
- [x] **발송 직후 `serverTapLog` 빈 상태 — 확인.** 탭 전이므로
      `length=0` — 계측이 탭 없이 조기 기록되지 않음을 확인(설계대로).
- [x] **알림 탭 — 백그라운드(경로 1)·콜드스타트(경로 2) 둘 다 통과.**
      §9-3-b·§9-3-c 참고.
- [x] **`serverTapLog` pushId 일치 — 두 경로 모두 확인.** §9-3-b(경로 1),
      §9-3-c(경로 2), 서로 다른 pushId로 각각 별도 엔트리 확인.
- [x] **콜드스타트/백그라운드 두 경로 각각의 결과 기록 — 완료.**
      §9-3-d 종합표 참고. 편향 없이 둘 다 통과.

### 9-3-a. 알림 미수신 진단 (2026-08-15, 읽기 전용 + 로그 조회)

발송 성공(`successCount:1`)이 기록됐으나 기기에 알림이 뜨지 않았다.
사용자 지시대로 네 갈래를 추정 없이 확인했다.

**1) 토큰 대조 — 성공한 토큰이 이 기기 것인가: 확인, 맞다.**
`cleanupInvalidTokens`가 실패 5건을 삭제한 뒤 `fcm_tokens`
서브컬렉션에 **정확히 1개**만 남았고, 그 `updatedAt`(`04:26:05.950Z`)이
이번 세션 앱 재기동(§9-3 첫 항목, `04:25:57Z` 실행) 직후 토큰 갱신
시각과 일치한다 — 남은 토큰이 지금 이 기기의 것이라는 뜻이다(제거법:
6개 중 5개가 사라졌고 남은 1개의 시각이 이 기기 재기동과 맞는다).
부수 관측 — 삭제된 5개와 남은 1개가 앞 12자리(`fUdrx8A9Q0yp`)를
공유한다. FCM 토큰이 `<Firebase Installation ID>:APA91b...` 구조를
쓰므로, 이 기기에서 반복 재설치해 온 이력(이 저장소의 알려진 패턴)과
부합한다 — 다른 기기가 아니라 **같은 기기의 이전 설치 회차들이
쌓아 둔 죽은 토큰**이라는 뜻이다.

**2) 실패 5건의 사유 — 확인, 전부 `messaging/registration-token-not-registered`.**
Cloud Functions 로그(`firebase functions:log --only
triggerScheduledCheckTest`) 조회 결과:
```
04:29:59.468~612Z [fcmTokenCleanup] 삭제 uid=BDDOIl08... token=fUdrx8A9Q0yp... code=messaging/registration-token-not-registered  (5회)
04:29:59.702Z [C단계] uid=BDDOIl08... targetDate=2026-08-16 triggered=true tokenCount=6 successCount=1 failureCount=5
```
전부 삭제 대상(`fcm_token_cleanup.ts`의 `DELETE` 판정) 사유였고
잔여 토큰 가설과 일치한다 — 다른 원인(자격 증명, 페이로드 형식 등)은
아니다.

**3) 기기 쪽 확인 — 부분적으로 불가능, 정직하게 미확인으로 남긴다.**
- 알림 권한(`POST_NOTIFICATIONS`): **확인, `granted=true`.** 재설치가
  런타임 권한을 초기화하지 않았다(`adb install -r`는 업데이트로
  취급돼 권한이 보존됨).
- 알림 채널(`agent_recommendation`): **확인, 정상.** `dumpsys
  notification`에서 `importance=DEFAULT userSet=true`(앱 레벨),
  채널 `mImportance=3`(DEFAULT), `mDeleted=false` — 차단된 상태가
  아니다.
- **logcat으로 "메시지가 기기까지 도달했는가"는 확인할 수 없었다
  — 로그 버퍼가 이미 순환되어 해당 시간대(04:25~04:30Z)가 남아있지
  않다.** 조회 시점(04:32Z 이후)의 3000줄 버퍼가 담은 범위는
  `04:32:27Z`부터였다 — 이 기기의 통신 관련 로그 볼륨이 매우 높아
  (텔레포니 상태 로그가 수 초 간격으로 찍힘) 5분 남짓한 창이 이미
  밀려났다. **"도달했는데 안 떴다"와 "아예 도달 안 했다"를 로그로는
  가르지 못한다 — 추정하지 않고 미확인으로 남긴다.**

**4) 토큰 갱신 시점 — 확인, 발송보다 먼저였다(이 갈래는 원인이
아니다).** 토큰 갱신 `04:26:05.950Z` < 발송 `04:29:59.614Z` — 서버가
발송 시점에 이미 새 토큰을 알고 있었다. "서버가 구 토큰으로 보냈다"
가설은 이걸로 배제된다.

**정리 — 네 갈래 중 원인 확정은 없다, 다만 유력한 가설 하나는
등록해 둔다(미확정).** 1·2·4는 전부 "정상"으로 확인됐고 3(권한·채널)도
정상이다. 원인 후보를 좁히는 유일한 단서는 **코드 자체의 알려진
설계**다 — `fcm_service.dart:46-51`의 주석이 "포그라운드 수신
(`onMessage`)은 의도적으로 안 넣는다"고 명시한다. FCM의
`notification`+`data` 혼합 페이로드는 **앱이 포그라운드에 떠 있으면
시스템이 알림 트레이에 아무것도 안 띄우고, 이 앱은 그 경우를 처리할
핸들러도 없다.** 이번 발송 직전(`04:25:57Z`~`04:26:05Z`) 이 세션이
직접 앱을 `adb shell am start`로 띄웠고, 발송 시각(`04:29:59Z`)까지
약 4분 사이 앱이 포그라운드에 계속 있었을 가능성이 있다 —
**다만 이 시간대 화면 상태(켜짐/꺼짐)를 로그로 확인하지 못해 확정할
수 없다.** 조회 시점(수 분 뒤)에는 앱이 이미 백그라운드였음을
확인했으나(`topResumedActivity`가 런처), 이건 "지금" 상태이지
"발송 당시" 상태의 증거가 아니다. **가설로만 등록하고 사실로
주장하지 않는다.**

### 9-3-b. 재발화 — 포그라운드 억제 가설 검증 및 경로 1(백그라운드) 확인 (2026-08-15)

**화면 상태를 발송 전후로 직접 기록**(§9-3-a가 못 남긴 것을 이번엔
남긴다):
- 발송 전(`04:36:50Z`): `topResumedActivity`=런처, `mWakefulness=Awake`.
- 발송 직후(`04:37:03Z`, 호출 완료 5초 후): `topResumedActivity`=런처
  (그대로). **앱이 발송 전후로 계속 백그라운드였음을 확인.**

`triggerScheduledCheckTest` 재호출(`04:36:57Z`) → `{"triggered":true,
"targetDate":"2026-08-16"}` — 직전 발송이 이력으로 남아 재발화를
막지 않음을 확인(추천 문서가 아직 안 생겼으므로 당연한 결과).

**포그라운드 억제 가설 — 기각.** `adb logcat -c`로 버퍼를 비운 뒤
바로 발화, 8초 후 덤프한 로그에 다음이 그대로 잡혔다:
```
13:36:58.157 NotificationManager: com.fashionai.ai_fashion_assistant: notify(0, FCM-Notification:345203475, channel=agent_recommendation ...)
13:36:58.412 HoneySpace.NotificationListener: onNotificationPosted com.fashionai.ai_fashion_assistant
13:36:58.422 InterruptionStateProvider: no Heads up : edgelighting enabled app
```
앱이 확인된 백그라운드 상태에서도 시스템이 알림을 정상 게시했고
상태바 아이콘도 붙었다(`StatusBarIconView` 다수 관측). `"no Heads up:
edgelighting enabled app"`은 이 기기(삼성) 엣지 라이팅 기능이 팝업
배너만 억제한다는 뜻이지 알림 자체를 없애는 게 아니다 — §9-3-a의
가설(포그라운드였을 가능성)은 **이번 회차에서는 성립하지 않음이
확인됐다.** 단, §9-3-a의 "미확인"은 그대로 유지한다(그때 확인 못
한 걸 지금 확인했다고 해서 그때도 그랬다는 증거는 아니다).

**pushId**: `8410e37d-7d5a-47e6-b636-a00043805eec`
(`successCount:1, failureCount:0` — 죽은 토큰이 이미 정리되어 이번엔
깨끗했다).

**경로 1(백그라운드) 탭 — 통과, 매칭 확인.** 사용자가 알림창을 내려
직접 탭. 결과:
```
serverTapLog = [{'pushId': '8410e37d-7d5a-47e6-b636-a00043805eec',
                 'tappedAt': 2026-08-15 04:38:10.254759+00:00,
                 'isColdStart': False}]
```
`serverInvocationLog` 최신 항목의 `pushId`와 **정확히 일치** — 이번
계측(§3)의 핵심 판정("두 값이 실제로 일치하는가")이 경로 1에서
처음으로 실측 통과했다. `serverTapCount`도 1로 증가, `serverTapAt`도
같은 시각대로 기록됨 — 기존 계측(§3-1 결함 이전부터 있던 필드)과
새 계측이 서로 모순 없이 병존한다.

**부수 효과 — 탭이 추천을 실제로 생성했다.** 탭은 `isColdStart=false`
경로라 `AgentPlanner.runProactiveCheck(uid)`가 그대로 실행됐고,
2026-08-16(KST) 대상 추천 `hzamK0D31UtkGfYYkWNt`이 생성됐다
(`targetDate=2026-08-15T15:00:00Z` = KST 08-16 자정, `dismissed=False`).
**이 부수 효과가 경로 2(콜드스타트) 검증의 전제를 바꾼다** — 재확인
결과(`04:38:52Z`) `{"triggered":false}`: 2026-08-16 슬롯이 이제
"이미 처리됨"으로 막혀, 같은 날짜로는 다시 발화시킬 수 없다. 경로 2를
보려면 **다른 날짜**의 새 캘린더 일정이 필요하다(§9-3-c에서 계속).

### 9-3-c. 경로 2(콜드스타트) 확인 (2026-08-15)

사용자가 캘린더에 2026-08-18 '일상·모임' 일정을 추가(8/16과 겹치지
않는 날짜 — §9-3-b가 요구한 조건).

**앱 완전 종료 확인 — 통과.** 사용자가 최근 앱 목록에서 스와이프
종료. 발화 전(`04:41:42Z`) `adb shell pidof
com.fashionai.ai_fashion_assistant` 결과 **빈 값**(프로세스 없음) —
완전 종료를 직접 확인한 뒤에 발화를 진행했다.

`adb logcat -c` → `triggerScheduledCheckTest`(`04:41:48Z`) →
`{"triggered":true,"targetDate":"2026-08-18"}`.

**발송 직후(6초 후) 관측 — 프로세스는 다시 떴지만 화면은 안 떴다.**
`pidof`가 새 pid(`11491`)를 반환했다 — 이건 앱이 "열린" 것이 아니라
FCM data 메시지를 처리하는 백그라운드 서비스
(`FlutterFirebaseMessagingBackgroundService`)가 시스템에 의해
새로 뜬 것이다(Android가 FCM 수신 시 앱 프로세스를 최소한으로
깨우는 표준 동작). `topResumedActivity`는 계속 런처였다 — **Activity가
뜨지 않았다는 뜻**, 즉 이 시점까지는 여전히 "완전 종료"에 해당하는
상태였다. logcat에서 알림 게시도 재확인했다:
```
13:41:49.739 NotificationManager: com.fashionai.ai_fashion_assistant: notify(...) channel=agent_recommendation
13:41:49.971 HoneySpace.NotificationListener: onNotificationPosted com.fashionai.ai_fashion_assistant
```

**pushId**: `a682aee3-af36-44fe-90e8-cc4524f8189d`
(`successCount:1, failureCount:0`).

**사용자 탭 — 통과.** 사용자가 알림을 탭했고, 그 과정에서 로그인
화면을 거쳐 로그인했다고 보고했다(완전 종료 후 콜드스타트 특유의
UI 전이로 보이나, 정확한 원인은 이번 확인 범위 밖이라 등록만 한다
— 아래 매칭 결과가 uid 동일성을 이미 실측으로 확인해 주므로 원인
규명이 이 판정에 영향을 주지 않는다).

**매칭 결과 — 통과, `isColdStart=True`로 정확히 분기됨.**
```
serverTapLog[1] = {'pushId': 'a682aee3-af36-44fe-90e8-cc4524f8189d',
                    'tappedAt': 2026-08-15 04:42:46.197373+00:00,
                    'isColdStart': True}
```
`serverInvocationLog` 최신 항목의 `pushId`와 **정확히 일치**하고,
경로 1의 pushId(`8410e37d...`)와도 **명확히 구분되는 별도 엔트리**로
남았다(§9-3-b가 요구한 확인). `serverTapCount`도 2로 증가. 로그인
화면을 거쳤음에도 같은 uid(`BDDOIl08...`)의 `agent_meta` 문서에
정확히 기록됐다는 사실 자체가 **로그인 전환이 uid를 바꾸지 않았음을
실측으로 증명한다** — 별도로 uid를 대조할 필요가 없다.

### 9-3-d. §9-3 종합 — 경로 1·2 모두 통과

| 항목 | 경로 1(백그라운드) | 경로 2(콜드스타트) |
|---|---|---|
| pushId | `8410e37d-7d5a-47e6-b636-a00043805eec` | `a682aee3-af36-44fe-90e8-cc4524f8189d` |
| `serverInvocationLog` ↔ `serverTapLog` 일치 | ✅ | ✅ |
| `isColdStart` 값 | `False`(정확) | `True`(정확) |
| 알림 게시(logcat) | 확인 | 확인 |

**한쪽만 되는 편향은 관측되지 않았다.** §3에서 설계한 계측(서버
`pushId` 발급 → FCM data 페이로드 → 클라이언트 `serverTapLog` 회수)이
두 진입 경로 모두에서 diff 없이 동작함을 실기기로 확인했다 — §9-3
체크리스트 전항목 통과, (a) 검증 종료.

**부수 발견(등록만, 이번 트랙 범위 밖)**: §9-3-b의 최초 시도가
`triggered:false`로 실패했던 근본 원인(캘린더에 `planned` 일정이
없으면 서버 응답만으로 "일정 없음"과 "이미 처리됨"이 구분되지
않는다는 것, §9-3 두 번째 체크 항목)과, 이번 발견(탭이 부수 효과로
추천을 생성해 같은 날짜 재발화를 막는다는 것, §9-3-b)은 **둘 다
"발화 정책 자기 조정"(b)이 참조할 상태값과 직접 관련된다** — b의
판정 함수가 "최근 5건"을 셀 때 이런 상태 전이를 어떻게 다룰지는
§5-1(반응률 산출부)에서 이미 `dismissed=true` 제외를 명시했지만,
"발화 자체가 무반응 판정에 앞서 추천을 만들어버리는" 이번 관측은
새로 등록해 둘 가치가 있다 — (b) 설계 재확인 시 참고.

## 10. 커밋 분리

**(a)와 (b)는 별도 커밋으로 한다.**

- **(a)(계측)는 기록만 하고 아무것도 읽지 않는다** —
  `recordServerInvocation`/`_handleMessageTap`은 이번 변경으로
  쓰기 필드(`pushId`, `serverTapLog`)만 추가될 뿐, 판정 로직
  (`judgeCadence`, `shouldRunNow`, 서버 게이트)이 이 필드들을 읽는
  코드는 (b) 커밋에만 있다. 즉 (a) 단독으로 배포해도 발화 정책의
  동작은 배포 전후로 diff 0이다 — §9 정책 객체 주입 A/B의 "diff 0
  확인" 절차로 이를 배포 후 직접 검증한다.
- (a)가 먼저, (b)가 나중 — (b)의 1단계(§4-1)는 (a) 없이도 동작하므로
  순서를 바꿀 수도 있으나, §1의 "계측 먼저" 원칙을 그대로 따라
  (a)를 먼저 둔다. 회귀가 나면 커밋 하나만 되돌려 어느 쪽 원인인지
  가릴 수 있다.

## 11. 남는 미결정 (구현 승인 시 함께 확정)

- `response_signal.dart`/`cadence_policy.dart`의 정확한 파일 위치·
  네이밍은 구현 착수 시 재확인(현재는 설계 초안).
- §5-2 규칙 초안의 구체적 배수(2배/절반)·상하한(12h/3h)은 실기기
  검증(§9-1 "실기기 검증 항목" 2·3번) 결과를 보고 조정 여지를 열어
  두되, **조정 여부와 방향은
  결과를 보기 전에 이미 사전 등록된 이 문서의 규칙을 기준으로
  판단한다** — 결과가 마음에 안 든다고 규칙을 사후에 바꾸지 않는다.
