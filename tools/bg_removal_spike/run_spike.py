"""배경 제거 재개 스파이크(docs/task_background_removal_v1.md §2-1) —
u2netp 실행 + 비교 이미지·측정치 생성. select_and_download.py가 받아둔
inputs/ 를 읽기만 하고, 결과는 outputs/에만 쓴다(Firestore/Storage
전혀 안 건드림).

측정 항목:
- 모델 로드 시간(onnxruntime InferenceSession 생성, 로컬에 이미
  캐시된 .onnx 파일 기준 — 컨테이너에 모델을 번들링한 프로덕션
  시나리오와 같은 조건. 최초 1회 네트워크 다운로드 시간은 별도로
  표시하고 이 지표에 안 넣는다).
- 장당 처리 시간(추론 1회, PIL 인코딩/디코딩 포함 — rembg.remove()
  전체를 감싼 시간).
- 피크 메모리(RSS, psutil로 폴링 스레드가 추론 도중 주기적으로
  샘플링 — 정확한 사후 프로파일링은 아니고 폴링 간격만큼의 근사치).
"""
from __future__ import annotations

import json
import sys
import threading
import time
from pathlib import Path

import psutil
from PIL import Image

if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")

SCRIPT_DIR = Path(__file__).resolve().parent
INPUT_DIR = SCRIPT_DIR / "inputs"
OUTPUT_DIR = SCRIPT_DIR / "outputs"

PANEL_HEIGHT = 512
LABEL_BAR_HEIGHT = 28


def _fit_to_height(img: Image.Image, height: int) -> Image.Image:
    ratio = height / img.height
    return img.resize((max(1, round(img.width * ratio)), height))


