"""wardrobe 컬렉션에서 본인(ownerUid) 소유 문서를 demo_wardrobe로 복사한다.
docs/task_demo_ready_v2.md F′.1.3 규약.

demo_wardrobe는 심사·시연용 공개 읽기 전용 세트다(firestore.rules가
allow write: if false). 이 스크립트만 채운다 — 앱 코드는 여기 쓰지 않는다.

기본 동작은 dry-run — 대상 수, 카테고리별 분포, attributes/embedding 보유
수, 제외 목록만 보여준다. 실제로 쓰려면 --apply를 명시해야 한다.

서비스 계정 키는 --credentials 또는 GOOGLE_APPLICATION_CREDENTIALS로만
받고, 이 저장소 안의 경로는 거부한다(tools/backfill_owner_uid와 동일 규약).

118벌 전량이 기본이다 — 일부만 골라 넣지 않는다. 제외하고 싶은 아이템은
--exclude <itemId>를 여러 번 줘서 처리한다(큐레이션이 아니라 단순 제외).

createdAt은 원본 값을 그대로 옮긴다 — Firestore Timestamp가 그대로
복사되며 serverTimestamp()로 재부여하지 않는다. 옷장 순회 순서가 동점
정렬을 결정하므로, 시각을 바꾸면 같은 옷장인데도 앱에서 다른 추천이 나온다.

demo_wardrobe 문서 id는 원본 wardrobe 문서 id를 그대로 쓴다 — 재실행해도
같은 문서를 덮어쓸 뿐이라 안전하고(idempotent) 추적이 쉽다. (앱 쪽
FirestoreService.seedDemoWardrobe가 demo_wardrobe -> wardrobe로 복사할
때는 반대로 새 id를 발급한다 — 여러 심사위원이 각자의 wardrobe에 시드할
때 충돌을 피하기 위함으로, 이 스크립트의 관심사가 아니다.)

사용법:
    # 1. dry-run — 대상 수, 분포, 보유 수만 확인
    python seed.py --credentials ~/secrets/personal-adminsdk.json \\
        --owner-uid <본인 uid>

    # 2. 확인 후 실제 시드
    python seed.py --credentials ~/secrets/personal-adminsdk.json \\
        --owner-uid <본인 uid> --apply

    # 3. 특정 아이템 제외
    python seed.py --credentials ~/secrets/personal-adminsdk.json \\
        --owner-uid <본인 uid> --apply --exclude <itemId1> --exclude <itemId2>
"""
from __future__ import annotations

import argparse
import os
import sys
from collections import Counter
from pathlib import Path

try:
    import firebase_admin
    from firebase_admin import credentials, firestore
except ImportError:
    print("firebase-admin이 설치되어 있지 않습니다: pip install -r requirements.txt", file=sys.stderr)
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
DEMO_WARDROBE_COL = "demo_wardrobe"
BATCH_LIMIT = 400  # Firestore 배치 쓰기 최대 500건, 여유를 둔다.
COPIED_FIELDS = (
    "imageUrl",
    "cutoutImageUrl",
    "category",
    "subCategory",
    "attributes",
    "size",
    "embedding",
    "createdAt",
)


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


def find_source_docs(db, owner_uid: str, excluded: set[str]) -> list:
    """ownerUid == owner_uid인 wardrobe 문서 중 제외 목록에 없는 것만 반환."""
    docs = []
    for doc in db.collection(WARDROBE_COL).where("ownerUid", "==", owner_uid).stream():
        if doc.id in excluded:
            continue
        docs.append(doc)
    return docs


def summarize(docs: list) -> None:
    """개수·카테고리별 분포·attributes/embedding 보유 수를 출력한다.
    이 출력이 사업계획서에 그대로 들어갈 수치다(F′.1.3)."""
    category_counts: Counter = Counter()
    attrs_count = 0
    embedding_count = 0
    for doc in docs:
        data = doc.to_dict() or {}
        category_counts[data.get("category", "(없음)")] += 1
        if data.get("attributes") is not None:
            attrs_count += 1
        if data.get("embedding") is not None:
            embedding_count += 1

    print(f"총 대상: {len(docs)}건")
    print("카테고리별 분포:")
    for cat, count in sorted(category_counts.items(), key=lambda kv: -kv[1]):
        print(f"  {cat}: {count}건")
    print(f"attributes 보유: {attrs_count}건")
    print(f"embedding 보유: {embedding_count}건")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--credentials",
        help="서비스 계정 키 경로(저장소 밖). 생략 시 GOOGLE_APPLICATION_CREDENTIALS 사용",
    )
    parser.add_argument("--owner-uid", required=True, help="원본 wardrobe의 ownerUid(본인 uid)")
    parser.add_argument("--apply", action="store_true", help="실제로 반영한다(기본은 dry-run)")
    parser.add_argument(
        "--exclude",
        action="append",
        default=[],
        metavar="ITEM_ID",
        help="데모 세트에서 제외할 wardrobe 문서 id. 여러 번 지정 가능",
    )
    args = parser.parse_args()

    cred = _load_credentials(args.credentials)
    project_id = cred.project_id

    mode_label = "APPLY(실제 반영)" if args.apply else "DRY-RUN(쓰지 않음)"
    print("\n=== demo_wardrobe 시드 ===")
    print(f"프로젝트: {project_id}")
    print(f"모드: {mode_label}")
    if args.exclude:
        print(f"제외 목록: {', '.join(args.exclude)}")
    print("==========================\n")

    app = firebase_admin.initialize_app(cred)
    db = firestore.client(app=app)

    excluded = set(args.exclude)
    docs = find_source_docs(db, args.owner_uid, excluded)
    summarize(docs)

    if not docs:
        print("\n시드할 문서가 없습니다 — --owner-uid 값을 확인하세요.")
        return

    if not args.apply:
        print("\ndry-run입니다. 결과를 확인한 뒤 --apply로 다시 실행하면 실제로 반영됩니다.")
        return

    answer = input(
        f"\n프로젝트 {project_id}의 demo_wardrobe에 {len(docs)}건을 씁니다.\n"
        f"진행하려면 대상 프로젝트 id를 입력하세요 [{project_id}]: "
    ).strip()
    if answer != project_id:
        print("입력이 대상 프로젝트 id와 일치하지 않습니다 — 중단합니다.", file=sys.stderr)
        sys.exit(1)

    written = 0
    batch = db.batch()
    batch_count = 0
    for doc in docs:
        data = doc.to_dict() or {}
        payload = {field: data[field] for field in COPIED_FIELDS if field in data}
        # demo_wardrobe 문서 id는 원본 wardrobe 문서 id를 그대로 쓴다 —
        # 재실행해도 같은 문서를 덮어쓸 뿐이라 안전하다(idempotent).
        batch.set(db.collection(DEMO_WARDROBE_COL).document(doc.id), payload)
        batch_count += 1
        written += 1
        if batch_count >= BATCH_LIMIT:
            batch.commit()
            print(f"  ... {written}/{len(docs)}건 커밋")
            batch = db.batch()
            batch_count = 0
    if batch_count > 0:
        batch.commit()
    print(f"\n시드 완료: {written}건 기록")

    # ── 검증 ──
    demo_count = sum(1 for _ in db.collection(DEMO_WARDROBE_COL).stream())
    print(f"\n=== 검증 ===\ndemo_wardrobe 총 문서 수: {demo_count}건")


if __name__ == "__main__":
    main()
