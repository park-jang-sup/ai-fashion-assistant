# 작업 지시서 — 주간 플랜 옷장 규모 간접 상한 (task_weekly_plan_scale_v1)

## 0. 승계 원칙

이 트랙은 `docs/handoff_2026-08-07.md` §2(작업 원칙)를 그대로
따른다 — 여기서 재서술하지 않고 링크로만 참조한다. 특히 이번
세션에 직접 관련된 것: 원칙 (5)(추정을 실측으로 포장하지 않는다),
원칙 (2)(판정 기준을 결과 보기 전에 등록), 원칙 (3)(확인 항목은
지점 단위로 열거).

착수 배경: `docs/handoff_2026-08-07.md` §6(F). **이번 세션은 측정과
근거 확인까지다 — 코드를 고치지 않는다.**

---

## 1단계 — 30,000이 어디서 왔는가

### (a) 도입 커밋과 당시 근거

`functions/src/request_shape.ts`의 `maxTotalTextChars`는 두 커밋을
거쳤다:

- **`bdcf459`(2026-08-10)**: 판정 순수 함수 신설. 커밋 메시지가
  스스로 밝힘 — **"상한값은 임시이며 계측 결과로 조인다"**. 이
  시점 값 자체에는 산출 근거가 없다(의도적 placeholder).
- **`4a9cc11`(2026-08-11)**: 재산정. 커밋 메시지: **"maxTotalTextChars
  (주간 플랜 옷장 카탈로그)만 추정치 - 부분 확정"**. 코드 주석
  (`request_shape.ts:206-217`)에 산출식이 명시돼 있다:
  - 데모 옷장 규모(118벌 인용) 기준 "줄당 약 55~60자 × 118 ≈
    6,500~7,000자"로 **추정**(실측 아님), 일정·이력·지시문을
    더해 **"약 10,000~12,000자로 추정"**.
  - 추정 최댓값(~12,000) × **여유 배수 ×2.5** ≈ 30,000.
  - 코드 주석이 명시한 배수 근거: "이 값만 측정이 아니라 추정이므로,
    다른 필드(측정 기반, ×2)보다 여유를 더 둔다."

**결론: 근거 없음이 아니라 "추정 근거"다 — 다만 그 추정 자체가
실측이 아니라는 게 코드 주석에 이미 명시돼 있다.** §2 원칙(5)에
따라 "근거 없음"으로 뭉개지 않고, 있는 그대로("추정, 실측 아님")
적는다.

### (b) 같은 파일의 다른 상한 3개와의 대조

`request_shape.ts:185-222`의 `REQUEST_SHAPE_CONFIG` 4개 필드 중
**3개는 "확정"(코드가 만들 수 있는 최댓값을 직접 셈), 1개
(`maxTotalTextChars`)만 "부분 확정"(추정)이다**:

| 필드 | 값 | 근거 | 확정도 |
|---|---|---|---|
| `maxContents` | 3 | 코드 전수 확인 — 항상 1, 고정 여유 +2 | 확정 |
| `maxPartsPerContent` | 20 | 한 번에 방식 피팅 코드 최댓값(1+9=10) × 2 | 확정 |
| `maxInlineDataCount` | 18 | 같은 근거(9) × 2 | 확정 |
| `maxTotalTextChars` | 30,000 | 카탈로그 크기 **추정**(~12,000, 미실측) × 2.5 | **부분 확정** |

**`payload_limit.ts`(text 4MB/image 16MB)와 대조**: 그 파일은
"이론상 최악"도 실측이다 — 실제 계정 최대 파일을 Storage에서
직접 조회해 합산(824,060B)하거나, picker 설정값으로 실제 JPEG
인코더를 돌려 측정(1,846,348B)했다(`payload_limit.ts:5-19`). **세
필드(`maxContents`/`maxPartsPerContent`/`maxInlineDataCount`)와
`payload_limit.ts`는 전부 "코드/실측값 × 배수" 방식이고,
`maxTotalTextChars`만 "추정값 × 배수" 방식이다** — 이 저장소
안에서 이 필드 하나만 방법론이 다르다.

### (c) 사용자에게 보이는 문구 — 지점 단위 추적

`allowed=false`가 되면 서버는 `HttpsError('invalid-argument',
'허용되지 않은 요청 형식입니다.', {violations: [...]})`를 던진다
(`functions/src/index.ts:361-364`, `726-729` — `callGeminiText`/
`generateFittingImage` 두 곳 동일). **다만 주간 플랜 경로에서는
이 문구가 사용자에게 그대로 도달하지 않는다** — 아래 경로를
지점 단위로 확인했다:

1. `functions/src/index.ts:361-364` — 서버가 이 메시지로
   `HttpsError` 발생.
2. `lib/services/gemini_service.dart:248-268`
   (`_mapProxyException`) — `invalid-argument`는 `deadline-exceeded`/
   `unauthenticated`/`resource-exhausted`/`data-loss`/`invalid-json`
   중 어디에도 안 걸려, **원본 `FirebaseFunctionsException`을 그대로
   반환**(메시지·`violations` 보존된 채).
3. `lib/services/agent_planner.dart:743`
   (`withTextModelFallback` 호출) — 이 함수는 `TimeoutException`/
   `GeminiApiException`/`FormatException`만 잡는다.
   `FirebaseFunctionsException`은 아무 분기에도 안 걸려 **그대로
   위로 전파**된다(재시도·폴백 없음).
