"""실시간 임베딩 — 클라우드 콜드스타트 스파이크.

docs/task_realtime_embedding_v1.md §11~§14가 로컬에서 검증한 경로를
그대로 컨테이너에 올려 콜드스타트·메모리만 잰다 — Firestore/Storage
읽기·쓰기 없음, 트리거 배선 없음, 클라이언트 연동 없음(§13(a) 범위).

전처리는 CLIPImageProcessor(transformers, TorchvisionBackend)의 실제
로직을 §14(a)에서 코드로 직접 확인해 그대로 옮긴 것이다(재구현이
아니라 이식 — image_processing_backends.py의
get_resize_output_image_size/center_crop을 그대로 따랐다):
  - 리사이즈: shorter edge를 정확히 224로, 긴 변은 int(224*long/short)
    (반올림 아니라 절삭), torchvision.transforms.v2.functional.resize를
    interpolation=BICUBIC, antialias=True로 호출.
  - 중앙 크롭: crop_top/crop_left = int((H-224)/2) 형태(절삭).
  - rescale 1/255, normalize(OPENAI_CLIP_MEAN/STD).
`transformers`는 이 함수 어디에도 안 쓴다 — import하지 않는다
(§14가 병목으로 지목한 것을 걷어낸 변형).

모델: patrickjohncyh/fashion-clip의 이미지 인코더만 ONNX로 변환한
것(fashionclip_vision.onnx + .onnx.data, 이 디렉터리에 번들링 —
빌드팩이 소스 디렉터리 전체를 컨테이너에 포함하므로 네트워크
다운로드 없음, 배경 제거 스파이크와 같은 원칙).

인증: invoker를 이 프로젝트의 Admin SDK 서비스 계정으로만 제한한다
(공개 엔드포인트 아님, docs/task_realtime_embedding_v1.md §5 결정과
일치 — 이미지 URL을 받는 공개 엔드포인트는 이 스파이크의 범위가
아니다).

입력: POST 바디에 원본 이미지 바이트. 바디가 없으면 콜드스타트
시간만 재기 위한 내장 1x1 JPEG로 대체한다(배경 제거 스파이크와
동일 패턴).
출력: JSON — 타이밍 breakdown + 512차원 벡터.
"""
import os
import time

# 재배포용 마커(기능 무변) — 콜드스타트를 자연 스케일다운 대기 없이
# 강제로 재현하려고 새 리비전을 만들기 위한 것뿐, 다른 설정은 전부
# 동일하게 유지한다(§2-6 방법론). 재배포마다 값만 올린다: 1

_t_module_start = time.perf_counter()

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
_MODEL_PATH = os.path.join(BASE_DIR, "fashionclip_vision.onnx")

import torch  # noqa: E402

_t_torch_imported = time.perf_counter()

from torchvision.transforms.v2 import functional as tvF  # noqa: E402

_t_torchvision_imported = time.perf_counter()

import onnxruntime as ort  # noqa: E402

_t_onnxruntime_imported = time.perf_counter()

import numpy as np  # noqa: E402
from PIL import Image  # noqa: E402
from firebase_functions import https_fn, options  # noqa: E402

_t_import_done = time.perf_counter()

# 콜드스타트 시(컨테이너 인스턴스 시작 시) 모듈 스코프에서 딱 한 번
# 로드된다 — 요청마다 다시 로드하지 않는다(배경 제거 스파이크와
# 동일 패턴, 웜 인스턴스에서는 재사용됨).
_session = ort.InferenceSession(_MODEL_PATH, providers=["CPUExecutionProvider"])

_t_session_ready = time.perf_counter()

# CLIPImageProcessor(patrickjohncyh/fashion-clip)에서 직접 확인한 값
# (docs/task_realtime_embedding_v1.md §9/§11 — 하드코딩이 아니라 그대로
# 옮긴 것).
_MEAN = [0.48145466, 0.4578275, 0.40821073]
_STD = [0.26862954, 0.26130258, 0.27577711]
_TARGET_SHORT = 224
_CROP_SIZE = 224


