"""피팅 프로브 입력 받기 — docs/task_fitting_quality_v2.md §3-1.

v1 `set4_7벌`(task_fitting_quality_v1.md "1회분 무효" 표의 7벌 행) 아이템
원본 7장과, 그 실행에 쓰인 전신 사진 원본을 tools/fitting_probe/input/ 으로
받고, 각 아이템의 Firestore `attributes`·`subCategory`로 labels.json 초안을
만든다.

**읽기 전용** — Firestore·Storage 어디에도 쓰지 않는다(v2 §5).

전신 사진 id는 history 문서에 저장되지 않는다. 대신 history의
`fittingCacheKey` = sha256("{userPhotoId}:{정렬된 아이템 id를 ','로}")
(functions/src/fitting_cache_key.ts)이므로, 소유자의 '전신' 문서 후보마다
같은 식으로 키를 계산해 일치하는 것을 고른다.

    python fetch_inputs.py --credentials ~/secrets/personal-adminsdk.json
    python fetch_inputs.py --person-id <wardrobe 문서 id>   # 역산이 안 될 때 직접 지정

서비스 계정 키는 저장소 밖 경로로만 받는다(tools/audit_image_refs와 같은 규칙).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path
from urllib.parse import unquote

if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")

from firebase_admin import credentials, firestore, initialize_app, storage

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent
INPUT_DIR = SCRIPT_DIR / "input"
DEFAULT_BUCKET = "ai-fashion-assistant-personal.firebasestorage.app"
# v1 0단계 관문 로그의 uid(task_fitting_quality_v1.md).
DEFAULT_UID = "BDDOIl08EhXnHu6oz6Zro47EtMw1"

# v1 set4_7벌 — 슬롯 → wardrobe 문서 id.
SET4_7 = {
    "top": "6vVNoavk5DLduhTNKu0d",
    "bottom": "ocHh3cdrQwcb5YW03HIT",
    "outer": "vRnIn4pj9Nn1CBsxyrYA",
    "shoes": "Z0HlgPZ6ypYyAnIim9Jw",
    "hat": "cb7yrcouGGpbsZCYGS1F",
    "bag": "cnwqpOYioHPlFxgju1JO",
    "watch": "WiyzsFM2QqSCYa3d8Uzp",
}
EXPECTED = {
    "top": ("상의", None), "bottom": ("하의", None), "outer": ("아우터", None), "shoes": ("신발", None),
    "hat": ("액세서리", "모자"), "bag": ("액세서리", "가방"), "watch": ("액세서리", "시계"),
}


def load_credentials(path_str: str | None) -> credentials.Certificate:
    path_str = path_str or os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    if not path_str:
        sys.exit("서비스 계정 키가 없습니다. --credentials 또는 GOOGLE_APPLICATION_CREDENTIALS로 지정하세요.")
    resolved = Path(os.path.expanduser(path_str)).resolve()
    if not resolved.is_file():
        sys.exit(f"서비스 계정 키 파일을 찾을 수 없습니다: {resolved}")
    if REPO_ROOT in resolved.parents:
        sys.exit("서비스 계정 키를 이 저장소 안에 두지 마세요 — 저장소 밖 경로를 쓰세요.")
    return credentials.Certificate(str(resolved))


def path_from_download_url(url: str | None) -> str | None:
    m = re.search(r"/o/([^?]+)", url or "")
    return unquote(m.group(1)) if m else None


def original_path(data: dict) -> str | None:
    # 원본만 — cutoutPath/cutoutImageUrl(배경 제거본)은 쓰지 않는다.
    return data.get("imagePath") or path_from_download_url(data.get("imageUrl"))


def cache_key(person_id: str, item_ids: list[str]) -> str:
    raw = f"{person_id}:{','.join(sorted(item_ids))}"
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def prompt_line(attrs: dict | None) -> str | None:
    # lib/models/clothing_attributes.dart toPromptLine()과 같은 형식.
    if not attrs:
        return None
    tags = attrs.get("tags") or []
    tags_text = f", 태그: {', '.join(tags)}" if tags else ""
    return (f"색상 {attrs.get('color')}, 스타일 {attrs.get('style')}, 패턴 {attrs.get('pattern')}, "
            f"격식 {attrs.get('formality')}, 핏 {attrs.get('fit')}{tags_text}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--credentials")
    ap.add_argument("--uid", default=DEFAULT_UID)
    ap.add_argument("--bucket", default=DEFAULT_BUCKET)
    ap.add_argument("--person-id", help="전신 사진 wardrobe 문서 id(역산 대신 직접 지정)")
    ap.add_argument("--overwrite", action="store_true", help="input/에 이미 있는 파일도 다시 받는다")
    args = ap.parse_args()

    initialize_app(load_credentials(args.credentials), {"storageBucket": args.bucket})
    db = firestore.client()
    bucket = storage.bucket()

    items = {}
    for slot, doc_id in SET4_7.items():
        snap = db.collection("wardrobe").document(doc_id).get()
        if not snap.exists:
            sys.exit(f"wardrobe/{doc_id} ({slot}) 문서가 없습니다.")
        data = snap.to_dict()
        cat, sub = data.get("category"), data.get("subCategory")
        exp_cat, exp_sub = EXPECTED[slot]
        flag = "" if cat == exp_cat and (exp_sub is None or sub == exp_sub) else "  ← 예상과 다름"
        print(f"{slot:6} {doc_id} category={cat} subCategory={sub}{flag}")
        items[slot] = data

    person_id = args.person_id
    if not person_id:
        hist = db.collection("users").document(args.uid).collection("history").where("type", "==", "fitting").stream()
        want = sorted(SET4_7.values())
        def ids_of(d: dict) -> list[str]:
            # 현행은 itemIds(정렬본). v1 기록은 clothingItemIds라고 적었으므로 둘 다, 없으면 items[].id.
            return sorted(d.get("itemIds") or d.get("clothingItemIds") or [i.get("id") for i in d.get("items") or []])
        keys = {d.to_dict().get("fittingCacheKey") for d in hist if ids_of(d.to_dict()) == want}
        keys.discard(None)
        print(f"set4_7벌과 아이템이 정확히 같은 history 문서의 fittingCacheKey {len(keys)}개")
        persons = db.collection("wardrobe").where("ownerUid", "==", args.uid).where("category", "==", "전신").stream()
        cands = [p.id for p in persons]
        matched = [pid for pid in cands if cache_key(pid, list(SET4_7.values())) in keys]
        if len(matched) != 1:
            sys.exit(f"전신 사진을 하나로 특정하지 못했습니다(후보 {len(cands)}개, 일치 {matched}). --person-id로 지정하세요.")
        person_id = matched[0]
    person = db.collection("wardrobe").document(person_id).get()
    if not person.exists:
        sys.exit(f"wardrobe/{person_id} (전신) 문서가 없습니다.")
    print(f"person {person_id}")

    INPUT_DIR.mkdir(exist_ok=True)
    for name, data in [("person", person.to_dict()), *items.items()]:
        dest = INPUT_DIR / f"{name}.jpg"
        if dest.exists() and not args.overwrite:
            print(f"  {dest.name} 이미 있음 — 건너뜀")
            continue
        path = original_path(data)
        if not path:
            sys.exit(f"{name}: 원본 Storage 경로를 알 수 없습니다.")
        blob_bytes = bucket.blob(path).download_as_bytes()
        dest.write_bytes(blob_bytes)
        print(f"  {dest.name} ← {path} ({len(blob_bytes)} B)")

    labels_path = INPUT_DIR / "labels.json"
    if labels_path.exists() and not args.overwrite:
        print("labels.json 이미 있음 — 건너뜀")
    else:
        labels = {}
        for slot, data in items.items():
            line = prompt_line(data.get("attributes"))
            sub = data.get("subCategory")
            labels[slot] = ", ".join(x for x in [sub, line] if x) or EXPECTED[slot][0]
        labels_path.write_text(json.dumps(labels, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"labels.json 작성 — 내용 확인 후 필요하면 손으로 다듬는다")


if __name__ == "__main__":
    main()
