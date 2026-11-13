# 작업 지시서 — 텍스트 모델 교체 v1 (task_text_model_v1)

작성 2026-11-13. 대회 제출 마감 **2026-11-19(목)**. 이 트랙에 쓸 수 있는 시간은 최대 1.5일이다.
기준 커밋 `5a65e0b`.

## 0. 목표와 범위

추천·자기평가·속성 추출·주간 플랜에 쓰는 **텍스트 모델을 교체**한다. 후보는 Gemini 최신과 Claude Sonnet이다. 사용자는 Claude Sonnet을 쓸 생각이고(Haiku는 쓰지 않기로 함), 프로브(§3)는 그 선택이 관문을 통과하는지 확인하고 Gemini 최신과 나란히 놓아 보기 위한 것이다. 가상 피팅 때와 같은 순서다: 프로브 → 사용자 판정 → 적용.

함께 하는 것 두 가지:

- **서버에서만 모델을 바꿀 수 있는 구조**로 만든다(§4-0). 대회 기간에만 다른 모델을 쓰거나 장애 시 되돌릴 때 APK를 다시 배포하지 않기 위함이다.
- **속성 추출 결과를 한국어로 강제**한다. 일본어 값(`레ギュラー`)이 24건 저장됐던 원인을 막는다.

범위 밖: 가상 피팅 경로, 매칭 로직, 자기평가의 통과 기준(70)·평가 횟수 상한, 프롬프트 문장(한국어 강제 한 줄 제외).

## 1. 현재 구조 (착수 전에 저장소와 대조하고 어긋나면 보고)

| # | 사실 | 위치 |
|---|---|---|
| 1 | 주 모델 `gemini-3.5-flash`, 폴백 `gemini-3.1-flash-lite`. 주 모델이 타임아웃·503·429·JSON 파싱 실패면 폴백 모델로 1회 재시도 | `gemini_service.dart` `_textModel`, `textModelFallback`, `withTextModelFallback` |
| 2 | 텍스트 호출은 5종: `extractAttributes`(이미지→JSON, temp 0.2, 800토큰, thinkingBudget 0), `extractSizeFromChart`(이미지→JSON, 0.1, 800, thinkingBudget 0), `analyzeOutfitFromAttributes`(자유 서술, 0.7, 3000), `planWeeklyOutfits`(JSON, 0.4, 2000, thinkingBudget 0), `analyzeOutfitFromAttributesStream`(스트리밍, 0.7, 3000) | 같은 파일 |
| 3 | 자기평가는 `analyzeOutfitFromAttributes`의 서술에서 `[총점] N`을 파싱한다. 주 모델로 받은 점수만 판정에 쓴다(폴백 응답은 판정 유보) | `outfit_self_evaluator.dart` `parseScore`, `threshold = 70` |
| 4 | 모든 텍스트 호출은 서버 `callGeminiText` 하나를 거친다(스트리밍 포함). 서버는 요청·응답을 Gemini 형식 그대로 중계한다. 서버에서 직접 텍스트 모델을 부르는 다른 함수가 있는지 확인할 것 | `functions/src/index.ts` |
| 5 | 클라이언트가 폴백으로 넘어가는 조건은 상태 코드 503·429뿐이다 | `gemini_api_exception.dart` `isRetryable` |
| 6 | 자기평가 타당도 자료가 있다: 조합 쌍 15개, 라벨러 3명의 선택, 조합별 itemIds, 아이템 이미지 55장 | `tools/eval_harness_selfeval/`, `docs/task_selfeval_validity_v1.md` |

## 2. 후보와 알려진 제약 (2026-11-13 공식 문서 기준 — 실제 호출로 재확인)

| 기호 | 모델 | 비고 |
|---|---|---|
| G0 | `gemini-3.5-flash` | 현행. 기준선 |
| G1 | `gemini-3.8-flash` | Gemini 최신 안정 Flash |
| C | `claude-sonnet-5-5` | 사용자가 쓰려는 모델. 기본 effort가 `high`라 그대로 두면 느릴 수 있다 — 사고량을 반드시 명시한다 |

Gemini 폴백 후보: `gemini-3.5-flash-lite`(최신 안정 Flash-Lite).

Claude 5.5 계열의 제약(문서 기준):

- **`temperature`·`top_p`·`top_k`를 보낼 수 없다.** 기본값이 아니면 400이다. 앱이 쓰는 온도(0.1~0.7)를 옮길 수 없다.
- **thinking이 기본으로 켜져 있다.** 응답의 첫 블록이 `thinking`일 수 있으므로 블록을 `type`으로 골라 읽는다. thinking 토큰이 `max_tokens`에 포함되므로 800 같은 작은 값은 본문이 나오기 전에 잘릴 수 있다. 사고량은 `output_config.effort`로 줄인다.
- 응답을 미리 채우는 방식(assistant prefill)은 쓸 수 없다. JSON은 프롬프트 지시 또는 structured outputs로 받는다.
- 엔드포인트 `POST https://api.anthropic.com/v1/messages`, 헤더 `x-api-key`, `anthropic-version: 2023-06-01`.
- 이미지 생성은 없다 — 가상 피팅은 Gemini에 남는다.

문서를 믿고 코드에 박지 않는다. §3-2에서 실제 호출로 확정한다.

## 3. 1단계 — 프로브 (앱·서버 변경 없이 로컬에서 비교)

**프로브 준비가 끝나면 사용자에게 실행 명령을 알려 주고 기다린다. 결과가 나오면 §3-6 형식으로 보고하고 멈춘다.**

### 3-1. 스크립트와 입력

