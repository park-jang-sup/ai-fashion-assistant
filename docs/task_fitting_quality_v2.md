# 작업 지시서 — 가상 피팅 속도·품질 개선 v2 (task_fitting_quality_v2)

작성 2026-11-13. 대회 제출 마감 **2026-11-19(목)**. 이 트랙에 쓸 수 있는 시간은 최대 2일이다.

## 0. 목표와 범위

가상 피팅의 **소요 시간을 줄이고 결과물 품질을 올린다.** 이미지 모델을 최신으로 교체하고, 호출 방식(순차 → 한 번에)과 프롬프트를 함께 손본다.

범위는 가상 피팅 경로뿐이다. 텍스트 모델(`_textModel`, `textModelFallback`) 교체는 자기평가 점수 분포에 영향을 주므로 별도 지시서로 다룬다.

## 0-1. v1과의 관계 — v1을 종결하고 이 문서가 대체한다 (사용자 결정)

`docs/task_fitting_quality_v1.md`(2026-08-31~09-01)는 0단계(카테고리 로그)만 완료했고, 1단계(H-1/H-3 접두사 판별)는 유효 회분을 한 번도 얻지 못한 채 멈췄다. 2~5단계는 기록이 없다.

**v1을 이어가지 않는 이유** (v1 원문의 실패 기록에서 나온다):

- v1의 폐기 사유 넷은 전부 **폰에서 손으로 실행하는 절차**에서 나왔다 — 비중첩 조합 실행, 캐시 히트, 강제 종료, 조합 착오. 이 문서의 프로브는 고정 입력 파일을 스크립트로 돌리므로 넷 다 구조적으로 발생하지 않는다(중첩은 파일 목록으로 고정, 캐시 없음, 시간당 상한 없음).
- v1의 판별 대상은 "구 모델에서 슬롯을 줄이는 베팅이 유효한가"였다. 모델을 바꾸면 그 질문의 대상이 바뀐다.
- v1의 질문 자체는 버리지 않는다. 같은 입력·같은 모델에서 **한 번에(누적 단계 0) vs 순차(누적 단계 N)**를 직접 비교하면 H-1(누적 손실)이, 한 번에 방식에서의 모자 품질을 보면 H-3(모자 고유 난이도)이 더 깨끗하게 분리된다(§3-3).

**v1에서 이어받는 실측** (이 문서의 기준선으로 쓴다):

| 항목 | 값 | 출처 |
|---|---|---|
| 단계당 소요(구 모델, 순차) | 11.5~16.8초 | v1 1회분 서버 로그 19단계 |
| 옷 1벌 피팅 | 19.0초 | v1 0단계 관문 |
| 8단계 피팅 전체 | 약 2분(05:12:36Z→05:14:37Z) | v1 14:13 실행 |
| 1단계 요청 크기 | 155KB(전신+옷 1) — **입력은 이미 작다** | v1 0단계 관문 |
| 응답 크기 / 출력 해상도 | 약 1.48MB / 약 900×1150 | v1 |
| 품질 관측(참고 등급) | ① 1벌 피팅도 기저 품질 하락 ② 얼굴·배경이 단계 수와 함께 열화 ③ 모자가 머리에 뜨고 로고·색이 창작됨 | v1 |

**v1의 금지 사항 중 이 문서가 뒤집는 것**: "판별 전 프롬프트 수정 금지", "판별 전 품질 대응 선반영 금지". v1 실험이 종결되므로 효력이 없다. 나머지(배포는 승인 후, 상한 상향 금지, 캐시 히트를 유효 데이터로 쓰지 않음 등)는 그대로 지킨다.

**착수 전에 할 일** (보고 후 진행):

1. `git log --oneline` 에서 2026-08-15 이후 커밋 중 피팅 경로(`gemini_service.dart`, `fitting_job_controller.dart`, `functions/src/index.ts`, `payload_limit.ts`, `request_shape.ts`, `fitting_cache_key.ts`, `main.dart`의 슬롯 맵)를 건드린 것을 나열한다. 이 문서는 GitHub의 2026-08-15 커밋과 v1 문서만 보고 썼다.
2. v1의 2~5단계(렌더링 코어 4 캡, thinking A/B, 액세서리 일괄, Pro) 중 **코드에 이미 반영된 것이 있는지** 확인한다.
3. §1 표의 각 항목이 지금 코드에서도 사실인지 예/아니오로 답한다. 어긋나면 저장소가 옳다.
4. v1 문서 끝에 "2026-11-13 v2로 대체, 1단계 미완 종결" 한 단락만 덧붙인다(원문은 고치지 않는다).

## 1. 현재 구조에서 확인된 원인

| # | 원인 | 위치 |
|---|---|---|
| 1 | 옷 N벌 = 이미지 생성 N회 순차 호출. 시간이 단계당 약 14초 × N으로 선형 증가하고(8슬롯이면 약 2분), 매 단계 출력이 다음 입력이 되어 얼굴·배경이 누적 열화한다 | `_generateFittingImageSequential`, `sequentialFittingEnabled` 기본 true |
| 2 | 이미지 모델이 이전 세대 `gemini-3.1-flash-image`. 순차 합성은 이 모델의 "옷 2벌 이상에서 60~300초" 회귀를 피하려는 우회책이었다(논문 5.21) | `_imageModel` |
| 3 | 프롬프트가 약하다 — 카테고리 이름만 넘기고(`- 상의`), 어느 이미지가 무엇인지 라벨이 없고, 추출해 둔 속성(색상·패턴·핏)과 `subCategory`(모자/가방/시계)를 쓰지 않는다. "로고·색 창작"과 직접 관련된다 | `_buildFittingPrompt` |
| 4 | `generationConfig`에 `responseModalities`만 있다 — thinking 수준·출력 크기 미지정 | one-shot·sequential requestBody |
| 5 | `mimeType`이 `image/jpeg`로 하드코딩 — 순차 중간 결과(모델 출력, PNG일 수 있음)도 jpeg로 표기된다. (입력 크기는 원인이 **아니다** — 실측 155KB) | 같은 위치 |
| 6 | 서버에 이미지 모델명이 3곳 하드코딩 — `ALLOWED_MODELS`, `generateFittingImage` 엔드포인트 URL, `payload_limit.ts`의 `kindForModel`(문자열 완전 일치). `kindForModel`을 빠뜨리면 첫 호출부터 조용히 거부된다(v1 5단계가 이미 경고) | `functions/src/index.ts`, `payload_limit.ts` |
| 7 | `serverFittingCacheEnabled`가 꺼진 빌드(현재 기본)는 한 번에 방식도 `_callProxyText`(클라이언트 시한 60초)를 탄다 | `gemini_service.dart` |