def _preprocess(img: Image.Image) -> np.ndarray:
    """image_processing_backends.py의 get_resize_output_image_size +
    TorchvisionBackend.resize/center_crop/rescale_and_normalize를
    그대로 재현(§14(a) 코드 대조 결과)."""
    if img.mode != "RGB":
        img = img.convert("RGB")
    arr = np.asarray(img)
    t = torch.from_numpy(arr.copy()).permute(2, 0, 1)

    height, width = t.shape[-2:]
    if width <= height:
        short, long = width, height
    else:
        short, long = height, width
    new_short = _TARGET_SHORT
    new_long = int(_TARGET_SHORT * long / short)  # 반올림 아니라 절삭
    if width <= height:
        new_h, new_w = new_long, new_short
    else:
        new_h, new_w = new_short, new_long

    resized = tvF.resize(
        t, [new_h, new_w], interpolation=tvF.InterpolationMode.BICUBIC, antialias=True
    )

    img_h, img_w = resized.shape[-2:]
    crop_top = int((img_h - _CROP_SIZE) / 2.0)  # 반올림 아니라 절삭
    crop_left = int((img_w - _CROP_SIZE) / 2.0)
    cropped = tvF.crop(resized, crop_top, crop_left, _CROP_SIZE, _CROP_SIZE)

    pixel = cropped.to(torch.float32) / 255.0
    mean_t = torch.tensor(_MEAN).view(3, 1, 1)
    std_t = torch.tensor(_STD).view(3, 1, 1)
    pixel = (pixel - mean_t) / std_t

    return pixel.unsqueeze(0).numpy().astype(np.float32)


# 바디 없는 요청(순수 콜드스타트 핑)용 — 1x1 JPEG(배경 제거 스파이크와 동일).
_TINY_JPEG = bytes.fromhex(
    "ffd8ffe000104a46494600010100000100010000ffdb004300030202020202"
    "03020202030303030406040404040408060605070908080807080808090a0c"
    "0a0a0b0a08080c100c0a0c0e0d0e0f0f0f090b1119110f180f0f0e00ffc9000"
    "b0800010001010011ffcc00060010100000ffda0008010100003f00d2cff03"
    "fffd9"
)

_ADMIN_SA = "firebase-adminsdk-fbsvc@ai-fashion-assistant-personal.iam.gserviceaccount.com"


@https_fn.on_request(
    region="asia-northeast3",
    memory=options.MemoryOption.GB_1,
    timeout_sec=60,
    min_instances=0,
    max_instances=1,
    invoker=[_ADMIN_SA],
)
def embedding_coldstart_spike(req: https_fn.Request) -> https_fn.Response:
    t_request_start = time.perf_counter()
    image_bytes = req.get_data() or _TINY_JPEG

    import io

    img = Image.open(io.BytesIO(image_bytes))
    t_preprocess_start = time.perf_counter()
    pixel_values = _preprocess(img)
    t_preprocess_done = time.perf_counter()

    out = _session.run(None, {"pixel_values": pixel_values})[0]
    t_inference_done = time.perf_counter()

    body = {
        "importTorchSeconds": round(_t_torch_imported - _t_module_start, 3),
        "importTorchvisionSeconds": round(_t_torchvision_imported - _t_torch_imported, 3),
        "importOnnxruntimeSeconds": round(_t_onnxruntime_imported - _t_torchvision_imported, 3),
        "importRestSeconds": round(_t_import_done - _t_onnxruntime_imported, 3),
        "moduleImportTotalSeconds": round(_t_import_done - _t_module_start, 3),
        "sessionLoadSeconds": round(_t_session_ready - _t_import_done, 3),
        "moduleTotalSeconds": round(_t_session_ready - _t_module_start, 3),
        "preprocessSeconds": round(t_preprocess_done - t_preprocess_start, 3),
        "inferenceSeconds": round(t_inference_done - t_preprocess_done, 3),
        "requestHandlingSeconds": round(t_inference_done - t_request_start, 3),
        "embeddingDim": int(out.shape[-1]),
        "embedding": out[0].tolist(),
    }
    import json

    return https_fn.Response(json.dumps(body), content_type="application/json")