- 위치: `tools/text_probe/probe.mjs`(Node, 내장 `fetch`, 외부 의존성 없음) + `README.md`. `tools/fitting_probe`의 구조·관례를 따른다.
- 키는 환경변수 `GEMINI_API_KEY`, `ANTHROPIC_API_KEY`로만 받는다. 둘 다 사용자 터미널에만 있다 — 호출이 필요한 실행은 사용자가 한다. 키를 파일·로그·커밋에 남기지 않는다. `ANTHROPIC_API_KEY`가 없으면 Gemini 후보만 돌리고 그 사실을 결과에 적는다.
- **프롬프트는 앱의 프롬프트 빌더가 만든 문자열을 그대로 쓴다.** 프로브에서 다시 작성하지 않는다. 환경변수를 줬을 때만 동작하는 덤프용 테스트(`flutter test`)로 Dart 빌더의 출력을 `tools/text_probe/input/prompts.json`에 내보낸다. 평소 `flutter test`에서는 파일을 쓰지 않아야 한다. private 빌더에 접근하려면 `@visibleForTesting` 접근자를 추가한다(동작 변경 없음).
- 아이템 속성은 Firestore에서 읽기 전용으로 받는다(`--credentials $HOME\secrets\personal-adminsdk.json`, 키 파일 내용은 읽어 출력하지 않는다). 이미지는 `tools/eval_harness_selfeval/labeling_material/images/`의 55장과 `tools/fitting_probe/input/`의 전신·옷 사진을 쓴다.
- 준비 순서: ① Firestore에서 아이템 속성을 `input/items.json`으로 받는다 → ② 덤프 테스트가 `items.json`을 읽어 `prompts.json`을 만든다 → ③ 사용자가 프로브를 실행한다. ①②는 키가 필요 없으므로 직접 실행한다.
- §4-0-b의 **프롬프트 한 줄(한국어 강제)은 1단계에서 먼저 넣는다** — 어느 후보가 채택되든 적용되는 변경이고, T2가 그 문장을 포함한 프롬프트로 측정돼야 하기 때문이다. 검증 로직과 별칭은 2단계에서 한다.
- 출력: `output/results.md`, `output/index.html`, 원자료 JSON. `input/`·`output/`은 `.gitignore`.
- 호출당 시한 90초. 실패는 1회만 재시도하고 기록한다. 제공자별 동시 3건.

### 3-2. 먼저 — 스키마 확정 (`probe.mjs schema`)

G1과 C에 과제별 요청을 1회씩 보내 다음을 확정하고 `results.md` 상단에 적는다.

Gemini 3.8:
1. `thinkingConfig.thinkingBudget: 0`이 받아들여지는가. 아니면 어떤 필드·값으로 사고를 최소화하는가
2. `responseMimeType: "application/json"`과 `temperature`가 그대로 통하는가

Claude:
1. 인증 헤더와 버전 헤더
2. `temperature`를 보내면 실제로 400인가(문서 확인용 1회)
3. thinking을 끄거나 최소화하는 실제 방법: `thinking: {"type":"disabled"}` 허용 여부, `output_config.effort`의 허용 값
4. 이미지 입력(JPEG base64) 형식
5. 응답 블록 구조와, 800토큰 분량 JSON이 잘리지 않는 `max_tokens`
6. 스트리밍 이벤트에서 텍스트 조각이 오는 형태

Claude가 인증·형식 문제로 한 번도 성공하지 못하면 멈추고 보고한다.

### 3-3. 측정 과제 (`probe.mjs run`)

모든 후보에 **같은 프롬프트**를 보낸다. Gemini는 앱과 같은 `generationConfig`, Claude는 §3-2에서 확정한 대응 설정(온도 없음, 사고 최소)을 쓴다.

| 과제 | 내용 | 호출 수(후보당) | 측정 |
|---|---|---|---|
| T1 자기평가 | 쌍 15개의 좌·우 조합 30개를 각 2회 채점. 프롬프트는 `analyzeOutfitFromAttributes`와 같은 것(사진 없음, 이력 없음). 8월 쌍 생성 때의 조건(`integration_test/self_eval_pair_generation_probe.dart`)과 다른 점이 있으면 기록 | 60 | 점수 파싱 성공률, 사람 다수결과의 일치, 70점 이상 비율, 2회 간 점수 차, 소요 시간. 참고로 답안지에 저장된 8월 점수로 계산한 일치도 함께 적는다 |
| T2 속성 추출 | 55장 중 itemId 오름차순 앞 20장. 프롬프트는 `extractAttributes`의 것 + 한국어 강제 한 줄(§4-0-b와 같은 문장) | 20 | JSON 유효, 필수 키, 가나·한자 포함 건수, 소요 시간 |
| T3 주간 플랜 | 고정 입력 1개(55벌 중 일부·7일 일정·날씨)를 3회 | 3 | JSON 유효, 앱이 응답에 적용하는 검증 통과 여부 |
| T4 스트리밍 분석 | 전신 사진 + 조합 3개, `analyzeOutfitFromAttributesStream`과 같은 요청 | 3 | 첫 글자까지 시간, 전체 시간, 본문 |

후보 3개 합계 약 258회.

**사람 일치의 정의**: 쌍마다 라벨러 3명의 사진 조건 선택으로 다수결(2/3 이상)을 낸다. 모델은 2회 평균 점수가 높은 쪽을 고른 것으로 본다. 다수결과 같으면 1, 동점이면 0.5, 다르면 0. `task_selfeval_validity_v1.md`에 등록된 정의와 다르면 그 문서의 정의를 따르고 차이를 적는다. 주의 확인용 쌍의 취급도 그 문서를 따른다.

`index.html`: 과제별 표, T1 점수 분포(후보별), T4와 T1 일부(쌍 3개)의 본문을 후보별로 나란히 놓아 사용자가 읽고 비교할 수 있게 한다.

### 3-4. 채택 기준 (결과를 보기 전에 고정. 기준선은 이번 프로브에서 잰 G0)

