"""팀 Firebase 프로젝트의 wardrobe 컬렉션 + 관련 Storage 이미지를 개인
Firebase 프로젝트로 "빠른 이관"한다. users/recommendations(이력)/
fitting_cache/fitting_results 등 이력·개인화 데이터는 옮기지 않는다.

앱 코드(lib/)는 전혀 건드리지 않는다 — 이관 후에도 Firestore에 Storage
절대 다운로드 URL을 저장하는 지금 방식 그대로 동작해야 하므로, Admin SDK로
같은 형태(.../o/<path>?alt=media&token=...)의 URL을 새로 만들어 넣는다.

SOURCE(팀 프로젝트)는 어떤 경우에도 read-only다 — 이 파일 안에서
source_db/source_bucket에 대해 read 계열 메서드(stream/get/exists/
download_as_bytes)만 호출되고, set/update/delete/upload 계열은 전부
dest_db/dest_bucket에만 호출된다(리뷰 시 grep -n "source_db\\.\\|source_bucket\\."
로 확인 가능).

서비스 계정 키는 --source-credentials/--dest-credentials로만 받고, 이
저장소 안의 경로는 거부한다. 기본 동작은 dry-run — 실제로 쓰려면 --apply를
명시해야 하고, 그때는 SOURCE→DEST 방향을 사람이 확인하도록 대상 프로젝트
id를 직접 입력해야 진행된다.

사용법:
    # 1. dry-run — 아무것도 안 씀, 이미지 필드 구성부터 확인
    python migrate.py \
        --source-credentials ~/secrets/team-adminsdk.json \
        --dest-credentials ~/secrets/personal-adminsdk.json \
        --dest-bucket ai-fashion-assistant-personal.firebasestorage.app

    # 2. 확인 후 실제 이관
    python migrate.py ... --apply
"""
from __future__ import annotations

import argparse
import os
import sys
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import quote, unquote, urlparse

try:
    import firebase_admin
    from firebase_admin import credentials, firestore, storage
except ImportError:
    print("firebase-admin이 설치되어 있지 않습니다: pip install -r requirements.txt", file=sys.stderr)
    raise

try:
    import requests
except ImportError:
    print("requests가 설치되어 있지 않습니다: pip install -r requirements.txt", file=sys.stderr)
    raise

# Windows 콘솔이 cp949 등 레거시 코드페이지면 한글/em-dash 출력에서
# UnicodeEncodeError가 날 수 있다 — --help(조기 종료)도 영향받으므로
# argparse 실행보다 먼저, 모듈 로드 시점에 강제한다.
if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent

WARDROBE_COL = "wardrobe"
# 문서 안에서 "이미지 필드"로 취급하는 이름 중 없으면 그 아이템 전체를
# 실패로 치는 필드. 그 외에 발견되는 Storage URL 필드(cutoutImageUrl 포함,
# 예상 밖 필드명도)는 실패해도 그 필드만 빼고 문서는 계속 이관한다.
REQUIRED_IMAGE_FIELD = "imageUrl"
KNOWN_IMAGE_FIELDS = {"imageUrl", "cutoutImageUrl"}
# firebase_options.dart(android/ios 공통)에 있는 값 — 클라이언트 설정 키라
# 민감정보 아님. tools/export_for_kaggle/export.py와 동일한 기본값.
DEFAULT_SOURCE_BUCKET = "ai-fashion-assistant-eb206.firebasestorage.app"


# ── 서비스 계정 키 로드 ──────────────────────────────────────────

def _load_credentials(cred_path_str: str, flag_name: str, label: str) -> credentials.Certificate:
    resolved = Path(os.path.expanduser(cred_path_str)).resolve()
    if not resolved.is_file():
        print(f"[{label}] 서비스 계정 키 파일을 찾을 수 없습니다: {resolved}", file=sys.stderr)
        sys.exit(1)
    if REPO_ROOT in resolved.parents or resolved == REPO_ROOT:
        print(
            f"[{label}] 서비스 계정 키를 이 저장소 안에 두지 마세요 "
            f"(--{flag_name}) — 저장소 밖의 안전한 경로를 쓰세요.",
            file=sys.stderr,
        )
        sys.exit(1)
    return credentials.Certificate(str(resolved))


# ── Storage URL 파싱/조립 ───────────────────────────────────────

def storage_path_from_url(url: str) -> str | None:
    """Firebase Storage 다운로드 URL/gs:// 경로에서 버킷 내부 오브젝트 경로를
    추출한다. tools/export_for_kaggle/export.py의 동명 함수와 동일 로직."""
    if not url:
        return None
    if url.startswith("gs://"):
        parts = url[len("gs://"):].split("/", 1)
        return parts[1] if len(parts) == 2 else None
    parsed = urlparse(url)
    marker = "/o/"
    idx = parsed.path.find(marker)
    if idx == -1:
        return None
    encoded_path = parsed.path[idx + len(marker):]
    return unquote(encoded_path)


