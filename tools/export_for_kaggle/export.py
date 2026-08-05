"""Kaggle 임베딩 품질 비교 실험용 로컬 데이터 내보내기 스크립트.

앱 코드(lib/)는 전혀 건드리지 않는다 — Firebase Admin SDK로 Firestore/
Storage를 직접 읽어 tools/export_for_kaggle/output/ 아래에 내보내고,
마지막에 wardrobe_export.zip 하나로 묶는다.

서비스 계정 키는 반드시 환경변수(GOOGLE_APPLICATION_CREDENTIALS) 또는
--credentials 로 넘긴 "로컬 경로"로만 참조한다. 이 스크립트는 그 파일을
읽기만 할 뿐 export 폴더 어디에도 복사/포함하지 않는다.

사용법:
    export GOOGLE_APPLICATION_CREDENTIALS=/path/to/serviceAccount.json
    python export.py

    # 또는
    python export.py --credentials /path/to/serviceAccount.json
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import re
import sys
import zipfile
import io
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse, unquote

from PIL import Image

try:
    import firebase_admin
    from firebase_admin import credentials, firestore, storage
except ImportError:
    print("firebase-admin이 설치되어 있지 않습니다: pip install -r requirements.txt", file=sys.stderr)
    raise

SCRIPT_DIR = Path(__file__).resolve().parent
# firebase_options.dart(android/ios 공통)에 있는 값 — 클라이언트 설정 키라
# 민감정보 아님. 기본값으로만 쓰고 --bucket으로 언제든 덮어쓸 수 있다.
DEFAULT_BUCKET = "ai-fashion-assistant-eb206.firebasestorage.app"
DEFAULT_MAX_SIDE = 512
ATTRIBUTE_FIELDS = ["color", "style", "pattern", "formality", "fit", "tags"]

# 내보낸 폴더에 이것들이 섞여 있으면 안 된다(자격증명/개인정보 흔적).
_FORBIDDEN_PATTERNS = [
    re.compile(r"BEGIN (RSA )?PRIVATE KEY"),
    re.compile(r"\"private_key\""),
    re.compile(r"\"client_email\""),
    re.compile(r"\"client_x509_cert_url\""),
    re.compile(r"serviceAccount", re.IGNORECASE),
]
_ALLOWED_TOP_LEVEL_FILES = {"items.csv", "items.json", "history.json", "matcher_spec.md"}


@dataclass
class ExportCounts:
    images_downloaded: int = 0
    images_skipped_existing: int = 0
    images_failed: int = 0
    metadata_rows: int = 0
    history_total: int = 0
    history_accepted: int = 0
    history_rejected_with_alternative: int = 0
    history_pending: int = 0
    users_seen: int = 0


def init_firebase(credentials_path: str | None, bucket_name: str) -> None:
    cred_path = credentials_path or os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    if not cred_path:
        print(
            "서비스 계정 키 경로가 없습니다. GOOGLE_APPLICATION_CREDENTIALS 환경변수를 "
            "설정하거나 --credentials로 넘겨주세요. (키 파일을 이 저장소 안에 두지 마세요)",
            file=sys.stderr,
        )
        sys.exit(1)
    cred_path = os.path.expanduser(cred_path)
    if not os.path.isfile(cred_path):
        print(f"서비스 계정 키 파일을 찾을 수 없습니다: {cred_path}", file=sys.stderr)
        sys.exit(1)
    # 저장소(tools/export_for_kaggle) 안쪽 경로를 실수로 지정하는 걸 막는다.
    if SCRIPT_DIR in Path(cred_path).resolve().parents or Path(cred_path).resolve() == SCRIPT_DIR:
        print(
            "서비스 계정 키를 export_for_kaggle 디렉토리 안에 두지 마세요 — 저장소 밖의 "
            "안전한 경로를 사용하세요.",
            file=sys.stderr,
        )
        sys.exit(1)

    cred = credentials.Certificate(cred_path)
    firebase_admin.initialize_app(cred, {"storageBucket": bucket_name})


def storage_path_from_url(url: str) -> str | None:
    """Firebase Storage 다운로드 URL에서 버킷 내부 오브젝트 경로를 추출."""
    if not url:
        return None
    if url.startswith("gs://"):
        # gs://<bucket>/<path>
        parts = url[len("gs://"):].split("/", 1)
        return parts[1] if len(parts) == 2 else None
    parsed = urlparse(url)
    marker = "/o/"
    idx = parsed.path.find(marker)
    if idx == -1:
        return None
    encoded_path = parsed.path[idx + len(marker):]
    return unquote(encoded_path)


def download_and_resize_image(
    bucket, object_path: str, dest_path: Path, max_side: int, bg_color: str
) -> None:
    blob = bucket.blob(object_path)
    raw_bytes = blob.download_as_bytes()
    with Image.open(io.BytesIO(raw_bytes)) as img:
        img = img.convert("RGBA") if img.mode in ("RGBA", "LA", "P") else img.convert("RGB")
        if img.mode == "RGBA":
            # 투명 배경 cutout PNG는 단색 배경에 합성한 뒤 JPEG로 저장한다.
            background = Image.new("RGB", img.size, bg_color)
            background.paste(img, mask=img.split()[3])
            img = background

        w, h = img.size
        longest = max(w, h)
        if longest > max_side:
            scale = max_side / longest
            img = img.resize((max(1, round(w * scale)), max(1, round(h * scale))), Image.LANCZOS)

        img.save(dest_path, format="JPEG", quality=90)


def export_wardrobe(
    db,
    bucket,
    output_dir: Path,
    max_side: int,
    bg_color: str,
    force: bool,
    counts: ExportCounts,
    owner_uid: str | None = None,
) -> list[dict]:
    images_dir = output_dir / "images"
    images_dir.mkdir(parents=True, exist_ok=True)

    rows: list[dict] = []
    docs = list(db.collection("wardrobe").stream())
    print(f"[wardrobe] Firestore 문서 {len(docs)}개 발견")

    for doc in docs:
        # DocumentSnapshot.data()는 JS SDK API — 파이썬 google-cloud-firestore는
        # to_dict()를 쓴다.
        data = doc.to_dict() or {}
        item_id = doc.id

        # isDemo 문서는 F′단계 데모 시드로 생긴 복제본이라 항상 제외한다
        # (F′.3 지표 오염 방지 — task_demo_ready_v2.md 금지 사항). --owner-uid를
        # 주면 그 uid 소유 문서로도 한 번 더 좁힌다(멀티 계정 상태에서 표9
        # 커버리지가 남의 옷장과 섞이는 것을 막는다).
        if data.get("isDemo"):
            continue
        if owner_uid is not None and data.get("ownerUid") != owner_uid:
            continue

        attrs = data.get("attributes") or {}

        cutout_url = data.get("cutoutImageUrl")
        image_url = data.get("imageUrl")
        source_url = cutout_url or image_url
        image_source = "cutout" if cutout_url else ("original" if image_url else None)

        dest_path = images_dir / f"{item_id}.jpg"
        if source_url and (force or not dest_path.exists()):
            object_path = storage_path_from_url(source_url)
            if object_path is None:
                print(f"  ! {item_id}: 이미지 URL 파싱 실패, 스킵 — {source_url[:80]}")
                counts.images_failed += 1
            else:
                try:
                    download_and_resize_image(bucket, object_path, dest_path, max_side, bg_color)
                    counts.images_downloaded += 1
                except Exception as e:  # noqa: BLE001 - 스크립트 도구, 개별 실패는 로그만 남기고 계속
                    print(f"  ! {item_id}: 다운로드/변환 실패 — {e}")
                    counts.images_failed += 1
        elif dest_path.exists():
            counts.images_skipped_existing += 1
        else:
            print(f"  ! {item_id}: imageUrl/cutoutImageUrl 둘 다 없음, 이미지 없이 메타데이터만 기록")

        created_at = data.get("createdAt")
        created_at_iso = created_at.isoformat() if hasattr(created_at, "isoformat") else None

        row = {
            "itemId": item_id,
            "category": data.get("category"),
            "subCategory": data.get("subCategory"),
            "createdAt": created_at_iso,
            "imageSource": image_source,
            "hasImageFile": dest_path.exists(),
        }
        for f in ATTRIBUTE_FIELDS:
            val = attrs.get(f)
            row[f] = ";".join(val) if isinstance(val, list) else val
        rows.append(row)
        counts.metadata_rows += 1

    return rows


def _to_iso(value):
    if hasattr(value, "isoformat"):
        return value.isoformat()
    return value


def export_history(db, counts: ExportCounts) -> list[dict]:
    entries: list[dict] = []
    user_pseudonyms: dict[str, str] = {}

    users = list(db.collection("users").stream())
    for user_doc in users:
        uid = user_doc.id
        recs = list(user_doc.reference.collection("recommendations").stream())
        if not recs:
            continue
        counts.users_seen += 1
        pseudonym = user_pseudonyms.setdefault(uid, f"user_{len(user_pseudonyms) + 1:03d}")

        for rec_doc in recs:
            d = rec_doc.to_dict() or {}
            user_choice = d.get("userChoice")
            if user_choice == "accepted":
                counts.history_accepted += 1
            elif user_choice == "rejected_with_alternative":
                counts.history_rejected_with_alternative += 1
            else:
                counts.history_pending += 1
            counts.history_total += 1

            entries.append(
                {
                    "user": pseudonym,  # 실제 Firebase uid는 절대 내보내지 않음
                    "recommendationId": rec_doc.id,
                    "itemIds": d.get("itemIds", []),
                    "itemSummaries": d.get("itemSummaries", []),
                    "colorScore": d.get("colorScore"),
                    "summaryText": d.get("summaryText"),
                    "triggerItemId": d.get("triggerItemId"),
                    "createdAt": _to_iso(d.get("createdAt")),
                    "dismissed": d.get("dismissed", False),
                    "evaluatedCount": d.get("evaluatedCount"),
                    "candidateScores": d.get("candidateScores", []),
                    "targetDate": _to_iso(d.get("targetDate")),
                    "targetTpoTag": d.get("targetTpoTag"),
                    "userChoice": user_choice,
                    "userChosenItemIds": d.get("userChosenItemIds", []),
                    "reflectedFeedback": d.get("reflectedFeedback", False),
                    "isFallback": d.get("isFallback", False),
                    "repairAttempted": d.get("repairAttempted", False),
                    "repairNote": d.get("repairNote"),
                }
            )

    return entries


def scan_for_leaks(output_dir: Path) -> list[str]:
    """자격증명/개인정보 흔적을 텍스트 파일에서 스캔. 문제 목록(비어있으면 통과)을 반환."""
    problems: list[str] = []

    for path in output_dir.rglob("*"):
        if path.is_dir():
            continue
        rel = path.relative_to(output_dir)
        # images/ 아래는 바이너리 jpg만 있어야 한다.
        if rel.parts[0] == "images":
            if path.suffix.lower() != ".jpg":
                problems.append(f"images/ 아래에 예상치 못한 파일: {rel}")
            continue
        if len(rel.parts) == 1 and rel.name not in _ALLOWED_TOP_LEVEL_FILES:
            problems.append(f"예상치 못한 최상위 파일: {rel}")
            continue
        if path.suffix.lower() in (".csv", ".json", ".md"):
            try:
                text = path.read_text(encoding="utf-8", errors="ignore")
            except Exception:
                continue
            for pattern in _FORBIDDEN_PATTERNS:
                if pattern.search(text):
                    problems.append(f"{rel}: 의심 패턴 매치 — {pattern.pattern}")

    return problems


def zip_output(output_dir: Path, zip_path: Path) -> None:
    if zip_path.exists():
        zip_path.unlink()
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for path in sorted(output_dir.rglob("*")):
            if path.is_file():
                zf.write(path, path.relative_to(output_dir))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--credentials", help="서비스 계정 키 JSON 로컬 경로 (기본: GOOGLE_APPLICATION_CREDENTIALS 환경변수)")
    parser.add_argument("--bucket", default=DEFAULT_BUCKET, help="Firebase Storage 버킷 이름")
    parser.add_argument("--output-dir", default=str(SCRIPT_DIR / "output"), help="출력 디렉토리")
    parser.add_argument("--max-side", type=int, default=DEFAULT_MAX_SIDE, help="이미지 긴 변 리사이즈 목표(px)")
    parser.add_argument("--bg-color", default="white", help="투명 cutout PNG를 JPEG로 저장할 때 채울 배경색")
    parser.add_argument("--force", action="store_true", help="이미 존재하는 이미지도 다시 다운로드")
    parser.add_argument(
        "--owner-uid",
        help="이 uid 소유 문서로만 좁힌다(생략 시 isDemo만 제외하고 전체). "
        "F′.3 표9 재계산 전 본인 uid로 좁혀 데모/타 계정과 섞이지 않게 할 것",
    )
    args = parser.parse_args()

    output_dir = Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    init_firebase(args.credentials, args.bucket)
    db = firestore.client()
    bucket = storage.bucket()

    counts = ExportCounts()

    print("=== 1/4 옷장 이미지 + 메타데이터 내보내는 중 (isDemo 제외"
          f"{', ownerUid=' + args.owner_uid if args.owner_uid else ''}) ===")
    rows = export_wardrobe(
        db, bucket, output_dir, args.max_side, args.bg_color, args.force, counts,
        owner_uid=args.owner_uid,
    )

    fieldnames = ["itemId", "category", "subCategory", "createdAt", "imageSource", "hasImageFile", *ATTRIBUTE_FIELDS]
    with open(output_dir / "items.csv", "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)
    with open(output_dir / "items.json", "w", encoding="utf-8") as f:
        json.dump(rows, f, ensure_ascii=False, indent=2)

    print("=== 2/4 추천 이력 내보내는 중 ===")
    history = export_history(db, counts)
    with open(output_dir / "history.json", "w", encoding="utf-8") as f:
        json.dump(history, f, ensure_ascii=False, indent=2)

    print("=== 3/4 matcher_spec.md 복사 중 ===")
    spec_src = SCRIPT_DIR / "matcher_spec.md"
    if spec_src.exists():
        (output_dir / "matcher_spec.md").write_text(spec_src.read_text(encoding="utf-8"), encoding="utf-8")
    else:
        print("  ! matcher_spec.md가 없습니다 — 건너뜀")

    print("=== 4/4 보안 스캔 + 압축 ===")
    problems = scan_for_leaks(output_dir)
    if problems:
        print("!!! 보안 스캔 실패 — 아래 문제를 해결한 뒤 다시 실행하세요 !!!")
        for p in problems:
            print(f"  - {p}")
        sys.exit(1)
    print("  보안 스캔 통과: 자격증명/의심 패턴 없음, 예상치 못한 파일 없음")

    zip_path = SCRIPT_DIR / "wardrobe_export.zip"
    zip_output(output_dir, zip_path)

    print("\n=== 완료 ===")
    print(f"이미지: 신규 다운로드 {counts.images_downloaded} / 기존 스킵 {counts.images_skipped_existing} / 실패 {counts.images_failed}")
    print(f"메타데이터 행: {counts.metadata_rows}")
    print(
        f"추천 이력: 총 {counts.history_total}건 "
        f"(accepted {counts.history_accepted} / rejected_with_alternative {counts.history_rejected_with_alternative} / "
        f"pending(미기록) {counts.history_pending}) — {counts.users_seen}개 계정에서 수집"
    )
    print(f"압축 파일: {zip_path}")


if __name__ == "__main__":
    main()