| 관문 | 기준 |
|---|---|
| 1 형식 | T1 점수 파싱 59/60 이상, T2 JSON 유효 20/20이고 가나·한자 0건, T3 3/3 통과 |
| 2 타당성 | T1 사람 일치 합계가 G0보다 1.0 넘게 낮지 않다 |
| 3 통과 기준 적합 | T1에서 70점 이상인 비율이 G0 대비 ±20%p 이내 |
| 4 재현성 | 같은 조합 2회 점수 차의 평균이 G0 + 3점 이내 |
| 5 속도 | T1 소요 중앙값이 G0의 1.5배 이내, T4 첫 글자까지 중앙값이 G0 + 2초 이내 |
| 6 본문 품질 | 사용자가 `index.html`에서 읽고 G0보다 나쁘지 않다고 판단 |

- 관문 3만 벗어난 후보는 탈락이 아니라 **"통과 기준 재조정 필요"**로 표시한다. 통과 기준(70)은 APK에 들어 있어서, 이런 후보는 서버 전환만으로는 쓸 수 없다. 채택 여부는 사용자가 정한다.
- C가 관문 2 또는 6에서만 탈락하면 `effort`를 한 단계 올려 T1만 1회 더 돌릴 수 있다. C가 관문 5(속도)에서만 탈락하면 §3-2에서 확인한 더 낮은 사고 설정이 남아 있을 때 그 설정으로 T1·T4만 1회 더 돌릴 수 있다(둘 다 사전 허용된 추가 실행).
- 관문을 모두 통과한 후보가 여럿이면 사용자가 고른다. 판정 초안의 순서는 사람 일치 합계 → T1 속도.
- G0 외에 통과한 후보가 없으면 모델은 바꾸지 않고 §4-0만 적용한다.

### 3-5. 사용자에게 알려 줄 것

실행 명령(`schema` → `run`), 예상 소요 시간, 필요한 환경변수. `schema` 결과를 보고 `run` 진행 여부를 판단할 수 있게 한다. 키를 환경변수에 넣는 방법은 명령 기록에 키가 남지 않는 방식(`Read-Host`로 입력받기)으로 안내한다.

### 3-6. 1단계 보고

§1 대조 결과, 스키마 확정 결과, 과제별 표, 관문별 판정 초안, `index.html` 경로. **여기서 멈춘다.**

## 4. 2단계 — 적용 (사용자가 후보를 지정한 뒤 착수)

### 4-0. 공통 (어느 후보든 적용)

**a. 모델 별칭**

- 클라이언트는 실제 모델명 대신 별칭을 보낸다: `_textModel = 'text-primary'`, `textModelFallback = 'text-fallback'`.
- 서버에 경로 표(`text_model_routes.ts`, 순수 함수 + 단위 테스트)를 둔다: 별칭 → `{provider, model}`. 기존 모델명(`gemini-3.5-flash`, `gemini-3.1-flash-lite`)은 자기 자신으로 풀려서 **이미 배포된 APK가 그대로 동작**한다.
- 모델 전환은 이 표의 한 줄을 고치고 함수를 배포하는 것으로 끝난다. APK는 건드리지 않는다.
- 서버 로그에 요청 모델명과 실제로 쓴 `provider:model`을 함께 남긴다. 응답의 `modelVersion`에 실제 모델명을 싣는다.
- 주 모델과 폴백은 서로 다른 모델이어야 한다. 주 모델이 Claude면 폴백은 Gemini로 둔다(제공자 장애에도 앱이 동작).
- 저장되는 `candidateModels` 값이 별칭으로 바뀐다. 이 값을 읽는 곳(화면, 판정 로직, `tools/`의 보고 도구)을 전부 찾아 영향이 있는지 보고한다. 영향이 있으면 고치기 전에 보고한다.
- 화이트리스트·요청 형태·페이로드·호출량 검사는 별칭 요청에도 지금과 똑같이 적용돼야 한다(테스트로 고정).

**b. 속성 한국어 강제**

- 속성 추출 프롬프트에 "모든 값은 한국어로만 쓴다" 취지의 한 줄을 추가한다(프로브 T2에서 쓴 그 문장).
- 클라이언트 파싱 뒤, 값에 히라가나·가타카나·한자가 있으면 `FormatException`으로 처리한다(기존 폴백 경로를 탄다). 라틴 문자와 숫자는 허용한다(`V넥`, `A라인`). 순수 함수 + 단위 테스트.

### 4-A. Gemini 후보(G1)를 채택한 경우

- 경로 표: `text-primary → gemini-3.8-flash`, `text-fallback →` 스키마 확인을 통과한 최신 Flash-Lite.
- 사고 최소화 필드가 §3-2에서 달라진 것으로 확인되면 클라이언트의 `generationConfig`를 그에 맞게 고친다.
- 서버 화이트리스트에 새 모델을 추가한다. 기존 모델은 지우지 않는다.

### 4-B. Claude 후보(C)를 채택한 경우

- **키**: `ANTHROPIC_API_KEY`를 Functions secret으로 쓴다. 등록(`firebase functions:secrets:set ANTHROPIC_API_KEY`)은 사용자가 자기 터미널에서 한다. `callGeminiText`의 `secrets` 선언에 추가한다.
- **변환기** `claude_adapter.ts`(순수 함수 + 단위 테스트. 프로브가 받은 실제 응답을 픽스처로 쓴다):
  - 요청: `contents[0].parts`의 `text` → 텍스트 블록, `inlineData` → base64 이미지 블록(순서 유지). `systemInstruction` → `system`. `temperature` 등 샘플링 값은 버린다. `maxOutputTokens`는 §3-2에서 확정한 하한 이상으로 올린다. 사고 설정은 §3-2에서 확정한 "최소" 값으로 고정한다.
  - 응답: `type`이 `text`인 블록만 이어 붙여 `candidates[0].content.parts[0].text`에 넣는다. `finishReason`, `usageMetadata`, `modelVersion`을 채운다. 클라이언트 파싱 코드는 바꾸지 않는다.
  - 스트리밍: 텍스트 조각마다 클라이언트가 지금 읽는 것과 같은 모양의 조각을 보낸다.