def build_download_url(bucket_name: str, object_path: str, token: str) -> str:
    # Firebase는 오브젝트 경로의 '/'까지 %2F로 인코딩해서 /o/ 뒤 한 세그먼트로
    # 넣는다 — 일반적인 경로 인코딩과 다르므로 safe=""가 핵심.
    encoded = quote(object_path, safe="")
    return f"https://firebasestorage.googleapis.com/v0/b/{bucket_name}/o/{encoded}?alt=media&token={token}"


def discover_image_fields(data: dict) -> dict[str, str]:
    """문서의 top-level 문자열 필드 중 Storage URL로 파싱되는 것만 반환한다.
    필드명을 imageUrl/cutoutImageUrl로 미리 못박지 않고 값 자체로 판별해서,
    필드 구성이 문서마다 다르거나 예상 밖 필드명이어도 놓치지 않는다."""
    found = {}
    for key, value in data.items():
        if not isinstance(value, str) or not value:
            continue
        if storage_path_from_url(value) is not None:
            found[key] = value
    return found


def _guess_content_type(object_path: str, fallback: str | None) -> str:
    lower = object_path.lower()
    if lower.endswith(".png"):
        return "image/png"
    if lower.endswith(".jpg") or lower.endswith(".jpeg"):
        return "image/jpeg"
    return fallback or "application/octet-stream"


# ── 이미지 필드 감사(모든 모드에서 실행) ────────────────────────

@dataclass
class FieldAudit:
    has_image_url: int = 0
    has_cutout_url: int = 0
    has_neither: list[str] = field(default_factory=list)
    unexpected_fields: list[tuple[str, str]] = field(default_factory=list)
    parse_failures: list[tuple[str, str, str]] = field(default_factory=list)


def audit_image_fields(docs) -> FieldAudit:
    audit = FieldAudit()
    for doc in docs:
        item_id = doc.id
        data = doc.to_dict() or {}
        discovered = discover_image_fields(data)

        if "imageUrl" in discovered:
            audit.has_image_url += 1
        if "cutoutImageUrl" in discovered:
            audit.has_cutout_url += 1
        if not discovered:
            audit.has_neither.append(item_id)

        for key in discovered:
            if key not in KNOWN_IMAGE_FIELDS:
                audit.unexpected_fields.append((item_id, key))

        # 파싱 실패 후보 — 필드명에 "url"이 들어가지만 위에서 유효한 Storage
        # URL로 인식되지 못한 값(휴리스틱, 완전하지 않음).
        for key, value in data.items():
            if key in discovered:
                continue
            if isinstance(value, str) and value and "url" in key.lower():
                preview = value[:80] + ("..." if len(value) > 80 else "")
                audit.parse_failures.append((item_id, key, preview))

    return audit


def print_field_audit(audit: FieldAudit, total: int) -> None:
    print("\n=== 이미지 필드 감사 ===")
    print(f"전체 문서: {total}")
    print(f"imageUrl 있음: {audit.has_image_url}건")
    print(f"cutoutImageUrl 있음: {audit.has_cutout_url}건")
    print(f"이미지 URL 필드 전혀 없음: {len(audit.has_neither)}건")
    if audit.has_neither:
        shown = ", ".join(audit.has_neither[:20])
        more = f" 외 {len(audit.has_neither) - 20}건" if len(audit.has_neither) > 20 else ""
        print(f"  → {shown}{more}")
    if audit.unexpected_fields:
        print(f"예상 밖 이름의 URL 필드 발견: {len(audit.unexpected_fields)}건")
        for item_id, key in audit.unexpected_fields[:20]:
            print(f"  ! {item_id}: 필드명 '{key}'")
    if audit.parse_failures:
        print(f"파싱 실패 의심(필드명에 url 포함, 값이 Storage URL로 안 읽힘): {len(audit.parse_failures)}건")
        for item_id, key, preview in audit.parse_failures[:20]:
            print(f"  ! {item_id}.{key} = {preview}")
    print("========================\n")


def print_dry_run_samples(docs, dest_bucket_name: str, sample_count: int) -> None:
    print(f"=== URL 변환 샘플 (최대 {sample_count}건, imageUrl 있는 문서만) ===")
    shown = 0
    for doc in docs:
        data = doc.to_dict() or {}
        discovered = discover_image_fields(data)
        if REQUIRED_IMAGE_FIELD not in discovered:
            continue
        url = discovered[REQUIRED_IMAGE_FIELD]
        object_path = storage_path_from_url(url)
        preview_url = build_download_url(dest_bucket_name, object_path, "<apply-시-새로-생성될-uuid>")
        print(f"[샘플 {shown + 1}] itemId={doc.id}")
        print(f"  소스 URL       : {url}")
        print(f"  오브젝트 경로   : {object_path}")
        print(f"  대상 URL(예정)  : {preview_url}")
        shown += 1
        if shown >= sample_count:
            break
    if shown == 0:
        print("  (imageUrl 있는 문서가 없어 샘플을 만들 수 없음)")
    print("========================================\n")


