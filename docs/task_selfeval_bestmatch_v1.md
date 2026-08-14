# 작업 지시서 — 폴백 응답 후보의 최종 추천 구조적 우위 해소 (task_selfeval_bestmatch_v1)

`task_selfeval_followup_v1.md` §9(트랙 종결)·§10 "다음 트랙 후보 1.
[최우선]"과 `handoff_2026-08-07.md` §4·§6(G)가 등록만 하고 남겨둔
결함을 오늘(2026-08-14) 착수한다. 사용자 결정: (F)(주간 플랜 옷장
규모 상한)보다 먼저 — 이미 배포돼 매 추천에 영향 중인 문제가, 아직
안 온 문제보다 먼저라는 근거.

## 0. 승인된 설계 제약 (사용자, 2026-08-14 — 착수 전 등록)

**"할인"이 아니라 "제외".** `judgeCandidate`가 이미 화이트리스트로
판정(주 모델 응답만 신뢰)하는 것과 같은 방향 — 폴백 응답의 점수에
상수(Δ=9.85 등)를 더하거나 빼는 보정은 쓰지 않는다. **폴백 응답은
최종 추천(`bestMatch`) 경쟁에서 제외하되, 신뢰 후보가 하나도 없으면
그때만 임시로 채택한다.** 이 설계는 `task_selfeval_followup_v1.md`
§7 "제안(착수하지 않음, 승인 필요)"과 정확히 같다 — 오늘 그 제안이
승인됐다.

금지: 점수 보정, `judgeCandidate` 재구현(반드시 그 함수를 그대로
호출), 임계값·부등호 변경, 인위적 폴백/실패 유발.

## 1단계 — 현재 동작을 재는 장치 (측정 우선, §2 원칙 1)

### (a) 현재 `bestMatch` 선정 로직 — 지점 단위 열거

대상: `lib/services/outfit_self_evaluator.dart`, `OutfitSelfEvaluator.run`
(원본 후보 루프 210-271행, 진단-수리 재평가 273-359행).

1. **원본 후보 갱신(242-246행)**: 후보를 평가해 `text != null`(호출
   자체는 성공)이면, `score`(파싱 실패 시 0 취급)가 현재 `bestScore`
   (초기 null→0 취급)보다 **크기만 하면** `bestMatch`/`bestText`/
   `bestScore`를 덮어쓴다. **응답 모델이 무엇인지(`evalResult.model`)
   는 이 비교에 전혀 등장하지 않는다.**
2. **`judgeCandidate` 호출(251행)은 그 다음에 일어난다** — 즉
   `bestMatch`가 이미 갱신된 **뒤에** `passed`/`verdictWithheld`가
   계산된다. `passed`는 조기 종료(`break`, 263행) 여부만 결정하고,
   `verdictWithheld`는 진단-수리 진입 여부(278행 `!judgment.
   verdictWithheld` 게이트)만 결정한다 — **둘 다 이미 끝난 bestMatch
   갱신을 되돌리지 않는다.**
3. **수리 재평가 갱신(350-354행)도 같은 성질**: `repairedScore`가
   현재 `bestScore`보다 크면 무조건 덮어쓴다. `repairedJudgment.
   verdictWithheld`는 `repairNote` 문구 분기(340행)와 로그 문구에만
   쓰이고, 이 대입 자체를 막지 않는다.
4. **결과적으로**: 평가 루프에 참여한 후보 중 신뢰 여부와 무관하게
   **원점수가 가장 높은 후보가 항상 `bestMatch`가 된다.** 신뢰
   판정(`judgeCandidate`)은 "통과해서 조기 종료할지"와 "수리를
   시도할지"만 결정하고, "이 후보를 최종 추천으로 내보낼지"는 전혀
   결정하지 않는다.
5. **`bestMatch == null` 반환(362행)** 조건은 이 로직과 별개다 —
   `evaluated`가 0건(모든 Gemini 호출이 에러로 실패, `text == null`)
   일 때만 발생한다. 신뢰 여부는 이 조건에 관여하지 않는다 — 폴백
   응답이라도 `text != null`이면 `evaluated`가 증가하고 위 1·3의
   raw-max 비교 대상이 된다.
6. `repairNote`(347행)는 수리 분기에 진입해 재평가까지 마치면
   `repairedJudgment`와 무관하게 무조건 설정된다(이미
   `task_selfeval_followup_v1.md` §7 (a) 말미가 등록해 둔 사실 —
   여기서는 인용만, 2단계 (b)에서 함께 볼 것).