- **오류**: Claude 쪽 2xx가 아닌 응답과 시한 초과는 **전부 상태 503으로** 돌려준다. 클라이언트가 폴백(Gemini)으로 넘어가게 하기 위함이다 — 크레딧 소진·키 오류 같은 400대도 포함한다. 원래 상태 코드와 메시지는 서버 로그에 남긴다.
- `callGeminiText`의 기존 검사(인증, 요청 형태, 페이로드, 호출량)를 모두 지난 뒤에 제공자별로 분기한다. 이미지 모델 요청은 Claude로 가지 않는다.
- "무가공 중계" 주석을 새 사실에 맞게 고친다.
- 사용자 사진(전신·옷)이 Claude로도 전송되게 된다. 앱 안의 개인정보·AI 처리 안내 문구에 제공자를 추가해야 하는 곳이 있는지 찾아 보고한다(문구는 고치지 말고 위치만).

### 4-3. 배포·검증 (배포는 사용자 승인 후)

1. `tsc`, `npm test`, `flutter analyze`, `flutter test` 통과. 여기서 멈추고 보고한다.
2. 승인 후 함수 배포 → 지금 폰의 APK(기존 모델명을 보냄)로 코디 분석 1회가 되는지 확인.
3. 릴리스 APK 빌드·설치 → 옷 1벌 등록(속성 추출), 코디 분석(스트리밍), 추천 1회(자기평가), 주간 플랜 1회. 서버 로그에서 각 호출의 실제 모델과 성공 여부를 표로 만든다.
4. **전환 리허설 1회**: 경로 표를 다른 모델로 바꿔 배포 → 같은 APK로 분석 1회 → 원래대로 되돌려 배포. APK 없이 전환되는지 확인한다.
5. Claude를 채택했으면 **폴백 리허설 1회**: 경로 표의 Claude 모델명을 일부러 틀리게 해 배포 → 앱이 Gemini 폴백으로 분석을 끝내는지 확인 → 되돌린다.

### 4-4. 커밋

프로브 1개, 공통(§4-0) 1개, 모델 적용(§4-A 또는 §4-B) 1개. 서버와 클라이언트의 별칭 변경은 같은 커밋. `git push`는 사용자가 지시할 때만.

## 5. 금지 사항

- 가상 피팅 경로(이미지 모델, `generateFittingImage`, 서명 제거)를 건드리지 않는다.
- 자기평가 통과 기준(70), 평가 횟수 상한, 매칭·추천 로직을 바꾸지 않는다. 바꿔야 한다는 근거가 나오면 보고만 한다.
- 프롬프트 문장을 고치지 않는다(§4-0-b의 한 줄 제외). 후보 비교는 같은 프롬프트로 한다.
- `firestore.rules`, `storage.rules`, 인증, App Check, 호출량 상한 값을 건드리지 않는다.
- API 키를 파일·로그·커밋·대화에 남기지 않는다.
- Firestore·Storage에는 읽기만 한다.
- `firebase deploy`는 사용자 승인 없이 실행하지 않는다.
- 서버 화이트리스트에서 기존 모델명을 제거하지 않는다.
- 채택 기준(§3-4)을 결과를 본 뒤 바꾸지 않는다.
- 논문·handoff 문서를 고치지 않는다. 결과는 이 문서 끝 "실행 기록" 절에 덧붙인다.
- 이 문서에 없는 리팩터링을 하지 않는다. 범위 밖 결함은 고치지 말고 보고한다.

## 6. 완료 보고 형식

1. §1 대조 결과
2. 스키마 확정 결과
3. 과제별 표와 관문별 판정 초안, `index.html` 경로
4. (2단계) 바꾼 파일, 테스트 통과 수, 실기기 확인 표, 전환·폴백 리허설 결과
5. 남은 문제와 범위 밖에서 발견한 것

## 실행 기록

### 2026-11-13 착수 전 §1 대조

1·2·3·4·6은 사실. **5는 좁다** — `isRetryable`은 503·429뿐이지만 실제 폴백 조건은 타임아웃·503/429·`FormatException` 셋이다(1번 행의 서술이 맞다). 6 보충: 라벨링 이미지는 실제로 `.jpg`인데 `pairs_blind.json`은 `.png`로 적고 있다. 서버에서 텍스트 모델을 부르는 곳은 `callGeminiText`뿐이다(`generateFittingImage`는 이미지).

### 2026-11-13 1단계 프로브 (사용자 터미널, 22:17 schema · 22:18~22:28 run)

준비: 한국어 강제 한 줄을 `_buildAttributeExtractionPrompt`에 먼저 넣었다(§3-1). 덤프용으로 `generationConfig` 3종 상수화, 주간 플랜 프롬프트·일정 줄·카탈로그 줄을 순수 함수로 분리, private 빌더 `@visibleForTesting` 접근자 추가(동작 변경 없음). T1 입력은 8월과 같은 진입점·프롬프트이고, 아이템 요약 4줄만 일본어 정정(`레ギュラー`→`레귤러`, p004L·p008R·p013R·p014R)으로 달라졌다.

**스키마 확정(§3-2)**:
- G1 `gemini-3.8-flash`: 앱 T2 설정(`thinkingBudget: 0`·`responseMimeType`·`temperature`) 그대로 통과.
- Flash-Lite: `gemini-3.5-flash-lite`는 `thinkingBudget: 0`을 400으로 거부, `thinkingLevel: "minimal"`로 통과. `gemini-3.1-flash-lite`(현 폴백)는 그대로 통과.
- Claude `claude-sonnet-5-5`: 버전 헤더 `2023-06-01`·`2026-10-21` 모두 통과(지시서대로 `2023-06-01` 사용). `temperature` → 400("deprecated for this model"). `thinking: disabled` → 400("send between_tools instead"). `between_tools`는 effort low·medium·high 모두 통과, effort 값 low~max 모두 통과. 확정 설정 **`thinking: between_tools` + effort low**. 이미지(JPEG base64) 정상, T2 JSON은 max_tokens 800으로 충분(출력 83토큰). 응답 블록 `["text"]`. 스트리밍은 `message_start → content_block_start → ping → content_block_delta(text_delta)… → message_delta → message_stop`, 첫 글자 0.8초.