# ── 실제 이미지 이관 (--apply 전용) ─────────────────────────────

@dataclass
class ImageMigrationResult:
    ok: bool
    new_url: str | None = None
    error: str | None = None


def migrate_image(source_bucket, dest_bucket, dest_bucket_name: str, source_url: str) -> ImageMigrationResult:
    object_path = storage_path_from_url(source_url)
    if object_path is None:
        return ImageMigrationResult(ok=False, error="URL 파싱 실패")

    # ↓ source_bucket에 대한 호출은 exists()/download_as_bytes()/reload()
    #   뿐이다 — 전부 읽기 전용.
    source_blob = source_bucket.blob(object_path)
    try:
        if not source_blob.exists():
            return ImageMigrationResult(ok=False, error=f"소스에 오브젝트 없음: {object_path}")
        image_bytes = source_blob.download_as_bytes()
        source_blob.reload()
        content_type = _guess_content_type(object_path, source_blob.content_type)
    except Exception as e:  # noqa: BLE001 - 스크립트 도구, 개별 실패는 로그만 남기고 계속
        return ImageMigrationResult(ok=False, error=f"소스 다운로드 실패: {e}")

    # ↓ 여기부터 dest_bucket에만 쓴다.
    token = str(uuid.uuid4())
    dest_blob = dest_bucket.blob(object_path)
    try:
        dest_blob.metadata = {"firebaseStorageDownloadTokens": token}
        dest_blob.upload_from_string(image_bytes, content_type=content_type)
    except Exception as e:  # noqa: BLE001
        return ImageMigrationResult(ok=False, error=f"대상 업로드 실패: {e}")

    new_url = build_download_url(dest_bucket_name, object_path, token)
    try:
        resp = requests.get(new_url, stream=True, timeout=15)
        status = resp.status_code
        content_type_header = resp.headers.get("Content-Type", "")
        resp.close()
    except Exception as e:  # noqa: BLE001
        return ImageMigrationResult(ok=False, error=f"검증 요청 실패: {e}")

    if status != 200 or not content_type_header.startswith("image/"):
        return ImageMigrationResult(
            ok=False, error=f"검증 실패(status={status}, content-type={content_type_header})"
        )
    return ImageMigrationResult(ok=True, new_url=new_url)


@dataclass
class MigrationCounts:
    migrated: int = 0
    skipped_existing: int = 0
    no_image: int = 0
    failed_required_image: int = 0
    write_failed: int = 0
    images_uploaded_ok: int = 0
    images_uploaded_failed: int = 0
    would_migrate: int = 0


