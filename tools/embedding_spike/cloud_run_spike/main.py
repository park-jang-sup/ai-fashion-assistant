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

[배포 시행착오, 2026-08-13] 무거운 임포트(torch/torchvision/
onnxruntime)+모델 로딩을 모듈 스코프에 그대로 두면 `firebase
deploy`의 로컬 배포 검사(discovery) 단계가 실패한다 —
"User code failed to load. Cannot determine backend specification.
Timeout after 10000"(Firebase 공식 문서 "avoid deployment timeouts
during initialization" 항목과 정확히 일치). 로컬 discovery는 실제
Cloud Run 콜드스타트가 아니라 별도의 10초 제한 검사이고, 이 제한은
firebase_functions.core.init 훅으로 무거운 초기화를 감싸 로컬
검사 단계에서는 건너뛰고 **실제 배포된 인스턴스가 뜰 때만**
실행되게 하는 것으로 우회한다(공식 권장 패턴 — 환경변수로 타임아웃을
늘리는 대안도 있으나, 이 방식이 로컬 검사 자체의 성격과 더
맞는다). 콜드스타트 측정 유효성에는 영향 없다 — init 훅은 "인스턴스당
1회, 함수 코드 실행 전"에 실제로 도는 것으로 문서화돼 있어 여전히
콜드스타트에 포함된다.
"""
import os
import time

# 재배포용 마커(기능 무변) — 콜드스타트를 자연 스케일다운 대기 없이
# 강제로 재현하려고 새 리비전을 만들기 위한 것뿐, 다른 설정은 전부
# 동일하게 유지한다(§2-6 방법론). 재배포마다 값만 올린다: 3

from firebase_functions import core, https_fn, options

_ADMIN_SA = "firebase-adminsdk-fbsvc@ai-fashion-assistant-personal.iam.gserviceaccount.com"

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
_MODEL_PATH = os.path.join(BASE_DIR, "fashionclip_vision.onnx")

# CLIPImageProcessor(patrickjohncyh/fashion-clip)에서 직접 확인한 값
# (docs/task_realtime_embedding_v1.md §9/§11 — 하드코딩이 아니라 그대로
# 옮긴 것).
_MEAN = [0.48145466, 0.4578275, 0.40821073]
_STD = [0.26862954, 0.26130258, 0.27577711]
_TARGET_SHORT = 224
_CROP_SIZE = 224

# 바디 없는 요청(순수 콜드스타트 핑)용 — 1x1 JPEG(배경 제거 스파이크와 동일).
_TINY_JPEG = bytes.fromhex(
    "ffd8ffe000104a46494600010100000100010000ffdb004300030202020202"
    "03020202030303030406040404040408060605070908080807080808090a0c"
    "0a0a0b0a08080c100c0a0c0e0d0e0f0f0f090b1119110f180f0f0e00ffc9000"
    "b0800010001010011ffcc00060010100000ffda0008010100003f00d2cff03"
    "fffd9"
)

# 무거운 임포트·모델 로딩 결과를 담는 상태 — @core.init이 실제 Cloud Run
# 인스턴스에서만 채운다(로컬 배포 검사에서는 이 함수 자체가 안 불린다).
_state: dict = {}


@core.init
def _initialize() -> None:
    t_module_start = time.perf_counter()

    import torch

    t_torch_imported = time.perf_counter()

    from torchvision.transforms.v2 import functional as tvF

    t_torchvision_imported = time.perf_counter()

    import onnxruntime as ort

    t_onnxruntime_imported = time.perf_counter()

    import numpy as np
    from PIL import Image

    t_import_done = time.perf_counter()

    session = ort.InferenceSession(_MODEL_PATH, providers=["CPUExecutionProvider"])

    t_session_ready = time.perf_counter()

    _state.update(
        torch=torch,
        tvF=tvF,
        np=np,
        Image=Image,
        session=session,
        importTorchSeconds=round(t_torch_imported - t_module_start, 3),
        importTorchvisionSeconds=round(t_torchvision_imported - t_torch_imported, 3),
        importOnnxruntimeSeconds=round(t_onnxruntime_imported - t_torchvision_imported, 3),
        importRestSeconds=round(t_import_done - t_onnxruntime_imported, 3),
        moduleImportTotalSeconds=round(t_import_done - t_module_start, 3),
        sessionLoadSeconds=round(t_session_ready - t_import_done, 3),
        moduleTotalSeconds=round(t_session_ready - t_module_start, 3),
    )


def _preprocess(img):
    """image_processing_backends.py의 get_resize_output_image_size +
    TorchvisionBackend.resize/center_crop/rescale_and_normalize를
    그대로 재현(§14(a) 코드 대조 결과)."""
    torch = _state["torch"]
    tvF = _state["tvF"]
    np = _state["np"]

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

    img = _state["Image"].open(io.BytesIO(image_bytes))
    t_preprocess_start = time.perf_counter()
    pixel_values = _preprocess(img)
    t_preprocess_done = time.perf_counter()

    out = _state["session"].run(None, {"pixel_values": pixel_values})[0]
    t_inference_done = time.perf_counter()

    body = {
        "importTorchSeconds": _state["importTorchSeconds"],
        "importTorchvisionSeconds": _state["importTorchvisionSeconds"],
        "importOnnxruntimeSeconds": _state["importOnnxruntimeSeconds"],
        "importRestSeconds": _state["importRestSeconds"],
        "moduleImportTotalSeconds": _state["moduleImportTotalSeconds"],
        "sessionLoadSeconds": _state["sessionLoadSeconds"],
        "moduleTotalSeconds": _state["moduleTotalSeconds"],
        "preprocessSeconds": round(t_preprocess_done - t_preprocess_start, 3),
        "inferenceSeconds": round(t_inference_done - t_preprocess_done, 3),
        "requestHandlingSeconds": round(t_inference_done - t_request_start, 3),
        "embeddingDim": int(out.shape[-1]),
        "embedding": out[0].tolist(),
    }
    import json

    return https_fn.Response(json.dumps(body), content_type="application/json")