**과제별 결과(§3-3)**:

| 후보 | T1 파싱 | T1 사람 일치 | T1 70+ | T1 2회 차 | T1 중앙값 | T2 JSON | T2 가나·한자 | T3 앱 검증 | T4 첫 글자 | T4 전체 |
|---|---|---|---|---|---|---|---|---|---|---|
| G0 `gemini-3.5-flash` | 60/60 | 10/14 | 96.7% | 2.1 | 11.9초 | 20/20 | 0 | 3/3 | 9.0초 | 9.5초 |
| G1 `gemini-3.8-flash` | 60/60 | 9/14 | 96.7% | 1.1 | 16.2초 | 20/20 | 0 | 3/3 | 9.6초 | 10.1초 |
| C `claude-sonnet-5-5` | 49/60 | 7/14 | 100% | 1.4 | 7.1초 | 0/20 | 0 | 0/3 | — | — |

- 참고: 정답지의 8월 점수로 계산한 사람 일치 10/14(등록 문서 §9 실측과 같음).
- **C 측정은 무효**: 실행 도중(약 49번째 C 호출부터 끝까지) Anthropic이 **503 `credential validation failed`**를 즉시(0.4초 안팎) 돌려줬다 — 재시도 1회도 같은 오류. 모델 응답이 아니라 제공자 인증 쪽 실패라 C의 T1 11건·T2 20건·T3 3건·T4 3건은 성능 측정값이 아니다. 성공한 49건 기준 참고값: 파싱 49/49, 점수 72~86(전부 70 이상), C가 양쪽 점수를 모두 가진 다수결 쌍 11개에서 일치 C 7/11 · G0 8/11 · G1 7/11.
- T3 참고: G0 3회차에 없는 id 2개(앱이 걸러 통과), 1회차에 상·하의 연속 1건. G1은 셋 다 깨끗.

**관문 판정 초안(§3-4)**: G1은 관문 1~5 통과(사람 일치 9 vs 10, T1 속도 1.36배, T4 첫 글자 +0.6초), 관문 6은 사용자 판단. C는 제공자 오류로 판정 불가 — C만 다시 측정할지 사용자 결정 대기.

### 2026-11-13 C 재측정 (22:34~22:37, `run --candidates C`)

- **인증 실패 0건** — C 86회 전부 HTTP 200, 재시도 0. 첫 실행의 503 `credential validation failed`는 재현되지 않았다(C 86칸을 이번 값으로 덮어씀).
- 세 후보 최종 표(기준선 G0):

  | 후보 | T1 파싱 | T1 사람 일치 | T1 70+ | T1 2회 차 | T1 중앙값 | T2 JSON | T2 가나·한자 | T3 앱 검증 | T4 첫 글자 | T4 전체 |
  |---|---|---|---|---|---|---|---|---|---|---|
  | G0 `gemini-3.5-flash` | 60/60 | 10/14 | 96.7% | 2.1 | 11.9초 | 20/20 | 0 | 3/3 | 9.0초 | 9.5초 |
  | G1 `gemini-3.8-flash` | 60/60 | 9/14 | 96.7% | 1.1 | 16.2초 | 20/20 | 0 | 3/3 | 9.6초 | 10.1초 |
  | C `claude-sonnet-5-5`(between_tools·effort low) | 60/60 | **8.5/14** | 96.7% | 1.2 | 7.2초 | 20/20 | 0 | 3/3 | 0.9초 | 2.7초 |

- C 참고: T1 점수 68~88. T3 3회 모두 7일·없는 id 0, 3회차에 상·하의 연속 1건. T1 출력 토큰 중앙값 791(G0 399·G1 457), 본문 길이 중앙값 727자(G0 632·G1 727).
- **관문 판정 초안(§3-4)**:

  | 후보 | 1 형식 | 2 타당성(G0−1.0 = 9.0 이상) | 3 통과 기준(±20%p) | 4 재현성(≤ G0+3) | 5 속도(T1 ≤1.5배, T4 ≤+2초) | 6 본문 |
  |---|---|---|---|---|---|---|
  | G1 | 통과 | 통과(9.0) | 통과(0%p) | 통과(1.1) | 통과(1.36배, +0.6초) | 사용자 판단 |
  | C | 통과 | **미달(8.5)** | 통과(0%p) | 통과(1.2) | 통과(0.61배, −8.1초) | 사용자 판단 |

  관문 1~5를 모두 통과한 후보는 G1뿐이다. C는 관문 2만 미달이라 §3-4의 사전 허용 추가 실행(effort를 한 단계 올려 T1만 1회 더 — `run --candidates C --tasks T1 --claude-effort medium`, 결과는 `C@medium`으로 따로 저장)이 가능하다. 실행 여부는 사용자가 정한다.

### 2026-11-13 C 추가 실행 — effort medium, T1만 (22:43~22:45, §3-4 사전 허용)

`run --candidates C --tasks T1 --claude-effort medium`(`between_tools` 유지, effort만 low→medium). 60/60 HTTP 200, 재시도 0. 결과는 `C@medium`으로 따로 저장했다(C(low) 결과 보존).

