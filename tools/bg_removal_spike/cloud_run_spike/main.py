"""배경 제거 재개 — 배포 콜드스타트 재측정: 경량 런타임(§2-5) 버전.

**같은 서비스, minimal_runtime 기반으로 교체한 것 외에는 전부
동일하다** — 리전(asia-northeast3), 메모리(1GiB), 최소 인스턴스 0,
u2netp 번들링, 입력 JPEG 재인코딩 정규화 단계, invoker 제한. §2-4
(rembg 버전, 68~70초)와의 비교 가능성이 이 측정의 핵심이라 다른
조건은 일부러 하나도 안 건드렸다.

**이 함수는 트리거 배선이 아니다.** wardrobe_images/ 업로드를 감지하지
않고, Firestore/Storage 어느 것도 읽거나 쓰지 않는다.

모델 번들링: u2netp.onnx를 이 디렉터리에 직접 두고(빌드팩이 소스
디렉터리 전체를 컨테이너에 포함) minimal_runtime.MinimalSession이
그 경로를 직접 로드한다 — 네트워크 다운로드 없음(§2-4와 동일 조건).

인증: invoker를 이 프로젝트의 Admin SDK 서비스 계정으로만 제한한다
(공개 엔드포인트 아님) — 호출 시 그 서비스 계정의 ID 토큰이 필요하다.

입력: POST 바디에 원본 이미지 바이트. 바디가 없으면 콜드스타트
시간만 재기 위한 내장 1x1 JPEG로 대체한다.
출력: JSON — 타이밍 breakdown + 결과 PNG(base64, 로컬 산출물과
직접 대조하기 위함).
"""
import base64
import io
import os
import time

# 재배포용 마커(기능 무변) — 콜드스타트를 자연 스케일다운 대기 없이
# 강제로 재현하려고 새 리비전을 만들기 위한 것뿐, 다른 설정은 전부
# 동일하게 유지한다. 재배포마다 값만 올린다: 3

_t_module_start = time.perf_counter()

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
_MODEL_PATH = os.path.join(BASE_DIR, "u2netp.onnx")

from firebase_functions import https_fn, options  # noqa: E402
from minimal_runtime import MinimalSession  # noqa: E402
from PIL import Image  # noqa: E402

_t_import_done = time.perf_counter()

# 콜드스타트 시(컨테이너 인스턴스 시작 시) 모듈 스코프에서 딱 한 번
# 로드된다 — 요청마다 다시 로드하지 않는다(§2-4 rembg 버전과 동일
# 패턴, revokeTokenOnUpload가 이미 실증한 것과 동일하게 모듈 스코프
# 초기화가 콜드스타트에 포함되고 웜 인스턴스에서는 재사용됨).
_session = MinimalSession(_MODEL_PATH)

_t_session_ready = time.perf_counter()

# 바디 없는 요청(순수 콜드스타트 핑)용 — 1x1 JPEG.
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
def bg_removal_coldstart_spike(req: https_fn.Request) -> https_fn.Response:
    t_request_start = time.perf_counter()
    image_bytes = req.get_data() or _TINY_JPEG
    # 업로드된 바이트가 유효한 이미지인지 확인 겸 JPEG로 정규화
    img = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    buf = io.BytesIO()
    img.save(buf, format="JPEG")
    result = _session.remove(buf.getvalue(), crop=False)
    t_request_done = time.perf_counter()

    body = {
        "moduleImportSeconds": round(_t_import_done - _t_module_start, 3),
        "modelLoadSeconds": round(_t_session_ready - _t_import_done, 3),
        "moduleTotalSeconds": round(_t_session_ready - _t_module_start, 3),
        "requestHandlingSeconds": round(t_request_done - t_request_start, 3),
        "resultBytes": len(result),
        "resultPngBase64": base64.b64encode(result).decode("ascii"),
    }
    import json

    return https_fn.Response(json.dumps(body), content_type="application/json")