## 2. 모델 정보 (2026-11-13 공식 문서 기준 — 실제 호출로 재확인할 것)

- 권장 이미지 모델: **`gemini-nano-banana-2.1`**. 참조 이미지 총 14장(객체 10·인물 4) — 전신 1 + 슬롯 8이 들어간다.
- 해상도 1K/2K/4K, 기본 1K.
- **thinking 기본값이 `medium`이다**(구 모델은 `minimal`). 모델만 바꾸면 더 느려질 수 있으므로 반드시 명시한다.
- **문서 간 불일치**: `generateContent` REST에서 이미지 크기 필드가 `generationConfig.imageConfig`인지 `generationConfig.responseFormat.image`인지, thinking 필드가 `thinkingConfig.thinkingLevel`인지 페이지마다 다르다. 최신 문서의 REST 예시는 Interactions API(`/v1beta/interactions`)를 쓴다. §3-2에서 실제 호출로 확정한다 — 문서를 믿고 코드에 박지 않는다(v1 3단계 (a)와 같은 원칙).

## 3. 1단계 — 프로브 (앱·서버 변경 없이 로컬에서 비교)

**이 단계가 끝나면 멈추고 보고한다.** 채택안은 사용자가 결과를 보고 정한다.

### 3-1. 스크립트

- 위치: `tools/fitting_probe/probe.mjs` (Node 22, 내장 `fetch`, 외부 의존성 없음) + `README.md`.
- API 키는 환경변수 `GEMINI_API_KEY`로만 받는다. 파일·로그·커밋 어디에도 남기지 않는다. URL을 로그에 찍을 때 `key=` 값은 가린다.
- 입력: `tools/fitting_probe/input/` 의 `person.jpg`, `top.jpg`, `bottom.jpg`, `outer.jpg`, `shoes.jpg`, `hat.jpg`, `bag.jpg`, `watch.jpg`.
  - 가능하면 **v1의 `set4_7벌`과 같은 아이템 원본 + 같은 전신 사진**을 쓴다(상의 `6vVNoavk…`, 하의 `ocHh3cdr…`, 모자 `cb7yrcou…`, 신발 `Z0HlgPZ6…`, 아우터 `vRnIn4pj…`, 가방 `cnwqpOYi…`, 시계 `WiyzsFM2…`). v1에서 쓴 읽기 전용 다운로드 방식으로 받는다. 썸네일이 아니라 **원본**이어야 한다. 안 되면 사용자가 직접 넣는다.
  - 입력은 축소하지 않고 그대로 보낸다. 각 파일의 픽셀 크기·바이트를 `results.md`에 기록한다.
- `input/labels.json`에 옷별 설명을 둔다(예: `"top": "네이비, 스트라이프, 레귤러 핏"`). 해당 아이템의 Firestore `attributes`와 `subCategory`에서 옮겨 적는다.
- 출력: `output/{변형}_{케이스}.png`, `output/results.md`, `output/index.html`.
- 호출마다 시한 180초를 둔다(구 모델에서 5분 이상 매달린 전례가 있다 — 논문 5.19.2). 시한 초과는 실패로 기록한다.
- 출력 해상도는 PNG/JPEG 헤더를 직접 읽어 구한다(이미지 라이브러리 설치 없이).
- `input/`, `output/`은 `.gitignore`에 추가한다.

### 3-2. 먼저 — 스키마 확정 호출

`gemini-nano-banana-2.1`에 옷 1벌 요청을 보내 아래를 확정하고 `results.md` 상단에 기록한다.

1. `generateContent` 엔드포인트가 이 모델에서 동작하는가
2. 이미지 크기·비율 필드의 실제 이름
3. thinking 수준 필드의 실제 이름, `minimal` 허용 여부
4. `responseModalities: ["IMAGE"]`(텍스트 없이) 허용 여부
5. 응답 이미지의 실제 `mimeType`과 해상도

`generateContent`가 안 되고 Interactions API만 된다면 **여기서 멈추고 보고한다** — 서버 프록시 구조가 달라져 범위를 다시 정해야 한다.

### 3-3. 비교 매트릭스

케이스는 **중첩 집합**이다(파일 목록으로 고정 — v1 슬롯 표의 설계를 그대로 살린다).

| 케이스 | 구성 |
|---|---|
| K1 | 상의 |
| K4 | 상의·하의·아우터·신발 |
| K5 | K4 + 모자 |
| K7 | K5 + 가방·시계 |

| 변형 | 모델 | 방식 | 프롬프트 | thinking | 호출 수(K1/K4/K5/K7) |
|---|---|---|---|---|---|
| A (기준선) | `gemini-3.1-flash-image` | 순차 | 현행 `_buildFittingPrompt` 그대로 | 미지정 | 1/4/5/7 |
| B | `gemini-nano-banana-2.1` | 한 번에 | 신규(§3-4) | `minimal` | 1/1/1/1 |
| C | `gemini-nano-banana-2.1` | 한 번에 | 신규 | `medium` | 1/1/1/1 |
| D | `gemini-nano-banana-2.1` | 순차 | 신규 | `minimal` | 1/4/5/7 |
| E | `gemini-nano-banana-2.1` | 코어 한 번에 → 액세서리 한 번에(2회) | 신규 | `minimal` | —/—/2/2 |

