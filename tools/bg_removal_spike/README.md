# 배경 제거 재개 — u2netp 품질 스파이크

`docs/task_background_removal_v1.md` §2-1의 1단계(모델 품질 스파이크,
로컬 전용, 배포 없음)를 위한 도구. 실제 옷장 이미지에 u2netp를
돌려 기존 온디바이스 ONNX 컷아웃과 나란히 비교하고, 처리 시간·
모델 로드 시간·피크 메모리를 측정한다.

**읽기 전용** — Firestore/Storage의 실제 데이터를 전혀 수정하지
않는다. 원본·기존 컷아웃을 내려받기만 하고, 생성물(비교 이미지)은
전부 로컬 `inputs/`/`outputs/`에만 쓴다(둘 다 `.gitignore` 대상 —
실제 옷장 사진이라 커밋하지 않는다).

## 사용법

```bash
# 0. 가상환경(선택, 권장) — 이 스파이크 전용
python -m venv .venv
.venv\Scripts\activate   # Windows
pip install -r requirements.txt

# 1. 대상 선정 + 원본/기존 컷아웃 다운로드 (Firestore/Storage 읽기만)
python select_and_download.py --credentials <저장소 밖 서비스 계정 키 경로>

# 2. u2netp 실행 + 비교 이미지·측정치 생성
python run_spike.py
```

`select_and_download.py`는 `inputs/selection.json`에 선정 근거와
대상 목록을, `inputs/<itemId>_original.*`/`inputs/<itemId>_cutout_existing.png`
에 다운로드한 이미지를 남긴다.

`run_spike.py`는 `outputs/<itemId>_compare.png`(원본/기존 컷아웃/
u2netp 결과 3분할 이미지)와 `outputs/report.json`(장당 처리 시간,
모델 로드 시간, 피크 메모리)을 만든다.

## 선정 기준

`select_and_download.py`가 카테고리별 균등 층화 추출을 한다 —
카테고리마다 `createdAt` 오름차순으로 정렬한 뒤 **등간격 인덱스**로
뽑는다(맨 앞 N개가 아니라 앞뒤로 고르게 — 특정 업로드 배치에
쏠리지 않게 하기 위함). "잘 나올 것 같은 것"을 눈으로 고르지
않는다 — 스크립트가 결정론적으로 고른다. 원본 다운로드가 실패하는
항목(§8-3 사고로 원본이 소실된 "부분 손상" 문서 등)은 자동으로
건너뛰고 다음 인덱스로 대체, 사유를 `selection.json`에 남긴다.
