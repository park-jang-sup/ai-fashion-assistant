"""배경 제거 재개 스파이크(docs/task_background_removal_v1.md §2-1) —
모델 실행 + 비교 이미지·측정치 생성. select_and_download.py가 받아둔
inputs/ 를 읽기만 하고, 결과는 outputs/에만 쓴다(Firestore/Storage
전혀 안 건드림).

기본값으로 u2netp와 full u2net을 순서대로 돌려 원본/기존 컷아웃/
u2netp/u2net 4분할 비교 이미지를 만든다(--models로 목록 조정 가능).

측정 항목(모델별로 각각):
- 모델 로드 시간(onnxruntime InferenceSession 생성, 로컬에 이미
  캐시된 .onnx 파일 기준 — 컨테이너에 모델을 번들링한 프로덕션
  시나리오와 같은 조건. 최초 1회 네트워크 다운로드 시간은 별도로
  표시하고 이 지표에 안 넣는다).
- 장당 처리 시간(추론 1회, PIL 인코딩/디코딩 포함 — rembg.remove()
  전체를 감싼 시간).
- 피크 메모리(RSS, psutil로 폴링 스레드가 추론 도중 주기적으로
  샘플링 — 정확한 사후 프로파일링은 아니고 폴링 간격만큼의 근사치).
  모델을 두 개 이상 순서대로 돌릴 때는 직전 모델의 세션을 명시적으로
  버리고(del + gc.collect()) 그 직후 RSS를 그 모델의 "베이스라인"으로
  다시 잰다 — 안 그러면 이전 모델이 물고 있던 메모리가 다음 모델의
  측정치에 섞인다(완전히 격리되진 않는다 — OS가 즉시 페이지를
  회수하지 않을 수 있어 근사치다).
"""
from __future__ import annotations

import argparse
import gc
import io
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

MODEL_LABELS = {
    "u2netp": "u2netp(경량, 4.7MB)",
    "u2net": "u2net(full, 176MB)",
}


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


def make_comparison(panels_in: list[tuple[Image.Image, str]]) -> Image.Image:
    """(이미지, 라벨) 목록을 받아 가로로 나란히 이어붙인다 — 패널 수 무관."""
    panels = []
    for img, label in panels_in:
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


def _current_rss_mb() -> float:
    return psutil.Process().memory_info().rss / (1024 * 1024)