### (b) `judgeCandidate` 재사용 확인

`judgeCandidate({required int? score, required String?
respondingModel})`(133-141행)는 이미 원본 후보(251행)와 수리
재평가(330-331행) 양쪽에서 호출돼 `judgment`/`repairedJudgment`
변수에 담겨 있다 — **이 값을 새로 계산할 필요 없이 그대로
재사용**하면 된다. bestMatch 갱신 조건(242행, 350행)에
`!judgment.verdictWithheld`(또는 `!repairedJudgment.verdictWithheld`)
를 추가하는 것으로 충분해 보인다 — 재구현 없음.

주의: 원본 후보 쪽은 현재 `judgment` 계산(251행)이 bestMatch
갱신(242행) **뒤에** 있다 — 갱신 조건에 신뢰 여부를 넣으려면 순서를
바꾸거나(judgeCandidate를 먼저 호출), 이미 계산된 `evalResult.model`
로 `judgeCandidate`를 갱신 지점에서 먼저 부르는 방식 중 하나를
2단계에서 선택한다.

### (c) 기존 데이터로 빈도를 답할 수 있는지 — 확인함, 결론: 표본 부족

새 계측을 만들기 전에 기존 데이터로 답이 되는지 먼저 봤다(§2 원칙:
기존 데이터 먼저). 저장소 밖 서비스 계정 키로 프로덕션 Firestore를
**읽기만** 했다(쓰기 없음, `tools/score_distribution_report`와 같은
관례 — 스크립트 자체는 스크래치패드에 두고 저장소에 커밋하지
않았다, 1회성이라 §2 원칙에 맞는 상시 도구로 다듬을 필요는 없다고
판단).

**질의 1 — `users/*/recommendations`의 `candidateScores`/
`candidateModels`로, "현재 raw-max 로직이 실제로 폴백을 채택한
사례"를 재구성.**
- `candidateScores`가 있는 추천 문서: 75건(계정 3개).
- 그중 `candidateModels`가 병기되고 길이가 일치하는 문서: **4건뿐**
  — 이 필드가 `task_selfeval_validity_v1.md`(2026-08-11) 이후에야
  추가돼, 그 이전 71건은 판단 불가(구버전 문서).
- 4건 중 폴백 모델이 최종 채택(현재 로직 기준 argmax)된 사례: **0건**.
- **판정: n=4는 빈도를 잴 표본이 아니다(§2 원칙 6, 공허한 검증
  식별) — "폴백이 안 나온다"로 읽으면 안 되고 "이 경로로는 답이
  안 된다"로 기록한다.**

**질의 2 — `users/*/agent_logs`의 `candidate_evaluated` 이벤트,
`verdictWithheld` 필드로 표본을 넓힘.**
- `candidate_evaluated` 이벤트 총 154건(계정 3개), 기간
  2026-07-25 ~ 2026-08-13(약 3주).
- `verdictWithheld == true`(폴백 응답이라 판정 유보): **0건 / 154건
  (0.0%)**.
- **판정: n=154로 표본은 커졌지만, 이 3주 동안 자기평가 경로에서
  폴백이 자연 발생한 적이 실제로 한 번도 없었다는 뜻이다.**
  `task_selfeval_followup_v1.md` §8이 실기기 검증 중 자연 발생
  폴백을 못 봐 "미검증"으로 남긴 것과 정합적이다(그때 관찰된 폴백
  2건도 속성 추출 경로였지 자기평가 경로가 아니었다).
- **이걸 "버그가 무해하다"로 읽지 않는다.** `judgeCandidate` 자체가
  화이트리스트로 정확히 막고 있는 대상(주 모델 타임아웃/재시도
  가능 오류 시 폴백)이 이 관측 기간에 드물게만 발생했다는 뜻이지,
  구조적 결함(신뢰 판정이 최종 선택에 반영 안 됨)이 없다는 뜻이
  아니다 — 결함은 코드에 그대로 있고, 발현 조건(업스트림 불안정)이
  이 기간에 덜 걸렸을 뿐이다.

