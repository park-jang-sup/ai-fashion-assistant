# 실시간 임베딩 — 클라우드 콜드스타트 스파이크

`docs/task_realtime_embedding_v1.md`(로드맵 5번, 신규 등록 아이템의
실시간 임베딩)의 클라우드 스파이크 도구. FashionCLIP 이미지 인코더를
ONNX로 변환해 `onnxruntime`으로 추론하는 경로(§10~§14가 로컬에서
검증)를 실제 Cloud Functions 배포로 재측정해 콜드스타트·메모리를
잰다.

**최소 기능 엔드포인트 하나까지다** — Firestore/Storage 읽기·쓰기
없음, 트리거 배선 없음, 클라이언트 연동 없음(§13(a) 범위). 공개
엔드포인트가 아니다 — invoker가 이 프로젝트의 Admin SDK 서비스
계정으로 제한돼 있다.

## 구조

```
cloud_run_spike/
  main.py            # 스파이크 함수 본체(https_fn.on_request)
  export_onnx.py      # fashionclip_vision.onnx(+.onnx.data) 재생성 스크립트
  requirements.txt    # firebase-functions, onnxruntime, torch/torchvision(CPU 전용 인덱스)
  .gcloudignore
  fashionclip_vision.onnx(.data)  # 재생성 산출물, git에 안 넣음(.gitignore)
```

## 전처리 — 재구현이 아니라 이식

`main.py`의 `_preprocess`는 `transformers`의 `CLIPImageProcessor`
(`TorchvisionBackend`)가 실제로 하는 연산을 소스 코드에서 직접
확인해 그대로 옮긴 것이다(`docs/task_realtime_embedding_v1.md`
§14(a) 코드 대조):

- 리사이즈: 짧은 변을 정확히 224로, 긴 변은 `int(224 * long/short)`
  (반올림이 아니라 절삭) — `torchvision.transforms.v2.functional.resize`를
  `interpolation=BICUBIC, antialias=True`로 호출.
- 중앙 크롭: `crop_top/crop_left = int((H-224)/2)` 형태(절삭).
- rescale(1/255) + normalize(OPENAI_CLIP_MEAN/STD).

`transformers`는 import하지 않는다 — 이게 이 변형이 검증된 경로
(`CLIPProcessor`+`onnxruntime`, ~10.1~10.7초)보다 가벼운 이유다.
같은 5건·같은 판정 기준(코사인 유사도 ≥0.9999997)으로 검증했다
(§14(b)(c)) — 기존 배치(`tools/export_for_kaggle`/
`tools/backfill_embeddings`)가 만든 벡터와 실제로 같은 벡터
공간임을 확인한 뒤에만 배포했다.

## ONNX 재생성

```bash
pip install torch torchvision transformers onnx onnxscript
python cloud_run_spike/export_onnx.py
```

`fashionclip_vision.onnx`(그래프, ~1.4MB)와
`fashionclip_vision.onnx.data`(외부 가중치, ~351.4MB)를 만든다 —
FashionCLIP의 텍스트 인코더는 안 쓰이므로(이미지→벡터 용도)
dynamo 트레이싱이 자동으로 그래프에서 뺀다. 이 산출물은
`patrickjohncyh/fashion-clip`에서 언제든 재생성 가능한 빌드
산출물이라 git에 커밋하지 않는다(`.gitignore`,
`tools/export_for_kaggle/embeddings.json`과 같은 원칙).

## 배포·정리

배포 전 `firebase.json`에 `embeddingspike` 코드베이스가 임시로
등록돼 있어야 한다(이미 등록됨, `docs/task_realtime_embedding_v1.md`
§13(b)). 배포·측정·롤백 절차 전부 그 문서(§13~§17)에 등록돼 있다
— **배포는 실행 전 사용자 확인 대상**이고, 측정이 끝나면 함수
삭제와 Artifact Registry 이미지 삭제를 함께 하는 롤백 절차를
사용자 승인 후 실행한다.