총 약 46회. 호출 사이 2초. A·D의 순차는 앱과 같은 순서(`fittingOrder`, 액세서리는 모자→가방→시계)로 이전 출력을 다음 단계 첫 이미지로 넘긴다. 실패한 호출은 1회만 재시도하고 재시도 여부를 기록한다.

A는 **앱의 현재 요청을 그대로 재현**한다 — 프롬프트의 옷 이름은 앱이 넘기는 최상위 `category`이므로 모자·가방·시계는 셋 다 `액세서리`로 들어가고, `mimeType`도 현행대로 `image/jpeg` 고정이다. 재현이 정확한지는 A의 K1 소요가 v1 실측(19초 안팎)과 같은 수준인지로 확인한다.

이 매트릭스가 답하는 것:

- **속도**: A vs B (같은 케이스)
- **H-1 누적 손실**: B vs D (같은 모델·프롬프트·입력, 단계 수만 다름)
- **H-3 모자 고유 난이도**: B의 K4 vs K5에서 모자 품질. 한 번에 방식에서도 모자가 뜨면 카테고리 고유 문제다
- **한 번에 방식의 한계**: B의 K7에서 옷 누락 여부. 누락되면 E가 대안이다

### 3-4. 신규 프롬프트 초안

이미지마다 **바로 앞에 텍스트 라벨**을 끼운다(텍스트→이미지 반복). 옷 라벨은 `labels.json`의 설명을 쓴다.

```
[text]  You are a virtual try-on engine. Edit IMAGE 1 so the person wears the items shown in the following images.
[text]  IMAGE 1 — the PERSON. This is the base image to edit.
[image] person
[text]  IMAGE 2 — ITEM (상의 / top): 네이비, 스트라이프, 레귤러 핏
[image] top
[text]  IMAGE 3 — ITEM (모자 / hat, worn on the head): 블랙 볼캡
[image] hat
...
[text]  Rules:
        - Keep the person's face, hair, skin tone, body shape, pose, camera framing and background exactly as in IMAGE 1.
        - Replace only the clothing in each item's category. Leave everything else the person wears unchanged.
        - Reproduce each item exactly: same color, pattern, print/logo, fabric texture, length and silhouette. Never redraw, restyle or invent a logo or detail.
        - Use only the item itself from each item image — ignore its background, hanger, mannequin or any other person.
        - Items must sit naturally on the body: a hat fits snugly on the head with hair visible below it, a bag is held or worn on the shoulder, a watch is on the wrist. Realistic drape, contact shadows and lighting consistent with IMAGE 1.
        - Every listed item must be worn. Show the full body. Output exactly one photorealistic image with no added text or extra items.
```

순차(D)와 E의 2회차에서는 같은 틀로 해당 호출의 아이템만 넣는다.

### 3-5. 비교 페이지 (`output/index.html`)

판정을 쉽게 하고 v1의 "확대 조건 미기록" 문제를 반복하지 않기 위해 정적 HTML 한 장을 만든다.

- 케이스별 한 줄: 입력 이미지들, 그 옆에 변형 A~E 결과를 **같은 표시 높이**로 나란히. 각 결과 아래에 총 소요 초·호출 수.
- 케이스별로 **얼굴~어깨 크롭**과 **모자 크롭** 줄을 따로 둔다. 크롭 박스는 전 변형 공통의 정규화 좌표로 잡고 좌표·배율을 페이지에 표기한다.
- 원본 전체 프레임은 클릭하면 열린다.
- 크롭은 CSS로만 한다(이미지를 잘라 새 파일로 만들지 않는다). 변형마다 출력 해상도·비율이 다를 수 있으므로 정규화 좌표를 쓴다.

### 3-6. 채택 기준 (결과를 보기 전에 고정)

- **시간**: K4 총 소요가 A의 50% 이하.
- **품질**(사용자 육안, K4·K5·K7): ① 얼굴·체형·배경 유지 ② 옷의 색·패턴·로고 일치 ③ 넣은 아이템 전부 착용 ④ 모자 밀착. 네 항목 중 A보다 나쁜 것이 없어야 한다.
- B가 둘 다 만족 → **B**. B가 품질 미달이고 C가 품질·시간 모두 만족 → **C**.
- B·C가 K4는 만족하는데 K5·K7에서 누락·붕괴 → **E**(코어 한 번에 + 액세서리 한 번에). E의 시간 기준은 K7 총 소요가 A의 50% 이하.
- 한 번에 방식이 K4에서도 누락 → **D**(순차 유지, 모델·프롬프트만 교체).
- 전부 미달이면 적용하지 않고 보고한다.

### 3-7. 1단계 보고

§0-1 확인 결과, 스키마 확정 결과, `results.md` 표, 채택 기준 대비 판정 초안, `index.html` 경로. **여기서 멈춘다.**

## 4. 2단계 — 채택안 적용 (사용자가 변형을 지정한 뒤 착수)

### 4-1. 서버 (`functions/`)

