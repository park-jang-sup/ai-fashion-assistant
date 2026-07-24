# 옷장 아이템 임베딩 백필

`tools/export_for_kaggle/embeddings.json`(Kaggle 임베딩 비교 실험 산출물)을
Firestore `wardrobe` 컬렉션 각 문서에 `embedding` 필드로 채워 넣는다.
앱 코드(`lib/`)는 건드리지 않는다.

## 준비

```bash
pip install -r requirements.txt
```

서비스 계정 키는 `tools/export_for_kaggle/export.py`와 동일한 원칙: 이
저장소 밖 로컬 경로에 두고 환경변수로만 참조한다.

## 실행

```bash
export GOOGLE_APPLICATION_CREDENTIALS=~/secrets/ai-fashion-assistant-firebase-adminsdk.json

# 1) 먼저 dry-run — 아무것도 쓰지 않고 무엇이 바뀔지만 확인
python backfill.py

# 2) 결과 확인 후 실제 반영
python backfill.py --apply

# 이미 embedding이 있는 문서까지 다시 채우려면
python backfill.py --apply --force
```

| 옵션 | 기본값 | 설명 |
|---|---|---|
| `--credentials` | `$GOOGLE_APPLICATION_CREDENTIALS` | 서비스 계정 키 경로 |
| `--embeddings-file` | `tools/export_for_kaggle/embeddings.json` | 임베딩 파일 경로 |
| `--model-name` | `patrickjohncyh/fashion-clip` | 파일이 평면 형식(`{itemId: [...]}`)이라 모델명이 없을 때만 쓰이는 기본값 |
| `--dim` | `512` | 위와 동일한 경우의 차원 기본값 |
| `--force` | off | 이미 `embedding` 필드가 있는 문서도 덮어쓰기 |
| `--apply` | off | 실제로 Firestore에 쓴다. **없으면 항상 dry-run** |
| `--sample-count` | `3` | dry-run 시 상세 출력할 샘플 개수 |

## Firestore 스키마

```
wardrobe/{itemId}:
  ...
  embedding:
    model:     "patrickjohncyh/fashion-clip"
    dim:       512
    vector:    [0.0123, -0.0456, ...]   # 길이 512, L2 정규화됨
    createdAt: <서버 타임스탬프>
```

## 동작

- `category == "전신"`인 문서는 스킵(착장 스냅 사진이라 임베딩 대상 아님).
- `embeddings.json`에 없는 itemId는 스킵.
- 이미 `embedding` 필드가 있는 문서는 `--force` 없으면 스킵.
- 저장 전 벡터 검증: 길이 512, 전부 유한한 float(NaN/inf 없음), L2 norm이
  0.99~1.01 범위인지 확인. 하나라도 어긋나면 그 아이템은 실패로 카운트하고
  건너뛴다(캐글에서 정규화했더라도 JSON 직렬화를 거쳤으니 한 번 더 확인).
- 실행 후 카운트 보고: 저장 성공/스킵(이미 있음)/스킵(전신)/스킵(파일에 없음)/실패(검증)/실패(쓰기).