**결론: 기존 데이터로는 "얼마나 자주"에 답할 수 없다(표본 부족·
발현 자체가 희소).** 새 계측을 추가로 만들지는 않는다(사용자 지시
범위 밖, 오늘은 수정이 목적) — 대신 이 사실 자체("발현 빈도는
낮지만 구조적 결함은 확정돼 있다")를 판정 기준에 반영한다: **2단계
검증은 자연 발생 빈도에 기대지 않고 단위 테스트로 강제 재현해야
한다**(아래 §1(d) 기준 6).

## (d) 판정 기준 — 결과를 보기 전에 등록한다 (§2 원칙 2)

수정 후 아래 전부가 성립해야 "됐다"로 본다:

1. **원본 후보(242-246행 대응 지점)와 수리 재평가(350-354행 대응
   지점) 양쪽 다** bestMatch 갱신 조건에 신뢰 판정이 반영돼야 한다
   — 한쪽만 고치면 미완료.
2. 신뢰 후보(`judgeCandidate(...).verdictWithheld == false`)가
   평가 루프 안에 하나 이상 있으면, **`bestMatch`는 반드시 신뢰
   후보 중 최댓값이어야 한다.** 신뢰 후보보다 점수가 높은 폴백
   후보가 있어도 `bestMatch`가 그 폴백 후보가 되면 안 된다.
3. 신뢰 후보가 **하나도 없고** 평가가 1건 이상 성공했다면(즉
   `evaluated > 0`), 그때만 폴백 후보 중 최댓값을 `bestMatch`로
   임시 채택한다 — **그리고 이 사실이 결과에 남아야 한다**(콜백
   인자나 `SelfEvalOutcome` 필드 등, 형태는 2단계에서 정함. 최소
   요건은 "이 채택이 신뢰 판정 없이 이뤄졌다"를 호출부가 구분할
   수 있어야 한다는 것 — `judgeCandidate`의 `verdictWithheld`가
   이미 같은 구분을 판정 단계에서 하고 있으므로 그 패턴을 따른다).
4. `bestMatch == null` 반환 조건(362행, 모든 호출이 에러로 실패)은
   **바뀌지 않는다** — 신뢰 여부와 무관하게 응답이 하나라도 있으면
   여전히 non-null을 반환해야 한다. 이 변경이 "판정 불가라 아예
   못 씀"이라는 새 실패 모드를 만들면 안 된다(재시도 태스크 생성
   경로, `wardrobe_screen.dart:99-108`와 맞물림 — §10 인계가 이미
   지적).
5. **정상 경로 회귀 없음**: 평가된 후보 전부가 주 모델로 응답하는
   흔한 경우(관측 154/154), 결과는 기존 raw-max 비교와 **완전히
   동일**해야 한다(모든 후보가 신뢰되면 새 로직도 raw-max와 동치).
6. **단위 테스트로 강제 재현**(§1(c)가 확인했듯 자연 발생이
   희소하므로, 실기기 자연 발생에 기대지 않는다): 최소
   - (i) 폴백 후보가 최고점, 신뢰 후보가 존재 → **신뢰 후보가
     채택됨**을 직접 검증.
   - (ii) 신뢰 후보가 0개(전부 폴백) → 최고점 폴백 후보가 임시
     채택되고, 그 사실이 구분 가능함을 직접 검증.
   - (iii) 기존 회귀 테스트 전량(`outfit_self_evaluator_verdict_test.dart`
     8건) 통과.
7. `flutter analyze` 경고 0건.
8. `repairNote`가 판정 유보 상태에서도 붙는 문제(§1(a)-6 인용)는
   이번 수정으로 자연히 닫히는지 확인하고, 닫히면 §4 등록 시 함께
   기록, 안 닫히면 별도 결함으로 등록만 하고 손대지 않는다(2단계
   (b), 사용자 지시).

## 1단계 결론

측정 장치(§1(a) 지점 열거) 확보, 재사용 대상(§1(b)) 확인, 기존
데이터 조회(§1(c), 표본 부족으로 빈도는 미확정이나 구조적 결함은
코드 확인으로 이미 확정) 완료, 판정 기준(§1(d)) 사전 등록 완료.