def run_model(model_name: str, items: list[dict], new_session, remove) -> dict:
    print(f"\n--- 모델: {model_name} ---")

    gc.collect()
    baseline_mb = _current_rss_mb()
    print(f"로드 전 RSS(직전 모델 정리 후): {baseline_mb:.1f}MB")

    # 워밍업 — 모델 파일이 로컬에 없으면 여기서 내려받는다(최초 1회만).
    # 그 네트워크 시간이 "모델 로드" 측정치에 안 섞이게 분리한다.
    warmup_start = time.perf_counter()
    warmup_session = new_session(model_name)
    warmup_elapsed_s = time.perf_counter() - warmup_start
    del warmup_session
    gc.collect()
    print(f"워밍업(모델 파일 캐시 확보, 최초 1회 네트워크 다운로드 포함 가능): {warmup_elapsed_s:.3f}s")

    load_start = time.perf_counter()
    with MemorySampler() as load_sampler:
        session = new_session(model_name)
    load_elapsed_s = time.perf_counter() - load_start
    print(f"모델 로드 시간(파일 캐시됨, InferenceSession 생성만): {load_elapsed_s:.3f}s, "
          f"로드 중 피크 RSS: {load_sampler.peak_mb:.1f}MB")

    per_item_results = []
    overall_peak_mb = load_sampler.peak_mb
    cutouts: dict[str, Image.Image] = {}

    for item in items:
        item_id = item["id"]
        original_path = INPUT_DIR / item["localOriginal"]

        infer_start = time.perf_counter()
        with MemorySampler() as infer_sampler:
            result_bytes = remove(original_path.read_bytes(), session=session)
        infer_elapsed_s = time.perf_counter() - infer_start
        overall_peak_mb = max(overall_peak_mb, infer_sampler.peak_mb)

        new_cutout_img = Image.open(io.BytesIO(result_bytes))
        new_cutout_img.load()
        cutouts[item_id] = new_cutout_img

        out_path = OUTPUT_DIR / f"{item_id}_{model_name}.png"
        out_path.write_bytes(result_bytes)

        per_item_results.append({
            "id": item_id,
            "category": item["category"],
            "subCategory": item.get("subCategory"),
            "inferenceSeconds": round(infer_elapsed_s, 3),
            "peakRssMbDuringInference": round(infer_sampler.peak_mb, 1),
            "outputImage": out_path.name,
        })
        print(f"  [{item['category']}] {item_id} — 추론 {infer_elapsed_s:.3f}s, "
              f"피크 RSS {infer_sampler.peak_mb:.1f}MB -> {out_path.name}")

    del session
    gc.collect()

    inference_times = [r["inferenceSeconds"] for r in per_item_results]
    report = {
        "model": model_name,
        "baselineRssMbBeforeLoad": round(baseline_mb, 1),
        "warmupSecondsIncludingPossibleDownload": round(warmup_elapsed_s, 3),
        "modelLoadSeconds": round(load_elapsed_s, 3),
        "peakRssMbDuringLoad": round(load_sampler.peak_mb, 1),
        "peakRssMbOverall": round(overall_peak_mb, 1),
        "inferenceSecondsMin": round(min(inference_times), 3),
        "inferenceSecondsMax": round(max(inference_times), 3),
        "inferenceSecondsMean": round(sum(inference_times) / len(inference_times), 3),
        "perItem": per_item_results,
    }
    return {"report": report, "cutouts": cutouts}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--models", default="u2netp,u2net", help="쉼표로 구분된 모델 목록(순서대로 실행)")
    args = parser.parse_args()
    model_names = [m.strip() for m in args.models.split(",") if m.strip()]

    selection_path = INPUT_DIR / "selection.json"
    if not selection_path.is_file():
        raise SystemExit(f"selection.json이 없습니다 — 먼저 select_and_download.py를 실행하세요: {selection_path}")
    manifest = json.loads(selection_path.read_text(encoding="utf-8"))
    items = manifest["selected"]
    OUTPUT_DIR.mkdir(exist_ok=True)

    print(f"\n=== 배경 제거 스파이크 — {len(items)}건 x 모델 {model_names} ===")

    from rembg import new_session, remove  # 임포트 자체도 무거워 측정 시작 이후로 늦춘다

    per_model_reports = {}
    per_model_cutouts = {}
    for model_name in model_names:
        result = run_model(model_name, items, new_session, remove)
        per_model_reports[model_name] = result["report"]
        per_model_cutouts[model_name] = result["cutouts"]

    print("\n=== 비교 이미지 생성 ===")
    for item in items:
        item_id = item["id"]
        original_img = Image.open(INPUT_DIR / item["localOriginal"])
        existing_cutout_img = Image.open(INPUT_DIR / item["localCutoutExisting"])

        panels = [
            (original_img.convert("RGB"), "원본"),
            (_flatten_on_checkerboard(existing_cutout_img), "기존 컷아웃(온디바이스 ONNX)"),
        ]
        for model_name in model_names:
            cutout_img = per_model_cutouts[model_name][item_id]
            panels.append((_flatten_on_checkerboard(cutout_img), MODEL_LABELS.get(model_name, model_name)))

        compare_img = make_comparison(panels)
        compare_out = OUTPUT_DIR / f"{item_id}_compare.png"
        compare_img.save(compare_out)
        print(f"  {item_id} -> {compare_out.name}")

    report = {
        "itemCount": len(items),
        "models": model_names,
        "perModel": per_model_reports,
        "notes": {
            "knownIssueCases": {
                "kC0gwb3bHizwF5TPp2Th": (
                    "신발, 분리된 신발끈 — u2netp는 끈이 반투명하게 사라짐, "
                    "u2net(full)에서 해소 확인(2026-08-06 재평가)."
                ),
                "MBbsBNRhzLgGQBnGPIYm": (
                    "신발, 흰색-on-흰색 저대비 — u2netp는 뒤쪽 신발 일부가 "
                    "반투명하게 지워짐, u2net(full)에서 해소 확인(2026-08-06 재평가)."
                ),
                "a0sJdOyoznPPUcSJVQFm": (
                    "상의, 원본 자체가 쇼핑앱 스크린샷(상태바·아이콘 등 UI "
                    "요소 포함) — u2netp·u2net(full) 둘 다 하단 UI 아이콘 "
                    "잔재가 남음. 모델을 바꿔도 안 고쳐지므로 모델 능력 "
                    "문제가 아니라 입력 데이터 성격 문제로 판단, 모델 선택 "
                    "기준에서 제외한다(같은 유형의 다른 스크린샷 입력 "
                    "yrD0GCANCa0ODvXVANUZ는 깔끔하게 처리됨 — 스크린샷이라고 "
                    "항상 실패하는 것도 아니라 사례별로 갈림)."
                ),
            },
            "canvasSizeConvention": (
                "기존 온디바이스 컷아웃은 피사체 경계로 타이트 크롭, rembg "
                "기본 출력은 원본 캔버스 전체 유지 — 마스크 품질과 무관한 "
                "출력 포맷 차이. 기존 111건 관행을 따르기로 확정"
                "(docs/task_background_removal_v1.md §3 참고), 알파 bbox "
                "크롭 후처리를 파이프라인에 포함 예정 — 이 스파이크 "
                "산출물 자체는 크롭 후처리 적용 전(원본 캔버스 그대로)."
            ),
        },
    }
    report_path = OUTPUT_DIR / "report.json"
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    print("\n=== 요약 ===")
    for model_name in model_names:
        r = per_model_reports[model_name]
        print(f"[{model_name}] 로드 {r['modelLoadSeconds']:.3f}s(피크 RSS {r['peakRssMbDuringLoad']:.1f}MB) | "
              f"장당 추론 평균 {r['inferenceSecondsMean']:.3f}s "
              f"(최소 {r['inferenceSecondsMin']:.3f}s, 최대 {r['inferenceSecondsMax']:.3f}s) | "
              f"전체 피크 RSS {r['peakRssMbOverall']:.1f}MB (베이스라인 {r['baselineRssMbBeforeLoad']:.1f}MB)")

    print(f"\nreport.json: {report_path}")
    print(f"비교 이미지: {OUTPUT_DIR}/<id>_compare.png")


if __name__ == "__main__":
    main()