1. 이미지 모델을 상수 하나(`FITTING_IMAGE_MODEL`)로 모으고 `generateFittingImage` 엔드포인트가 이를 쓰게 한다.
2. `ALLOWED_MODELS`에 새 모델을 **추가**한다. `gemini-3.1-flash-image`는 지우지 않는다 — 이미 배포된 APK가 이 모델명을 보낸다.
3. `kindForModel`이 두 이미지 모델 모두 `"image"`를 반환하게 하고 `payload_limit.test.ts`를 갱신한다.
4. 라벨이 끼면서 parts 수가 늘어난다 — 8슬롯을 다 채운 경우(텍스트 약 11 + 이미지 9)가 `request_shape.ts` 상한(`maxPartsPerContent`, `maxInlineDataCount`) 안에 드는지 현재 값으로 계산한다. 넘으면 근거 주석과 함께 조정하고 테스트를 갱신한다.
5. 캐시 키에 버전을 넣는다 — 같은 조합이 옛 모델 결과를 캐시에서 돌려주면 개선이 보이지 않는다(v1이 캐시 히트로 회분을 버린 것과 같은 함정). `fitting_cache_key.ts`와 Dart `_buildFittingCacheKey`의 원문 앞에 `v2:`를 붙이고 양쪽 고정 벡터 테스트를 갱신한다.
6. v1 0단계의 `category` 형제 키: 한 번에 방식에서는 `category=oneshot:{아이템 수}`처럼 남겨 서버 로그로 방식과 규모를 구분할 수 있게 한다.
7. `npx tsc --noEmit`, `npm test` 통과.

### 4-2. 클라이언트 (`lib/`)

1. `_imageModel` 교체.
2. `_buildFittingPrompt`를 §3-4 구조로 교체. 옷별 설명 인자를 추가하고 `fitting_job_controller.dart`에서 `subCategory`와 `attributes?.toPromptLine()`을 넘긴다(속성이 없으면 카테고리만).
3. `generationConfig`에 프로브에서 확정한 필드명으로 thinking 수준·출력 크기·`responseModalities`를 명시한다.
4. `mimeType`을 매직 넘버로 PNG/JPEG 판별한다. 입력 축소는 하지 않는다.
5. 채택 변형에 따라:
   - **B/C**: `sequentialFittingEnabled` 기본값을 `false`로. 순차 코드는 지우지 않는다(`--dart-define=SEQUENTIAL_FITTING=true`로 복귀 가능). 플래그 위 주석("false는 회귀로의 복귀")을 새 사실에 맞게 고친다.
   - **E**: 코어(상의·하의·아우터·신발) 1회 + 액세서리 1회의 2단계 경로를 추가한다. 진행 표시는 2단계로. 액세서리 호출이 실패하면 코어 결과를 살리고 `missingCategories`에 남긴다(기존 부분 성공 규칙).
   - **D**: 플래그는 그대로 두고 모델·프롬프트·설정만 바꾼다.
6. **피팅 시도 계수**: 현재 `_beginFittingAttempt()`는 순차 경로에서만 호출된다. 한 번에 방식과 E 경로도 진입 직전에 1회 호출해 "피팅 시도 1회 = fitting 1콜" 의미를 유지한다(fail-open 처리도 순차 경로와 동일). 이걸 빠뜨리면 `fittingLimit`이 조용히 무력화된다.
7. **재시도 이중 적용 금지**: `fitting_job_controller.dart`는 `sequentialFittingEnabled`가 false면 전체를 `_withRetry`로 감싼다. E처럼 내부에서 단계별 재시도를 하는 경로가 이 분기에 걸리면 재시도가 곱해진다 — 경로별로 재시도가 정확히 한 겹만 걸리게 한다.
8. 이미지 호출의 클라이언트 시한을 120초 이상으로 한다(§1-7). 텍스트 호출의 60초는 바꾸지 않는다. 현재 배포용 APK의 `--dart-define` 값을 먼저 확인해 보고한다.
9. 한 번에 방식에서는 단계 콜백이 오지 않는다 — 피팅 화면 진행 표시가 step/total이 null일 때 어색하지 않은지 확인하고 필요하면 "합성 중…" 한 줄로 대체한다.
10. `flutter analyze`, `flutter test` 통과.

### 4-3. 배포·검증 순서

1. 함수 배포(**사용자 승인 후**, `--project ai-fashion-assistant-personal` 명시). 서버가 신·구 모델을 모두 받으므로 구 APK가 깨지지 않는다.
2. 구 APK로 피팅 1회 — 여전히 동작하는지.
3. 릴리스 APK 빌드, `adb install -r`(삭제 후 재설치 금지).
4. 실기기에서 K1/K4/K7 상당 조합 각 1회 — 클라이언트 총 소요와 서버 로그 `elapsedMs`를 v1 기준선과 나란히 표로 남긴다. 매 실행 캐시 미스 여부를 기록한다. 같은 조합 재요청 시 캐시 히트도 확인한다.
5. `fittingLimit`(시간당 6회)을 검증 중 소진하지 않게 횟수를 센다.
6. 검증이 끝나면 사용자에게 알린다 — **심사위원에게 배포해 둔 APK를 새 APK로 교체**하는 것은 사용자가 한다.

### 4-4. 커밋

- 프로브(§3)는 커밋 1개.
- 2단계는 **서버와 클라이언트의 모델 상수 변경을 같은 커밋에** 넣는다(이 저장소의 기존 규칙). 캐시 키 버전도 서버·클라이언트 같은 커밋.
- `git push`는 사용자가 지시할 때만 한다.

## 5. 금지 사항

- `firestore.rules`, `storage.rules`, 인증, App Check, 호출량 상한 값(`rate_limit.ts`)을 건드리지 않는다.
- 텍스트 모델 상수와 자기평가·추천 경로를 건드리지 않는다.
- API 키를 파일·로그·커밋에 남기지 않는다. 프로브 입력·출력 이미지를 커밋하지 않는다.
- Firestore·Storage에는 읽기만 한다(프로브 입력 다운로드). 쓰기·삭제 금지.
- `firebase deploy`는 사용자 승인 없이 실행하지 않는다.
- `ALLOWED_MODELS`에서 기존 모델을 제거하지 않는다. 순차 합성 코드를 삭제하지 않는다.
- 코디보드 슬롯 수(8)와 `fittingOrder`를 바꾸지 않는다.
- 채택 기준(§3-6)을 결과를 본 뒤 바꾸지 않는다.
- 논문(`DOT_paper_rev9.md`)·handoff 문서를 고치지 않는다. v1 문서는 §0-1의 종결 단락 외에 고치지 않는다. 결과는 이 문서 끝 "실행 기록" 절에 덧붙인다.
- 이 문서에 없는 리팩터링·이름 변경을 하지 않는다. 범위 밖 결함은 고치지 말고 보고한다.