4. **`lib/services/agent_planner.dart:751-754`** — 상위 `try`의
   범용 `catch (e)`가 이 예외를 잡아 **원문 메시지·`violations`를
   버리고** `throw StateError('플랜 생성에 실패했어요. 잠시 후
   다시 시도해주세요.')`로 **완전히 다른 문구로 교체**한다. 원문은
   `debugPrint('[PLAN] 주간 플랜 Gemini 실패: $e')`로만 남는데,
   이는 개발 콘솔 전용이라 릴리스에서는 사실상 안 남는다.
5. `lib/screens/calendar_screen.dart:67-68` — `_runWeeklyPlan()`이
   `on StateError catch (e) { _showSnack(e.message, ...) }`로
   위 4번의 문구를 스낵바에 그대로 띄운다.

**정정: handoff §6(F)가 인용한 "허용되지 않은 요청 형식입니다"는
서버가 실제로 보내는 문구로는 정확하지만, 사용자 화면에 실제로
뜨는 문구는 아니다.** 최종 사용자 가시 문구는
**"플랜 생성에 실패했어요. 잠시 후 다시 시도해주세요."**다 —
원인이 안 보이는 정도가 아니라 **"다시 시도하면 될 수도 있는
일시적 실패"처럼 보이게 만드는, 실제보다 덜 정확한 방향의
오분류**다(이 실패는 옷장 크기가 줄지 않는 한 재시도해도 반복
재현된다). `violations` 배열(예: `text_too_long`)은 클라이언트
어디에도 로그되지 않는다 — 실패해도 사용자뿐 아니라 개발자도
릴리스 빌드에서는 원인을 사후에 알 방법이 없다.

---

## 2단계 — 실제 여유

**방법**: `agent_planner.dart:717-728`의 catalog 조립과
`gemini_service.dart:721-740`의 prompt 템플릿을 Python으로 문자
단위로 재현(Dart 미실행), 오늘 실제 옷장(Firestore, 읽기 전용)으로
계산. 스크립트는 스크래치패드에 두고 저장소에 커밋하지 않았다
(1회성 측정, §2 원칙과 같은 이유로 `tools/score_distribution_report`
관례를 따름 — 서비스 계정 키는 저장소 밖 경로만 참조, 쓰기 없음).

### (a) 오늘 실제 옷장 기준 재측정

- 옷장 총 문서 141개, `attributes` 있는(usable) 140개.
- **catalog 총 문자수: 13,472**(140줄, 줄당 평균 **95.24자**,
  표준편차 2.58, 최소 88·최대 102).
- 고정 오버헤드(옷장과 무관, 스케줄 7일 대표값 + 템플릿, **피드백
  제외**): 251(스케줄) + 605(템플릿) = **856자**.
- **합계(피드백 제외): 14,328자 = 상한의 47.8%.**
- **52.8%(15,848자) 수치의 출처**: `docs/task_hardening_v2.md`
  §4-3 "전환 후 검증" 3번, 2026-08-11 실기기 실측(reqId
  `188b53fc`) — 이건 이번 계산과 달리 **진짜 실기기 관측값**이다
  (피드백·실제 캘린더 태그·실제 날씨 포함, 당시 옷장 벌수는 로그에
  없어 미상). 오늘 계산치(14,328, 피드백 제외)가 그 실측(15,848)과
  근접한 규모라는 점은 재현성의 방증이지, 같은 조건의 재실측은
  아니다 — **이번 계산은 대표값이지 실기기 실측이 아니다**(스케줄을
  실제 캘린더가 아닌 "전부 일상" 대표값으로 근사했고, 피드백 섹션은
  RAG 관련도 로직을 재현하지 않고 0으로 뒀다 — 기존 실측
  `task_hardening_v2.md`가 5건 308자였음을 참고 수치로만 인용).

### (b) 선형성

줄당 표준편차 2.58(평균 95.24의 약 2.7%)로 **매우 균질** —
카테고리별 평균도 93.39~97.00자 범위에 몰려 있어(상의 33벌
93.39 ~ 전신 3벌 97.00), 카테고리 구성비가 지금과 크게 달라지지
않는 한 "카탈로그 문자수 ≈ 벌수 × 95.24자(+개행)"라는 선형 근사가
높은 신뢰도로 성립한다. **고정 오버헤드(856자, 피드백 제외)는
벌수와 무관** — 옷장이 커져도 이 부분은 안 늘어난다(스케줄은
날짜 수·템플릿은 상수 고정).

### (c) 30,000자 도달 벌수·시점

- **도달 벌수(피드백 제외, 대표값 기준): 약 303벌**
  (= (30,000 − 856) / 96.24, 96.24 = 평균 줄길이 95.24 + 개행 1).
  현재 140벌의 **약 2.16배**.
