# 자기 평가 점수 분포/변별력 모니터

앱 코드(`lib/`)와 무관한 독립 도구. `users/{uid}/recommendations`에 저장된
`candidateScores`(자기 평가 루프 — `OutfitSelfEvaluator`가 Gemini로 매긴
총점)를 읽기 전용으로 조회해, 점수가 실제로 후보를 변별하고 있는지 확인한다.

**아무 것도 쓰지 않는다.** Firestore를 조회만 하고 콘솔에 통계를 출력한다.

## 왜 필요한가

2026-07에 실측 데이터(최근 4건: `[96]`, `[68,82]`, `[65,65,65]`, `[68,88]`)를
직접 조회해보니 관측 최저값이 65였는데, 당시 `AgentPlanner._lowScoreFloor`가
60으로 박혀 있어 도달 불가능한 임계값이었다(→ `isFallback`이 이 경로로는
한 번도 켜지지 않음). 그 픽스(`_lowScoreFloor`를
`OutfitSelfEvaluator.threshold`(70) 참조로 변경) 이후에도, 점수 변별력
자체가 실사용에서 유지되는지는 코드 리뷰만으로 알 수 없다 — 그래서 이
스크립트를 상시 도구로 남겨, 필요할 때마다 재실행해 회귀를 잡는다.

## 준비

```bash
pip install -r requirements.txt
```

Firebase 콘솔에서 서비스 계정 키를 발급받아 **이 저장소 밖**의 로컬 경로에
저장한다(예: `~/secrets/personal-adminsdk.json`). 키 파일을 저장소 안에
두면 스크립트가 실행을 거부한다.

## 실행

```bash
export GOOGLE_APPLICATION_CREDENTIALS=~/secrets/personal-adminsdk.json
python score_distribution_report.py

# 또는
python score_distribution_report.py --credentials ~/secrets/personal-adminsdk.json --limit 50
```

## 옵션

| 옵션 | 기본값 | 설명 |
|---|---|---|
| `--credentials` | `GOOGLE_APPLICATION_CREDENTIALS` 환경변수 | 서비스 계정 키 JSON 로컬 경로 |
| `--limit` | 30 | 최신순으로 몇 건을 볼지 |

## 출력 항목

- **표1** — 전체 `candidateScores` 히스토그램(5점 단위, 95-100은 한 구간).
- **표2** — 추천 1건 내 후보 간 점수 차이(`max - min`) 분포와, 후보가
  2개 이상인데도 점수가 전부 동일했던 비율("변별력 없음" 신호).
- **표3** — `60~69` 데드존(채택 기준 `threshold`=70 바로 아래) 비율 —
  추천당 최종 채택 점수(`max(candidateScores)`) 기준.
- **표4** — `repairAttempted=true` 건의 수리 전/후 점수 변화율.

## 수리 전/후 판정의 한계 (표4)

`OutfitSelfEvaluator.run`은 `candidateScores`에 "원본 후보 점수, (수리 시도
시) 수리 후 점수"를 평가 순서대로 그냥 이어 붙인다. 수리가 첫 후보에서
일어난 뒤 실패해 다음 후보까지 평가되면 `[원본0, 수리0, 원본1]`처럼 수리
쌍이 앞쪽에 오고, 두 번째 후보에서 수리가 일어나면
`[원본0, 원본1, 수리1]`처럼 뒤쪽에 온다 — `repairAttempted` 불리언 하나만
으로는 배열 길이가 3 이상일 때 어느 인덱스 쌍이 수리 쌍인지 특정할 수
없다.

그래서 이 스크립트는 `candidateScores` 길이가 정확히 2인(=원본과 수리
결과만 있는, 유일하게 모호하지 않은) 문서만 "수리 전/후" 비교에 쓰고,
길이가 다른 건 억지로 추정하지 않고 "모호 케이스"로만 집계한다.