| 항목(기준) | G0 | C(low) | C@medium |
|---|---|---|---|
| 관문 2 사람 일치(G0−1.0 = 9.0 이상) | 10/14 | 8.5 **미달** | 9.5 **통과** |
| 관문 3 70점 이상 비율(G0 ±20%p) | 96.7% | 96.7% 통과 | 96.7% 통과 |
| 관문 4 2회 점수 차 평균(G0+3 = 5.1 이하) | 2.1 | 1.2 통과 | 2.1 통과 |
| 관문 5 T1 소요 중앙값(G0×1.5 = 17.9초 이하) | 11.9초 | 7.2초 통과 | 7.2초 통과 |
| 참고: 점수 범위 / 70 미만 | 62~94 / 2 | 68~88 / 2 | 66~86 / 2 |
| 참고: 출력 토큰 중앙값 | 399 | 791 | 794 |

- 관문 5의 T4 부분(첫 글자 G0+2초 이내)은 이번에 T4를 다시 재지 않아 C@medium에 대해선 판정하지 않았다(C(low)는 0.9초로 통과).
- **해석 주의**: C(low)와 C@medium의 일치 차이 1.0은 6개 쌍의 선택이 뒤집혀 생겼는데, 그중 5쌍은 좌우 평균 점수 차가 0~2점이었다(p008 82:80, p002 77:78, p012 80:82, p011 75:76, p015 84:85; p004만 78:84). `between_tools`(사고 끔)에서는 effort를 올려도 출력 토큰·소요 시간이 거의 같아(791→794, 7.2초→7.2초), 이 차이는 설정 효과보다 회차 간 변동일 가능성이 크다 — 판정 기준은 바꾸지 않고 기록만 한다.

### 2026-11-13 관문 6 — 본문 품질 (사용자 판단)

- **사용자 판단: C가 G0보다 좋다**(사용자가 `tools/text_probe/output/index.html`을 직접 읽고 판단). 관문 6 통과.
- 판단 시점의 비교 페이지에는 T4 본문 3개(전신 사진 + 조합, C는 effort low)와 T1 본문 쌍 3개(`p001`·`p007`·`p013`, C(low)와 C@medium 모두)가 G0·G1과 나란히 있었다.
- 이로써 C(low)는 관문 2만 미달(8.5), C@medium은 T1 기준 관문 2~5 통과 + 관문 6 통과다. 채택 후보·effort·폴백은 사용자가 정한다.

## 2단계 결정 (2026-11-13, 사용자)

1. **채택: C = `claude-sonnet-5-5`.** `thinking: {"type": "between_tools"}`, 버전 헤더 `2023-06-01`.
2. **effort**: 요청의 `generationConfig.thinkingConfig.thinkingBudget`이 0이면 `low`, 아니면 `medium`. JSON 호출(속성 추출·사이즈표·주간 플랜)은 low, 분석·자기평가·스트리밍 분석은 medium이 된다.
3. **경로 표**: `text-primary → claude:claude-sonnet-5-5`, `text-fallback → gemini:gemini-3.5-flash`. 기존 모델명(`gemini-3.5-flash`, `gemini-3.1-flash-lite`)은 자기 자신으로 푼다. `gemini-3.8-flash`는 쓰지 않는다.
4. **거절**: Anthropic 서버 측 `fallbacks`는 넣지 않는다. 거절(`stop_reason`이 거절이거나 text 블록이 비어 있음)은 다른 Claude 오류와 똑같이 503으로 돌려 앱의 폴백을 타게 한다.
5. **채택 근거**: 사람 일치는 G0과 구별되지 않는 수준이고(C(low) 8.5·C@medium 9.5 vs G0 10, 14쌍), 속도(T1 중앙값 7.2초 vs 11.9초, T4 첫 글자 0.9초 vs 9.0초)와 본문 품질(관문 6, 사용자 판단)에서 앞선다. low→medium 일치 상승(8.5→9.5)은 변동일 가능성이 크다 — 뒤집힌 6쌍 중 5쌍의 좌우 평균 차가 0~2점이었고, `between_tools`에서는 effort를 올려도 출력 토큰·소요 시간이 거의 같았다(791→794토큰, 7.2→7.2초).

보충:
- a) 어댑터가 만드는 Claude 요청은 프로브가 C에 보낸 요청과 같아야 한다(모델, thinking, effort, max_tokens 정책, 이미지 블록 형식). 프로브 요청을 픽스처로 삼아 어댑터 출력과 대조하는 테스트를 둔다.
- b) T4(스트리밍)는 medium으로 잰 적이 없다 — 사용자가 `run --candidates C --tasks T4 --claude-effort medium`을 돌리고, 첫 글자 중앙값이 G0+2초(11.0초) 이내인지 판정해 이 기록에 적는다.
- c) `ANTHROPIC_API_KEY` secret 등록은 사용자가 자기 터미널에서 한다. 배포 직전에 알린다.

### 2026-11-13 T4 스트리밍 — effort medium (22:52, 보충 b)

`run --candidates C --tasks T4 --claude-effort medium` — 3/3 HTTP 200, 재시도 0, stop_reason 전부 `end_turn`.

| 항목 | G0 | C(low) | C@medium |
|---|---|---|---|
| 첫 글자(회차별) | 9.0 / 8.6 / 12.0초 | 0.9 / 1.1 / 0.7초 | 1.1 / 1.2 / 1.4초 |
| **첫 글자 중앙값**(기준 G0+2 = 11.0초 이내) | 9.0초 | 0.9초 통과 | **1.2초 통과** |
| 전체 중앙값 | 9.5초 | 2.7초 | 3.1초 |
| 본문 길이(자) | 143 / 146 / 137 | 154 / 185 / 236 | 169 / 201 / 199 |

판정: 관문 5의 T4 부분 **통과**. 채택 설정(분석·스트리밍 분석은 effort medium)으로 T1·T4 모두 관문 5를 넘는다.

### 2026-11-13 2단계 적용 (§4-0·§4-B, 배포 전)