## 6. 완료 보고 형식

1. §0-1 확인 결과(이후 커밋, v1 2~5단계 반영 여부, §1 대조)
2. 스키마 확정 결과(§3-2)
3. 프로브 결과 표와 판정 초안, `index.html` 경로
4. (2단계) 바꾼 파일 목록, 테스트 통과 수, 실기기 측정 표(v1 기준선 대비)
5. 남은 문제·범위 밖에서 발견한 것

## 실행 기록

### 2026-11-13 1단계 프로브 (사용자 터미널에서 실행, 19:44~19:56)

- 입력: v1 `set4_7벌` 원본 7장 + 전신 1장(`tools/fitting_probe/input/`, 커밋 안 함). 원자료는 `tools/fitting_probe/output/`의 `schema.json`·`results.json`·`results.md`, 비교 페이지는 `index.html`.
- **스키마 확정(§3-2)**: `generateContent`가 `gemini-nano-banana-2.1`에서 동작한다(Interactions API 불필요). 크기 `generationConfig.imageConfig.imageSize`, 비율 `generationConfig.imageConfig.aspectRatio`, thinking `generationConfig.thinkingConfig.thinkingLevel`(`minimal` 허용). `responseModalities: ["IMAGE"]` 단독 허용. 응답은 **image/jpeg**(선언·실제 일치), 880×1210(비율 지정 시 896×1200). thinking 미지정 호출은 thoughts 358토큰이 나와 기본값이 minimal이 아님을 확인했다.
- **시간(§3-6)**: K4 총 소요 A 40.2초 / B 12.9초(32%, 통과) / C 20.4초(51%, 미달) / D 45.3초(113%, 미달). E의 K7은 33.5초로 A 70.2초의 48%(통과). 재시도 0건, 전 호출 HTTP 200.
- **A 재현 확인(§3-3)**: A K1이 8.6초로 v1 실측 19.0초와 같은 수준이 **아니다**. 단계당 시간도 8.2~11.8초로 v1(11.5~16.8초)보다 일관되게 짧다. 프로브는 Functions 프록시를 거치지 않고 API를 직접 호출하므로 그 왕복분이 빠진 것으로 추정한다(검증 안 함). 변형 간 상대 비교는 같은 조건이라 유효하고, 앱에서의 절대 시간은 §4-3 실기기 측정으로 확인한다.
- **시간 표**(호출 왕복 합, 재시도 포함·호출 사이 간격 제외 — 초 / 호출 수):

  | 케이스 | A 구 모델·순차 | B 한 번에·minimal | C 한 번에·medium | D 새 모델·순차 | E 코어+액세서리 |
  |---|---|---|---|---|---|
  | K1 | 8.6 / 1 | 10.1 / 1 | 12.7 / 1 | 10.6 / 1 | — |
  | K4 | 40.2 / 4 | 12.9 / 1 | 20.4 / 1 | 45.3 / 4 | — |
  | K5 | 49.3 / 5 | 11.9 / 1 | 15.2 / 1 | 54.8 / 5 | 24.4 / 2 |
  | K7 | 70.2 / 7 | 12.7 / 1 | 26.4 / 1 | 84.1 / 7 | 33.5 / 2 |

  C는 thinking 토큰 307~861을 쓰고 B보다 3~14초 느렸다. 옷 누락 0건(전 변형·전 케이스).
- **품질 관측**(비교 시트, 각 칸 1회): ① A의 K5·K7과 D의 K7에서 얼굴 뭉개짐·배경 노이즈, B·C·E는 깨끗 — 같은 모델·프롬프트에서 B는 깨끗하고 D는 열화했으므로 H-1(누적 손실)을 지지한다. B_K7·E_K7·D_K5는 원본의 위아래 검은 띠가 사라지고 구도가 약간 확대됐다. ② 모자 로고·바지 스트라이프·가방 로고 문구는 전 변형 재현, A_K5에 목 부분 택 잔상. ③ K7 전 변형에서 모자·가방·시계 착용 — 단 **B_K7은 넣지 않은 팔찌가 오른손에 추가**됐다. ④ 한 번에 방식(B·C·E)에서 모자 밀착은 자연스러웠다 — v1의 "뜬 모자"가 재현되지 않아 H-3은 이번 관측으로는 약해졌다.
- **판정(사용자, 2026-11-13)**: **변형 B 확정.** 사용자가 비교 페이지에서 직접 확인했다(B가 A보다 훨씬 좋음). 구도 변화(검은 띠 제거·약간 확대)는 감점으로 보지 않는다. 각 칸 1회 관측이고 B_K7에 팔찌가 추가됐으므로 재현성 확인(아래)을 별도로 한다.
- **[정정 2026-11-13] B_K7 팔찌 — 위반 아님.** 위 ③의 "B_K7은 넣지 않은 팔찌가 오른손에 추가" 서술은 틀렸다. 원본 전신 사진에 있던 팔찌가 유지된 것으로 사용자가 원본과 대조해 확인했다 — "나머지 착용물은 그대로 둔다" 규칙대로의 정상 동작이다. 관측자(Claude)가 원본과 대조하지 않고 판독한 오류다. 이 정정으로 아래 재현성 확인(B2)은 근거가 없어져 실행하지 않는다.
- 범위 밖 결함: 모자 아이템의 Firestore attributes에 `핏 레ギュラー`(일본어 혼입)가 있고 B~E 프롬프트에 그대로 들어갔다. 이번에 고치지 않는다(§4 보충 6).

