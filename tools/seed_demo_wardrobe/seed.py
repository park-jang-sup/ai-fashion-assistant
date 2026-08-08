"""wardrobe 컬렉션에서 본인(ownerUid) 소유 문서를 demo_wardrobe로 복사한다.
docs/task_demo_ready_v2.md F′.1.3 규약.

demo_wardrobe는 심사·시연용 공개 읽기 전용 세트다(firestore.rules가
allow write: if false). 이 스크립트만 채운다 — 앱 코드는 여기 쓰지 않는다.

기본 동작은 dry-run — 대상 수, 카테고리별 분포, attributes/embedding 보유
수, 제외 목록, 삭제 대상만 보여준다. 실제로 쓰려면 --apply를 명시해야 한다.

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

[삭제 반영, 2026-08-08] 원본 wardrobe에서 지워진 문서를 demo_wardrobe
에서도 지운다 — 지금까지는 upsert만 해서, 원본을 지워도 demo_wardrobe
에는 고아로 남아 있었다(손상된 원본 5건이 바로 이 경로로 데모에 계속
남아 심사 계정 피팅 404를 재현시키고 있었다). --exclude와는 무관한
판정이다 — --exclude는 "이번 실행에서만 안 올린다"는 뜻이지 "원본에서
없어졌다"는 뜻이 아니므로, 삭제 판정은 항상 원본 wardrobe 전체(제외
목록 적용 전)를 기준으로 한다.

**Storage 객체는 이 삭제 경로에서 절대 안 지운다 — Firestore 문서만
지운다.** demo_wardrobe 문서는 원본과 같은 Storage 파일을 URL로
공유한다(COPIED_FIELDS가 imageUrl 문자열만 복사하지 파일 자체는 복사
안 함). 이 저장소는 바로 이 공유 구조 때문에 파일을 잘못 지워 전신
12건(원본 wardrobe 8 + demo_wardrobe 4)을 영구히 잃은 전례가 있다
(docs/task_signed_urls_v1.md §8-3). Firestore 문서만 지우면 그 위험이
없다 — 지운 문서가 참조하던 파일은 원본이 살아있으면 그대로 있고,
원본도 이미 죽은 파일(404)이었다면 어차피 못 되돌린다.

사용법:
    # 1. dry-run — 대상 수, 분포, 보유 수, 삭제 대상만 확인
    python seed.py --credentials ~/secrets/personal-adminsdk.json \\
        --owner-uid <본인 uid>

    # 2. 확인 후 실제 시드(+ 삭제 반영)
    python seed.py --credentials ~/secrets/personal-adminsdk.json \\
        --owner-uid <본인 uid> --apply

    # 3. 특정 아이템 제외
    python seed.py --credentials ~/secrets/personal-adminsdk.json \\
        --owner-uid <본인 uid> --apply --exclude <itemId1> --exclude <itemId2>

    # 4. 삭제 비율 상한 조정(기본 0.2 = 20%, 아래 --max-delete-ratio 설명 참고)
    python seed.py --credentials ~/secrets/personal-adminsdk.json \\
        --owner-uid <본인 uid> --apply --max-delete-ratio 0.1
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from collections import Counter
from datetime import datetime, timezone
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


def find_all_source_ids(db, owner_uid: str) -> set[str]:
    """ownerUid == owner_uid인 wardrobe 문서 id 전체 — --exclude 적용 전.
    삭제 판정(find_stale_demo_docs)은 이 전체 집합을 기준으로 해야 한다 —
    --exclude는 "이번엔 안 올린다"는 뜻이지 "원본에서 사라졌다"는 뜻이
    아니므로, --exclude된 아이템의 demo 사본을 삭제 대상으로 잘못
    판정하면 안 된다."""
    return {
        doc.id
        for doc in db.collection(WARDROBE_COL).where("ownerUid", "==", owner_uid).stream()
    }


def find_stale_demo_docs(db, source_ids: set[str]) -> list:
    """demo_wardrobe에는 있는데 원본 wardrobe(source_ids)에는 없는 문서 —
    원본에서 삭제된 항목의 demo 사본(삭제 대상 후보)."""
    stale = []
    for doc in db.collection(DEMO_WARDROBE_COL).stream():
        if doc.id not in source_ids:
            stale.append(doc)
    return stale


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


MANIFESTS_DIR = SCRIPT_DIR / "manifests"


def _write_delete_manifest(project_id: str, reason: str, stale_docs: list) -> Path:
    """삭제 전 문서 전문을 백업한다 — 롤백은 못 하지만(demo_wardrobe는
    삭제된 원본을 가리키던 문서일 수 있어 되살려도 무의미할 때가 많다)
    무엇이 왜 사라졌는지는 남긴다. tools/backfill_image_paths,
    tools/delete_orphaned_docs와 같은 형식."""
    MANIFESTS_DIR.mkdir(exist_ok=True)
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H-%M-%S-%fZ")[:-3] + "Z"
    manifest = {
        "createdAt": datetime.now(timezone.utc).isoformat(),
        "projectId": project_id,
        "reason": reason,
        "documents": [
            {
                "collection": DEMO_WARDROBE_COL,
                "id": doc.id,
                "data": doc.to_dict() or {},
            }
            for doc in stale_docs
        ],
    }
    path = MANIFESTS_DIR / f"delete_stale_demo_{timestamp}.json"
    path.write_text(json.dumps(manifest, indent=2, default=str, ensure_ascii=False), encoding="utf-8")
    return path


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
    # 기본값 0.2(20%)는 제안일 뿐 임의로 확정한 값이 아니다 — 후보:
    # 0.1(보수적, 알려진 손상 5건/118건=4.2%에 여유를 조금만 둠) /
    # 0.2(기본으로 잡음, 정상적인 정리 작업 정도는 통과시키되 대량
    # 이상은 막음) / 0.3(느슨, false positive를 더 줄이고 싶을 때).
    # 실제 운영 전 재검토 대상 — docs/handoff_2026-08-07.md 참고.
    parser.add_argument(
        "--max-delete-ratio",
        type=float,
        default=0.2,
        metavar="RATIO",
        help=(
            "삭제 대상이 demo_wardrobe 전체의 이 비율을 넘으면 --apply여도 "
            "아무것도 쓰지 않고 중단한다(기본 0.2). 제안값일 뿐이니 "
            "필요에 맞게 조정할 것"
        ),
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
    print(f"삭제 안전장치: 삭제 대상 비율이 {args.max_delete_ratio:.0%}를 넘으면 중단")
    print("==========================\n")

    app = firebase_admin.initialize_app(cred)
    db = firestore.client(app=app)

    excluded = set(args.exclude)
    docs = find_source_docs(db, args.owner_uid, excluded)
    summarize(docs)

    # ── 삭제 대상 판정: 원본에서 사라진 demo_wardrobe 문서.
    # --exclude와 무관하게 원본 전체(all_source_ids)를 기준으로 한다 —
    # --exclude는 "이번엔 안 올린다"는 뜻이지 "원본에서 없어졌다"는 뜻이
    # 아니므로, --exclude된 아이템의 demo 사본을 삭제 대상으로 잘못
    # 판정하면 안 된다(모듈 docstring 참고).
    all_source_ids = find_all_source_ids(db, args.owner_uid)
    stale_docs = find_stale_demo_docs(db, all_source_ids)
    demo_total = sum(1 for _ in db.collection(DEMO_WARDROBE_COL).stream())
    stale_ratio = (len(stale_docs) / demo_total) if demo_total > 0 else 0.0

    print("\n=== 삭제 대상(원본에서 없어진 demo_wardrobe 문서) ===")
    print(
        f"demo_wardrobe 총 {demo_total}건 중 {len(stale_docs)}건"
        f"({stale_ratio:.1%})이 원본에 대응 문서가 없다."
    )
    if stale_docs:
        for doc in sorted(stale_docs, key=lambda d: d.id):
            data = doc.to_dict() or {}
            print(
                f"  id={doc.id} category={data.get('category')} "
                f"subCategory={data.get('subCategory')}"
            )
    else:
        print("  없음.")

    if not docs:
        print("\n시드할 문서가 없습니다 — --owner-uid 값을 확인하세요.")
        return

    if not args.apply:
        print("\ndry-run입니다. 결과를 확인한 뒤 --apply로 다시 실행하면 실제로 반영됩니다.")
        return

    # ── 안전장치: 삭제 비율이 상한을 넘으면 upsert도 포함해 전부 중단.
    # 삭제 대상이 비정상적으로 많다는 건 --owner-uid 오타나
    # wardrobe.ownerUid 필드 이상 같은 근본 문제의 신호일 수 있어,
    # 그 상태로 upsert까지 진행하면 잘못된 데이터가 같이 실릴 위험이
    # 있다 — 통째로 멈추고 사람이 보게 한다.
    if demo_total > 0 and stale_ratio > args.max_delete_ratio:
        print(
            f"\n삭제 대상 비율({stale_ratio:.1%})이 상한(--max-delete-ratio="
            f"{args.max_delete_ratio:.0%})을 넘습니다 — upsert·삭제 전부 "
            f"중단합니다.\n원본 조회(--owner-uid={args.owner_uid})가 맞는지, "
            f"wardrobe의 ownerUid 필드가 의도치 않게 바뀌지 않았는지 먼저 "
            f"확인하세요.",
            file=sys.stderr,
        )
        sys.exit(1)

    answer = input(
        f"\n프로젝트 {project_id}의 demo_wardrobe에 {len(docs)}건을 쓰고, "
        f"{len(stale_docs)}건을 지웁니다(Firestore 문서만 — Storage 파일은 "
        f"절대 안 지웁니다).\n진행하려면 대상 프로젝트 id를 입력하세요 "
        f"[{project_id}]: "
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

    # ── 삭제 반영: Firestore 문서만 지운다. Storage 객체는 이 스크립트
    # 어디서도 건드리지 않는다(모듈 docstring의 이유 참고 — 파일 공유
    # 구조 때문에 전신 12건을 잃은 전례가 있다) ──
    deleted = 0
    if stale_docs:
        manifest_path = _write_delete_manifest(
            project_id,
            f"원본 wardrobe(ownerUid={args.owner_uid})에서 삭제된 문서의 "
            f"demo_wardrobe 사본 정리 — Firestore 문서만, Storage 파일 미삭제",
            stale_docs,
        )
        print(f"삭제 전 manifest 기록: {manifest_path}")
        batch = db.batch()
        batch_count = 0
        for doc in stale_docs:
            batch.delete(db.collection(DEMO_WARDROBE_COL).document(doc.id))
            batch_count += 1
            deleted += 1
            if batch_count >= BATCH_LIMIT:
                batch.commit()
                batch = db.batch()
                batch_count = 0
        if batch_count > 0:
            batch.commit()
        print(f"삭제 완료: {deleted}건(Firestore 문서만, Storage 파일 미삭제)")

    # ── 검증 ──
    demo_count = sum(1 for _ in db.collection(DEMO_WARDROBE_COL).stream())
    print(
        f"\n=== 검증 ===\ndemo_wardrobe 총 문서 수: {demo_count}건 "
        f"(시드 {written}건, 삭제 {deleted}건 반영 후)"
    )


if __name__ == "__main__":
    main()