- **서버**
  - `functions/src/text_model_routes.ts`: 경로 표 `text-primary → claude:claude-sonnet-5-5`, `text-fallback → gemini:gemini-3.5-flash`. 표에 없는 이름(배포된 APK의 `gemini-3.5-flash`·`gemini-3.1-flash-lite`)은 자기 자신(gemini). kind가 image인 요청은 무조건 gemini 자기 자신 — Claude로 가지 않는다. 테스트 9건(주 모델·폴백 제공자 상이, 별칭은 text kind, 3.8-flash 미사용 포함).
  - `ALLOWED_MODELS`에 별칭 2개 추가, 기존 모델명은 유지. 요청 형태·페이로드·호출량 검사는 요청 모델명·kind 기준으로 지금과 똑같이 돈 뒤에 경로로 분기한다. start 로그에 `model=<요청> route=<provider:model>`, Gemini 응답에 `modelVersion`이 없으면 실제 모델명을 채운다.
  - `functions/src/claude_adapter.ts`(순수 함수): parts → text·base64 image 블록(순서 유지), systemInstruction → system, 샘플링 값 버림, `thinking: between_tools`, effort는 `thinkingBudget: 0`이면 low 아니면 medium. **max_tokens 정책**(프로브 그대로): Gemini `maxOutputTokens`가 800 이하면 그 값(속성 추출·사이즈표 800 — 프로브 T2에서 잘림 없음), 그 외 `max(maxOutputTokens, 4000)`(분석 3000·주간 플랜 2000 → 4000). 응답은 text 블록만 이어 `candidates[0].content.parts[0].text`, `finishReason`·`usageMetadata`·`modelVersion` 채움. 스트리밍은 text_delta마다 Gemini 형식 청크.
  - 오류: Claude 2xx 아님(400대 포함)·시한 초과·네트워크·거절(`refusal`)·빈 본문·변환 실패·스트림 error 이벤트를 **전부 `upstreamStatus: 503`**으로 돌려준다(`claude-error` 로그에 원래 상태·사유). 클라이언트 `_mapProxyException` → `GeminiApiException(503)` → 폴백.
  - `ANTHROPIC_API_KEY`를 `callGeminiText`의 secrets에 추가(사용자 등록 완료, versions/1). "무가공 중계" 주석을 새 사실로 고쳤다.
  - 테스트: `claude_adapter.test.ts` 21건 — 요청 4건은 `tools/text_probe` 픽스처(`probe.mjs fixtures`, 프로브가 C에 보낸 요청과 같은 함수로 생성, T1·T4 medium·T2·T3 low)와 `deepStrictEqual`로 대조. 응답 픽스처는 프로브 결과에 남은 C의 실제 본문·토큰·stop_reason으로 다시 만든 Messages 응답 모양(원본 JSON은 프로브가 저장하지 않았다).
- **클라이언트**
  - `_textModel = 'text-primary'`, `textModelFallback = 'text-fallback'`.
  - 속성 추출 후 값(color·style·pattern·formality·fit·tags)에 가나·한자가 있으면 `FormatException`(기존 폴백 경로). 라틴 문자·숫자 허용. 테스트 5건.
- **`candidateModels` 영향(보고)**: 저장값이 `text-primary`/`text-fallback`으로 바뀐다. 읽는 곳은 `RecommendationEntry`(직렬화만), `agent_planner.dart`(쓰기), `integration_test/self_eval_*_probe.dart`(출력만)뿐이고 화면·`tools/` 보고 도구에는 없다. 판정 로직(`judgeCandidate`)은 응답 모델을 `GeminiService.primaryTextModel`과 비교하는데 둘 다 별칭이라 그대로 동작한다. 과거 문서의 실제 모델명과 새 별칭이 섞이지만 이를 해석하는 코드는 없다 — 고친 것 없음.
- **개인정보·AI 처리 안내(위치만, 문구 안 고침)**: 사용자 사진(전신·옷)이 이제 Anthropic으로도 전송된다. 제공자를 적어야 할 수 있는 곳 — `lib/screens/login_screen.dart:142`(이용약관·개인정보처리방침 동의 문구), `lib/screens/settings_screen.dart:619`(개인정보처리방침 행 — 현재 "준비 중"), `lib/screens/fitting_room_screen.dart:1302`(분석 카드 제목 "Gemini Fashion Advisor" — 분석은 이제 Claude). 앱 안에 제공자를 밝히는 기존 문구는 없다.
- **검증**: `npx tsc --noEmit` 통과, `npm test` 154건 PASS(새로 30건), `flutter analyze` 0건, `flutter test` 242건 통과(덤프 1건 건너뜀).

### 2026-11-13 배포·실기기 검증 (§4-3 1~4)