def migrate_doc(
    data: dict,
    item_id: str,
    source_bucket,
    dest_bucket,
    dest_bucket_name: str,
    counts: MigrationCounts,
) -> tuple[dict, bool]:
    discovered = discover_image_fields(data)
    new_data = dict(data)  # attributes/size/embedding/category/createdAt 등은 그대로 복사

    if not discovered:
        counts.no_image += 1
        return new_data, True  # 이미지 없어도 메타데이터는 이관

    item_failed = False
    for field_name, url in discovered.items():
        result = migrate_image(source_bucket, dest_bucket, dest_bucket_name, url)
        if result.ok:
            new_data[field_name] = result.new_url
            counts.images_uploaded_ok += 1
        else:
            counts.images_uploaded_failed += 1
            if field_name == REQUIRED_IMAGE_FIELD:
                print(f"  ! {item_id}: 필수 이미지({field_name}) 이관 실패 — {result.error}")
                item_failed = True
            else:
                print(f"  ! {item_id}: 선택 이미지({field_name}) 이관 실패, 필드 제외하고 계속 — {result.error}")
                new_data.pop(field_name, None)

    if item_failed:
        counts.failed_required_image += 1
        return new_data, False
    return new_data, True


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source-credentials", required=True, help="소스(팀) 프로젝트 서비스 계정 키 경로")
    parser.add_argument("--dest-credentials", required=True, help="대상(개인) 프로젝트 서비스 계정 키 경로")
    parser.add_argument("--source-bucket", default=DEFAULT_SOURCE_BUCKET, help="소스 Storage 버킷")
    parser.add_argument("--dest-bucket", required=True, help="대상 Storage 버킷")
    parser.add_argument("--apply", action="store_true", help="실제로 이관한다(기본은 dry-run)")
    parser.add_argument("--force", action="store_true", help="대상에 이미 있는 문서도 다시 이관")
    parser.add_argument("--sample-count", type=int, default=3, help="dry-run 시 URL 변환 샘플 개수")
    args = parser.parse_args()

    source_cred = _load_credentials(args.source_credentials, "source-credentials", "SOURCE")
    dest_cred = _load_credentials(args.dest_credentials, "dest-credentials", "DEST")
    source_project = source_cred.project_id
    dest_project = dest_cred.project_id

    mode_label = "APPLY(실제 반영)" if args.apply else "DRY-RUN(쓰지 않음)"
    print("\n=== Firebase 마이그레이션 ===")
    print(f"SOURCE (읽기전용): {source_project}")
    print(f"DEST   (쓰기)     : {dest_project}")
    print(f"모드: {mode_label}")
    print("==============================\n")

    if source_project == dest_project:
        print("SOURCE와 DEST가 같은 프로젝트입니다 — 중단합니다.", file=sys.stderr)
        sys.exit(1)

    if args.apply:
        answer = input(
            f"SOURCE {source_project}(읽기) → DEST {dest_project}(쓰기) 방향으로 진행합니다.\n"
            f"방향이 맞다면 대상 프로젝트 id를 입력하세요 [{dest_project}]: "
        ).strip()
        if answer != dest_project:
            print("입력이 대상 프로젝트 id와 일치하지 않습니다 — 중단합니다.", file=sys.stderr)
            sys.exit(1)

    source_app = firebase_admin.initialize_app(
        source_cred, {"storageBucket": args.source_bucket}, name="source"
    )
    dest_app = firebase_admin.initialize_app(
        dest_cred, {"storageBucket": args.dest_bucket}, name="dest"
    )

    source_db = firestore.client(app=source_app)
    dest_db = firestore.client(app=dest_app)
    source_bucket = storage.bucket(app=source_app)
    dest_bucket = storage.bucket(app=dest_app)

    # ↓ source_db에 대한 호출은 여기 stream() 하나뿐이다 — 읽기 전용.
    docs = list(source_db.collection(WARDROBE_COL).stream())
    total = len(docs)
    print(f"[wardrobe] SOURCE 문서 {total}개 발견\n")

    audit = audit_image_fields(docs)
    print_field_audit(audit, total)

    if not args.apply:
        print_dry_run_samples(docs, args.dest_bucket, args.sample_count)

    counts = MigrationCounts()

    for i, doc in enumerate(docs, start=1):
        item_id = doc.id
        data = doc.to_dict() or {}

        if not args.force:
            # dest_db에 대한 읽기 — 재실행 시 이미 이관된 문서는 건너뛴다.
            existing = dest_db.collection(WARDROBE_COL).document(item_id).get()
            if existing.exists:
                counts.skipped_existing += 1
                print(f"[{i}/{total}] {item_id}: SKIP(대상에 이미 있음)")
                continue

        if not args.apply:
            counts.would_migrate += 1
            continue

        new_data, ok = migrate_doc(data, item_id, source_bucket, dest_bucket, args.dest_bucket, counts)
        if not ok:
            print(f"[{i}/{total}] {item_id}: FAIL(필수 이미지 이관 실패, 문서 안 씀)")
            continue

        try:
            # ↓ dest_db에 대한 유일한 쓰기 — 문서 id를 소스와 동일하게 유지한다.
            dest_db.collection(WARDROBE_COL).document(item_id).set(new_data)
            counts.migrated += 1
            print(f"[{i}/{total}] {item_id}: OK")
        except Exception as e:  # noqa: BLE001
            counts.write_failed += 1
            print(f"[{i}/{total}] {item_id}: FAIL(Firestore 쓰기 실패) — {e}")

    print("\n=== 완료 ===")
    if args.apply:
        print(f"문서 이관 성공: {counts.migrated}")
        print(f"문서 스킵(대상에 이미 있음): {counts.skipped_existing}")
        print(f"문서 실패(필수 이미지 이관 실패): {counts.failed_required_image}")
        print(f"문서 실패(Firestore 쓰기): {counts.write_failed}")
        print(f"이미지 없는 문서(메타데이터만 이관): {counts.no_image}")
        print(f"이미지 업로드 성공: {counts.images_uploaded_ok}")
        print(f"이미지 업로드 실패: {counts.images_uploaded_failed}")
    else:
        print(f"이관 예정(dry-run, 실제 반영 안 함): {counts.would_migrate}")
        print(f"스킵 예정(대상에 이미 있음): {counts.skipped_existing}")
        print(f"이미지 URL 필드 전혀 없는 문서: {len(audit.has_neither)}")
        print("\ndry-run입니다. 결과를 확인한 뒤 --apply를 붙여 다시 실행하면 실제로 반영됩니다.")


if __name__ == "__main__":
    main()
