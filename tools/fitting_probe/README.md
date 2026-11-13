# 가상 피팅 프로브 (fitting_probe)

`docs/task_fitting_quality_v2.md` §3. 앱 빌드·함수 배포 없이 이미지 모델·호출
방식(순차/한 번에)·프롬프트를 로컬에서 비교한다. 앱 코드(`lib/`)·서버
(`functions/`)와 무관한 독립 도구다.

## 안전 원칙

- API 키는 `GEMINI_API_KEY` 환경변수로만 받는다. URL이 아니라
  `x-goog-api-key` 헤더로 보내 로그 URL에 키가 남지 않고, 로그·오류 문자열에
  키가 섞여 나와도 가린다.
- `input/`(실제 옷장·전신 사진)과 `output/`(모델 출력)은 `.gitignore` 대상 —
  커밋하지 않는다.
- `fetch_inputs.py`는 Firestore·Storage를 **읽기만** 한다.

## 1. 입력 준비

`input/`에 `person.jpg`, `top.jpg`, `bottom.jpg`, `outer.jpg`, `shoes.jpg`,
`hat.jpg`, `bag.jpg`, `watch.jpg` + `labels.json`. 원본이어야 한다(썸네일·배경
제거본 금지). 입력은 축소하지 않고 그대로 보낸다.

v1 `set4_7벌` 원본을 받는 경우(서비스 계정 키는 저장소 밖 경로):

```bash
../bg_removal_spike/.venv/Scripts/python.exe fetch_inputs.py --credentials ~/secrets/personal-adminsdk.json
```

전신 사진은 history의 `fittingCacheKey`를 역산해 특정한다(스크립트 docstring
참고). 하나로 특정되지 않으면 `--person-id <wardrobe 문서 id>`로 지정한다.
`labels.json`은 각 아이템의 `subCategory` + `attributes`(앱의
`toPromptLine()` 형식)로 초안이 만들어진다 — 확인 후 필요하면 손으로 다듬는다.

## 2. 실행

```bash
export GEMINI_API_KEY=...        # PowerShell: $env:GEMINI_API_KEY = "..."
node probe.mjs schema            # §3-2 스키마 확정 호출만(약 4~6회)
node probe.mjs matrix            # §3-3 매트릭스(약 46회, 호출 사이 2초)
node probe.mjs all               # 둘 다(기본값)
node probe.mjs matrix --variants A,B --cases K4   # 부분 재실행 — 같은 칸은 덮어쓰고 나머지는 유지
node probe.mjs repeat B:K7:3 B2:K7:3   # 지정 칸만 반복(output/repeat/, 기존 결과 보존, 라운드로빈)
node probe.mjs html              # 크롭 좌표(probe.mjs 상단 CROPS)만 고친 뒤 페이지 재생성
```

- `schema`에서 `generateContent`가 새 모델에서 동작하지 않으면 거기서 멈춘다
  (§3-2 — Interactions API 탐침 결과만 기록).
- thinking 필드가 확정되지 않으면 `matrix`는 실행을 거부한다.
- 호출마다 시한 180초, 실패 시 1회만 재시도(재시도 여부 기록). 순차 경로는 앱과
  같은 부분 성공 규칙(첫 단계 실패 = 전체 실패, 이후 실패 = 직전 결과 + 누락).

## 3. 출력 (`output/`)

- `{변형}_{케이스}.{png|jpg}` — 최종 결과. 확장자는 응답 바이트의 실제 형식을 따른다.
- `steps/` — 순차·E의 단계별 중간 결과, 스키마 호출 결과.
- `schema.json`, `results.json` — 원자료. `results.md` — 표.
- `index.html` — 비교 페이지(케이스별 전체 프레임 + 얼굴~어깨·모자 CSS 크롭,
  좌표·배율 표기). 브라우저로 직접 연다.

`B2`(Rules 마지막 줄만 다른 B)는 재현성 확인용으로 만들었으나 근거가 정정되어
실행하지 않았다(docs/task_fitting_quality_v2.md 실행 기록). 앱의 프롬프트는
변형 B 문자열이고, `test/fitting_prompt_test.dart`가 이 파일의 B 문자열과
앱 문자열이 같은지 대조한다 — B 문자열을 바꾸면 그 테스트가 깨진다.