- **배포**(커밋 `e9d845c`): 9개 함수 갱신 성공, 경고는 기존 2건뿐. CLI가 함수 실행 계정에 `ANTHROPIC_API_KEY` secret 읽기 권한(`secretmanager.secretAccessor`)을 자동 부여했다(secret 연결 시 정상 동작).
- **구 APK(별칭 이전 빌드) 코디 분석 1회**(23:10): `model=gemini-3.5-flash route=gemini:gemini-3.5-flash`, 성공, 12.6초 — 배포된 APK는 그대로 동작.
- 새 APK 빌드 전 문구 수정 2건(별도 커밋): 분석 카드 제목 → "AI Fashion Advisor"(`62dfeaa`), 사용자에게 보이는 "Gemini" 문구 3곳 → "AI"(`5ea8a10`, 의존하는 테스트·판정 코드 없음).
- **새 APK**(커밋 `5ea8a10`, `flutter build apk --release`, `adb install -r`) 실기기 4종 — 서버 로그 + 에이전트 활동 기록(읽기 전용) 대조:

  | 시각(KST) | 기능 | 요청 모델 | route | 결과 | elapsedMs | claude-error |
  |---|---|---|---|---|---|---|
  | 23:23:59 | 옷 1벌 등록 — 속성 추출(이미지 132KB, low) | `text-primary` | `claude:claude-sonnet-5-5` | 성공 | 1,651 | 없음 |
  | 23:24:01 | 등록이 띄운 추천 — 자기평가 후보 1(84점 통과·채택) | `text-primary` | `claude:claude-sonnet-5-5` | 성공 | 7,371 | 없음 |
  | 23:24:26 | 코디 분석(스트리밍, 68점) | `text-primary` | `claude:claude-sonnet-5-5` | 성공 | 3,044 | 없음 |
  | 23:25:04 | 주간 플랜 1회차 | `text-primary` | `claude:claude-sonnet-5-5` | 성공 | 9,588 | 없음 |
  | 23:25:49 | 주간 플랜 2회차 | `text-primary` | `claude:claude-sonnet-5-5` | 성공 | 10,884 | 없음 |

  `text-fallback` 요청 0건, `claude-error` 0건 — 다섯 호출 모두 Claude 경로에서 성공(폴백에 가려진 실패 없음). 등록한 옷의 속성은 전부 한국어(`핏 레귤러`, 태그 `니트·골지·가을겨울·어깨단추`). 추천 문서의 `candidateModels`는 `['text-primary']`. 추천(자기평가) 호출은 옷 등록이 자동으로 띄운 파이프라인의 것이고, 별도의 추천 호출은 로그에 없다. 주간 플랜은 두 번 호출됐다.

### 2026-11-13 리허설 (§4-3 5) — (가) 생략, (나) 폴백, (다) 복구

리허설용 변경(경로 표 `text-primary` 한 줄)은 커밋하지 않았다. 바뀐 함수가 `callGeminiText` 하나라 두 번 모두 `--only functions:callGeminiText`로 배포했다(경고는 firebase-functions 버전 권고 1건).

**(나) 폴백 — `text-primary → claude:claude-rehearsal-nonexistent`로 배포**

| 시각(KST) | 기능 | 호출 순서 | Claude 실패(원래 상태·사유) | 폴백 | 소요 |
|---|---|---|---|---|---|
| 23:33:44 | 코디 분석 | 스트리밍 `text-primary` → 비스트리밍 `text-primary` → `text-fallback` | 404 `model: claude-rehearsal-nonexistent` ×2 → 503 | `gemini:gemini-3.5-flash` 성공 | 1,000 + 342 + 12,222ms(시작~완료 13.8초) |
| 23:35:42 | 옷 등록 — 속성 추출 | `text-primary` → `text-fallback` | 404 → 503 | gemini 성공 | 489 + 2,476ms |
| 23:35:49 | 확인 못 함(28KB, 사용자 기억 없음) | `text-primary` → `text-fallback` | 404 → 503 | gemini 성공 | 583 + 2,185ms |
| 23:35:52 | 자기평가 후보 1 | `text-primary` → `text-fallback` | 404 → 503 | gemini 성공 | 345 + 11,470ms |
| 23:36:04 | 자기평가 후보 2 | `text-primary` → `text-fallback` | 404 → 503 | gemini 성공 | 392 + 17,014ms |

- Claude 실패 6건 모두 `claude-error` 로그에 원래 상태 404·사유가 남고 클라이언트에는 503으로 갔다. 클라이언트는 매번 `text-fallback`으로 넘어가 성공했다. 실패 응답은 0.3~1.0초.
- 코디 분석은 등록된 순서대로 스트리밍 실패 → [STREAM-FALLBACK] 비스트리밍 → 폴백으로 갔고 결과(78점)가 정상 저장됐다.
- 폴백(Gemini)으로 추출한 속성도 전부 한국어(`레귤러`, 태그 `니트·봄가을·로고·라운드넥`).
- 자기평가는 폴백 모델 응답이라 설계대로 "판정 불가(대체 모델 응답)" — 후보 1(83점)·2(85점) 모두 유보, 후보 3은 평가 횟수 상한으로 호출되지 않아 이번 등록으로는 추천이 생기지 않았다. 주 모델 장애가 길어지면 추천이 만들어지지 않는다는 뜻이다(기존 판정 규칙 그대로, 범위 밖 — 기록만).
- 23:35:49의 28KB 호출은 요청 크기(이미지 1장 축소본 수준)와 호출 위치로 보아 사이즈표 자동 입력(`extractSizeFromChart`)으로 추정되지만, 사용자 기억이 없고 활동 기록에도 남지 않아 확정하지 못했다.

**(다) 복구 — `git checkout`으로 경로 표를 커밋된 값(`claude:claude-sonnet-5-5`)으로 되돌려 배포**

- 23:43:05 코디 분석(스트리밍): `model=text-primary route=claude:claude-sonnet-5-5`, 성공, 3,188ms. `claude-error` 0건, `text-fallback` 0건.
- 작업 트리: `git status`·`git diff`에 `functions/src/text_model_routes.ts` 변경 없음(이 실행 기록 문서만 수정, 미추적 `prototype/`은 이 트랙과 무관). 리허설 흔적 없음.

### 마무리

- 텍스트 모델: 주 `text-primary → claude:claude-sonnet-5-5`(between_tools, JSON 호출 effort low·분석 medium), 폴백 `text-fallback → gemini:gemini-3.5-flash`. 배포된 구 APK는 실제 모델명으로 Gemini를 그대로 쓴다.
- 실기기에서 Claude 경로 4종(속성 추출·자기평가·스트리밍 분석·주간 플랜) 성공, 폴백 리허설·복구 확인. 모델 전환은 경로 표 한 줄 + `callGeminiText` 배포로 APK 없이 된다(리허설 (나)·(다)로 확인).
- 남은 것(범위 밖, 손대지 않음): 개인정보처리방침·로그인 동의 문구에 AI 제공자(Anthropic) 안내 없음(위치는 위 기록), firebase-functions 버전 권고.
