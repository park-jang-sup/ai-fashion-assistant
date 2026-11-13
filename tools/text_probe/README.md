# 텍스트 모델 프로브 (text_probe)

`docs/task_text_model_v1.md` §3. 앱 빌드·함수 배포 없이 텍스트 모델 후보
(G0 `gemini-3.5-flash` 현행 / G1 `gemini-3.8-flash` / C `claude-sonnet-5-5`)를
**같은 프롬프트**로 비교한다. 구조·관례는 `tools/fitting_probe`를 따른다.

## 안전 원칙

- 키는 환경변수로만 받는다: `GEMINI_API_KEY`(`x-goog-api-key` 헤더),
  `ANTHROPIC_API_KEY`(`x-api-key` 헤더). URL에 싣지 않고, 로그·오류에 섞여도 가린다.
- `ANTHROPIC_API_KEY`가 없으면 Gemini 후보만 돌리고 결과에 그 사실을 적는다.
- `input/`(옷장 속성·프롬프트)과 `output/`(모델 응답)은 `.gitignore` 대상이다.
- `fetch_items.py`는 Firestore를 **읽기만** 한다.

## 1. 입력 준비 (키 불필요)

```bash
# ① 아이템 속성(자기평가 55벌 + 피팅 세트 7벌) → input/items.json
../bg_removal_spike/.venv/Scripts/python.exe fetch_items.py --credentials ~/secrets/personal-adminsdk.json
# ② 앱 프롬프트 빌더 출력 → input/prompts.json (저장소 루트에서)
TEXT_PROBE_DUMP=1 flutter test test/text_probe_dump_test.dart
```

②는 `test/text_probe_dump_test.dart`가 `GeminiService`·`AgentPlanner`의 빌더를
그대로 불러 만든다 — 프로브는 프롬프트를 다시 쓰지 않는다. 환경변수 없이
`flutter test`를 돌리면 이 테스트는 건너뛰고 파일을 쓰지 않는다.

이미지: T2는 `tools/eval_harness_selfeval/labeling_material/images/`의 itemId
오름차순 앞 20장, T4는 `tools/fitting_probe/input/person.jpg`.

## 2. 실행 (키 필요 — 사용자 터미널)

PowerShell에서 명령 기록에 키가 남지 않게 입력받는다:

```powershell
$env:GEMINI_API_KEY = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR((Read-Host "Gemini key" -AsSecureString)))
$env:ANTHROPIC_API_KEY = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR((Read-Host "Anthropic key" -AsSecureString)))
node tools/text_probe/probe.mjs schema   # §3-2 스키마 확정(약 25회, 1~2분)
node tools/text_probe/probe.mjs run      # §3-3 측정(약 258회)
```

- `run --candidates G0,G1 --tasks T1`처럼 일부만 다시 돌릴 수 있다(같은 칸은 덮어씀).
- `report`는 호출 없이 `results.json`에서 `results.md`·`index.html`만 다시 만든다.
- 호출당 시한 90초, 실패는 1회만 재시도, 제공자별 동시 3건.

## 3. 과제

| 과제 | 내용 | 후보당 호출 |
|---|---|---|
| T1 자기평가 | 쌍 15개 좌·우 30조합 × 2회, `analyzeOutfitFromAttributes`와 같은 프롬프트(사진·이력 없음) | 60 |
| T2 속성 추출 | 20장, `extractAttributes` 프롬프트(한국어 강제 한 줄 포함) | 20 |
| T3 주간 플랜 | 30벌 카탈로그 + 7일 고정 일정·예보, 3회 | 3 |
| T4 스트리밍 분석 | 전신 사진 + 조합 3개, 스트리밍 | 3 |

Gemini는 앱의 `generationConfig`를 그대로 쓴다(`schema`에서 거부된 필드는 확정한
대체 값으로). Claude는 `schema`에서 확정한 설정(온도 없음, 사고 최소)을 쓴다.

## 4. 출력 (`output/`)

- `schema.json`, `results.json` — 원자료(응답 본문 포함).
- `results.md` — 스키마 확정 결과, 과제별 표, 관문별 판정 초안(§3-4).
- `index.html` — 과제별 표, T1 점수 분포, T4·T1 일부 본문을 후보별로 나란히.