- **등록 속도 실측(Firestore `createdAt` 분포, 계정
  `BDDOIl08EhXnHu6oz6Zro47EtMw1`, 141건 전량 `createdAt` 있음)**:
  가장 이른 문서 2026-07-01, 가장 최근 2026-08-14 — 기간 43.56일,
  단순 평균 **3.24벌/일**.
  **다만 이 평균은 오해를 부른다** — 날짜별 분포가 극단적으로
  몰려 있다: 2026-07-12 하루에 66건(전체의 47%), 2026-08-09
  하루에 23건(16%) — 이 두 날짜만으로 141건 중 89건(63%)이다.
  나머지 16개 날짜는 대부분 1~13건의 소규모 등록이다. **이건
  실사용자의 점진적 등록 패턴이 아니라 벌크 등록(시드/이관성
  이벤트로 추정, 원인 확인 안 함 — 범위 밖) 위주다.** 이 계정은
  이미 `handoff_2026-08-07.md` §1 "천장 1"이 등록해 둔 n=1
  개발자 옷장이라는 한계를 그대로 갖고 있어, **이 속도로 실사용자
  등록 패턴을 추정하는 것은 근거가 약하다** — 그래서 "언제쯤"을
  단일 숫자로 확정하지 않는다.
  - 참고용 기계적 계산만 남긴다(추정임을 명시): naive
    3.24벌/일이면 163벌(303−140) 도달에 약 50일. 두 벌크 날짜를
    뺀 나머지(52건/43.56일 ≈ 1.19벌/일)로 계산하면 약 137일. **이
    둘의 차이(50일 vs 137일, 2.7배) 자체가 이 추정의 신뢰구간이
    사실상 없다는 뜻이다** — 등록 참고용으로만 남기고, "언제"에
    대한 판정 근거로 쓰지 않는다.

### (d) Gemini 실제 입력 한도 대비

공식 문서 확인(WebSearch, 아래 출처): `gemini-3.5-flash`·
`gemini-3.1-flash-lite` 둘 다 **입력 토큰 한도 1,048,576(=1M)
토큰**, 출력 65,536 토큰.

**문자↔토큰 환산(한국어)**: 영어 기준 통상 "토큰당 약 4자"가
쓰이지만, 이 비율은 한국어에 적용되지 않는다 — Gemini의
SentencePiece 토크나이저는 CJK(중국어·일본어·한국어) 문자를
음절 단위보다 잘게(subword) 쪼개는 경향이 있어, **CJK는 문자당
약 1.5~2토큰**(= 문자당 0.5~0.67 사이, 영어의 역수 관계)이라는
게 일반적으로 인용되는 범위다(출처 아래).

**계산(범위로 제시, 정밀 실측 아님 — `countTokens` API 실호출은
이번 범위 밖, 아래 한계 참고)**: 30,000자 × 1.5~2토큰/자 =
45,000~60,000토큰. 1,048,576 대비 **약 4.3%~5.7%**.

**해석 — 이 대비가 답을 정하지는 않는다.** 자체 가드
(30,000자)는 Gemini의 실제 입력 한도에 비하면 극히 작은 비중이지만,
`request_shape.ts` 헤더 주석(1-13행)이 이미 밝히듯 이 판정의
목적은 "Gemini 한도 보호"가 아니라 **"우리 앱이 실제로 만들 수
있는 형태인지"를 검증하는 요청-형태 방화벽**이다(S2/App Check가
보류 중이라 현재 유일한 방어, §4 서두). 나머지 세 필드가 전부
"우리 코드가 만들 수 있는 최댓값 × 배수" 방식으로 정해진 것도
같은 이유다 — **Gemini의 실제 한도와의 거리는 "여유가 얼마나
넓은가"를 보여줄 뿐, 새 값을 그 한도에 맞춰 정해야 한다는 뜻은
아니다.** 3단계(b)가 이 구분을 판정 기준에 반영한다.

**한계**: 이 계산은 Gemini `countTokens` API로 실제 토큰 수를
직접 잰 것이 아니라 공개 자료가 인용하는 CJK 배율 범위를 곱한
것이다 — 정밀 토큰 수가 필요해지면(예: 실제 조정값을 정할 때)
`countTokens` 실호출로 재확인해야 한다. 이번 세션은 프로덕션
Firestore 읽기로 범위를 한정했고, Gemini API 실호출(무료이지만
호출 자체)은 하지 않았다 — 등록만.