### 재현성 확인 계획 (B vs B2, 실행 전 고정) — [취소 2026-11-13] 실행하지 않음

> 계획의 근거였던 "B_K7 팔찌 추가"가 원본에 있던 팔찌로 정정되어(위 정정 블록) 사용자가 취소했다. `probe.mjs`의 `repeat` 명령과 변형 B2는 코드에만 남기고 실행하지 않는다. 앱에는 B 문자열을 그대로 쓴다.

- **B2**: B와 전부 같다(입력·labels.json·설정 동일). Rules의 마지막 줄만 다음으로 바꾼다.
  `- Every listed item must be worn. Do not add any item that is not in the list above — no extra jewelry, glasses or accessories. Show the full body. Output exactly one photorealistic image with no added text.`
- 실행: B K7 3회, B K4 2회, B2 K7 3회, B2 K4 2회(총 10회). `probe.mjs repeat`로 회차별 파일에 저장하고 기존 결과는 덮어쓰지 않는다.
- **판정 규칙**: K7 3회에서 "넣지 않은 아이템 추가" 건수가 B2 < B이고, B2가 ①~④에서 B보다 나쁜 항목이 없으면 B2 문자열을 채택한다. 그 외에는 B 문자열을 채택하고 팔찌 추가는 알려진 한계로 이 기록에 남긴다. 최종 확인은 사용자가 `index.html`에서 한다.

## §4 보충 (프로브 결과 반영, 2026-11-13 사용자 지시)

§4-1·§4-2를 적용할 때 아래가 우선한다.

1. **확정 값**: 모델 `gemini-nano-banana-2.1`, 한 번에 방식. `generationConfig` = `responseModalities: ["IMAGE"]`, `thinkingConfig.thinkingLevel: "minimal"`, `imageConfig.imageSize: "1K"`. `aspectRatio`는 지정하지 않는다(프로브 B와 같은 조건).
2. 앱의 프롬프트는 `tools/fitting_probe/probe.mjs`에서 B가 실제로 보낸 문자열·parts 구성을 **글자 그대로** 옮긴다. 새로 다듬지 않는다 — 검증된 것은 그 문자열이다. (Rules 마지막 줄 상수 분리는 B2 취소로 하지 않는다 — B 문자열 전체를 그대로 옮긴다.)
3. 한 번에 경로에서도 아이템 순서를 프로브와 같게 보낸다(상의→하의→아우터→신발→액세서리, 액세서리 안에서는 기존 동률 규칙 그대로).
4. 옷 라벨은 프로브의 `labels.json`과 같은 형식으로 만든다(subCategory가 있으면 그것을, 없으면 category + attributes 요약. attributes가 없으면 이름만).
5. 팔찌(8번째 슬롯)는 프로브에 없었다. 8슬롯을 다 채운 요청이 `request_shape` 상한(parts, inlineData)에 걸리지 않는지 테스트로 고정하고, §4-3 실기기 검증에 8슬롯 1회를 추가한다.
6. 모자 아이템의 일본어 속성(`レギュラー`)은 이번에 고치지 않는다. 실행 기록에 범위 밖 결함으로만 남긴다.

### 2026-11-13 2단계 배포·실기기 검증 (§4-3)

- **배포**: `firebase deploy --only functions --project ai-fashion-assistant-personal`(커밋 `2ee4304`) — 9개 함수 갱신 성공, `bg_removal_on_upload`는 변경 없음으로 건너뜀. 경고 2건(`firebase-functions` 업그레이드 권고, firebase-tools 내부 Node DEP0190)은 배포 결과와 무관함을 사용자가 확인.
- **구 APK 확인**: 20:39 KST 순차 피팅이 구 모델(`gemini-3.1-flash-image`)로 정상 완료(단계 `elapsedMs` 9919·9884, 서버 화이트리스트 유지 확인).
- **새 APK**: `flutter build apk --release`(dart-define 없음 → 한 번에 방식) → `adb install -r`. 첫 빌드가 Gradle `assembleRelease`에서 실패했고 원인 확인 없이 재실행에서 성공했다(일시적 실패로 추정).
- **측정**(서버 = `[callGeminiText] done`의 `elapsedMs`, 클라이언트 = 사용자 체감 측정, 각 1회):

  | 실행(KST) | 서버 category | 실제 아이템 | 서버 초 | 클라이언트 초 | requestBytes | responseBytes |
  |---|---|---|---|---|---|---|
  | 20:50 | `oneshot:1` | 1 | 12.8 | (미측정) | 100,296 | 1,973,157 |
  | 20:51 | `oneshot:4` | 상의·하의·신발·액세서리 1 | 10.8 | 12.33 | 346,915 | 3,379,445 |
  | 20:52 | `oneshot:6` | 상의·하의·신발·액세서리 3 | 21.6 | 23.07 | 478,479 | 4,587,341 |
  | 20:53 | `oneshot:7` | 상의·하의·신발·액세서리 4 | 23.1 | 26.87 | 521,103 | 5,516,337 |
  | 20:54 | (서버 호출 없음) | 위 7개 재요청 | — | 즉시 | — | — |

  사용자가 "7벌"·"8슬롯"으로 실행한 두 회는 history·서버 로그상 6개·7개이고 둘 다 **아우터가 없다**. 앱은 채워진 슬롯을 전부 보내므로(`selectedItems.values.whereType<WardrobeItem>()`) 아우터 슬롯이 비어 있었던 것으로 본다. 따라서 **8슬롯 전부(parts 20) 실기기 요청은 아직 관측되지 않았다**(§4 보충 5 — 단위 테스트로만 고정됨).
