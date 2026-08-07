"""배경 제거 재개 — 재검토 조건 (c) 검증: rembg 없이 onnxruntime을
직접 호출하는 경량 런타임(docs/task_background_removal_v1.md §2-3
재검토 조건 (c), 배포 스파이크에서 콜드스타트 68~70초 확인 후 착수).

`python -X importtime -c "import rembg"` 실측(2026-08-07)으로 확인된
사실: `rembg.bg`가 모듈 로드 시점에 `pymatting.alpha`를
무조건 임포트한다(alpha_matting=False가 기본값이라 실제로는 한 번도
안 쓰는데도) — 이게 numba+llvmlite+scipy.linalg 체인을 끌고 와 로컬
기준 전체 임포트 시간(1.9초)의 63%(1.2초)를 차지한다.
`remove(img, session=session)`(기본 인자, alpha_matting=False,
post_process_mask=False, putalpha=False)의 실제 실행 경로는
`naive_cutout()`뿐이라 pymatting은 애초에 실행되지 않는다 — 순수
데드 웨이트.

이 모듈은 rembg.sessions.u2netp.U2netpSession.predict()/
BaseSession.normalize()/rembg.bg.naive_cutout()/fix_image_orientation()
을 그대로 재현한다(정규화 파라미터를 rembg 소스에서 직접 확인,
임의로 정하지 않음) — onnxruntime + numpy + Pillow만 쓴다.
"""
from __future__ import annotations

import io

import numpy as np
import onnxruntime as ort
from PIL import Image, ImageOps

# rembg.sessions.u2netp.U2netpSession.predict()에서 그대로 가져온 정규화
# 파라미터 — ImageNet 평균/표준편차, 입력 크기 320x320.
_MEAN = (0.485, 0.456, 0.406)
_STD = (0.229, 0.224, 0.225)
_INPUT_SIZE = (320, 320)


def _fix_orientation(img: Image.Image) -> Image.Image:
    return ImageOps.exif_transpose(img)


def _preprocess(img: Image.Image) -> np.ndarray:
    im = img.convert("RGB").resize(_INPUT_SIZE, Image.Resampling.LANCZOS)
    im_ary = np.array(im)
    im_ary = im_ary / max(np.max(im_ary), 1e-6)

    tmp = np.zeros((im_ary.shape[0], im_ary.shape[1], 3))
    tmp[:, :, 0] = (im_ary[:, :, 0] - _MEAN[0]) / _STD[0]
    tmp[:, :, 1] = (im_ary[:, :, 1] - _MEAN[1]) / _STD[1]
    tmp[:, :, 2] = (im_ary[:, :, 2] - _MEAN[2]) / _STD[2]
    tmp = tmp.transpose((2, 0, 1))
    return np.expand_dims(tmp, 0).astype(np.float32)


def _postprocess_mask(ort_out: np.ndarray, target_size: tuple[int, int]) -> Image.Image:
    pred = ort_out[:, 0, :, :]
    ma, mi = np.max(pred), np.min(pred)
    pred = (pred - mi) / (ma - mi)
    pred = np.squeeze(pred)
    mask = Image.fromarray((pred * 255).astype("uint8"), mode="L")
    return mask.resize(target_size, Image.Resampling.LANCZOS)


def _naive_cutout(img: Image.Image, mask: Image.Image) -> Image.Image:
    empty = Image.new("RGBA", img.size, 0)
    return Image.composite(img, empty, mask)


def _bbox_crop(img: Image.Image) -> Image.Image:
    """§3-1 결정 — 기존 111건 관행(타이트 크롭)을 따른다."""
    bbox = img.getbbox()
    return img.crop(bbox) if bbox else img


class MinimalSession:
    """rembg.new_session('u2netp') + remove(session=...)의 최소 대체.
    한 인스턴스가 InferenceSession을 한 번만 들고 있다가 여러 이미지에
    재사용한다 — rembg 세션과 같은 사용 패턴."""

    def __init__(self, model_path: str):
        self._session = ort.InferenceSession(model_path, providers=["CPUExecutionProvider"])
        self._input_name = self._session.get_inputs()[0].name

    def remove(self, image_bytes: bytes, crop: bool = True) -> bytes:
        img = _fix_orientation(Image.open(io.BytesIO(image_bytes)))
        inp = _preprocess(img)
        ort_outs = self._session.run(None, {self._input_name: inp})
        mask = _postprocess_mask(ort_outs[0], img.convert("RGB").size)
        cutout = _naive_cutout(img.convert("RGB"), mask)
        if crop:
            cutout = _bbox_crop(cutout)
        buf = io.BytesIO()
        cutout.save(buf, format="PNG")
        return buf.getvalue()
