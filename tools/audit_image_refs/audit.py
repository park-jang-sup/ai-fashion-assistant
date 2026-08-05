"""wardrobe/fitting_cache 문서가 가리키는 Storage 파일이 실제로 존재하는지
전수 검사한다. docs/task_signed_urls_v1.md 관문 A 조사(2026-08-06)에서
발견한 "고아 참조"(문서는 다운로드 URL을 갖고 있으나 Storage에 그 파일이
없는 경우, 예: wardrobe 3건)를 다시 찾아내려고 만든 재현 코드다 — 실측치는
저장소의 코드로 재현 가능해야 한다는 원칙(handoff 함정 28)의 적용.

**핵심 함정 — 다음 사람이 반드시 알아야 할 것**: Firebase Storage의 공개
다운로드 엔드포인트(.../o/{path}?alt=media&token=...)는 "토큰이 틀림"과
"객체가 아예 없음"을 구분하지 않고 **둘 다 403으로 응답한다**(열거 공격
방지가 목적으로 보인다). 그래서 이 스크립트가 공개 URL만 두드려 보고하는
403은 진짜 원인(권한 문제 vs 파일 부재)을 말해주지 않는다. 진짜 원인을
가르려면 --check-storage로 Admin SDK bucket.file(path).exists()를 직접
불러야 한다 — 이게 있어야 "403 = 파일 없음"이라고 성급히 결론 내리지
않는다(2026-08-06 실측: 403 3건 전부 exists()==False로 확인됐지만, 이건
매번 성립한다고 가정하면 안 된다).

개인 데이터 보호: 출력에 다운로드 토큰이 든 원본 URL을 그대로 찍지 않는다
— Storage 경로(토큰 없음)와 상태 코드만 남긴다.

읽기 전용 — 아무것도 쓰지 않아 몇 번을 실행해도 안전하다.

사용법:
    # 1. 기본 — 특정 사용자 소유 문서의 공개 URL만 두드려 상태 코드 집계
    python audit.py --credentials ~/secrets/personal-adminsdk.json \
        --owner-uid <uid>

    # 2. Storage 파일 존재까지 직접 대조(진짜 원인 판별, 서비스 계정에
    #    Storage 읽기 권한 필요)
    python audit.py --credentials ~/secrets/personal-adminsdk.json \
        --owner-uid <uid> --check-storage

    # 3. 특정 사용자로 좁히지 않고 컬렉션 전체(모든 소유자) 검사
    python audit.py --credentials ~/secrets/personal-adminsdk.json --all-owners

    # 4. fitting_cache까지 함께 검사
    python audit.py --credentials ~/secrets/personal-adminsdk.json \
        --owner-uid <uid> --collections wardrobe fitting_cache
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path
from urllib.parse import unquote

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

if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent

DEFAULT_BUCKET = "ai-fashion-assistant-personal.firebasestorage.app"

# 컬렉션별로 검사할 (필드명, 카테고리 표시용 필드) — 필드가 없는 문서는
# 조용히 건너뛴다(예: cutoutImageUrl은 배경 제거 안 한 아이템엔 없음 —
# 결함이 아니라 정상 상태).
COLLECTION_URL_FIELDS = {
    "wardrobe": ["imageUrl", "cutoutImageUrl"],
    "demo_wardrobe": ["imageUrl", "cutoutImageUrl"],
    "fitting_cache": ["imageUrl"],
}


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


# Firebase Storage 다운로드 URL(.../o/{encodedPath}?alt=media&token=...)에서
# 경로만 역산한다(토큰은 버린다) — functions/src/signed_url_policy.ts의
# pathFromDownloadUrl과 동일 규칙. 출력에 토큰이 남지 않게 하는 이유이기도 하다.
def path_from_download_url(url: str | None) -> str | None:
    if not url:
        return None
    match = re.search(r"/o/([^?]+)", url)
    if not match:
        return None
    try:
        return unquote(match.group(1))
    except Exception:
        return None


def check_public_url(url: str, timeout: float = 15.0) -> int | None:
    try:
        res = requests.head(url, timeout=timeout, allow_redirects=True)
        # 일부 CDN 경로가 HEAD를 지원하지 않아 405를 주는 경우가 있어
        # 그때만 GET으로 재시도한다 — 평소엔 HEAD로 충분(본문을 안 받는다).
        if res.status_code == 405:
            res = requests.get(url, timeout=timeout, stream=True)
        return res.status_code
    except requests.RequestException:
        return None


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--credentials", help="서비스 계정 키 경로(저장소 밖). 생략 시 GOOGLE_APPLICATION_CREDENTIALS 사용")
    parser.add_argument("--owner-uid", help="이 ownerUid 소유 문서만 검사(생략하고 --all-owners 안 주면 에러)")
    parser.add_argument("--all-owners", action="store_true", help="ownerUid로 좁히지 않고 컬렉션 전체 검사")
    parser.add_argument(
        "--collections", nargs="+", default=["wardrobe"],
        choices=list(COLLECTION_URL_FIELDS.keys()),
        help="검사할 컬렉션(기본: wardrobe만)",
    )
    parser.add_argument(
        "--check-storage", action="store_true",
        help="공개 URL이 403/404인 문서에 한해 Admin SDK로 파일 존재 여부까지 직접 확인",
    )
    parser.add_argument("--bucket", default=DEFAULT_BUCKET, help="Storage 버킷 이름")
    args = parser.parse_args()

    if not args.owner_uid and not args.all_owners:
        print("--owner-uid 또는 --all-owners 중 하나는 필요합니다.", file=sys.stderr)
        sys.exit(1)

    cred = _load_credentials(args.credentials)
    project_id = cred.project_id

    print("\n=== 이미지 참조 감사(audit_image_refs) ===")
    print(f"프로젝트: {project_id}")
    print(f"대상 컬렉션: {', '.join(args.collections)}")
    print(f"소유자 범위: {args.owner_uid if args.owner_uid else '전체'}")
    print(f"Storage 직접 대조: {'예' if args.check_storage else '아니오'}")
    print("==========================\n")

    app = firebase_admin.initialize_app(cred, {"storageBucket": args.bucket} if args.check_storage else None)
    db = firestore.client(app=app)
    bucket = storage.bucket(app=app) if args.check_storage else None

    total_checked = 0
    broken: list[dict] = []

    for collection in args.collections:
        fields = COLLECTION_URL_FIELDS[collection]
        query = db.collection(collection)
        if args.owner_uid:
            query = query.where("ownerUid", "==", args.owner_uid)
        docs = list(query.stream())
        print(f"[{collection}] {len(docs)}건 순회")

        for doc in docs:
            data = doc.to_dict() or {}
            for field in fields:
                url = data.get(field)
                if url is None:
                    continue  # 필드 자체가 없는 건 정상(예: 컷아웃 미보유)
                total_checked += 1
                status = check_public_url(url)
                if status == 200:
                    continue

                storage_path = path_from_download_url(url)
                entry = {
                    "collection": collection,
                    "id": doc.id,
                    "field": field,
                    "category": data.get("category"),
                    "status": status,
                    "path": storage_path,
                    "created_at": data.get("createdAt"),
                    "exists_in_storage": None,
                }
                if args.check_storage and storage_path:
                    try:
                        entry["exists_in_storage"] = bucket.blob(storage_path).exists()
                    except Exception as e:  # noqa: BLE001 — 진단 목적, 원인 그대로 남긴다
                        entry["exists_in_storage"] = f"확인 실패: {e}"
                broken.append(entry)

    print(f"\n총 검사한 URL: {total_checked}건")
    print(f"200이 아닌 것: {len(broken)}건\n")

    if not broken:
        print("전부 정상(200) — 고아 참조 없음.")
        return

    print("| 컬렉션 | 문서id | 필드 | 카테고리 | 상태코드 | 생성시각 | 경로 | Storage 존재 |")
    print("|---|---|---|---|---|---|---|---|")
    for e in broken:
        exists_display = e["exists_in_storage"]
        if exists_display is None:
            exists_display = "(--check-storage 안 씀)"
        print(
            f"| {e['collection']} | {e['id']} | {e['field']} | {e['category']} | "
            f"{e['status']} | {e['created_at']} | {e['path']} | {exists_display} |"
        )

    if args.check_storage:
        print(
            "\n주의: 위 상태코드가 403이어도 exists_in_storage==False면 진짜 원인은 "
            "'파일 없음'이지 권한 문제가 아니다(핵심 함정 참고, 스크립트 상단 docstring)."
        )


if __name__ == "__main__":
    main()
