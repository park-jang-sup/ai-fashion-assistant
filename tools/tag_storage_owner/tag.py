"""Storage 파일에 주인(ownerUid)·데모(demo) 표시를 붙인다 — 보안 최소 조치 S1.

storage.rules(3be21fc)는 읽기를 "파일 메타데이터 ownerUid == 호출자 또는 demo == 'true'"로만 허용하고,
getSignedImageUrls(S2)도 같은 조건으로 서명한다. 그 전에 이미 올라가 있는 파일에 표시를 붙인다.

  (가) 데모가 아닌(isDemo 아님) wardrobe 문서마다 원본·누끼 파일에 ownerUid가 없으면 문서의 ownerUid
  (나) demo_wardrobe 문서가 가리키는 원본·누끼 파일에 demo = "true"
  (다) ownerUid가 있는 fitting_cache 문서의 fitting_results/{id}.jpg에 ownerUid가 없으면 그 ownerUid

- isDemo 사본 문서는 대상이 아니다(파일의 주인은 원본 문서의 주인).
- 이미 다른 ownerUid가 붙은 파일, 주인이 다른 문서들이 함께 가리키는 파일은 건드리지 않고 센다.
- 기존 메타데이터(다른 키, 다운로드 토큰)는 그대로 둔다 — 붙일 키만 더한다. 파일을 지우거나 옮기지
  않고, Firestore 문서는 쓰지 않는다.
- 기본은 미리 보기(쓰기 없음). --apply를 줘야 쓰고, 쓴 내용을 manifests/에 남긴다(저장소에 넣지 않는다).
  --revert <manifest>는 그 apply가 더한 키만 지운다. 여러 번 돌려도 결과가 같다(이미 있으면 건너뜀).
- 출력은 개수만 — 경로·uid 값은 출력하지 않는다.
- 메타데이터만 바꾸는 것은 Storage의 metadataUpdate 이벤트라, finalize 이벤트에 붙은 배경 제거
  (bg_removal_on_upload)·토큰 회수(revokeTokenOnUpload) 트리거는 다시 돌지 않는다.

  python tag.py --credentials <키 경로>            # 미리 보기
  python tag.py --credentials <키 경로> --apply    # 적용(manifest 남김)
  python tag.py --credentials <키 경로> --revert manifests/<파일>.json
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import unquote

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
MANIFEST_DIR = SCRIPT_DIR / "manifests"

OWNER_KEY = "ownerUid"
DEMO_KEY = "demo"  # storage.rules의 isDemo()가 보는 키
DEMO_VALUE = "true"


def _reject_repo_path(resolved: Path, hint: str) -> None:
    if REPO_ROOT in resolved.parents or resolved == REPO_ROOT:
        print(f"서비스 계정 키를 이 저장소 안에 두지 마세요 ({hint}) — 저장소 밖의 경로를 쓰세요.", file=sys.stderr)
        sys.exit(1)


def _load_credentials(cred_path_str: str | None) -> credentials.Certificate:
    path_str = cred_path_str or os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    hint = "--credentials" if cred_path_str else "GOOGLE_APPLICATION_CREDENTIALS"
    if not path_str:
        print("서비스 계정 키가 없습니다. --credentials 또는 GOOGLE_APPLICATION_CREDENTIALS로 지정하세요.", file=sys.stderr)
        sys.exit(1)
    resolved = Path(os.path.expanduser(path_str)).resolve()
    if not resolved.is_file():
        print(f"서비스 계정 키 파일을 찾을 수 없습니다({hint}).", file=sys.stderr)
        sys.exit(1)
    _reject_repo_path(resolved, hint)
    return credentials.Certificate(str(resolved))


def path_from_url(url: str | None) -> str | None:
    """Firebase 다운로드 URL(.../o/{encoded}?...)에서 경로 — signed_url_policy.ts의 pathFromDownloadUrl과 같은 규칙."""
    if not url:
        return None
    m = re.search(r"/o/([^?]+)", url)
    return unquote(m.group(1)) if m else None


def doc_paths(d: dict) -> list[str]:
    out = []
    for p in (d.get("imagePath") or path_from_url(d.get("imageUrl")), d.get("cutoutPath") or path_from_url(d.get("cutoutImageUrl"))):
        if p and p not in out:
            out.append(p)
    return out


def plan(wardrobe: list[dict], demo: list[dict], fitting: list[tuple[str, dict]]):
    """붙일 표시를 정한다(순수 — 파일 조회 전). 반환: (owner_targets{path: uid}, demo_targets{path}, skips Counter)."""
    skips: Counter = Counter()
    owners: dict[str, set[str]] = defaultdict(set)
    for d in wardrobe:
        if d.get("isDemo"):
            continue  # 사본 — 파일의 주인은 원본 문서의 주인
        uid = d.get("ownerUid")
        if not uid:
            skips["주인 없는 wardrobe 문서"] += 1
            continue
        for p in doc_paths(d):
            owners[p].add(uid)
    for doc_id, d in fitting:
        uid = d.get("ownerUid")
        if not uid:
            skips["주인 없는 fitting_cache 문서"] += 1
            continue
        owners[f"fitting_results/{doc_id}.jpg"].add(uid)
    owner_targets: dict[str, str] = {}
    for p, uids in owners.items():
        if len(uids) > 1:
            skips["주인이 다른 문서들이 함께 가리킴"] += 1
            continue
        owner_targets[p] = next(iter(uids))
    demo_targets = {p for d in demo for p in doc_paths(d)}
    return owner_targets, demo_targets, skips


def decide(meta: dict | None, owner: str | None, want_demo: bool):
    """한 파일에 더할 키(없으면 빈 dict)와 결과 분류. meta가 None이면 파일 없음."""
    if meta is None:
        return {}, ["파일 없음"]
    add, result = {}, []
    if owner is not None:
        have = meta.get(OWNER_KEY)
        if not have:
            add[OWNER_KEY] = owner
            result.append("주인 붙일 것")
        elif have == owner:
            result.append("주인 이미 있음")
        else:
            result.append("건너뜀: 다른 ownerUid가 이미 있음")
    if want_demo:
        if meta.get(DEMO_KEY) == DEMO_VALUE:
            result.append("데모 이미 있음")
        else:
            add[DEMO_KEY] = DEMO_VALUE
            result.append("데모 붙일 것")
    return add, result


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--credentials")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--apply", action="store_true", help="실제로 메타데이터를 붙이고 manifest를 남긴다")
    g.add_argument("--revert", metavar="MANIFEST", help="그 apply가 더한 키만 지운다")
    args = ap.parse_args()

    bucket_name = json.load(open(REPO_ROOT / "android" / "app" / "google-services.json", encoding="utf-8"))["project_info"]["storage_bucket"]
    firebase_admin.initialize_app(_load_credentials(args.credentials), {"storageBucket": bucket_name})
    db, bucket = firestore.client(), storage.bucket()

    if args.revert:
        entries = json.load(open(args.revert, encoding="utf-8"))["entries"]
        n = 0
        for e in entries:
            blob = bucket.get_blob(e["path"])
            if blob is None:
                continue
            blob.metadata = {k: None for k in e["added"]}  # 더한 키만 지운다(다른 키는 그대로)
            blob.patch()
            n += 1
        print(f"되돌림: manifest {len(entries)}건 중 {n}건의 더한 키를 지웠다")
        return

    wardrobe = [d.to_dict() or {} for d in db.collection("wardrobe").stream()]
    demo = [d.to_dict() or {} for d in db.collection("demo_wardrobe").stream()]
    fitting = [(d.id, d.to_dict() or {}) for d in db.collection("fitting_cache").stream()]
    owner_targets, demo_targets, skips = plan(wardrobe, demo, fitting)

    counts: Counter = Counter()
    by_prefix: Counter = Counter()
    entries = []
    for path in sorted(set(owner_targets) | demo_targets):
        blob = bucket.get_blob(path)
        meta = None if blob is None else (blob.metadata or {})
        add, result = decide(meta, owner_targets.get(path), path in demo_targets)
        for r in result:
            counts[r] += 1
        if add:
            by_prefix[path.split("/", 1)[0]] += 1
            if args.apply:
                blob.metadata = add  # PATCH — 더할 키만 보낸다(기존 키·토큰은 그대로 남는다)
                blob.patch()
                entries.append({"path": path, "added": sorted(add)})

    print(f"문서: wardrobe {len(wardrobe)}(isDemo 사본 {sum(bool(d.get('isDemo')) for d in wardrobe)}) · demo_wardrobe {len(demo)} · fitting_cache {len(fitting)}")
    print(f"대상 파일: {len(set(owner_targets) | demo_targets)} (주인 대상 {len(owner_targets)}, 데모 대상 {len(demo_targets)})")
    for k in ["주인 이미 있음", "주인 붙일 것", "데모 이미 있음", "데모 붙일 것", "건너뜀: 다른 ownerUid가 이미 있음", "파일 없음"]:
        print(f"  {k}: {counts.get(k, 0)}")
    for k, v in sorted(skips.items()):
        print(f"  건너뜀(계획 단계): {k}: {v}")
    print(f"  쓸 파일(폴더별): {dict(by_prefix) or 0}")
    if args.apply:
        MANIFEST_DIR.mkdir(exist_ok=True)
        stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ")
        out = MANIFEST_DIR / f"tag_{stamp}.json"
        out.write_text(json.dumps({"appliedAt": stamp, "entries": entries}, ensure_ascii=False, indent=1), encoding="utf-8")
        print(f"적용: {len(entries)}개 파일에 메타데이터를 더했다 — manifest: manifests/{out.name}")
    else:
        print("미리 보기(쓰기 없음) — 적용하려면 --apply")


if __name__ == "__main__":
    main()