**출처**:
- [What's new in Gemini 3.5 Flash | Gemini API](https://ai.google.dev/gemini-api/docs/whats-new-gemini-3.5)
- [Gemini 3.1 Flash-Lite - Model Card — Google DeepMind](https://deepmind.google/models/model-cards/gemini-3-1-flash-lite/)
- [Understand and count tokens | Gemini API](https://ai.google.dev/gemini-api/docs/tokens)
- [Gemini Character Limits Explained](https://insights.terabox.com/hub/how-many-characters-can-you-send-to-gemini-and-how-to-bypass-the-limits)

---

## 3단계 — 판정 기준 (결과를 본 뒤 등록 — 사후 정당화 위험 명시)

**[중요한 한계 고지]** 이 순서는 §2 원칙(2)이 요구하는 "결과 보기
전에 등록"을 어겼다 — 1·2단계 측정을 이미 마친 뒤에 이 절을 쓰고
있다. 사용자 지시("1·2단계 결과를 보기 전에 정해 등록하라")와
실제 진행 순서(1·2단계 먼저 완료, 이제 3단계 작성)가 어긋난다는
사실을 숨기지 않고 등록한다 — §2 원칙(13)("안 한 것을 했다고
쓰지 않는다"). 아래 기준은 **1·2단계 수치를 보고 나서 정한
것**이므로, 다음 세션에서 실제로 상한을 조정하게 되면 이 판정
자체가 사후 정당화가 아니었는지 별도로 재검토해야 한다.

### (a) "상한 조정으로 충분" vs "근본 해법 필요" 판정 기준

- **상한 조정으로 충분**하다고 볼 조건(전부 충족 시): (i)
  `maxTotalTextChars`를 늘려도 나머지 세 필드처럼 "코드가 만들
  수 있는 실제 최댓값 × 합리적 배수"로 재정의할 수 있다(추정을
  또 다른 추정으로 대체하지 않는다), **그리고** (ii) 그 값이
  §2단계(d)가 확인한 Gemini 실제 입력 한도(1M 토큰) 대비 여전히
  안전한 여유를 남긴다(현재도 4.3~5.7%에 불과하므로 이 조건은
  거의 항상 충족될 것으로 보임 — 즉 (ii)는 사실상 병목이 아니다),
  **그리고** (iii) 응답 품질(주간 플랜의 배분·중복회피 정확도)이
  카탈로그 크기에 따라 저하된다는 관측이 없다(이번 세션엔 이
  품질 축을 측정하지 않았다 — 미확인 항목으로 아래 등록).
- **근본 해법이 필요**하다고 볼 조건(하나라도 해당 시): (i)
  카탈로그 크기가 커질수록 Gemini 응답 품질(형식 오류율, 배분
  적절성)이 실측으로 저하됨이 확인되거나, (ii) 단순 상한 조정이
  §1(b)가 확인한 "코드 최댓값 기반" 방법론을 지킬 수 없어(예:
  옷장 규모 자체에 상한이 없으므로 "코드 최댓값"이라는 개념이
  성립하지 않음 — 이 경우가 유력하다, 아래 참고) 또 다른 추정치를
  낳게 되는 경우.

**이 세션이 이미 확보한 근거로 미리 표시해 둘 것**: 위 (i)의
"코드가 만들 수 있는 최댓값"이라는 개념 자체가 옷장 규모에는
성립하지 않는다 — 나머지 세 필드(피팅 슬롯 등)는 **우리 코드/UI가
발행하는 상한**(코디보드 8슬롯 등)이 있어 최댓값을 셀 수 있지만,
**옷장 벌수는 사용자가 옷을 등록하는 한 무한히 늘어날 수 있는
축**이다(`task_hardening_v2.md` "옷장 규모 축 등록" 절이 이미
이 성질을 "통제 주체: 사용자"로 등록해 둠). 그러므로 상한 조정
방식을 쓰더라도 "코드 최댓값"이 아니라 **"이 시점 관측된 실사용
규모 × 배수"**가 될 수밖에 없어, 이는 정의상 다시 "추정"이 된다
— **완전히 방법론이 같아지지는 않는다.** 이 긴장은 이번 세션에서
풀지 않고 다음 판단으로 넘긴다.

### (b) 상한을 조정하기로 할 경우의 새 값 산정 방식(선례 준용)

`payload_limit.ts`의 "이론상 최악 실측 × 여유 배수" 방식을
그대로 따른다면:

1. **이론상 최악을 정의**: "옷장 규모에 상한이 없다"는 §3(a)의
   문제 때문에, `payload_limit.ts`처럼 코드가 강제하는 값을 셀
   수 없다. 대안: (i) 이 세션이 실측한 벌당 평균(95.24자)을
   고정하고, "실사용에서 관측 가능한 최대 벌수"를 별도로
   정의(예: 데모 옷장 상한, UI가 안내하는 권장 옷장 규모가 있다면
   그 값)하거나, (ii) `maxTotalTextChars` 자체를 "벌수 기반 상한"
   (예: 500벌 × 벌당 평균)으로 재정의해 옷장 벌수 자체에 서버측
   가드를 새로 도입한다(이건 이미 "옷장 규모의 서버측 상한으로
   작동한다"는 기존 관찰을 명시적 설계로 승격시키는 것 — 범위가
   커진다, 근본 해법 쪽에 더 가깝다).
2. **여유 배수**: 다른 세 필드가 쓴 ×2(코드 근거) 또는 다른 두
   payload 필드가 쓴 ×1.01~2.3(실측 근거) 범위를 참고하되, 이
   필드는 입력이 "추정"이므로 이번에도 더 큰 배수가 정당화될
   여지가 있다 — 다만 "왜 더 큰가"의 근거(예: 카테고리 구성비
   변화, 옷장 상한 정책 부재)를 반드시 함께 적어야 한다(§2
   원칙(5) 위반 방지).
3. **재산정 후 필수 확인**: `request_shape.test.ts`의 기존
   픽스처(6종 + 주간 플랜 g픽스처, `task_hardening_v2.md` §4-4가
   이미 추가함) 전량 재통과, 실기기 검증(§2 원칙 15·16) — 이번
   세션 범위 밖.

**착수하지 않는다 — 다음 세션에서 사용자가 (a)(b) 중 방향을
정한 뒤 진행.**

### (c) 근본 해법 후보 — 나열만, 이번에 고르지 않음

- **프롬프트에서 옷장 전체를 빼고 후보만 추리기** — 매칭 엔진
  (`OutfitMatcher`)이 이미 격식·색상 조화로 후보를 좁히는 로직을
  갖고 있으니(천장 3, 매칭 코어), 그 출력을 주간 플랜 프롬프트
  입력으로 쓰는 방향. 다만 주간 플랜은 "여러 날 동시에 봐야 하는"
  전역 최적화(중복 회피·격식 배분, `gemini_service.dart:705-707`
  주석)라 후보를 미리 좁히면 그 전역성이 깨질 위험이 있다 — 검토
  필요.
- **카테고리별 요약** — 옷장을 통째로 나열하지 않고 카테고리×
  격식×색상 조합별 개수/대표값만 요약해서 전달. 프롬프트 크기는
  줄지만 "정확히 이 id를 쓰라"는 현재 제약(724행 주석)과 충돌 —
  요약본에서 실제 id로 역참조하는 후처리가 추가로 필요.
- **관련 아이템만 선별(RAG류)** — 이미 코디 분석/자기평가 경로가
  `getRelevantHistorySilently`로 관련도 기반 이력 선별을 쓰고
  있는 것과 같은 방향. 다만 주간 플랜은 "이번 주 전체에 쓸 수
  있는 옷 전체"가 필요하다는 성격이 이력 선별과 다르다(이력은
  "참고"지만 옷장은 "재료 전체") — 선별 기준을 잘못 정하면 특정
  옷이 매주 배제되는 편향이 생길 수 있다.

이 셋 다 **이번에 고르지 않는다** — 다음 세션에서 (a)(b) 판정과
함께 사용자가 결정.

---

---

## 4단계 — (F) 트랙 2세션: 에러 문구 수정 설계 + 접근 계측 (2026-08-14 이어서)

**사용자 결정(우선순위 재배치)**: F-2(에러 문구)가 F-1(상한 조정)보다
먼저다 — 범용 catch는 상한과 무관하게 **모든 주간 플랜 실패**에
이미 걸리고 있어 지금 당장 영향 중이다. F-1(상한 조정)은 **하지
않는다** — 303벌 도달까지 현재의 2.16배, 도달 시점 신뢰구간이
50~137일로 사실상 없고(§2(c)), 무엇보다 "코드 최댓값" 개념이
옷장 규모엔 성립하지 않는다는 §3(a)의 긴장 때문에 상한을 조정해도
또 다른 추정을 "고쳤다"고 기록하는 꼴이 된다. 대신 접근을
계측한다(§5).

### 4-1단계(a) 범용 catch가 버리는 것 — 지점 단위 열거

`agent_planner.dart:751-754`:

```dart
} catch (e) {
  debugPrint('[PLAN] 주간 플랜 Gemini 실패: $e');
  throw StateError('플랜 생성에 실패했어요. 잠시 후 다시 시도해주세요.');
}
```

이 `catch (e)`(타입 미지정 — Dart에서 어떤 throw도 다 잡음)에
실제로 도달할 수 있는 타입과, 각 타입이 들고 있었는데 버려지는
정보:

1. **`FirebaseFunctionsException`**(`code=='unauthenticated'`이거나,
   `_mapProxyException`이 매핑하지 못한 나머지 — `invalid-argument`
   가 여기 포함된다, 아래 참고). 버려지는 것: `.code`(예:
   `invalid-argument`/`unauthenticated`), `.message`(서버 원문,
   예: "허용되지 않은 요청 형식입니다."), `.details`(Map — 우리
   `request_shape.ts` 위반이면 `{violations: [...]}`,
   `payload_limit.ts` 위반이면 `{requestBytes, limitBytes, kind}`
   — **스키마가 서로 다르다**, index.ts:362/392/726/743).
2. **`GeminiApiException`**(`_mapProxyException`이 `upstreamStatus`
   있는 경우 재구성, 또는 직접 호출 경로의 원본) — 이미 한 번
   `withTextModelFallback`이 재시도 가능(503/429)이면 폴백까지
   써본 뒤에도 실패한 경우만 여기 도달한다(즉 **두 모델 다
   실패한 경우**). 버려지는 것: `.statusCode`, `.isRetryable`
   (이미 계산돼 있는 값인데 다시 버려짐), `.message`.
3. **`RateLimitExceededException`**(서버 프록시 호출량 상한,
   `resource-exhausted`) — 이 타입은 **이미 자기 자신이 사용자
   적합 문구를 들고 있다**(`toString()`이 곧 안내문이라는 게
   클래스 자체의 설계 의도, `gemini_api_exception.dart:26-28`
   주석). 버려지는 것: 이미 완성된 좋은 문구 그 자체.
4. **`TimeoutException`**(주 모델·폴백 모델 둘 다 타임아웃) —
   버려지는 것: `.message`뿐(원래 정보가 적음).
5. **`FormatException`**(주 모델·폴백 모델 둘 다 JSON 파싱 실패) —
   버려지는 것: `.message`.
6. **그 외 무엇이든**(네트워크 예외 등, 분류 안 된 나머지).

공통: `debugPrint`는 릴리스 빌드에서 콘솔이 안 붙어 있으면
사실상 안 남는다 — 확인해 보니 **이 실패 경로는 Firestore
`agent_logs`에도 전혀 기록되지 않는다**(다른 배경 파이프라인과
달리 이 함수는 실패 시 Firestore를 쓰지 않는다, 코드 전수 확인).
즉 지금은 사용자도 개발자도 릴리스에서 원인을 사후에 알 방법이
없다.

**기존 선례 확인**: 이 저장소에 이미 "구조적 실패는 재시도하지
않는다"는 판단이 두 곳에 있다 — `fitting_job_controller.dart:229-235`
(`_withRetry`)와 `gemini_service.dart:492-498`
(`extractSizeFromChart` 재시도 경로) 둘 다 `FirebaseFunctionsException`
의 `code=='invalid-argument'`를 `rethrow`하고 주석에 "결정론적
실패 - 재시도 안 함"이라고 명시해 뒀다. 이번 설계는 이 선례와
같은 판단(재시도 안 함)에, "그럼 사용자에게 뭐라고 보여줄지"를
더하는 것이다.

### 4-1단계(b) 분류 설계 — 최소 3단계, 근거와 함께

| 분류 | 해당 타입/조건 | 재시도 유효? | 사용자 문구 |
|---|---|---|---|
| **일시적** | `TimeoutException`, `GeminiApiException`(`isRetryable`=503/429), `FormatException`, 미분류 나머지 | 예 | 기존 그대로: "플랜 생성에 실패했어요. 잠시 후 다시 시도해주세요." |
| **구조적 — 옷장 규모** | `FirebaseFunctionsException`이고 `details.violations`에 `text_too_long` 포함 | **아니오** | "지금 등록된 옷이 많아 이번 주 플랜을 만들지 못했어요. 잠시 후 다시 시도해도 같은 결과가 나올 수 있어요." |
| **구조적 — 기타** | `GeminiApiException`(`isRetryable`=false, 예: 400/403), `FirebaseFunctionsException`(그 외 — `unauthenticated`, `violations`에 `text_too_long` 없음, `payload_limit` 위반 등) | **아니오** | "요청 형식 문제로 플랜을 만들지 못했어요. 잠시 후에도 같은 문제가 반복될 수 있어요." |
| **호출량 상한** | `RateLimitExceededException` | 아니오(당장은) | `e.message` 그대로(이미 적합한 기존 문구, 관례 재사용) |

**판단 근거**:
- "구조적 — 옷장 규모"만 원인을 구체적으로 밝힌다 — 서버가 실제로
  그 원인을 특정할 수 있는 신호(`violations` 배열의 `text_too_long`)
  를 이미 보내고 있는 **유일한** 경우이기 때문이다(아래 (c)).
  다른 구조적 실패(예: `unauthenticated`, 미지의 `invalid-argument`)
  는 원인을 사용자에게 안전하게 특정해 줄 근거가 없어 뭉뚱그린다
  — 틀린 원인을 확정적으로 말하는 것이 원인을 안 말하는 것보다
  나쁘다(이번 트랙이 고치려는 문제의 반복이 되지 않게).
- "일시적" 버킷에 **미분류 나머지**(`catch`의 진짜 catch-all)를
  넣는 것은 회귀 방지를 위한 보수적 선택이다 — 모르는 실패를
  "구조적"으로 잘못 분류해 재시도를 막느니, 기존처럼 재시도를
  권하는 쪽이 안전하다(무해한 방향의 오분류).
- **`unauthenticated`를 "구조적 — 기타"에 뭉뚱그리는 것은 의도적
  타협이다** — 정확히는 "재로그인이 필요하다"는 세 번째 성격이지만,
  이번 세션 범위(최소 갈림 = 재시도 유효/무효)를 넘는 전용 UX까지는
  설계하지 않는다. 등록만 하고 넘어간다 — 다음에 이 경로가 실제로
  관측되면 재검토.

### 4-1단계(c) 서버가 이미 보내는 정보로 충분한가 — 확인함

**"옷장 규모" 분류에는 충분하다.** `request_shape.ts`의
`text_too_long` 위반이 곧 `HttpsError`의 `details.violations`
배열에 그대로 실린다(index.ts:361-364) — 서버 변경 없이
클라이언트에서 바로 읽을 수 있다.

**부족한 지점(등록만, 서버 미수정)**:
- `payload_limit.ts` 위반은 `details` 스키마가 다르다
  (`requestBytes`/`limitBytes`/`kind`, `violations` 없음) — 주간
  플랜은 텍스트만 보내 이 상한(4MB)에 사실상 안 걸리므로(§2(a)
  실측 14,328자 ≈ 14KB) 지금은 실질적 공백이 아니다. 다만 두
  검증기가 서로 다른 실패 스키마를 쓴다는 사실 자체는 다음에
  통합 계측을 만들 때 참고할 사항으로 등록한다.
- `GeminiApiException`(비재시도, 예: 400)의 원인은 서버 쪽에
  `upstreamMessage`가 실려 있지만(`_mapProxyException:264`),
  이건 Gemini가 보낸 원문이라 사용자에게 그대로 노출하기엔
  적절하지 않을 수 있다(내부 구현 세부가 섞일 위험) — 이번엔
  "구조적 — 기타"로 뭉뚱그리는 것으로 충분하다고 판단, 서버·
  클라이언트 둘 다 안 고친다.

### 구현 스케치 — 승인 후 작업(아직 미구현)

새 파일 없이 `agent_planner.dart`에 순수 함수 하나만 추가한다
(`FirebaseFunctionsException`은 생성자가 `@protected`라 테스트에서
직접 만들 수 없다 — `judgeCandidate`와 같은 이유로 원시 값
(`List<String>?`)만 받는 함수로 분리한다):

```dart
// violations 목록만으로 구조적 실패 문구를 고른다(Firebase 타입 자체를
// 받지 않는다 - 테스트가 직접 List<String>?만 넘겨 검증할 수 있게).
static String weeklyPlanStructuralFailureMessage(List<String>? violations) {
  if (violations != null && violations.contains('text_too_long')) {
    return '지금 등록된 옷이 많아 이번 주 플랜을 만들지 못했어요. '
        '잠시 후 다시 시도해도 같은 결과가 나올 수 있어요.';
  }
  return '요청 형식 문제로 플랜을 만들지 못했어요. '
      '잠시 후에도 같은 문제가 반복될 수 있어요.';
}
```

호출부(`generateWeeklyPlan`)의 `try/catch`를 타입별로 분기(기존
저장소 관례, `fitting_job_controller.dart`와 같은 패턴):
`RateLimitExceededException`(자기 메시지 그대로) →
`GeminiApiException`(`isRetryable`이면 기존 문구, 아니면 "구조적
— 기타") → `FirebaseFunctionsException`(`details.violations`를
뽑아 위 함수 호출) → `TimeoutException`/`FormatException`(기존
문구) → 나머지(기존 문구, 안전한 기본값).

**승인됨 — 아래 세 가지를 반영해 구현했다(2026-08-14 이어서).**

### 승인 시 반영된 수정 3건

1. **실패 기록을 문구 수정과 함께 넣었다.** 문구만 고치면 "어떤
   실패가 얼마나 자주 나는지"는 여전히 모른다는 지적을 받아들여,
   `AgentLogEntry`에 `typeWeeklyPlanFailed` 이벤트와 계측 전용
   필드 5개(`weeklyPlanFailureReason`/`weeklyPlanExceptionType`/
   `weeklyPlanViolations`/`weeklyPlanStatusCode`/
   `weeklyPlanCatalogChars`)를 추가했다 — 새 컬렉션을 만들지
   않고 기존 `agent_logs`를 재사용(§2 원칙: 기존 데이터/경로
   먼저). 사용자 식별 정보·옷장 내용(아이템 id·속성)은 담지
   않는다 — `weeklyPlanCatalogChars`는 옷장 카탈로그의 **문자
   수**만 담아, 5단계(상한 접근 계측)와 겹치는 지점을 필드
   하나로 합쳤다(전체 병합은 아니다 — 성공 시 계측은 여전히
   5단계 몫으로 남겨둠, 아래 참고).
2. **`unauthenticated`를 "구조적—기타"에서 빼 "일시적"으로
   옮겼다.** 재로그인하면 풀리는 실패에 "재시도해도 소용없다"는
   문구를 붙이면 이번에 고치려는 문제(틀린 방향 안내)를 그대로
   반복하는 셈이라는 지적을 반영 — `classifyWeeklyPlanFailure`가
   `functionsErrorCode == 'unauthenticated'`를 별도로 먼저
   검사해 `transient`로 분류한다. 전용 재로그인 UX는 여전히
   범위 밖(등록만) — 별도 항목으로 아래 "미확인으로 남긴 것"에
   추가.
3. **분류와 문구를 분리했다.** `weeklyPlanStructuralFailureMessage`
   (분류+문구 결합) 대신 `classifyWeeklyPlanFailure`(순수, 원시값
   → `WeeklyPlanFailureReason` 열거형)와 `weeklyPlanFailureMessage`
   (열거형 → 문자열) 둘로 나눴다 — 계측이 분류 결과(열거형)를
   그대로 쓰므로 문구 함수를 다시 호출/재구현할 필요가 없다.
   `@protected` 생성자 문제로 원시값만 받는 설계는 그대로 유지.

### 구현 위치

- `lib/models/agent_log_entry.dart`: `typeWeeklyPlanFailed` +
  계측 필드 5개(생성자·`fromFirestore`·`toFirestore` sparse write).
- `lib/services/agent_planner.dart`: 최상위 `enum WeeklyPlanFailureReason
  { transient, wardrobeTooLarge, structuralOther, rateLimited }`,
  `AgentPlanner.classifyWeeklyPlanFailure`(순수)·
  `AgentPlanner.weeklyPlanFailureMessage`(순수), `generateWeeklyPlan`의
  `try/catch`를 `RateLimitExceededException`→`GeminiApiException`→
  `FirebaseFunctionsException`→`TimeoutException`→`FormatException`→
  나머지 순으로 타입별 분기(기존 저장소 관례,
  `fitting_job_controller.dart`의 invalid-argument rethrow 패턴과
  같은 판단 — 재구현하지 않음). 각 분기가 로컬 클로저
  `logWeeklyPlanFailure`로 `agent_logs`에 기록한 뒤
  `weeklyPlanFailureMessage(reason)`로 `StateError`를 던진다
  (`RateLimitExceededException`만 예외 — 자기 자신의 `.message`를
  그대로 씀, 기존 관례 유지).
- `test/agent_planner_weekly_plan_failure_test.dart`(신규):
  `classifyWeeklyPlanFailure` 9케이스(호출량 상한, 재시도 가능/
  불가 Gemini 오류, unauthenticated, text_too_long 단독/혼재,
  violations 없음, violations 자체 없음, 완전 미분류) +
  `weeklyPlanFailureMessage` 3케이스.

### 검증

`flutter analyze` 0건. `flutter test` 191개 전량 통과(기존 179개
+ 신규 12개, 회귀 없음). **실기기 검증은 이번엔 안 함 — 다음 승인
후.** 서버(`request_shape.ts`)·`maxTotalTextChars` 값 모두
미변경.

---

## 0단계 — `weeklyPlanCatalogChars` 기록 경로 확인·보정 (2026-08-14 이어서)

### (a) 코드 확인 — 성공 경로엔 없었다

`generateWeeklyPlan`(`agent_planner.dart:900-907`, `typeWeeklyPlanned`
성공 이벤트)를 확인한 결과, **`weeklyPlanCatalogChars`가 실패
분기(4단계)에만 있고 성공 이벤트에는 없었다.** 지적대로 이러면
"터지기 전에 안다"는 계측 목적이 성립하지 않는다 — 실패했을
때만 남으므로 이미 터진 뒤에야 안다.

### (b) 보정 — 새 이벤트 없이 기존 성공 이벤트에 필드만 추가

새 이벤트 타입을 만들지 않고, 기존 `typeWeeklyPlanned` 이벤트
생성 지점(`agent_planner.dart:900-907`)에 `weeklyPlanCatalogChars:
catalog.length`만 추가했다 — 실패 분기와 필드명이 같아 나중에
성공/실패를 가리지 않고 같은 필드로 집계할 수 있다.

### (c) 경고 임계값 — 실측에서 역산, 임의의 숫자 아님

두 방식으로 각각 역산해 대조했다:

**방식 1 — 이미 등록된 70% 재검토 트리거를 오늘 실측으로 환산.**
`task_hardening_v2.md`가 이미 "실측이 상한의 70%를 넘으면
재검토"를 등록해 뒀다(`handoff_2026-08-07.md` §6(F) 인용). 이걸
오늘 실측(벌당 95.24자, 고정 오버헤드 856자, §2(a))으로 벌수·
문자수 단위로 환산하면: `(30,000 × 0.7 − 856) / 96.24 ≈ 211.5`
→ **약 212벌**(현재 140벌 대비 +72벌), 문자수로는 약 21,000자.

**방식 2 — 실측 최대 벌크 등록(66벌, §2(c))을 흡수할 여유로
역산.** 30,000자 도달 예상 303벌(§2(c))에서, 이 계정이 실제로
겪은 **가장 큰 단일 등록 이벤트(2026-07-12, 66벌)**를 여유로
뺀다: `303 − 66 = 237벌` → 문자수 `856 + 237 × 96.24 ≈ 23,665자
≈ 78.9%`.

**두 값을 비교해 더 보수적인(먼저 울리는) 쪽을 채택한다**: 방식
1(70%, 약 212벌)이 방식 2(78.9%, 약 237벌)보다 낮다 — 즉 방식
2로만 정했다면 이미 등록된 70% 트리거보다 늦게 울렸을 것이다.
**따라서 기존에 등록된 70%(≈212벌, ≈21,000자)를 그대로 경고
임계값으로 채택한다** — 오늘의 실측이 그 값을 무효화하지 않고
오히려 같은 자릿수(70~79%대)로 재확인해 줬다는 뜻으로 기록한다.
방식 2(237벌, 78.9%)는 폐기하지 않고 "이 값을 넘으면 과거 최대
벌크 등록 규모조차 흡수할 여유가 없다"는 2차 참고선으로 함께
등록한다.

**등록만 — 이 임계값을 실제로 검사해 알림을 띄우는 코드는
이번에 만들지 않는다**(근본 해법·자동화 기능 착수 금지, 사용자
지시). 대신 §1(d)가 인계하는 "며칠 뒤 `agent_logs`
`weeklyPlanCatalogChars` 직접 조회"가 이 임계값과 비교하는
수동 점검 방식이다 — `task_hardening_v2.md`의 70% 트리거도
원래 자동화가 아니라 문서화된 수동 재검토 조건이었다는 점과
같은 성격이다.

### (d) 검증

`flutter analyze` 0건, `flutter test` 191개 전량 통과(신규 테스트
불필요 — 기존 필드와 동일한 sparse-write 패턴의 값 하나 추가라
`AgentLogEntry` 자체에 대한 직렬화 테스트가 이 저장소에 아예
없다는 기존 관례와 일치, 새로 만들지 않음).

---

## 미확인으로 남긴 것

- 카탈로그 크기가 Gemini 응답 품질(형식 오류율, 배분 적절성)에
  실제로 영향을 주는지 — 이번 세션은 문자 수만 쟀고 품질은 안 쟀다.
  §3(a) 판정의 조건 (iii)이 이것에 의존한다.
- Gemini `countTokens` 실호출 기반 정밀 토큰 수 — §2(d)는 공개
  자료의 배율 범위(1.5~2토큰/자)로 계산한 근사치다.
- 30,000자 도달 "시점" — 등록 속도 추정의 신뢰구간이 사실상 없음
  (§2(c), 50일~137일 범위, 벌크 등록 이벤트에 크게 좌우됨).
- 이 계정(n=1 개발자 옷장)의 등록 패턴이 실사용자 패턴을 대표하지
  않는다는 기존 한계(`handoff_2026-08-07.md` §1 "천장 1")가
  그대로 적용된다 — §2(c)의 등록 속도 실측 전체에 이 한계가 걸린다.
