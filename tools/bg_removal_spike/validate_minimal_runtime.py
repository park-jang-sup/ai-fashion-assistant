"""minimal_runtime.py 검증 — rembg u2netp 출력과 픽셀 대조 + 임포트/추론
시간·피크 메모리 측정. docs/task_background_removal_v1.md §2-3 재검토
조건 (c) 검증용.

대상: 기존 15건 표본(inputs/selection.json) + 신발 22벌 전수
(inputs/selection_shoes_full.json)의 합집합(id 기준 중복 제거) — 이미
rembg u2netp 결과가 outputs/, outputs/shoes_full/에 저장돼 있어 그걸
그대로 대조군으로 쓴다(rembg 재실행 안 함).

픽셀 대조는 **크롭 전**(원본 캔버스 그대로) 상태로 한다 — bbox 크롭은
§3-1에서 이미 확정된 별개의 결정론적 후처리라 여기서 다시 검증할
필요가 없고, 섞으면 "재구현이 같은 마스크를 내는가"라는 이번 질문이
흐려진다.
"""
from __future__ import annotations

import gc
import json
import sys
import threading
import time
from pathlib import Path

import numpy as np
import psutil
from PIL import Image

if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")

SCRIPT_DIR = Path(__file__).resolve().parent
INPUT_DIR = SCRIPT_DIR / "inputs"
OUTPUT_DIR = SCRIPT_DIR / "outputs"
MODEL_PATH = str(Path.home() / ".u2net" / "u2netp.onnx")


class MemorySampler:
    def __init__(self, interval_s: float = 0.05):
        self._interval = interval_s
        self._process = psutil.Process()
        self._peak_bytes = 0
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def _run(self):
        while not self._stop.is_set():
            rss = self._process.memory_info().rss
            if rss > self._peak_bytes:
                self._peak_bytes = rss
            self._stop.wait(self._interval)

    def __enter__(self):
        self._peak_bytes = self._process.memory_info().rss
        self._thread.start()
        return self

    def __exit__(self, *exc):
        self._stop.set()
        self._thread.join()

    @property
    def peak_mb(self):
        return self._peak_bytes / (1024 * 1024)


def load_items() -> list[dict]:
    seen = {}
    for manifest_name in ("selection.json", "selection_shoes_full.json"):
        path = INPUT_DIR / manifest_name
        if not path.is_file():
            continue
        manifest = json.loads(path.read_text(encoding="utf-8"))
        for item in manifest["selected"]:
            seen[item["id"]] = item  # id 기준 중복 제거(교집합은 나중 항목으로 덮어써도 내용 동일)
    return list(seen.values())


def rembg_output_path(item_id: str) -> Path | None:
    for candidate in (OUTPUT_DIR / f"{item_id}_u2netp.png", OUTPUT_DIR / "shoes_full" / f"{item_id}_u2netp.png"):
        if candidate.is_file():
            return candidate
    return None


def main() -> None:
    items = load_items()
    print(f"검증 대상: {len(items)}건 (15건 표본 + 신발 22벌 합집합)\n")

    baseline_mb = psutil.Process().memory_info().rss / (1024 * 1024)
    print(f"임포트 전 RSS: {baseline_mb:.1f}MB")

    import_start = time.perf_counter()
    from minimal_runtime import MinimalSession  # noqa: E402  — 임포트 시간 자체가 측정 대상
    import_elapsed = time.perf_counter() - import_start
    print(f"임포트 시간(onnxruntime+numpy+Pillow만): {import_elapsed:.3f}s\n")

    load_start = time.perf_counter()
    with MemorySampler() as load_sampler:
        session = MinimalSession(MODEL_PATH)
    load_elapsed = time.perf_counter() - load_start
    print(f"모델 로드: {load_elapsed:.3f}s, 피크 RSS {load_sampler.peak_mb:.1f}MB\n")

    diffs = []
    infer_times = []
    overall_peak_mb = load_sampler.peak_mb
    missing_baseline = []

    for item in items:
        item_id = item["id"]
        original_path = INPUT_DIR / item["localOriginal"]
        rembg_path = rembg_output_path(item_id)
        if rembg_path is None:
            missing_baseline.append(item_id)
            continue

        infer_start = time.perf_counter()
        with MemorySampler() as infer_sampler:
            result_bytes = session.remove(original_path.read_bytes(), crop=False)
        infer_elapsed = time.perf_counter() - infer_start
        infer_times.append(infer_elapsed)
        overall_peak_mb = max(overall_peak_mb, infer_sampler.peak_mb)

        minimal_img = Image.open(__import__("io").BytesIO(result_bytes)).convert("RGBA")
        rembg_img = Image.open(rembg_path).convert("RGBA")

        if minimal_img.size != rembg_img.size:
            print(f"  [{item_id}] 크기 불일치! minimal={minimal_img.size} rembg={rembg_img.size}")
            continue

        a = np.array(minimal_img).astype(int)
        b = np.array(rembg_img).astype(int)
        diff = np.abs(a - b)
        mean_diff = diff.mean()
        max_diff = diff.max()
        diffs.append(mean_diff)
        print(f"  [{item['category']}] {item_id} — 추론 {infer_elapsed:.3f}s, "
              f"평균차 {mean_diff:.3f}/255, 최대차 {max_diff}")

    print(f"\n=== 요약 ({len(diffs)}건 대조, 기준 없음 {len(missing_baseline)}건: {missing_baseline}) ===")
    print(f"임포트: {import_elapsed:.3f}s (rembg 대비 §2-3 로컬 실측 1.04~1.36s)")
    print(f"모델 로드: {load_elapsed:.3f}s")
    print(f"장당 추론: 평균 {sum(infer_times)/len(infer_times):.3f}s "
          f"(최소 {min(infer_times):.3f}s, 최대 {max(infer_times):.3f}s)")
    print(f"전체 피크 RSS: {overall_peak_mb:.1f}MB (베이스라인 {baseline_mb:.1f}MB)")
    print(f"픽셀 평균차: 평균 {sum(diffs)/len(diffs):.4f}/255, 최대 {max(diffs):.4f}/255")

    report = {
        "itemCount": len(diffs),
        "missingBaseline": missing_baseline,
        "importSeconds": round(import_elapsed, 3),
        "modelLoadSeconds": round(load_elapsed, 3),
        "peakRssMbDuringLoad": round(load_sampler.peak_mb, 1),
        "peakRssMbOverall": round(overall_peak_mb, 1),
        "inferenceSecondsMean": round(sum(infer_times) / len(infer_times), 3),
        "inferenceSecondsMin": round(min(infer_times), 3),
        "inferenceSecondsMax": round(max(infer_times), 3),
        "pixelDiffMeanOverall": round(sum(diffs) / len(diffs), 4),
        "pixelDiffMax": round(max(diffs), 4),
        "perItemMeanDiff": {item_id: round(d, 4) for item_id, d in zip([i["id"] for i in items if i["id"] not in missing_baseline], diffs)},
    }
    report_path = OUTPUT_DIR / "minimal_runtime_validation.json"
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\nreport: {report_path}")


if __name__ == "__main__":
    main()