- **기준선 대비**:

  | 비교 | 1벌 | 4벌 | 6~7벌 |
  |---|---|---|---|
  | v1 앱 실측(구 모델·순차) | 19.0 | 단계당 11.5~16.8 × 4 ≈ 46~67 | 8단계 약 120 |
  | 프로브 A(구 모델·순차, API 직접) | 8.6 | 40.2 | 70.2(7벌) |
  | 프로브 B(새 모델·한 번에, API 직접) | 10.1 | 12.9 | 12.7(7벌) |
  | **새 APK 서버 elapsedMs** | **12.8** | **10.8** | **21.6(6) / 23.1(7)** |

  4벌은 프로브 B와 같은 수준. 6~7벌은 프로브 B(K7 12.7초)의 약 2배다 — 구성이 다르고(아우터 없음, 액세서리 3~4개; 프로브 K7은 아우터 포함·액세서리 3개) 각 1회 관측이라 원인은 가리지 않았다. 그래도 구 순차 경로(7벌 약 70초 이상) 대비 약 3배 빠르다.
- **피팅 시도 계수(§4-2-6)**: `beginFittingAttempt`가 새 APK 실행 4회에 각 1회(20:50:43, 20:51:51, 20:52:33, 20:53:29), 캐시 히트 재요청에는 호출되지 않았다. 구 APK 1회 포함 이 시간 창 fitting 5/6.
- **캐시 키 v2**: 같은 조합 재요청이 서버 호출 없이 즉시 표시됨(캐시 히트) — 새 APK가 쓴 v2 키로 조회가 맞는다.
- **관측(미해결, 범위 밖)**: ① `responseBytes`가 아이템 수에 따라 2.0MB → 5.5MB로 커진다. 프로브 B 출력 이미지는 0.7~0.8MB(base64 약 1MB)였으므로 응답에 이미지 외 내용(예: thought signature 등)이 더 실려 오는 것으로 추정한다 — 클라이언트 다운로드량에 영향. 확인하지 않았다. ② App Check: 구·새 APK 모두 `hasApp=false`("Decoding App Check token failed", enforcement 꺼져 있어 통과). 이번 변경 이전(구 APK)부터 같은 상태라 이 트랙의 결과가 아니다 — §5에 따라 손대지 않았다.
- **추가 실행(20:59, 아우터 포함·시계 제외)**: 서버 `category=oneshot:7`(아이템 7 — 8슬롯 중 시계만 비움), `requestBytes` 456,218, **서버 `elapsedMs` 42,973**, `responseBytes` 5,537,617, 사용자 측정 클라이언트 **63.55초**. 시각 분해(서버 로그): `beginFittingAttempt` 20:59:40.4 → 이미지 모델 호출 시작 20:59:58.9(**18.4초**) → 완료 21:00:41.8(43.0초) → 화면 표시까지 약 2초. 앞선 세 실행은 `beginFittingAttempt` → 호출 시작 간격이 약 0.5초였다. 이 간격은 클라이언트의 이미지 다운로드 + 요청 업로드 구간이고, 같은 시각 `getSignedImageUrls` 호출은 없었다(URL은 클라이언트 캐시) — 서버 로그만으로는 18초의 원인(네트워크·다운로드)을 가릴 수 없다. 모델 구간 43.0초도 20:53의 같은 아이템 수(7) 실행 23.1초의 약 2배다 — 업스트림 변동으로 보이나 1회 관측이다. **8슬롯 전부(parts 20) 요청은 여전히 실기기에서 관측되지 않았다.** 이 실행으로 UTC 11시 창 fitting 6/6.

## §7 후속 — 응답 축소와 준비 구간 계측 (2026-11-13 사용자 지시)

### 근거 (프로브 inspect 실측, `tools/fitting_probe/output/inspect/`)

| 구성 | 직접 호출 초 | 응답 전체 | 최종 이미지 data | thoughtSignature | thought 이미지 |
|---|---|---|---|---|---|
| K4(상의·하의·아우터·신발) | 11.3 | 4,749,785 | 975,516 | 3,773,408 | 0 |
| K7(K4 + 모자·가방·시계) | 13.9 | 5,912,785 | 945,260 | 4,966,448 | 0 |
| 아우터 없음 6(상의·하의·신발·모자·가방·시계) | 22.0 | 5,516,641 | 952,028 | 4,563,536 | 0 |
| 시계 없음 6(상의·하의·아우터·신발·모자·가방) | 18.1 | 6,764,260 | 1,065,440 | 5,697,744 | 0 |

- 응답의 80~85%가 `thoughtSignature`다. 단일 턴 요청이라 서명을 쓰지 않는다.
- 직접 호출 시간 11.3~22.0초 — 앱의 21~23초(`oneshot:6`·`oneshot:7`)는 모델 자체의 변동 범위 안이다. 아우터 없는 6개 구성은 직접 호출로도 22.0초로 앱(21.6초)과 같다.

### 지시

1. **서버: 이미지 응답에서 thoughtSignature 제거.** 대상은 `callGeminiText`에서 kind가 image인 비스트리밍 응답과 `generateFittingImage`가 클라이언트로 돌려주는 응답. `candidates[*].content.parts[*]`에서 `thoughtSignature` 키를 지우고 `thought: true`인 part는 뺀다. 그 외 필드는 그대로. 순수 함수로 분리해 단위 테스트하고, 예상 형태가 아니면 그대로 돌려주며 예외를 던지지 않는다. 로그의 `responseBytes`는 업스트림 원본 크기 그대로, 축소 후 크기는 `returnedBytes`로 추가한다. 텍스트 응답·스트리밍 경로는 건드리지 않는다. Storage 저장 이미지는 축소 전후로 같아야 한다.
2. **클라이언트: 준비 구간 계측.** 한 번에 경로에서 `generateFittingImage` 진입부터 callable 호출 직전까지(이미지 내려받기 + 인코딩)를 `clientPrepMs`로 보낸다(category와 같은 형제 키, requestBody 불변). 서버는 start 로그에 남기고, 없거나 숫자가 아니면 무시한다.
3. tsc·npm test·flutter analyze·flutter test 통과. 커밋은 inspect 1개, [1]+[2] 1개. 배포·APK 빌드는 사용자 승인 뒤. 승인 뒤 확인: 피팅 1회에서 `returnedBytes`가 1MB대인지, `clientPrepMs`가 로그에 찍히는지, 구 APK 피팅 1회가 여전히 되는지.