def _checkerboard(size: tuple[int, int], cell: int = 16) -> Image.Image:
    """PNG 알파 채널을 눈으로 보기 쉽게 체크무늬 배경 위에 합성한다."""
    w, h = size
    bg = Image.new("RGB", (w, h), (255, 255, 255))
    dark = (200, 200, 200)
    for y in range(0, h, cell):
        for x in range(0, w, cell):
            if (x // cell + y // cell) % 2 == 0:
                bg.paste(dark, (x, y, min(x + cell, w), min(y + cell, h)))
    return bg


def _flatten_on_checkerboard(img: Image.Image) -> Image.Image:
    if img.mode != "RGBA":
        return img.convert("RGB")
    bg = _checkerboard(img.size)
    bg.paste(img, (0, 0), img)
    return bg


_FONT = None


def _label_font():
    global _FONT
    if _FONT is None:
        from PIL import ImageFont

        # 기본 PIL 폰트는 한글을 못 그린다(네모만 나옴) — Windows 기본
        # 한글 폰트로 대체, 없으면 기본 폰트로 폴백(글자는 깨져도 비교
        # 이미지 자체는 만들어지게).
        try:
            _FONT = ImageFont.truetype("C:/Windows/Fonts/malgun.ttf", 16)
        except OSError:
            _FONT = ImageFont.load_default()
    return _FONT


def _label(text: str, width: int) -> Image.Image:
    from PIL import ImageDraw

    bar = Image.new("RGB", (width, LABEL_BAR_HEIGHT), (30, 30, 30))
    draw = ImageDraw.Draw(bar)
    draw.text((8, 6), text, fill=(255, 255, 255), font=_label_font())
    return bar


def make_comparison(original: Image.Image, existing_cutout: Image.Image, new_cutout: Image.Image) -> Image.Image:
    panels = []
    for img, label in (
        (original.convert("RGB"), "원본"),
        (_flatten_on_checkerboard(existing_cutout), "기존 컷아웃(온디바이스 ONNX)"),
        (_flatten_on_checkerboard(new_cutout), "u2netp(서버 후보)"),
    ):
        resized = _fit_to_height(img, PANEL_HEIGHT)
        labeled = Image.new("RGB", (resized.width, PANEL_HEIGHT + LABEL_BAR_HEIGHT))
        labeled.paste(_label(label, resized.width), (0, 0))
        labeled.paste(resized, (0, LABEL_BAR_HEIGHT))
        panels.append(labeled)

    total_width = sum(p.width for p in panels) + 8 * (len(panels) - 1)
    canvas = Image.new("RGB", (total_width, PANEL_HEIGHT + LABEL_BAR_HEIGHT), (255, 255, 255))
    x = 0
    for p in panels:
        canvas.paste(p, (x, 0))
        x += p.width + 8
    return canvas


class MemorySampler:
    """추론 도중 RSS를 주기적으로 샘플링해 근사 피크 메모리를 구한다."""

    def __init__(self, interval_s: float = 0.05):
        self._interval = interval_s
        self._process = psutil.Process()
        self._peak_bytes = 0
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def _run(self) -> None:
        while not self._stop.is_set():
            rss = self._process.memory_info().rss
            if rss > self._peak_bytes:
                self._peak_bytes = rss
            self._stop.wait(self._interval)

    def __enter__(self) -> "MemorySampler":
        self._peak_bytes = self._process.memory_info().rss
        self._thread.start()
        return self

    def __exit__(self, *exc) -> None:
        self._stop.set()
        self._thread.join()

    @property
    def peak_mb(self) -> float:
        return self._peak_bytes / (1024 * 1024)


def main() -> None:
    selection_path = INPUT_DIR / "selection.json"
    if not selection_path.is_file():
        raise SystemExit(f"selection.json이 없습니다 — 먼저 select_and_download.py를 실행하세요: {selection_path}")
    manifest = json.loads(selection_path.read_text(encoding="utf-8"))
    items = manifest["selected"]
    OUTPUT_DIR.mkdir(exist_ok=True)

    print(f"\n=== u2netp 스파이크 — {len(items)}건 ===\n")

    with MemorySampler() as sampler_before_load:
        pass  # 베이스라인(모델 로드 전) 메모리 확인용

    baseline_mb = sampler_before_load.peak_mb
    print(f"모델 로드 전 RSS: {baseline_mb:.1f}MB")

    from rembg import new_session, remove  # 임포트 자체도 무거워 로드시간 측정 이후로 늦춘다

    # new_session()은 매번 새 onnxruntime.InferenceSession을 만들지만
    # (rembg가 세션을 캐싱하지 않음, BaseSession.__init__ 확인됨) 모델
    # 파일 자체는 최초 1회만 ~/.u2net/에 내려받는다. 그 네트워크
    # 다운로드 시간이 "모델 로드" 측정치에 섞이면 안 되므로(프로덕션은
    # 컨테이너에 파일이 이미 있는 상태를 가정) 워밍업으로 한 번 미리
    # 받아두고, 실제 측정은 그다음 호출로 한다.
    warmup_start = time.perf_counter()
    new_session("u2netp")
    warmup_elapsed_s = time.perf_counter() - warmup_start
    print(f"워밍업(모델 파일 캐시 확보, 최초 1회 네트워크 다운로드 포함 가능): {warmup_elapsed_s:.3f}s")

    load_start = time.perf_counter()
    with MemorySampler() as load_sampler:
        session = new_session("u2netp")
    load_elapsed_s = time.perf_counter() - load_start
    print(f"모델 로드 시간(파일 캐시됨, InferenceSession 생성만): {load_elapsed_s:.3f}s, "
          f"로드 중 피크 RSS: {load_sampler.peak_mb:.1f}MB")

    per_item_results = []
    overall_peak_mb = load_sampler.peak_mb

    for item in items:
        item_id = item["id"]
        original_path = INPUT_DIR / item["localOriginal"]
        existing_cutout_path = INPUT_DIR / item["localCutoutExisting"]

        original_img = Image.open(original_path)
        existing_cutout_img = Image.open(existing_cutout_path)

        infer_start = time.perf_counter()
        with MemorySampler() as infer_sampler:
            result_bytes = remove(original_path.read_bytes(), session=session)
        infer_elapsed_s = time.perf_counter() - infer_start
        overall_peak_mb = max(overall_peak_mb, infer_sampler.peak_mb)

        new_cutout_img = Image.open(__import__("io").BytesIO(result_bytes))
        new_cutout_out = OUTPUT_DIR / f"{item_id}_u2netp.png"
        new_cutout_out.write_bytes(result_bytes)

        compare_img = make_comparison(original_img, existing_cutout_img, new_cutout_img)
        compare_out = OUTPUT_DIR / f"{item_id}_compare.png"
        compare_img.save(compare_out)

        per_item_results.append({
            "id": item_id,
            "category": item["category"],
            "subCategory": item.get("subCategory"),
            "inferenceSeconds": round(infer_elapsed_s, 3),
            "peakRssMbDuringInference": round(infer_sampler.peak_mb, 1),
            "compareImage": compare_out.name,
        })
        print(f"  [{item['category']}] {item_id} — 추론 {infer_elapsed_s:.3f}s, "
              f"피크 RSS {infer_sampler.peak_mb:.1f}MB -> {compare_out.name}")

    inference_times = [r["inferenceSeconds"] for r in per_item_results]
    report = {
        "itemCount": len(per_item_results),
        "model": "u2netp",
        "baselineRssMbBeforeLoad": round(baseline_mb, 1),
        "warmupSecondsIncludingPossibleDownload": round(warmup_elapsed_s, 3),
        "modelLoadSeconds": round(load_elapsed_s, 3),
        "peakRssMbDuringLoad": round(load_sampler.peak_mb, 1),
        "peakRssMbOverall": round(overall_peak_mb, 1),
        "inferenceSecondsPerItem": inference_times,
        "inferenceSecondsMin": round(min(inference_times), 3),
        "inferenceSecondsMax": round(max(inference_times), 3),
        "inferenceSecondsMean": round(sum(inference_times) / len(inference_times), 3),
        "perItem": per_item_results,
    }
    report_path = OUTPUT_DIR / "report.json"
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"\n모델 로드: {load_elapsed_s:.3f}s (피크 RSS {load_sampler.peak_mb:.1f}MB)")
    print(f"장당 추론: 평균 {report['inferenceSecondsMean']:.3f}s "
          f"(최소 {report['inferenceSecondsMin']:.3f}s, 최대 {report['inferenceSecondsMax']:.3f}s)")
    print(f"전체 피크 RSS: {overall_peak_mb:.1f}MB (베이스라인 {baseline_mb:.1f}MB)")
    print(f"\nreport.json: {report_path}")
    print(f"비교 이미지: {OUTPUT_DIR}/<id>_compare.png")


if __name__ == "__main__":
    main()