**[정정 등록, 2026-08-14]** (G)를 (F)보다 먼저 고른 근거("이미
배포돼 매 추천에 영향 중")를 정정한다. §1(c) 실측대로 최근 3주
(154건)간 자기평가 경로에서 폴백 발현은 0건이다 — "매 추천에
영향"이 아니라 "폴백이 걸릴 때만 영향이고, 이 기간엔 안 걸렸다"가
정확하다. **그럼에도 진행하는 근거**: `task_selfeval_validity_v1.md`
§6-가가 2026-08-12에 별도 측정 하네스 실행 중 5분 3초 구간에서
폴백률이 60%(20건 중 12건)까지 튄 사례를 실측해 뒀다(그 앞뒤
8/1~8/11 구간은 0~4.9%로 일관되게 낮았다 — 상승은 이 짧은 창에만
몰려 있었다, 원인 미확정: 외부 수요 급증 vs 하네스의 연속 호출
유발 효과). 이 관측 자체는 자기평가 경로가 아니라 같은 프록시
(`callGeminiText`)를 쓰는 별도 하네스의 호출이었다는 점을 밝히고
인용한다 — 그대로 같다고 단정하지 않는다. 다만 **평시 0, 업스트림이
아플 때 몰아서 튀는 패턴**이라는 점에서, 이 결함이 실제로 작동하는
조건(폴백 발생)과 실패가 몰리는 조건이 겹친다 — 무작위 희소가
아니라 "아플 때 함께 아픈" 구조라 희소성만으로 후순위로 미루지
않는다. `handoff_2026-08-07.md` §6(G)에도 같은 정정을 등록했다
(원문은 보존, 정정 블록만 추가).

## 2단계 — 수정 (2026-08-14)

### (a)(c) 설계 구현 — 순서 재배치, 최소 변경으로 진행

§1(b)가 이미 확인한 대로, `judgeCandidate`가 필요로 하는 입력
(`score`, `evalResult.model`)은 원본 후보의 bestMatch 갱신 지점
(구 242행)보다 **먼저** 확정돼 있었다 — `judgeCandidate`는 순수
함수라 호출 시점을 옮겨도 이후 읽는 지점(`passed`/`verdictWithheld`
쓰임, §1(a) 열거 5곳) 값은 전혀 바뀌지 않는다. 수리 재평가 경로는
`repairedJudgment`가 애초에 bestMatch 덮어쓰기 지점보다 먼저
계산돼 있어 재배치가 필요 없었다(조건 추가만). **파급이 사실상
0으로 확인돼(§1(b) 예상대로), "순서를 그대로 두고 필요한 정보만
따로 읽는" 대안과 비교해 제시할 실익이 없다고 판단해 곧바로
재배치로 진행했다**(지시 "파급이 작으면 순서 재배치로 그대로
진행하라"에 따름).

`bestMatch`/`bestScore`/`bestText`와 함께 `bestIsTrusted`(현재
최선이 신뢰 후보로 채워졌는지)를 추적하고, 순수 함수
`OutfitSelfEvaluator.shouldReplaceBest`로 갱신 판정을 뽑았다
(`judgeCandidate`와 같은 이유 — `run()`은 Gemini를 호출해 직접
단위 테스트할 수 없다):

```dart
static bool shouldReplaceBest({
  required bool hasCurrentBest,
  required bool currentBestTrusted,
  required int currentBestScore,
  required bool candidateTrusted,
  required int candidateScore,
}) {
  if (!hasCurrentBest) return true;
  if (candidateTrusted && !currentBestTrusted) return true;
  if (candidateTrusted != currentBestTrusted) return false;
  return candidateScore > currentBestScore;
}
```

신뢰 후보는 항상 미신뢰 후보를 이기고(점수 무관), 같은 신뢰
등급끼리는 기존과 동일하게 원점수 최댓값으로 비교한다 — 점수에
상수를 더하거나 빼는 보정은 쓰지 않는다(금지 사항 준수). 원본
후보(구 242-246행)와 수리 재평가(구 350-354행) 두 지점 모두 이
함수로 판정한다 — 앞선 트랙(`task_selfeval_followup_v1`)이 수리
재평가 자리를 빠뜨려 반쪽이 됐던 전례를 반복하지 않는다.

`bestMatch == null` 반환 조건(모든 호출이 에러로 실패한 경우)은
손대지 않았다 — `shouldReplaceBest`는 `hasCurrentBest`가 false일 때
무조건 true를 반환하므로, 응답이 하나라도 있으면(신뢰 여부 무관)
여전히 non-null을 반환한다.

### (b) 임시 채택 기록

`SelfEvalOutcome.bestMatchUntrusted`(bool, 신뢰 후보 없이 임시
채택됐으면 true)를 추가했다. `RecommendationEntry.bestMatchUntrusted`
로 Firestore까지 전파해(sparse write, `isFallback`/`repairAttempted`와
같은 관례 — true일 때만 씀) 나중에 스크립트로 셀 수 있게 했다.
`agent_planner.dart`의 `recommendation_registered` 로그 메시지 두
곳(선제 추천, 새 옷 등록) 모두에 `bestMatchUntrusted`일 때만
" (신뢰 후보 없음 — 판정 보류된 조합을 임시로 등록)"을 덧붙였다 —
판정 경로가 "판정 불가(대체 모델 응답)"를 로그에 남기는 것과 같은
원칙.

### (c) 수리 재평가 경로 — 함께 적용

`repairedTrusted`를 계산해 원본과 동일하게 `shouldReplaceBest`로
판정한다(§ (a) 코드에 포함). `task_selfeval_followup_v1.md` §7(a)가
지목한 "수리 재평가는 bestScore 원점수만으로 덮어쓴다" 결함이 이
지점에서 함께 닫혔다.

### (d) repairNote — 별도 결함으로 등록만, 손대지 않음

`repairNote`(수리 시도 시 "OO 교체(축 개선)" 문구)는 신뢰 여부와
무관하게 수리 재평가 응답이 오면 무조건 설정되는 별도 지점이다 —
이번 수정이 자연히 닫히는 지점이 아니다(bestMatch 갱신과는 독립된
코드 경로). 사용자 지시대로 손대지 않고 코드 주석과 이 문서에만
등록한다. 남은 결함: 판정 유보된 수리 결과에도 "다듬었다"는
확정적 문구가 붙을 수 있다(`task_selfeval_followup_v1.md` §7(a)
말미가 이미 등록해 둔 내용과 동일).

### (e) 단위 테스트

`test/outfit_self_evaluator_verdict_test.dart`에 `shouldReplaceBest`
그룹 6건 추가(기존 `judgeCandidate` 8건은 그대로 유지) — 핵심
케이스: 폴백이 최고점이어도 신뢰 후보가 있으면 안 밀림(이번 수정의
핵심, 구 로직은 반대로 동작했다), 신뢰 후보가 나중에 나오면 점수
무관 즉시 교체, 같은 신뢰 등급끼리는 기존과 동일한 원점수 비교
(회귀 없음), 신뢰 후보가 0개면 그때만 폴백 최댓값 임시 채택.

### (f) 검증

`flutter analyze` — 이슈 0건. `flutter test` — 전량(179개) 통과,
회귀 없음.

## 2단계 결론

수정 완료, 커밋(`ea99d1f`) 완료.

## 3단계 — 실기기 정상 경로 회귀 확인 (2026-08-14, 사용자 승인 후)

**전제**: 이번 변경은 폴백이 없으면 아무것도 바꾸지 않는 설계다 —
정상 경로의 기대 결과는 "예전과 완전히 동일". 확인 목적은 "새
동작이 잘 도는가"가 아니라 "아무것도 안 달라졌는가"다.

### (a)(b) 빌드·설치·대조

`flutter build apk --debug` 완료(Gradle 약 40초) → `adb -s
R3CW10DF8CW install -r` 성공. `dumpsys package
com.fashionai.ai_fashion_assistant`:
`lastUpdateTime=2026-08-14 12:07:16`(기기 로컬, KST). 대상 커밋
`ea99d1f`의 커밋 시각 `2026-08-14T11:56:53+09:00`. 설치 시각이
커밋보다 약 10분 23초 뒤 — 커밋 → 빌드(약 40초) → 설치 소요와
정합적이다. **대조 통과.**

### 트리거 경위 — 정확한 조작 경위 불확실, 결과는 Firestore 실측으로 확인

옷장 화면에서 "+"(신규 등록) 버튼을 한 번 탭한 직후, 이 기기로
실제 전화(무관한 통화)가 걸려와 화면을 덮었다 — 통화 종료 후
확인해 보니 사진 선택·등록 확인 등 후속 탭을 추가로 하지 않았음에도
새 옷 등록이 이미 완료돼 있었다(옷장 141벌, 신규 항목 "화이트
상의" 2026.08.14). **탭 이후 등록 완료까지의 정확한 사용자 조작
경위는 확인하지 못했다** — 통화 인터럽트와 시점이 겹쳐 중간
과정을 직접 보지 못했다(§2 원칙 13, 안 한 것을 했다고 쓰지 않는다
— 그래서 이 문단을 남긴다). 다만 결과 자체는 **인위로 조작하지
않은 Firestore 실측**으로 확인된다: `new_item_detected`
(12:09:35 KST) → `candidates_generated` → `candidate_evaluated`
→ `recommendation_registered`(12:09:44 KST)까지 정상 파이프라인이
자연히 완주했고, 이는 이번 검증이 필요로 한 표준 트리거(새 옷
등록)와 정확히 같은 결과다 — 인위로 폴백·실패를 유발하지 않았다는
금지 사항과 배치되지 않는다.

### (c) 홈 화면 추천 정상 생성 — 통과

새로 등록된 흰 상의("I own my youth")를 반영한 새 코디 카드가
홈 화면 "오늘의 추천 코디"에 표시됨을 스크린샷으로 확인.

### (d) agent_logs 문구 대조 — 기존 형식과 완전히 동일, 통과

Firestore Admin SDK로 직접 조회(읽기 전용):

```
{"eventType":"new_item_detected","message":"새 옷(화이트 상의) 등록을 감지했습니다"}
{"eventType":"candidates_generated","message":"옷장 140벌과 대조해 후보 3개 조합을 생성했습니다"}
{"eventType":"candidate_evaluated","message":"후보 1 평가 중..."}
{"eventType":"candidate_evaluated","message":"후보 1 평가: 75점 — 기준(70점) 통과, 채택"}
{"eventType":"recommendation_registered","message":"옷장 분석으로 75점 조합을 추천으로 등록했습니다"}
```

`task_selfeval_followup_v1.md` §8(c)이 이전 검증(대상 커밋
`db75aa0`)에서 확인한 것과 **글자 하나 다르지 않다** — "후보 1
평가: 75점 — 기준(70점) 통과, 채택", "옷장 분석으로 75점 조합을
추천으로 등록했습니다" 형식 동일. `(신뢰 후보 없음 — 판정 보류된
조합을 임시로 등록)` 접미사도 붙지 않았다 — `bestMatchUntrusted`가
false이므로 붙지 않는 게 설계대로다(아래 (e)).

### (e) `bestMatchUntrusted` — false 경로 확인, true 경로는 미검증(설계대로)

새 recommendations 문서(`oFuNAW3kuMKaaeEj7p6M`)를 직접 조회:
`candidateModels=['gemini-3.5-flash']`(주 모델), `candidateScores=[75]`,
`evaluatedCount=1`. **`bestMatchUntrusted` 필드 자체가 문서에
없다(`None`)** — `RecommendationEntry.toFirestore()`의 sparse-write
설계(`if (bestMatchUntrusted) ...`, `isFallback`/`repairAttempted`와
같은 관례) 그대로다. 필드 부재는 `fromFirestore`가 `false`로
복원하므로, **이 문서 기준으로는 "false로 정확히 기록된 것"과
동일하게 동작함을 실측으로 확인했다.** 다만 이번에도 폴백이 안
걸려 `bestMatchUntrusted=true`가 실제로 필드로 **나타나는** 경로는
관찰하지 못했다 — **미검증으로 남긴다**(인위 유발 금지).

### (f) `verdictWithheld` — false로 정확히 해석됨, 이전과 동일 패턴

`candidate_evaluated` 이벤트에 `verdictWithheld` 필드가 없다
(`None`) → 기존 설계(참일 때만 씀) 그대로, `false`로 복원된다.
`task_selfeval_followup_v1.md` §8(d)가 확인한 것과 같은 패턴 —
회귀 없음.

### (g) 자기 수리 — 자연히 안 나옴, 미검증

후보 1이 첫 시도에서 바로 통과(75점 ≥ 70점)해 나머지 후보도
진단-수리 루프도 돌지 않았다(`evaluatedCount=1`,
`repairAttempted` 필드 없음). 이전 검증들과 같은 패턴 — 억지로
미달을 만들지 않았으므로 **미검증으로 남긴다.**

### 3단계 결론

**정상 경로 회귀 없음 — (c)(d)(f) 통과, (e)는 false 경로만 확인
(true 경로 미검증), (g) 미검증(자연 미발생).** 신뢰 판정 게이팅
자체(폴백이 실제로 걸렸을 때의 동작)는 여전히 미검증 상태로
남아 있다 — 3주 154건 관측 0건인 현상이라 인위로 만들지 않았다
(사용자 지시).
