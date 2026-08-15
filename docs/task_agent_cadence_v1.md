# 작업 지시서 — 발화 정책 자기 조정 + 반응 계측 (task_agent_cadence_v1)

**이번 커밋은 설계 등록만 한다. 구현은 승인 후.** 아래 §2의 실측(표본
카운트)만 예외 — 읽기 전용 쿼리로, 설계 자체(§6·§8)가 그 결과에
의존하므로 승인 전에 먼저 실행했다.

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

## 3. (a) 발송-탭 매칭 계측

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
보장한다**(§5-2). §2 실측이 이를 실측으로 뒷받침한다:

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

이 시점부터 커밋 `(§9-4에서 기록)`이 가리키는 코드가 프로덕션에
떠 있다 — 아직 로컬 커밋은 안 한 상태다(hardening S1과 같은 패턴,
배포가 커밋보다 먼저).

### 9-3. (a) 실기기 매칭 확인 — 대기 중

§0 승계 규약대로 설치 시각·커밋 해시 대조, 콜드스타트/백그라운드
두 경로 각각의 매칭 결과를 여기 기록한다. 아래 체크리스트가 전부
채워지기 전까지 (b) 착수하지 않는다.

- [ ] 앱 재빌드(`flutter build apk --release`)·설치·`lastUpdateTime`
      대조
- [ ] 서버 발화 알림 1건 수신(자연 발화 또는
      `triggerScheduledCheckTest` — 어느 쪽이든 `runScheduledCheckCore`를
      공유하므로 `pushId` 발급 경로는 동일함을 코드로 이미 확인,
      §9-2 위 목록 참고)
- [ ] 알림 탭(콜드스타트 1회, 백그라운드 생존 중 1회 — 두 경로 각각)
- [ ] `serverInvocationLog` 최신 항목의 `pushId` 확인
- [ ] `serverTapLog`에 같은 `pushId`가 기록됐는지 확인 — **두 값
      일치 여부가 이 계측의 전부**
- [ ] 콜드스타트/백그라운드 두 경로 각각의 결과를 사실대로 기록
      (한쪽만 되면 그것도 결과 — 고치기 전에 등록)

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
