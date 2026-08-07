"""배경 제거 재개 스파이크(docs/task_background_removal_v1.md §2-1) —
대상 선정 + 원본/기존 컷아웃 다운로드. **읽기 전용**: wardrobe 컬렉션과
Storage 객체를 조회·다운로드만 하고, 어떤 문서·파일도 쓰거나 지우지
않는다.

선정 방법: ownerUid가 실제 사용자(uid는 --uid로 지정, 기본값은 이
세션에서 계속 써온 본인 계정)인 wardrobe 문서 중 imagePath와
cutoutPath(=온디바이스 ONNX로 이미 만들어진 컷아웃)가 둘 다 있는
것만 후보로 삼는다. 기본 모드는 카테고리별로 createdAt 오름차순
정렬 후 등간격 인덱스로 뽑는다 — 특정 업로드 배치(같은 날 한꺼번에
올린 것들)에 쏠리지 않게 하기 위해서다. "결과가 잘 나올 것 같은
것"을 사람이 눈으로 고르지 않는다.

--category를 주면 표본 추출을 하지 않고 그 카테고리 **전수**를
선정한다(신발 22벌 전수 평가처럼 표본 대신 전량이 필요할 때).
--tag를 주면 selection_<tag>.json으로 별도 저장해 기존 선정
(기본 selection.json, 5카테고리 x 3건)과 섞이지 않는다 — 다운로드된
원본/컷아웃 파일 자체는 item id로 이름 붙어 공유되므로 겹치는
항목은 중복 다운로드 없이 재사용된다.

원본 다운로드가 실패하는 항목(예: §8-3 사고로 원본이 소실된 문서)은
표본 모드에서는 같은 카테고리의 다음 인덱스로 자동 대체하고,
전수 모드(--category)에서는 그냥 제외한다(대체할 다음 순번 개념이
없음 — 전수이므로).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

try:
    import firebase_admin
    from firebase_admin import credentials, firestore, storage
except ImportError:
    print("firebase-admin이 설치되어 있지 않습니다: pip install -r requirements.txt", file=sys.stderr)
    raise

if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent
INPUT_DIR = SCRIPT_DIR / "inputs"

DEFAULT_BUCKET = "ai-fashion-assistant-personal.firebasestorage.app"
DEFAULT_UID = "BDDOIl08EhXnHu6oz6Zro47EtMw1"
PER_CATEGORY = 3  # 5개 카테고리 x 3 = 15


def _reject_repo_path(resolved: Path, hint: str) -> None:
    if REPO_ROOT in resolved.parents or resolved == REPO_ROOT:
        print(
            f"서비스 계정 키를 이 저장소 안에 두지 마세요 ({hint}) — "
            f"저장소 밖의 안전한 경로를 쓰세요.",
            file=sys.stderr,
        )
        sys.exit(1)


def _load_credentials(cred_path_str: str | None) -> credentials.Certificate:
    if cred_path_str:
        resolved = Path(os.path.expanduser(cred_path_str)).resolve()
        if not resolved.is_file():
            print(f"서비스 계정 키 파일을 찾을 수 없습니다: {resolved}", file=sys.stderr)
            sys.exit(1)
        _reject_repo_path(resolved, "--credentials")
        return credentials.Certificate(str(resolved))

    env_path_str = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    if env_path_str:
        resolved = Path(os.path.expanduser(env_path_str)).resolve()
        if not resolved.is_file():
            print(
                f"GOOGLE_APPLICATION_CREDENTIALS가 가리키는 파일을 찾을 수 없습니다: {resolved}",
                file=sys.stderr,
            )
            sys.exit(1)
        _reject_repo_path(resolved, "GOOGLE_APPLICATION_CREDENTIALS")
        return credentials.Certificate(str(resolved))

    print(
        "서비스 계정 키가 없습니다. --credentials 또는 GOOGLE_APPLICATION_CREDENTIALS "
        "환경변수로 지정하세요.",
        file=sys.stderr,
    )
    sys.exit(1)


def _spaced_indices(n: int, k: int) -> list[int]:
    """0..n-1 범위에서 k개를 등간격으로 고른다(맨 앞 k개가 아니라)."""
    if n <= k:
        return list(range(n))
    return [round(i * (n - 1) / (k - 1)) for i in range(k)] if k > 1 else [n // 2]


def _ext_from_path(path: str) -> str:
    suffix = Path(path).suffix
    return suffix if suffix else ".jpg"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--credentials", help="서비스 계정 키 경로(저장소 밖). 생략 시 GOOGLE_APPLICATION_CREDENTIALS 사용")
    parser.add_argument("--uid", default=DEFAULT_UID, help=f"대상 사용자 uid(기본 {DEFAULT_UID})")
    parser.add_argument("--bucket", default=DEFAULT_BUCKET, help="Storage 버킷 이름")
    parser.add_argument("--per-category", type=int, default=PER_CATEGORY, help="카테고리당 선정 개수(표본 모드)")
    parser.add_argument("--category", help="지정하면 표본 대신 이 카테고리 전수를 선정한다(예: 신발)")
    parser.add_argument("--tag", help="selection_<tag>.json으로 별도 저장(기본 selection.json과 안 섞이게)")
    args = parser.parse_args()

    cred = _load_credentials(args.credentials)
    app = firebase_admin.initialize_app(cred, {"storageBucket": args.bucket})
    db = firestore.client(app=app)
    bucket = storage.bucket(app=app)

    print(f"\n=== 배경 제거 스파이크 — 대상 선정 (uid={args.uid}) ===\n")

    docs = list(db.collection("wardrobe").where("ownerUid", "==", args.uid).stream())
    candidates_by_category: dict[str, list[dict]] = {}
    for doc in docs:
        data = doc.to_dict() or {}
        image_path = data.get("imagePath")
        cutout_path = data.get("cutoutPath")
        if not image_path or not cutout_path:
            continue
        category = data.get("category") or "(미분류)"
        created_at = data.get("createdAt")
        candidates_by_category.setdefault(category, []).append({
            "id": doc.id,
            "category": category,
            "subCategory": data.get("subCategory"),
            "createdAt": created_at.isoformat() if created_at else None,
            "imagePath": image_path,
            "cutoutPath": cutout_path,
        })

    print(f"후보 총 {sum(len(v) for v in candidates_by_category.values())}건, "
          f"카테고리 {len(candidates_by_category)}개: "
          f"{', '.join(f'{k}={len(v)}' for k, v in candidates_by_category.items())}\n")

    selected: list[dict] = []
    excluded: list[dict] = []
    INPUT_DIR.mkdir(exist_ok=True)

    full_mode = args.category is not None
    if full_mode:
        if args.category not in candidates_by_category:
            print(f"카테고리 '{args.category}'에 후보가 없습니다. "
                  f"가능한 카테고리: {sorted(candidates_by_category)}", file=sys.stderr)
            sys.exit(1)
        categories_to_process = {args.category: candidates_by_category[args.category]}
    else:
        categories_to_process = candidates_by_category

    for category, items in sorted(categories_to_process.items()):
        items.sort(key=lambda x: x["createdAt"] or "")

        if full_mode:
            # 전수 모드 — 표본 추출 없이 전부 순서대로, 대체 없음(실패하면 그냥 제외).
            order = list(range(len(items)))
            primary_idx = set(order)
            target_n = len(items)
        else:
            # 다운로드 실패 시 대체할 수 있도록 등간격 인덱스 + 나머지 순서를
            # 우선순위 큐로 둔다(등간격으로 뽑은 것 먼저, 나머지는 등간격
            # 지점에서 가까운 순).
            target_n = min(args.per_category, len(items))
            primary_idx = set(_spaced_indices(len(items), target_n))
            remaining_idx = [i for i in range(len(items)) if i not in primary_idx]
            order = list(primary_idx) + remaining_idx

        picked_for_category = 0
        for idx in order:
            if not full_mode and picked_for_category >= target_n:
                break
            item = items[idx]
            was_primary = idx in primary_idx
            try:
                original_bytes = bucket.blob(item["imagePath"]).download_as_bytes()
                cutout_bytes = bucket.blob(item["cutoutPath"]).download_as_bytes()
            except Exception as e:  # noqa: BLE001 — 다운로드 실패는 전부 제외/대체 사유로 기록
                excluded.append({**item, "excludeReason": f"다운로드 실패: {e}", "wasPrimaryPick": was_primary})
                print(f"  [{category}] {item['id']} 다운로드 실패 — 건너뜀 ({e})")
                continue

            ext = _ext_from_path(item["imagePath"])
            original_out = INPUT_DIR / f"{item['id']}_original{ext}"
            cutout_out = INPUT_DIR / f"{item['id']}_cutout_existing.png"
            original_out.write_bytes(original_bytes)
            cutout_out.write_bytes(cutout_bytes)

            item["localOriginal"] = original_out.name
            item["localCutoutExisting"] = cutout_out.name
            item["wasPrimaryPick"] = was_primary
            selected.append(item)
            picked_for_category += 1
            pick_label = "전수" if full_mode else ("등간격" if was_primary else "대체")
            print(f"  [{category}] {item['id']} 선정 ({pick_label}) — "
                  f"{original_out.name}, {cutout_out.name}")

    manifest = {
        "uid": args.uid,
        "bucket": args.bucket,
        "mode": "full_category" if full_mode else "stratified_sample",
        "category": args.category,
        "perCategory": None if full_mode else args.per_category,
        "selectionMethod": (
            f"'{args.category}' 카테고리 전수 선정(표본 추출 없음). "
            "원본 다운로드 실패 시 제외(excluded 목록 참고, 대체 없음)."
            if full_mode else
            "카테고리별 createdAt 오름차순 정렬 후 등간격 인덱스로 "
            f"{args.per_category}개씩 선정. 원본 다운로드 실패 시 같은 "
            "카테고리의 다음 순번으로 자동 대체(excluded 목록 참고)."
        ),
        "selected": selected,
        "excluded": excluded,
    }
    manifest_name = f"selection_{args.tag}.json" if args.tag else "selection.json"
    (INPUT_DIR / manifest_name).write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
    )

    print(f"\n선정 {len(selected)}건, 제외(다운로드 실패) {len(excluded)}건.")
    print(f"{manifest_name}: {INPUT_DIR / manifest_name}")


if __name__ == "__main__":
    main()