### 실행 기록

- 서버: `functions/src/strip_thought_signature.ts`(순수 함수, 입력 불변·총체적) + 테스트 11건. `callGeminiText`는 `kind === "image"`일 때만 적용하고 `returnedBytes`를 done 로그에 추가, "무가공 중계" 주석에 예외와 근거를 적었다. `generateFittingImage`는 Storage 캐시 이미지를 **원본 응답에서 먼저 꺼낸 뒤**(기존 순서 그대로) 축소본을 돌려준다 — 함수가 입력을 변형하지 않으므로 저장 이미지는 축소 전과 같다. 두 함수의 start 로그에 `clientPrepMs`(유한한 0 이상 숫자만, 반올림).
- 클라이언트: `clientPrepMs` = 진입부 `beginFittingAttempt` 소요 + 이번 시도의 다운로드·인코딩 소요(재시도 시 실패한 호출 시간이 섞이지 않게 시도마다 잰다). 순차 경로는 보내지 않는다.
- 구 APK 영향: 구 APK(커밋 `0613cf6` 시점) `_extractImageFromResponse`는 `candidates[0].content.parts`를 돌며 **첫 `inlineData.data`만** 읽고 다른 키는 보지 않는다 — 서명 키 제거는 영향이 없다. 구 APK도 이미지 모델 호출이 `callGeminiText`를 타므로 같이 축소된다(구 APK 로그의 1단계 `responseBytes` 2,224,487도 이미지보다 커서 같은 혜택이 예상된다 — 미확인). 한계: 응답 parts가 **전부** `thought: true`인 경우 축소 후 parts가 비어 클라이언트가 "이미지 없음" 오류를 낸다(축소 전이었다면 추론 중간 이미지를 그대로 보여줬을 것). inspect 4회에서 thought part는 0건이었다.
- 검증: `npx tsc --noEmit` 통과, `npm test` 124건 PASS, `flutter analyze` 이슈 0, `flutter test` 237건 통과.

### 2026-11-13 §7 배포·검증

- **배포**: `firebase deploy --only functions --project ai-fashion-assistant-personal`(커밋 `8155d4e`) — 9개 함수 갱신 성공, `bg_removal_on_upload` 변경 없음으로 건너뜀. 경고는 지난번과 같은 2건(firebase-functions 버전 권고, DEP0190)뿐이다.
- **기존 클라이언트의 축소 응답 처리**: 그때 폰에 설치돼 있던 APK(변형 B, 커밋 `2ee4304`, `clientPrepMs` 없음)로 21:19 피팅 1회 — `oneshot:2`, `elapsedMs` 10,455, `responseBytes` 2,483,465 → **`returnedBytes` 586,054(−76%)**. 기준으로 잡았던 "1MB대"보다 작은 것은 2벌이라 결과 이미지 자체가 작아서다(서명만 빠지고 이미지만 남은 크기). 같은 시각 피팅 history 문서가 `fittingCacheKey`와 함께 생성됐다 — 클라이언트가 축소 응답에서 이미지를 꺼내 캐시 업로드까지 마쳤다는 뜻이다.
- **8월 시점 구 APK 재설치 확인은 생략**(사용자 결정). 대신 코드로 확인했다: 구 APK(커밋 `0613cf6`)의 `_extractImageFromResponse`는 첫 `inlineData.data`만 읽고 다른 키를 보지 않으므로 서명 키 제거에 영향받지 않는다.
- **새 APK**: `flutter build apk --release`(커밋 `8155d4e`, 136.9MB) → `adb install -r`.
- **8칸 전부(아우터·상의·하의·신발·모자·가방·시계·팔찌) 실기기 1회(21:24)** — §4 보충 5의 관측:

  | 항목 | 값 |
  |---|---|
  | category | **`oneshot:8`** |
  | requestBytes | 588,031 (parts 20·inline 9 — `request_shape` 상한 경계에서 통과, 거부 없음) |
  | clientPrepMs | **419** (`beginFittingAttempt` 21:24:49.07 → 호출 시작 21:24:49.76) |
  | 서버 elapsedMs | **15,370** |
  | responseBytes → returnedBytes | 5,121,019 → **616,439 (−88%)** |
  | 사용자 체감 | 약 18초 |

  체감 18초 ≈ 준비 0.4초 + 모델 15.4초 + 응답 수신·표시 약 2초. 20:59 실행의 앞쪽 18.4초 같은 지연은 이번에는 없었다(그때 원인은 여전히 미확정 — 이제 `clientPrepMs`로 다음에 가릴 수 있다).

### 마무리 요약

| 항목 | 이전(구 모델·순차) | 이후(변형 B) |
|---|---|---|
| 4벌 | 프로브 40.2초 · v1 앱 약 46~67초 | 앱 서버 10.8초 |
| 7~8벌 | 프로브 70.2초(7) · v1 앱 8단계 약 120초 | 앱 서버 15.4초(8칸) · 21.6~43.0초(6~7, 변동) |
| 이미지 호출 수 | 옷 수만큼 | 1회 |
| 폰이 받는 응답 | 단계당 약 2.2MB × N | 약 0.6MB(서명 제거 후) |
| 품질 | 단계 수와 함께 얼굴·배경 열화 | 사용자 육안으로 A보다 훨씬 좋음 |

남은 것(범위 밖, 고치지 않음): App Check 토큰이 구·새 APK 모두 `hasApp=false`(enforcement 꺼져 있어 통과), `firebase-functions` 버전 권고, 6~7벌 모델 시간의 회차 간 변동(21.6~43.0초, 직접 호출로도 11.3~22.0초).
